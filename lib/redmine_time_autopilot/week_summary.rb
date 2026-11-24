# frozen_string_literal: true

module RedmineTimeAutopilot
  # "Wochenstunden" (Block my_week): gebuchte Stunden einer Woche je Tag, Summe gegen ein
  # Wochenziel. Wahlweise für einen anderen Benutzer, dessen Zeiten der
  # Betrachter sehen darf, und für frühere oder spätere Wochen.
  #
  # Ziel und Arbeitstage kommen aus der Arbeitszeit der Person (WorkSchedule:
  # Stunden je Wochentag). Ist keine eingestellt, gilt das Wochenziel des
  # Blocks, gleich verteilt auf Redmines Arbeitstage ("Arbeitsfreie Tage").
  # Wurde an einem freien Tag gebucht, erscheinen alle freien Tage der Woche
  # (Samstag und Sonntag gemeinsam, nicht nur der eine).
  class WeekSummary
    Day = Struct.new(:date, :hours, :target, :today, keyword_init: true)

    DEFAULT_TARGET = 40

    attr_reader :target, :viewer, :user

    # Benutzer, deren Woche der Betrachter wählen kann: er selbst und alle
    # aktiven Mitglieder der Projekte, in denen er Aufwände sehen darf
    # (Admins: alle aktiven Benutzer). Welche Buchungen er sieht, entscheidet
    # danach TimeEntry.visible – bei Rollen mit "nur eigene" bleibt es leer.
    def self.selectable_users(viewer)
      users = User.active
      unless viewer.admin?
        projects = Project.where(Project.allowed_to_condition(viewer, :view_time_entries))
        users = users.where(id: Member.where(project_id: projects.select(:id)).select(:user_id))
                     .or(User.active.where(id: viewer.id))
      end
      users.sorted.to_a.partition { |user| user.id == viewer.id }.flatten
    end

    # Gewählter Benutzer, wenn erlaubt – sonst der Betrachter selbst
    def self.resolve_user(viewer, user_id)
      return viewer if user_id.blank? || user_id.to_s == viewer.id.to_s

      selectable_users(viewer).detect { |user| user.id.to_s == user_id.to_s } || viewer
    end

    def initialize(viewer, target: nil, user: nil, date: nil)
      @viewer = viewer
      @user = user || viewer
      @date = parse_date(date) || viewer.today
      @schedule = WorkSchedule.new(@user).hours
      @schedule = nil unless @schedule&.values&.sum.to_f.positive?
      @target = @schedule ? @schedule.values.sum : target.to_s.tr(',', '.').to_f
      @target = DEFAULT_TARGET unless @target.positive?
    end

    # Ziel aus der Arbeitszeit der Person (nicht aus dem Block)?
    def scheduled?
      @schedule.present?
    end

    def start
      @start ||= Calendar.week_start(@date)
    end

    def finish
      start + 6
    end

    def previous_start
      start - 7
    end

    def next_start
      start + 7
    end

    def current?
      start == Calendar.week_start(@viewer.today)
    end

    def own?
      @user == @viewer
    end

    # Kalenderwoche nach ISO (der Donnerstag der Woche entscheidet)
    def number
      (start..finish).detect { |date| date.cwday == 4 }.cweek
    end

    def days
      @days ||= begin
        weekend = (start..finish).any? { |date| non_working?(date) && hours_by_day[date].to_f.positive? }
        (start..finish).filter_map do |date|
          next if non_working?(date) && !weekend

          Day.new(date: date, hours: hours_by_day[date].to_f, target: target_for(date), today: date == @viewer.today)
        end
      end
    end

    def total
      hours_by_day.values.sum.to_f
    end

    # Ziel eines Tages: laut Arbeitszeit, sonst das Wochenziel gleich verteilt
    def target_for(date)
      return @schedule[date.cwday] if @schedule
      return 0.0 if non_working?(date)

      working = (start..finish).count { |day| !non_working?(day) }
      working.positive? ? target / working : target
    end

    # Höchstes Tagesziel (für die Höhe der Balken)
    def daily_target
      (start..finish).map { |date| target_for(date) }.max.to_f
    end

    # Projekt mit den meisten Stunden in dieser Woche (nur sichtbare)
    def top_project
      project_id, hours = entries.group(:project_id).sum(:hours).max_by { |_id, sum| sum }
      return nil unless project_id

      project = Project.visible(@viewer).find_by(id: project_id)
      project && [project, hours.to_f]
    end

    private

    # Eigene Buchungen wie bisher; fremde nur, soweit Redmine sie zeigt
    def entries
      scope = own? ? TimeEntry.all : TimeEntry.visible(@viewer)
      scope.where(user_id: @user.id, spent_on: start..finish)
    end

    def hours_by_day
      @hours_by_day ||= entries.group(:spent_on).sum(:hours)
    end

    def non_working?(date)
      return @schedule[date.cwday] <= 0 if @schedule

      Array(Setting.non_working_week_days).map(&:to_i).include?(date.cwday)
    end

    def parse_date(value)
      return value if value.is_a?(Date)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
