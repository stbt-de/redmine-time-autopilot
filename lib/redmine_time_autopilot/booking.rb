# frozen_string_literal: true

module RedmineTimeAutopilot
  # Bucht, was in einer Woche bereit ist: je Tag und Ticket eine normale
  # Zeitbuchung (Kommentar aus den Zusammenfassungen), mit Redmines Rechten.
  # Fehlt das Ticket des Monats, wird es dabei angelegt. Was nicht geht,
  # bleibt als Entwurf stehen und wird gemeldet.
  class Booking
    Failure = Struct.new(:entry, :message, keyword_init: true)

    attr_reader :booked, :failures, :created_issues

    def initialize(user, week)
      @user = user
      @week = week
      @booked = []
      @failures = []
      @created_issues = []
    end

    # hours: { entry.key => "1,5" } – geänderte Stunden aus dem Formular;
    # 0 heißt: nicht buchen
    def call(hours: {}, keys: nil)
      created = {}
      @week.entries.each do |entry|
        next if keys && !keys.include?(entry.key)

        book(entry, hours_for(entry, hours), created)
      end
      self
    end

    def booked_hours
      booked.sum(&:hours)
    end

    private

    def book(entry, hours, created)
      draft_ids = entry.drafts.map(&:id)
      if hours <= 0
        TimeAutopilotDraft.where(id: draft_ids).update_all(status: 'skipped', updated_at: Time.current)
        return
      end

      TimeEntry.transaction do
        issue = entry.issue || created[entry.resolution.key] ||= create_issue(entry)
        raise BookingError, ::I18n.t(:error_time_autopilot_not_allowed, project: issue.project.name) unless @user.allowed_to?(:log_time, issue.project)

        time_entry = TimeEntry.new(project: issue.project, issue: issue, user: @user, author: @user,
                                   spent_on: entry.date, hours: hours,
                                   activity_id: activity_id(entry, issue),
                                   comments: entry.comments.truncate(1024))
        time_entry.save!
        TimeAutopilotDraft.where(id: draft_ids).update_all(status: 'booked', time_entry_id: time_entry.id, updated_at: Time.current)
        @booked << time_entry
      end
    rescue BookingError, ActiveRecord::RecordInvalid => e
      created.delete(entry.resolution.key) if entry.to_create?
      @failures << Failure.new(entry: entry, message: e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.to_sentence : e.message)
    end

    def create_issue(entry)
      issue = MonthlyIssue.new(@user, entry.rule).create!(entry.date)
      @created_issues << issue
      issue
    end

    def activity_id(entry, issue)
      activities = issue.project.activities.to_a
      chosen = entry.rule&.activity_id && activities.detect { |activity| activity.id == entry.rule.activity_id }
      (chosen || activities.detect(&:is_default) || activities.first)&.id
    end

    def hours_for(entry, overrides)
      value = overrides[entry.key]
      return entry.hours.to_f if value.blank?

      parsed = value.to_s.strip.to_hours
      parsed.is_a?(Numeric) ? parsed.to_f.clamp(0, 24) : entry.hours.to_f
    end
  end
end
