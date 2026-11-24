# frozen_string_literal: true

# Seite „Zeiten“: Woche mit Fragen und Buchen. Dieselben Aktionen gibt es als
# REST-Schnittstelle (.json mit API-Schlüssel) für Agents und den MCP-Server:
#
#   GET  /time_autopilot.json?week=…     Woche: Fragen, Vorschläge, Summen
#   POST /time_autopilot/answer.json     Frage beantworten (optional merken)
#   POST /time_autopilot/book.json       Vorschläge buchen (optional Stunden
#                                        ändern, nur bestimmte Einträge)
#   POST /time_autopilot/drafts.json     Entwürfe hochladen
#   GET  /time_autopilot/issues.json     Tickets suchen (Nummer oder Betreff)
class TimeAutopilotController < ApplicationController
  UPLOAD_PERMITTED = [*TimeAutopilotDraft::UPLOAD_FIELDS, :source_key, :issue_refs, { paths: [], issue_refs: [] }].freeze

  before_action :require_login
  before_action :authorize_time_autopilot
  before_action :load_week, only: %i[show answer book]
  accept_api_auth :show, :answer, :book, :upload, :issues

  helper :time_autopilot

  def show
    respond_to do |format|
      format.html
      format.json { render json: RedmineTimeAutopilot::WeekPayload.new(@week, view_context).to_h }
    end
  end

  def answer
    choice = params[:choice].to_s
    answer = RedmineTimeAutopilot::Answer.new(User.current, @week)
    done = answer.call(folder: params[:folder].to_s,
                       issue_id: params[:issue_id].presence || choice[/\Aissue-(\d+)\z/, 1],
                       skip: skip_requested?(choice),
                       remember: truthy?(params[:remember]))
    respond_to do |format|
      format.html do
        done ? flash[:notice] = l(:notice_time_autopilot_answered) : flash[:error] = answer.error
        redirect_to time_autopilot_path(week: @week.start.iso8601)
      end
      format.json do
        if done
          render json: { answered: params[:folder].to_s, remembered: truthy?(params[:remember]) }
        else
          render json: { errors: [answer.error] }, status: 422
        end
      end
    end
  end

  def book
    hours = params[:hours].respond_to?(:to_unsafe_h) ? params[:hours].to_unsafe_h : {}
    keys = params[:keys].is_a?(Array) ? params[:keys].map(&:to_s) : nil
    booking = RedmineTimeAutopilot::Booking.new(User.current, @week).call(hours: hours, keys: keys)
    respond_to do |format|
      format.html do
        flash_booking(booking)
        redirect_to time_autopilot_path(week: @week.start.iso8601)
      end
      format.json { render json: booking_json(booking), status: (booking.failures.empty? ? :ok : 422) }
    end
  end

  def upload
    items = params[:drafts].is_a?(Array) ? params[:drafts].map { |item| item.respond_to?(:permit) ? item.permit(*UPLOAD_PERMITTED).to_h : {} } : []
    result = RedmineTimeAutopilot::Upload.new(User.current).call(items, replace_from: params[:replace_from], replace_to: params[:replace_to])
    render json: result.to_h, status: (result.errors.empty? ? :ok : 422)
  end

  # Ticketsuche für Fragen, Zuordnung und Agents: Nummer oder Betreff, nur
  # offene Tickets in Projekten, in denen die Person Aufwand buchen darf.
  # Im Browser ohne .json aufrufen – sonst gilt die Sitzung nicht.
  def issues
    term = params[:term].to_s.strip
    scope = Issue.visible.open.includes(:project)
                 .where(project_id: Project.allowed_to(User.current, :log_time).select(:id))
    found = []
    found << scope.find_by(id: Regexp.last_match(1).to_i) if term =~ /\A#?(\d+)\z/
    found += scope.like(term).order(id: :desc).limit(10).to_a if term.present?
    render json: found.compact.uniq.first(10).map { |issue|
      { id: issue.id, subject: issue.subject, project: issue.project.name,
        label: "##{issue.id} #{issue.subject.truncate(80)} · #{issue.project.name}",
        value: "##{issue.id} #{issue.subject.truncate(60)}" }
    }
  end

  private

  def authorize_time_autopilot
    render_403 unless User.current.allowed_to_globally?(:log_time)
  end

  def load_week
    @week = RedmineTimeAutopilot::Week.new(User.current, week: params[:week])
  end

  def truthy?(value)
    [true, 'true', '1', 1].include?(value)
  end

  def skip_requested?(choice)
    return false if params[:issue_id].present?

    choice == 'skip' || truthy?(params[:skip])
  end

  def flash_booking(booking)
    if booking.booked.any?
      notice = l(:notice_time_autopilot_booked, count: booking.booked.size, hours: view_context.ta_hours(booking.booked_hours))
      if booking.created_issues.any?
        notice += " #{l(:notice_time_autopilot_issues_created, issues: booking.created_issues.map { |i| "##{i.id}" }.join(', '))}"
      end
      flash[:notice] = notice
    end
    return if booking.failures.empty?

    flash[:error] = booking.failures.map { |failure| "#{failure.entry.date.strftime('%-d.%-m.')} #{view_context.ta_entry_title(failure.entry)}: #{failure.message}" }.join(' · ')
  end

  def booking_json(booking)
    {
      booked: booking.booked.map { |entry| { id: entry.id, spent_on: entry.spent_on, hours: entry.hours.to_f, issue_id: entry.issue_id, comments: entry.comments } },
      booked_hours: booking.booked_hours.to_f,
      created_issues: booking.created_issues.map { |issue| { id: issue.id, subject: issue.subject } },
      failures: booking.failures.map { |failure| { key: failure.entry.key, title: view_context.ta_entry_title(failure.entry), message: failure.message } }
    }
  end
end
