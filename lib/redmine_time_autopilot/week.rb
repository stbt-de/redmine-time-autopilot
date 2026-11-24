# frozen_string_literal: true

module RedmineTimeAutopilot
  # Eine Woche einer Person: Tage mit Stunden, offene Fragen (Ordner ohne
  # Zuordnung) und was bereit zum Buchen ist – je Tag und Ticket
  # zusammengefasst.
  class Week
    Day = Struct.new(:date, :hours, :booked_hours, :ready_hours, :logged_hours, :question_count, :target, keyword_init: true) do
      def open?
        question_count.positive?
      end
    end

    Question = Struct.new(:folder, :drafts, :resolutions, keyword_init: true) do
      def hours
        drafts.sum(&:hours)
      end

      def dates
        drafts.map(&:spent_on).uniq.sort
      end

      def summaries
        drafts.map(&:summary).compact_blank.uniq
      end

      def guesses
        resolutions.select { |resolution| resolution.kind == :guess }.map(&:issue).uniq
      end
    end

    Entry = Struct.new(:date, :resolution, :drafts, keyword_init: true) do
      delegate :issue, :rule, :planned_subject, :to_create?, to: :resolution

      def key
        "#{date.iso8601}-#{resolution.key}"
      end

      # Auf Viertelstunden gerundet (mindestens 0,25): Agents liefern viele
      # kleine Abschnitte mit krummen Minuten
      def hours
        exact = drafts.sum(&:hours).to_f
        exact.positive? ? [(exact * 4).round / 4.0, 0.25].max : 0.0
      end

      def comments
        drafts.map(&:summary).compact_blank.uniq.join('; ')
      end

      def project
        issue&.project || rule&.project
      end
    end

    attr_reader :user, :start

    def initialize(user, week: nil, today: nil)
      @user = user
      @today = today || user.today
      @start = monday(parse(week) || default_date)
    end

    def finish
      start + 6
    end

    def range
      start..finish
    end

    def previous_week
      start - 7
    end

    def next_week
      start + 7
    end

    def label
      "KW #{start.cweek}"
    end

    def range_label
      "#{start.strftime('%-d.%-m.')}–#{finish.strftime('%-d.%-m.')}"
    end

    def drafts
      @drafts ||= TimeAutopilotDraft.for_user(user).within(range).order(:spent_on, :started_at, :id).to_a
    end

    def pending
      drafts.select(&:pending?)
    end

    def resolver
      @resolver ||= Resolver.new(user)
    end

    def resolutions
      @resolutions ||= pending.index_with { |draft| resolver.resolve(draft) }
    end

    def questions
      @questions ||= resolutions.select { |_, resolution| resolution.question? }
                                .group_by { |draft, _| draft.folder }
                                .map { |folder, pairs| Question.new(folder: folder, drafts: pairs.map(&:first), resolutions: pairs.map(&:last)) }
                                .sort_by { |question| -question.hours }
    end

    def entries
      @entries ||= resolutions.select { |_, resolution| resolution.ready? }
                              .group_by { |draft, resolution| [draft.spent_on, resolution.key] }
                              .map { |(date, _), pairs| Entry.new(date: date, resolution: pairs.first.last, drafts: pairs.map(&:first)) }
                              .sort_by { |entry| [entry.date, -entry.hours] }
    end

    def entries_by_day
      entries.group_by(&:date)
    end

    def skipped_hours
      resolutions.select { |_, resolution| resolution.skip? }.sum { |draft, _| draft.hours } +
        drafts.select { |draft| draft.status == 'skipped' }.sum(&:hours)
    end

    def total_hours
      drafts.sum(&:hours)
    end

    def booked_hours
      drafts.select { |draft| draft.status == 'booked' }.sum(&:hours)
    end

    def days
      @days ||= range.map do |date|
        on_day = drafts.select { |draft| draft.spent_on == date }
        Day.new(date: date,
                hours: on_day.sum(&:hours),
                booked_hours: on_day.select { |draft| draft.status == 'booked' }.sum(&:hours),
                ready_hours: entries.select { |entry| entry.date == date }.sum(&:hours),
                logged_hours: logged_hours_on(date),
                question_count: questions.count { |question| question.dates.include?(date) },
                target: target_for(date))
      end
    end

    # Tagesziel aus der Arbeitszeit der Person (Mein Konto)
    def target_for(date)
      @schedule = WorkSchedule.new(user).hours unless defined?(@schedule)
      @schedule && @schedule[date.cwday]
    end

    # Absender der Woche: Name, Abschnitte, Ordner, zuletzt übertragen
    Source = Struct.new(:name, :segments, :folders, :uploaded_at, keyword_init: true)

    def sources
      @sources ||= drafts.group_by(&:source_name).map do |name, list|
        Source.new(name: name, segments: list.size, folders: list.map(&:folder).uniq.size,
                   uploaded_at: TimeAutopilotDraft.for_user(user).where(source: list.first.source).maximum(:updated_at))
      end
    end

    # Zeitbuchungen der Person in dieser Woche (von Hand und aus Vorschlägen)
    def time_entries
      @time_entries ||= TimeEntry.where(user_id: user.id, spent_on: range).includes(:issue, :project)
                                 .order(:spent_on, :id).to_a
    end

    def logged_hours_on(date)
      time_entries.select { |entry| entry.spent_on == date }.sum(&:hours).to_f
    end

    def logged_hours
      time_entries.sum(&:hours).to_f
    end

    def ready_hours
      entries.sum(&:hours).to_f
    end

    def target_hours
      range.sum { |date| target_for(date).to_f }
    end

    # Ticket-Vorschläge für Fragen: Vermutungen, dann Tickets, auf die die
    # Person zuletzt am meisten gebucht hat
    def suggestions_for(question)
      recent = TimeEntry.where(user_id: user.id).where(spent_on: (@today - 60)..@today).where.not(issue_id: nil)
                        .group(:issue_id).order(Arel.sql('SUM(hours) DESC')).limit(8).pluck(:issue_id)
      issues = Issue.visible(user).open.where(id: recent).index_by(&:id)
      (question.guesses + recent.filter_map { |id| issues[id] }).uniq.first(4)
    end

    private

    # Ohne Angabe: die älteste Woche mit offenen Entwürfen (bis 8 Wochen
    # zurück), sonst die laufende
    def default_date
      TimeAutopilotDraft.for_user(user).pending.where(spent_on: (@today - 56)..@today).minimum(:spent_on) || @today
    end

    def monday(date)
      date - (date.cwday - 1)
    end

    def parse(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end
  end
end
