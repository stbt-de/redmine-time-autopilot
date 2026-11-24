# frozen_string_literal: true

module RedmineTimeAutopilot
  # Stylesheet und Script der Widgets nur auf „Meine Seite“; Arbeitszeit in
  # „Mein Konto“ und in der Benutzerverwaltung; Link auf „Aufgewendete Zeit“
  class Hooks < Redmine::Hook::ViewListener
    render_on :view_my_account_preferences, partial: 'time_autopilot/work_hours_fields'
    render_on :view_users_form_preferences, partial: 'time_autopilot/work_hours_fields'

    def view_layouts_base_html_head(context = {})
      controller = context[:controller]
      if controller.is_a?(MyController) && controller.action_name == 'page'
        safe_join([
          stylesheet_link_tag('time_autopilot_blocks', plugin: 'redmine_time_autopilot'),
          javascript_include_tag('time_autopilot_blocks', plugin: 'redmine_time_autopilot', defer: true)
        ], "\n")
      elsif controller.is_a?(TimelogController) && controller.action_name == 'index' && User.current.allowed_to_globally?(:log_time)
        context[:hook_caller].send(:render, partial: 'time_autopilot/timelog_link')
      else
        ''
      end
    end
  end
end
