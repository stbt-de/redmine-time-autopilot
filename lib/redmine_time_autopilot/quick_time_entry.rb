# frozen_string_literal: true

module RedmineTimeAutopilot
  # Daten für "Zeit buchen": Ticketsuche, zuletzt gebuchte Tickets,
  # Tätigkeiten, heute gebuchte Stunden. Gebucht wird nur auf sichtbare,
  # offene Tickets in Projekten, in denen der Benutzer Aufwand buchen darf.
  class QuickTimeEntry
    SEARCH_LIMIT = 8
    RECENT_LIMIT = 5

    def initialize(user)
      @user = user
    end

    def loggable_issues
      Issue.visible(@user).open
           .joins(:project)
           .where(Project.allowed_to_condition(@user, :log_time))
    end

    def allowed?
      Project.where(Project.allowed_to_condition(@user, :log_time)).exists?
    end

    # Suche über Nummer ("#123", "123"), Titel und Projektname; jedes Wort
    # muss vorkommen. Mir zugewiesene Tickets zuerst, dann zuletzt geändert.
    def search(query)
      query = query.to_s.strip
      return [] if query.empty?

      scope = loggable_issues.includes(:project, :tracker)
      if query =~ /\A#?(\d+)\z/
        by_id = scope.find_by(id: Regexp.last_match(1).to_i)
        return [by_id].compact + matching(scope, query).where.not(id: by_id&.id).limit(SEARCH_LIMIT - 1).to_a
      end

      matching(scope, query).limit(SEARCH_LIMIT).to_a
    end

    # Zuletzt bebuchte Tickets des Benutzers (nur noch buchbare)
    def recent_issues
      ids = TimeEntry.where(user_id: @user.id).where.not(issue_id: nil)
                     .order(spent_on: :desc, created_on: :desc).limit(50).pluck(:issue_id).uniq
      issues = loggable_issues.includes(:project).where(id: ids).index_by(&:id)
      ids.filter_map { |id| issues[id] }.first(RECENT_LIMIT)
    end

    # Tätigkeiten ohne Projektbezug, bis ein Ticket gewählt ist
    def default_activities
      TimeEntryActivity.shared.active.sorted
    end

    def today_hours
      TimeEntry.where(user_id: @user.id, spent_on: @user.today).sum(:hours).to_f
    end

    private

    def matching(scope, query)
      words = query.split(/\s+/).first(5)
      words.inject(scope) do |result, word|
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(word.downcase)}%"
        result.where(
          "LOWER(#{Issue.table_name}.subject) LIKE :pattern OR LOWER(#{Project.table_name}.name) LIKE :pattern",
          pattern: pattern
        )
      end.reorder(
        Arel.sql(ActiveRecord::Base.sanitize_sql_array(
          ["CASE WHEN #{Issue.table_name}.assigned_to_id IN (?) THEN 0 ELSE 1 END", ([@user.id] + @user.group_ids)]
        )),
        "#{Issue.table_name}.updated_on DESC"
      )
    end
  end
end
