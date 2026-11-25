# frozen_string_literal: true

# Werkzeuge für den MCP-Server des Plugins redmine_mcp_plugin
# (https://github.com/joaoperfig/redmine_mcp_plugin). Geladen nur, wenn das
# Plugin installiert ist (mcp/registration.rb) – deshalb außerhalb von lib/,
# das Zeitwerk sonst immer laden würde.
#
# Jedes Werkzeug läuft als die angemeldete Person, mit Redmines Rechten
# (Aufwand buchen) und den OAuth-Scopes des Tokens; schreibende Werkzeuge
# erscheinen nur, wenn das MCP-Plugin nicht im Nur-Lesen-Modus läuft.
# Eigener Namensraum außerhalb von RedmineTimeAutopilot: dessen Dateien lädt
# Zeitwerk, diese hier nicht.
module TimeAutopilotMcp
  module Tools
    # Helfer für Texte, wie auf der Seite „Zeiten“ (Gründe, Herkunft)
    class Texts
      include Redmine::I18n
      include ActionView::Helpers::TagHelper
      include ActionView::Helpers::OutputSafetyHelper
      include ActionView::Helpers::NumberHelper
      include TimeAutopilotHelper
    end

    class Base < RedmineMcpPlugin::Tools::Base
      # Recht je Werkzeug: die DSL des MCP-Plugins speichert es an der Klasse
      # selbst, Unterklassen erben es nicht – daher hier für jede setzen
      def self.inherited(tool)
        super
        tool.permission :log_time
      end

      private

      def week_for(arguments)
        RedmineTimeAutopilot::Week.new(user, week: arguments['week'])
      end

      def texts
        @texts ||= Texts.new
      end

      def week_payload(week)
        RedmineTimeAutopilot::WeekPayload.new(week, texts).to_h
      end
    end

    class TimeWeek < Base
      tool_name 'time_week'
      title 'Time: show week'
      description 'Time Autopilot: one week of the authenticated user – hours logged and proposed per day, ' \
                  'open questions (work in folders without a rule, with suggested issues) and the proposals ' \
                  'ready to book, each with a key. Without week: the oldest week with open drafts.'
      input_schema(
        'type' => 'object',
        'properties' => { 'week' => { 'type' => 'string', 'format' => 'date', 'description' => 'Any day of the week (YYYY-MM-DD).' } },
        'additionalProperties' => false
      )

      private

      def perform(arguments)
        week_payload(week_for(arguments))
      end
    end

    class TimeAnswer < Base
      tool_name 'time_answer'
      title 'Time: answer question'
      description 'Time Autopilot: answers an open question – the work in a folder goes to an issue, or is not booked ' \
                  '(skip). With remember (default) this becomes the folder rule and applies to all open drafts. ' \
                  'Only call with the user\'s answer, never guess.'
      write true
      input_schema(
        'type' => 'object',
        'properties' => {
          'week' => { 'type' => 'string', 'format' => 'date', 'description' => 'Any day of the week (YYYY-MM-DD).' },
          'folder' => { 'type' => 'string', 'description' => 'Folder from the question.' },
          'issue_id' => { 'type' => 'integer', 'description' => 'Issue to book on; omit with skip.' },
          'skip' => { 'type' => 'boolean', 'description' => 'true: do not book this work.' },
          'remember' => { 'type' => 'boolean', 'description' => 'Save as rule for the folder. Defaults to true.' }
        },
        'required' => %w[week folder],
        'additionalProperties' => false
      )

      private

      def perform(arguments)
        remember = arguments.key?('remember') ? arguments['remember'] == true : true
        answer = RedmineTimeAutopilot::Answer.new(user, week_for(arguments))
        done = answer.call(folder: arguments['folder'].to_s, issue_id: arguments['issue_id'],
                           skip: arguments['skip'] == true && arguments['issue_id'].blank?, remember: remember)
        raise RedmineMcpPlugin::ToolError, answer.error unless done

        { answered: arguments['folder'], issue_id: arguments['issue_id'], skipped: arguments['skip'] == true, remembered: remember }
      end
    end

    class TimeBook < Base
      tool_name 'time_book'
      title 'Time: book proposals'
      description 'Time Autopilot: books the proposals of a week as regular Redmine time entries. ONLY call after the ' \
                  'user has seen the summary and explicitly agreed. Optional: hours changes hours per proposal key ' \
                  '(0 = do not book), keys books only these proposals. Missing issues of the month are created.'
      write true
      input_schema(
        'type' => 'object',
        'properties' => {
          'week' => { 'type' => 'string', 'format' => 'date', 'description' => 'Any day of the week (YYYY-MM-DD).' },
          'hours' => { 'type' => 'object', 'additionalProperties' => { 'type' => %w[number string] },
                       'description' => 'Changed hours per key, e.g. {"2026-11-19-issue-45": 1.5}.' },
          'keys' => { 'type' => 'array', 'items' => { 'type' => 'string' }, 'description' => 'Only book these proposals.' }
        },
        'required' => %w[week],
        'additionalProperties' => false
      )

      private

      def perform(arguments)
        keys = arguments['keys'].is_a?(Array) ? arguments['keys'].map(&:to_s) : nil
        booking = RedmineTimeAutopilot::Booking.new(user, week_for(arguments)).call(hours: (arguments['hours'] || {}).to_h, keys: keys)
        {
          booked: booking.booked.map { |entry| { id: entry.id, spent_on: entry.spent_on.iso8601, hours: entry.hours.to_f, issue_id: entry.issue_id, comments: entry.comments } },
          booked_hours: booking.booked_hours.to_f,
          created_issues: booking.created_issues.map { |issue| { id: issue.id, subject: issue.subject } },
          failures: booking.failures.map { |failure| { key: failure.entry.key, title: texts.ta_entry_title(failure.entry), message: failure.message } }
        }
      end
    end

    class TimeUpload < Base
      tool_name 'time_upload'
      title 'Time: upload drafts'
      description 'Time Autopilot: uploads recorded work segments as drafts. The same source_key replaces an open draft; ' \
                  'with replace_from/replace_to, open drafts in that range that are not sent again are removed. Send ' \
                  'no content of the work – only hours, folder, branch, file paths, issue numbers and a short summary.'
      write true
      input_schema(
        'type' => 'object',
        'properties' => {
          'drafts' => {
            'type' => 'array',
            'items' => {
              'type' => 'object',
              'properties' => {
                'source_key' => { 'type' => 'string' }, 'spent_on' => { 'type' => 'string', 'format' => 'date' },
                'hours' => { 'type' => 'number' }, 'folder' => { 'type' => 'string' },
                'started_at' => { 'type' => 'string' }, 'ended_at' => { 'type' => 'string' },
                'branch' => { 'type' => %w[string null] }, 'paths' => { 'type' => 'array', 'items' => { 'type' => 'string' } },
                'issue_refs' => { 'type' => 'array', 'items' => { 'type' => 'string' } },
                'summary' => { 'type' => 'string' }, 'guess_issue_id' => { 'type' => 'integer' }, 'source' => { 'type' => 'string' }
              },
              'required' => %w[source_key spent_on hours folder]
            }
          },
          'replace_from' => { 'type' => 'string', 'format' => 'date' },
          'replace_to' => { 'type' => 'string', 'format' => 'date' }
        },
        'required' => %w[drafts],
        'additionalProperties' => false
      )

      private

      def perform(arguments)
        result = RedmineTimeAutopilot::Upload.new(user).call(arguments['drafts'] || [], replace_from: arguments['replace_from'], replace_to: arguments['replace_to'])
        result.to_h
      end
    end

    class TimeRules < Base
      tool_name 'time_rules'
      title 'Time: show rules'
      description 'Time Autopilot: the user\'s rules (which folder, files, branch or word goes to which issue, the issue ' \
                  'of the month, or not booked) and folders without a rule from the last four weeks.'
      input_schema('type' => 'object', 'properties' => {}, 'additionalProperties' => false)

      private

      def perform(_arguments)
        rules = TimeAutopilotRule.for_user(user).includes(:issue, :project).order(:id)
        assigned = rules.select { |rule| rule.kind == 'folder' }.flat_map(&:folder_list)
        unassigned = TimeAutopilotDraft.for_user(user).where(spent_on: (user.today - 28)..user.today)
                                       .where.not(folder: assigned).group(:folder).sum(:hours)
        {
          rules: rules.map do |rule|
            { id: rule.id, folders: rule.folder_list, kind: rule.kind, pattern: rule.pattern, target: rule.target,
              issue: rule.issue && { id: rule.issue.id, subject: rule.issue.subject },
              project: rule.project&.name, subject_term: rule.subject_term }
          end,
          unassigned: unassigned.map { |folder, hours| { folder: folder, hours_last_4_weeks: hours.to_f } }
        }
      end
    end

    class TimeSearchIssues < Base
      tool_name 'time_search_issues'
      title 'Time: search issues to book on'
      description 'Time Autopilot: open issues by number or subject, only in projects where the user may log time.'
      input_schema(
        'type' => 'object',
        'properties' => { 'term' => { 'type' => 'string', 'description' => 'Number (#123) or words from the subject.' } },
        'required' => %w[term],
        'additionalProperties' => false
      )

      private

      def perform(arguments)
        term = arguments['term'].to_s.strip
        scope = Issue.visible(user).open.includes(:project).where(project_id: Project.allowed_to(user, :log_time).select(:id))
        found = []
        found << scope.find_by(id: Regexp.last_match(1).to_i) if term =~ /\A#?(\d+)\z/
        found += scope.like(term).order(id: :desc).limit(10).to_a if term.present?
        { issues: found.compact.uniq.first(10).map { |issue| { id: issue.id, subject: issue.subject, project: issue.project.name } } }
      end
    end

    ALL = [TimeWeek, TimeAnswer, TimeBook, TimeUpload, TimeRules, TimeSearchIssues].freeze
  end
end
