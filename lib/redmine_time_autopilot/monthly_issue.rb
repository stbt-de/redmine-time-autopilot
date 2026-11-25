# frozen_string_literal: true

module RedmineTimeAutopilot
  # Das Ticket des Monats einer Zuordnung, z. B. „Nordlicht - 2026 - November“.
  #
  # Der Betreff kommt aus der Vorlage der Zuordnung (SubjectTemplate). Gefunden
  # wird das offene Ticket im Projekt mit genau diesem Betreff – oder eines,
  # dessen Betreff zur Vorlage passt und dessen Beginn und Abgabedatum den Tag
  # umfassen. Fehlt es, kann es angelegt werden; Tracker, Zuweisung,
  # Beschreibung und Schätzung kommen dann vom Ticket des Vormonats.
  class MonthlyIssue
    attr_reader :rule

    def initialize(user, rule)
      @user = user
      @rule = rule
    end

    def project
      rule.project
    end

    def template
      @template ||= SubjectTemplate.new(rule.subject_template, project: project, locale: rule.month_locale)
    end

    def find(date)
      open = candidates.reject(&:closed?)
      open.detect { |issue| template.same?(issue.subject, date) } ||
        open.select { |issue| runs_on?(issue, date) && template.matches?(issue.subject) }.max_by(&:id)
    end

    # Ticket des Monats gibt es, ist aber geschlossen – dann kein zweites anlegen
    def closed_for?(date)
      candidates.any? { |issue| issue.closed? && template.same?(issue.subject, date) }
    end

    def planned_subject(date)
      template.render(date)
    end

    # Vorlage für das neue Ticket: das des Vormonats, sonst das letzte
    # Monatsticket davor
    def template_for(date)
      candidates.detect { |issue| template.same?(issue.subject, date.prev_month) } ||
        candidates.select { |issue| template.matches?(issue.subject) && started(issue) < date.beginning_of_month }
                  .max_by { |issue| [started(issue), issue.id] }
    end

    def can_create?
      project.present? && @user.allowed_to?(:add_issues, project)
    end

    # Legt das Ticket an (Kopie der Vorlage ohne Anhänge, Unteraufgaben und
    # Beobachter, Laufzeit der ganze Monat) und schließt auf Wunsch die Vorlage
    def create!(date)
      raise BookingError, ::I18n.t(:error_time_autopilot_cannot_create_issue, project: project&.name.to_s) unless can_create?

      previous = template_for(date)
      issue = Issue.new
      issue.copy_from(previous, attachments: false, subtasks: false, watchers: false, link: false) if previous
      issue.project = project
      issue.tracker = previous&.tracker || project.trackers.sorted.first
      issue.author = @user
      issue.subject = planned_subject(date)
      issue.start_date = date.beginning_of_month
      issue.due_date = date.end_of_month
      issue.status = issue.tracker.default_status
      issue.done_ratio = 0
      issue.priority ||= IssuePriority.default || IssuePriority.active.first
      issue.parent_issue_id = previous&.parent_id
      issue.save!
      close(previous) if rule.close_previous && previous && !previous.closed?
      @candidates = nil
      issue
    end

    private

    def candidates
      @candidates ||= begin
        scope = Issue.visible(@user).where(project_id: rule.project_id)
        fixed = template.fixed_part.downcase
        scope = scope.where('LOWER(subject) LIKE ?', "%#{Issue.sanitize_sql_like(fixed)}%") if fixed.present?
        scope.includes(:status).to_a
      end
    end

    def runs_on?(issue, date)
      issue.start_date && issue.due_date && (issue.start_date..issue.due_date).cover?(date)
    end

    def started(issue)
      issue.start_date || issue.created_on.to_date
    end

    def close(previous)
      status = previous.new_statuses_allowed_to(@user).detect(&:is_closed?)
      return unless status

      previous.init_journal(@user)
      previous.status = status
      previous.save
    end
  end
end
