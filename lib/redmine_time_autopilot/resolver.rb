# frozen_string_literal: true

module RedmineTimeAutopilot
  # Ordnet einen Entwurf einem Ticket zu. Reihenfolge:
  #
  #   1. von Hand gewähltes Ticket
  #   2. Ticketnummer im Text (Eingabe, Branch, Commit)
  #   3. Ausnahmen: Dateien, dann Branch, dann Begriff
  #   4. Standard des Ordners (festes Ticket, Ticket des Monats, nicht buchen)
  #   5. Vermutung des Absenders – als Frage
  #   6. sonst offen – als Frage
  class Resolver
    Resolution = Struct.new(:kind, :issue, :rule, :planned_subject, :month, keyword_init: true) do
      def ready?
        %i[chosen ref rule monthly].include?(kind) && (issue.present? || planned_subject.present?)
      end

      def question?
        %i[open guess].include?(kind)
      end

      def skip?
        kind == :skip
      end

      def to_create?
        issue.nil? && planned_subject.present?
      end

      # Gleiche Ziele werden je Tag zu einer Buchung zusammengefasst
      def key
        issue ? "issue-#{issue.id}" : "new-#{rule.id}-#{month.strftime('%Y-%m')}"
      end
    end

    def initialize(user, rules: nil)
      @user = user
      @rules = rules || TimeAutopilotRule.for_user(user).order(:id).to_a
      @issues = {}
      @monthly = {}
    end

    attr_reader :rules

    def resolve(draft)
      if draft.chosen_issue_id && (issue = visible_issue(draft.chosen_issue_id))
        return Resolution.new(kind: :chosen, issue: issue)
      end

      draft.issue_ref_ids.each do |id|
        issue = visible_issue(id)
        return Resolution.new(kind: :ref, issue: issue) if issue
      end

      rule = matching_rule(draft)
      return target(rule, draft.spent_on) if rule

      guess = draft.guess_issue_id && visible_issue(draft.guess_issue_id)
      guess ? Resolution.new(kind: :guess, issue: guess) : Resolution.new(kind: :open)
    end

    def matching_rule(draft)
      TimeAutopilotRule::EXCEPTION_KINDS.each do |kind|
        rule = @rules.detect { |candidate| candidate.kind == kind && candidate.matches?(draft) }
        return rule if rule
      end
      @rules.detect { |candidate| candidate.kind == 'folder' && candidate.matches?(draft) }
    end

    def visible_issue(id)
      @issues.fetch(id) { @issues[id] = Issue.visible(@user).find_by(id: id) }
    end

    private

    def target(rule, date)
      case rule.target
      when 'skip' then Resolution.new(kind: :skip, rule: rule)
      when 'monthly' then monthly(rule, date)
      else
        issue = visible_issue(rule.issue_id)
        issue ? Resolution.new(kind: :rule, issue: issue, rule: rule) : Resolution.new(kind: :open, rule: rule)
      end
    end

    def monthly(rule, date)
      @monthly[[rule.id, date]] ||= begin
        finder = MonthlyIssue.new(@user, rule)
        issue = finder.find(date)
        if issue
          Resolution.new(kind: :monthly, issue: issue, rule: rule)
        elsif rule.create_missing && rule.project
          Resolution.new(kind: :monthly, rule: rule, planned_subject: finder.planned_subject(date),
                         month: date.beginning_of_month)
        else
          Resolution.new(kind: :open, rule: rule)
        end
      end
    end
  end
end
