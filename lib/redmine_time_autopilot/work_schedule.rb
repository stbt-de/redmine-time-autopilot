# frozen_string_literal: true

module RedmineTimeAutopilot
  # Arbeitszeit einer Person: Stunden je Wochentag (1 = Montag … 7 = Sonntag),
  # z. B. Mo–Do 8 h, Fr 4 h. Gilt für die Person, nicht für den Betrachter:
  # Wer die Woche einer Kollegin ansieht, sieht ihr Ziel. Liegt in den
  # Einstellungen der Person (UserPreference), ändern darf sie die Person
  # selbst und ein Admin.
  class WorkSchedule
    # Name aus der Zeit, als die Arbeitszeit zu Dashboard Blocks gehörte –
    # bleibt, damit eingetragene Werte erhalten bleiben
    PREFERENCE_KEY = :dashboard_blocks_work_hours
    DAYS = (1..7).freeze
    MAX_DAY_HOURS = 24

    def self.editable?(viewer, user)
      viewer.logged? && (viewer == user || viewer.admin?)
    end

    def initialize(user)
      @user = user
    end

    # Stunden je Wochentag oder nil, solange nichts eingestellt ist
    def hours
      stored = @user.pref[PREFERENCE_KEY]
      return nil unless stored.is_a?(Hash) && stored.any?

      DAYS.to_h { |cwday| [cwday, stored[cwday.to_s].to_f] }
    end

    def configured?
      hours.present? && hours.values.sum.positive?
    end

    # Werte aus dem Formular ("8", "7,5", leer = frei); ungültige werden 0,
    # alles über 24 h wird gekappt. Ohne eine einzige Stunde: Einstellung weg
    # (dann gilt wieder das Wochenziel des Blocks).
    def update(values)
      values = values.to_h.transform_keys(&:to_s)
      cleaned = DAYS.to_h do |cwday|
        value = values[cwday.to_s].to_s.tr(',', '.').to_f
        [cwday.to_s, value.clamp(0, MAX_DAY_HOURS)]
      end
      @user.pref[PREFERENCE_KEY] = cleaned.values.sum.positive? ? cleaned : nil
      @user.pref.save
    end
  end
end
