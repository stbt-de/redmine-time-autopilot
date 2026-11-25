# frozen_string_literal: true

# Reiter „Zuordnung“: die eigenen Zuordnungen ansehen, anlegen, ändern
class TimeAutopilotRulesController < ApplicationController
  before_action :require_login
  before_action :authorize_time_autopilot
  before_action :find_rule, only: %i[edit update destroy]
  accept_api_auth :index

  helper :time_autopilot

  def index
    @rules = TimeAutopilotRule.for_user(User.current).includes(:issue, :project).order(:id).to_a
    @unassigned = unassigned_folders(@rules)
    respond_to do |format|
      format.html
      format.json do
        render json: {
          rules: @rules.map { |rule| rule_json(rule) },
          unassigned: @unassigned.map { |folder, hours| { folder: folder, hours_last_4_weeks: hours.to_f } }
        }
      end
    end
  end

  def new
    @rule = TimeAutopilotRule.new(user: User.current, kind: params[:kind].presence_in(TimeAutopilotRule::KINDS) || 'folder',
                                  folders: params[:folders], target: params[:target].presence_in(TimeAutopilotRule::TARGETS) || 'issue',
                                  subject_template: RedmineTimeAutopilot::SubjectTemplate.default)
  end

  def create
    @rule = TimeAutopilotRule.new(user: User.current)
    if save_rule
      flash[:notice] = l(:notice_successful_create)
      redirect_to time_autopilot_rules_path
    else
      render :new, status: 422
    end
  end

  def edit; end

  def update
    if save_rule
      flash[:notice] = l(:notice_successful_update)
      redirect_to time_autopilot_rules_path
    else
      render :edit, status: 422
    end
  end

  def destroy
    @rule.destroy
    flash[:notice] = l(:notice_successful_delete)
    redirect_to time_autopilot_rules_path
  end

  private

  def authorize_time_autopilot
    render_403 unless User.current.allowed_to_globally?(:log_time)
  end

  def find_rule
    @rule = TimeAutopilotRule.for_user(User.current).find_by(id: params[:id])
    render_404 unless @rule
  end

  def save_rule
    values = params.require(:rule).permit(*RedmineTimeAutopilot::RuleEditor::FIELDS)
    RedmineTimeAutopilot::RuleEditor.new(User.current, @rule).save(values.to_h)
  end

  def rule_json(rule)
    {
      id: rule.id, folders: rule.folder_list, kind: rule.kind, pattern: rule.pattern, target: rule.target,
      issue: rule.issue && { id: rule.issue.id, subject: rule.issue.subject },
      project: rule.project&.name, subject_template: rule.subject_template, month_locale: rule.month_locale,
      create_missing: rule.create_missing, close_previous: rule.close_previous,
      sentence: view_context.strip_tags("#{view_context.ta_rule_condition(rule)} → #{view_context.ta_rule_target(rule)}").squish
    }
  end

  # Ordner aus den letzten vier Wochen, für die es keinen Standard gibt
  def unassigned_folders(rules)
    assigned = rules.select { |rule| rule.kind == 'folder' }.flat_map(&:folder_list)
    TimeAutopilotDraft.for_user(User.current).where(spent_on: (User.current.today - 28)..User.current.today)
                      .where.not(folder: assigned).group(:folder).order(Arel.sql('SUM(hours) DESC')).sum(:hours)
  end
end
