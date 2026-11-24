# frozen_string_literal: true

module RedmineTimeAutopilot
  # Wochenbeginn nach Redmines Einstellung „Woche beginnt am“ (leer: Sprache
  # des Benutzers); 1 = Montag … 7 = Sonntag
  module Calendar
    module_function

    def week_start(date)
      first = Setting.start_of_week.presence || ::I18n.t(:general_first_day_of_week, default: '1')
      date - ((date.cwday - first.to_i) % 7)
    end
  end
end
