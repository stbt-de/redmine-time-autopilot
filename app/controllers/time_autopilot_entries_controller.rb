# frozen_string_literal: true

# Block "Zeit buchen" auf Meine Seite: Ticketsuche, Tätigkeiten des
# Projekts, Buchen und Rückgängig. Antwortet mit JSON für
# assets/javascripts/time_autopilot_blocks.js.
#
# Rechte wie in Redmine: nur sichtbare, offene Tickets in Projekten mit dem
# Recht "Aufwand buchen"; Rückgängig nur für eigene Buchungen, die der
# Benutzer bearbeiten darf.
class TimeAutopilotEntriesController < ApplicationController
  before_action :require_login
  before_action :find_issue, only: %i[activities create]

  helper TimeAutopilotHelper

  def issues
    issues = quick_time_entry.search(params[:q])
    render json: issues.map { |issue| issue_json(issue) }
  end

  def activities
    activities = @issue.project.activities
    render json: activities.map { |activity| { id: activity.id, name: activity.name, default: activity.is_default? } }
  end

  def create
    entry = TimeEntry.new(project: @issue.project, issue: @issue, user: User.current, author: User.current,
                          spent_on: User.current.today)
    entry.safe_attributes = params.permit(:hours, :spent_on, :activity_id, :comments).to_h

    if entry.save
      render json: {
        id: entry.id,
        message: l(:notice_time_autopilot_time_logged, hours: hours_text(entry.hours), issue: "##{@issue.id} #{@issue.subject}"),
        # Das Skript verlinkt die Nummer in der Meldung auf das Ticket
        issue: { label: "##{@issue.id}", url: issue_path(@issue) },
        today: hours_text(quick_time_entry.today_hours),
        undo: entry.editable_by?(User.current)
      }
    else
      render json: { errors: entry.errors.full_messages, form_url: new_issue_time_entry_path(@issue) }, status: 422
    end
  end

  def destroy
    entry = TimeEntry.find_by(id: params[:id], user_id: User.current.id)
    return render_json_error(404, l(:error_time_autopilot_not_found)) unless entry&.editable_by?(User.current)

    entry.destroy
    render json: { today: hours_text(quick_time_entry.today_hours) }
  end

  private

  def quick_time_entry
    @quick_time_entry ||= RedmineTimeAutopilot::QuickTimeEntry.new(User.current)
  end

  def find_issue
    @issue = quick_time_entry.loggable_issues.find_by(id: params[:issue_id])
    render_json_error(403, l(:error_time_autopilot_issue_not_loggable)) unless @issue
  end

  def render_json_error(status, message)
    render json: { errors: [message] }, status: status
  end

  def hours_text(hours)
    view_context.time_autopilot_hours(hours)
  end

  def issue_json(issue)
    {
      id: issue.id,
      subject: issue.subject,
      project: issue.project.name,
      tile: view_context.time_autopilot_project_tile(issue.project, size: 20).to_s
    }
  end
end
