# frozen_string_literal: true

module RedmineTimeAutopilot
  # Das Ticket des Monats einer Zuordnung, z. B. „Wartung November 2026“.
  #
  # Gefunden wird ein offenes Ticket im Projekt, dessen Betreff den Begriff
  # enthält und das am Tag läuft: Beginn und Abgabedatum umfassen den Tag,
  # oder – ohne Daten – der Betreff nennt den Monat („November 2026“).
  # Fehlt es, kann es aus dem Ticket des Vormonats angelegt werden.
  class MonthlyIssue
    LOCALES = %i[de en].freeze

    attr_reader :rule

    def initialize(user, rule)
      @user = user
      @rule = rule
    end

    def project
      rule.project
    end

    def find(date)
      candidates.reject(&:closed?).select { |issue| covers?(issue, date) }
                .max_by { |issue| [issue.start_date || Date.new(1970), issue.id] }
    end

    # Letztes Ticket vor dem Monat: Vorlage für das neue
    def template_for(date)
      first = date.beginning_of_month
      candidates.select { |issue| (issue.start_date || issue.created_on.to_date) < first }
                .max_by { |issue| [issue.start_date || issue.created_on.to_date, issue.id] }
    end

    # Betreff des neuen Tickets: der Vormonat im Betreff wird ersetzt
    # („Wartung Oktober 2026“ → „Wartung November 2026“), sonst angehängt
    def planned_subject(date)
      base = template_for(date)&.subject || rule.subject_term.to_s
      LOCALES.each do |locale|
        names = month_names(locale)
        pattern = /\b(#{names.map { |name| Regexp.escape(name) }.join('|')})(\s+)(\d{4})\b/i
        next unless base.match?(pattern)

        return base.sub(pattern) { "#{names[date.month - 1]}#{Regexp.last_match(2)}#{date.year}" }
      end
      "#{base} #{month_names(default_locale)[date.month - 1]} #{date.year}".strip
    end

    def can_create?
      project.present? && @user.allowed_to?(:add_issues, project)
    end

    # Legt das Ticket an (Kopie der Vorlage ohne Anhänge, Unteraufgaben und
    # Beobachter, Laufzeit der ganze Monat) und schließt auf Wunsch die Vorlage
    def create!(date)
      raise BookingError, ::I18n.t(:error_time_autopilot_cannot_create_issue, project: project&.name.to_s) unless can_create?

      template = template_for(date)
      issue = Issue.new
      issue.copy_from(template, attachments: false, subtasks: false, watchers: false, link: false) if template
      issue.project = project
      issue.tracker = template&.tracker || project.trackers.sorted.first
      issue.author = @user
      issue.subject = planned_subject(date)
      issue.start_date = date.beginning_of_month
      issue.due_date = date.end_of_month
      issue.status = issue.tracker.default_status
      issue.done_ratio = 0
      issue.priority ||= IssuePriority.default || IssuePriority.active.first
      issue.parent_issue_id = template&.parent_id
      issue.save!
      close(template) if rule.close_previous && template && !template.closed?
      issue
    end

    private

    def candidates
      @candidates ||= begin
        term = rule.subject_term.to_s.strip.downcase
        scope = Issue.visible(@user).where(project_id: rule.project_id)
        scope = scope.where('LOWER(subject) LIKE ?', "%#{Issue.sanitize_sql_like(term)}%") if term.present?
        scope.includes(:status).to_a
      end
    end

    def covers?(issue, date)
      if issue.start_date && issue.due_date
        (issue.start_date..issue.due_date).cover?(date)
      else
        names_month?(issue.subject, date)
      end
    end

    def names_month?(subject, date)
      LOCALES.any? do |locale|
        subject.match?(/\b#{Regexp.escape(month_names(locale)[date.month - 1])}\s+#{date.year}\b/i)
      end || subject.match?(/\b(#{date.year}-#{format('%02d', date.month)}|#{format('%02d', date.month)}\/#{date.year})\b/)
    end

    def month_names(locale)
      ::I18n.t('date.month_names', locale: locale).compact
    end

    def default_locale
      locale = Setting.default_language.to_s.split('-').first&.to_sym
      LOCALES.include?(locale) ? locale : :en
    end

    def close(template)
      status = template.new_statuses_allowed_to(@user).detect(&:is_closed?)
      return unless status

      template.init_journal(@user)
      template.status = status
      template.save
    end
  end
end
