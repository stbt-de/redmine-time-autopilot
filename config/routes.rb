# frozen_string_literal: true

get 'time_autopilot', to: 'time_autopilot#show', as: 'time_autopilot'
post 'time_autopilot/answer', to: 'time_autopilot#answer', as: 'time_autopilot_answer'
post 'time_autopilot/book', to: 'time_autopilot#book', as: 'time_autopilot_book'
get 'time_autopilot/issues', to: 'time_autopilot#issues', as: 'time_autopilot_issues'
post 'time_autopilot/drafts', to: 'time_autopilot#upload', as: 'time_autopilot_drafts'

scope 'time_autopilot' do
  resources :rules, controller: 'time_autopilot_rules', as: 'time_autopilot_rules', except: :show
end

# Widget „Zeit buchen“ und „Zeit nachtragen“ auf der Seite „Zeiten“. Antworten
# sind JSON; das Format bleibt bewusst offen: Mit format=json hielte Redmine
# die Anfrage für einen API-Aufruf und ignorierte die Sitzung.
scope 'time_autopilot/entries' do
  get 'issues', to: 'time_autopilot_entries#issues', as: 'time_autopilot_time_entry_issues'
  get 'activities', to: 'time_autopilot_entries#activities', as: 'time_autopilot_time_entry_activities'
  post '', to: 'time_autopilot_entries#create', as: 'time_autopilot_time_entries'
  delete ':id', to: 'time_autopilot_entries#destroy', as: 'time_autopilot_time_entry', constraints: { id: /\d+/ }
end
