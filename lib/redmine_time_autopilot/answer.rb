# frozen_string_literal: true

module RedmineTimeAutopilot
  # Antwort auf eine Frage „Wohin gehört die Arbeit in Ordner X?“:
  # ein Ticket oder „nicht buchen“. Mit remember wird daraus die Zuordnung
  # des Ordners (gilt sofort für alle offenen Entwürfe), sonst nur für die
  # Entwürfe dieser Frage.
  class Answer
    attr_reader :error

    def initialize(user, week)
      @user = user
      @week = week
    end

    def call(folder:, issue_id: nil, skip: false, remember: false)
      question = @week.questions.detect { |candidate| candidate.folder == folder }
      return fail_with(:error_time_autopilot_question_gone) unless question

      issue = nil
      unless skip
        issue = Issue.visible(@user).find_by(id: issue_id.to_s[/\d+/])
        return fail_with(:error_time_autopilot_issue_invalid) unless issue
        return fail_with(:error_time_autopilot_not_allowed, project: issue.project.name) unless @user.allowed_to?(:log_time, issue.project)
      end

      remember ? remember!(folder, issue) : apply!(question, issue)
      true
    end

    private

    def remember!(folder, issue)
      rule = TimeAutopilotRule.for_user(@user).where(kind: 'folder').detect { |candidate| candidate.folder_list == [folder] }
      rule ||= TimeAutopilotRule.new(user: @user, kind: 'folder', folder_list: [folder])
      rule.target = issue ? 'issue' : 'skip'
      rule.issue = issue
      rule.save!
    end

    def apply!(question, issue)
      scope = TimeAutopilotDraft.where(id: question.drafts.map(&:id))
      if issue
        scope.update_all(chosen_issue_id: issue.id, updated_at: Time.current)
      else
        scope.update_all(status: 'skipped', updated_at: Time.current)
      end
    end

    def fail_with(key, **args)
      @error = ::I18n.t(key, **args)
      false
    end
  end
end
