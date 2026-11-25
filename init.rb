# frozen_string_literal: true

# Time Autopilot – Zeiterfassung aus erfasster Arbeit für Redmine
#
# Ein Absender (z. B. ein lokales Skript, das Claude-Code-Sitzungen auswertet)
# lädt Arbeitsabschnitte als Entwürfe hoch: Tag, Stunden, Ordner, Branch,
# geänderte Dateien, Ticketnummern, kurze Zusammenfassung. Jede Person legt
# fest, wohin die Arbeit eines Ordners gebucht wird – auf ein Ticket, auf das
# Ticket des Monats oder gar nicht, mit Ausnahmen nach Dateien, Branch oder
# Begriff. Auf der Seite „Zeiten“ beantwortet sie offene Fragen und bucht die
# Woche als normale Zeitbuchungen. Dazu die Widgets „Zeit buchen“ und
# „Wochenstunden“ und die Arbeitszeit je Wochentag in „Mein Konto“.
#
# Daten liegen in eigenen Tabellen (time_autopilot_*); gebucht wird mit
# Redmines Rechten (Aufwand buchen, Tickets anlegen).

Redmine::Plugin.register :redmine_time_autopilot do
  name 'Time Autopilot'
  author 'stbt.de'
  author_url 'https://stbt.de/'
  description 'Time tracking for Redmine: proposals from recorded work (e.g. AI agents) with rules per folder, file, branch or word, monthly issues, quick time entry and weekly hours widgets, working hours per weekday.'
  version '0.2.0'
  url 'https://github.com/stbt-de/redmine-time-autopilot'
  requires_redmine version_or_higher: '6.0.0'

  menu :top_menu, :time_autopilot, { controller: 'time_autopilot', action: 'show' },
       caption: :label_time_autopilot, after: :my_page,
       if: proc { User.current.logged? && User.current.allowed_to_globally?(:log_time) }
end

# Widgets auf „Meine Seite“ (bis 1.3 in Dashboard Blocks, Namen unverändert,
# damit vorhandene Anordnungen und Einstellungen bleiben):
#   quick_time_entry   Zeit buchen: Ticket suchen, Dauer, buchen
#   my_week            Wochenstunden: gebucht je Tag gegen die Arbeitszeit,
#                      dazu was als Vorschlag wartet
RedmineTimeAutopilot::Hooks
MyController.helper(TimeAutopilotHelper)
MyController.include(RedmineTimeAutopilot::WorkHoursPatch::MyAccount) unless MyController < RedmineTimeAutopilot::WorkHoursPatch::MyAccount
UsersController.include(RedmineTimeAutopilot::WorkHoursPatch::Users) unless UsersController < RedmineTimeAutopilot::WorkHoursPatch::Users

# Wochenstunden mehrfach hinzufügbar (je Mitarbeiter eine Instanz)
{ 'my_week' => 5 }.each do |name, max|
  Redmine::MyPage.additional_blocks[name]&.merge!(max_occurs: max)
end

# Werkzeuge für den MCP-Server von redmine_mcp_plugin (nur wenn installiert)
require File.expand_path('mcp/registration', __dir__)
TimeAutopilotMcp::Registration.install
