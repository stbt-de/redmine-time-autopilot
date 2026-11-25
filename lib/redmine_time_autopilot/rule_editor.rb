# frozen_string_literal: true

module RedmineTimeAutopilot
  # Legt eine Zuordnung an oder ändert sie – für die Seite „Zuordnung“ und das
  # MCP-Werkzeug time_save_rule. Übernimmt nur die übergebenen Felder; Ticket,
  # Projekt und Tätigkeit nur, wenn die Person dort Aufwand buchen darf.
  class RuleEditor
    FIELDS = %w[folders kind pattern target issue_id project_id subject_template month_locale
                create_missing close_previous activity_id].freeze

    attr_reader :rule

    def initialize(user, rule = nil)
      @user = user
      @rule = rule || TimeAutopilotRule.new(user: user)
    end

    def save(values)
      values = values.to_h.stringify_keys.slice(*FIELDS)
      assign_plain(values)
      assign_issue(values) if values.key?('issue_id')
      assign_project(values) if values.key?('project_id')
      assign_activity(values) if values.key?('activity_id')
      normalize
      return false if @invalid_issue && invalid!(:issue_id)
      return false if @invalid_project && invalid!(:project_id)

      rule.save
    end

    private

    def assign_plain(values)
      if values.key?('folders')
        folders = values['folders']
        folders.is_a?(Array) ? rule.folder_list = folders : rule.folders = folders
      end
      %w[kind pattern target subject_template month_locale create_missing close_previous].each do |field|
        rule.public_send("#{field}=", values[field]) if values.key?(field)
      end
    end

    def assign_issue(values)
      id = values['issue_id'].to_s[/\d+/]
      rule.issue = id && Issue.visible(@user).find_by(id: id)
      @invalid_issue = id.present? && (rule.issue.nil? || !@user.allowed_to?(:log_time, rule.issue.project))
    end

    # Projekt als Nummer oder Kennung
    def assign_project(values)
      value = values['project_id'].to_s.strip
      scope = Project.allowed_to(@user, :log_time)
      rule.project = if value.blank? then nil
                     elsif value.match?(/\A\d+\z/) then scope.find_by(id: value)
                     else scope.find_by(identifier: value)
                     end
      @invalid_project = value.present? && rule.project.nil?
    end

    def assign_activity(values)
      rule.activity_id = TimeEntryActivity.shared.active.find_by(id: values['activity_id'])&.id
    end

    def normalize
      rule.issue_id = nil unless rule.target == 'issue'
      if rule.monthly?
        rule.subject_template = SubjectTemplate.default if rule.subject_template.blank?
      else
        rule.project_id = rule.subject_template = rule.month_locale = nil
      end
      rule.pattern = nil unless rule.exception?
    end

    def invalid!(field)
      rule.valid?
      rule.errors.add(field, :invalid)
      true
    end
  end
end
