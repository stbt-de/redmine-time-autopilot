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

      def rule_payload(rule)
        payload = { id: rule.id, folders: rule.folder_list, kind: rule.kind, pattern: rule.pattern, target: rule.target,
                    issue: rule.issue && { id: rule.issue.id, subject: rule.issue.subject } }
        return payload unless rule.monthly?

        finder = RedmineTimeAutopilot::MonthlyIssue.new(user, rule)
        months = [user.today, user.today.next_month].map do |date|
          issue = finder.find(date)
          { month: date.strftime('%Y-%m'), subject: finder.planned_subject(date), issue: issue && { id: issue.id, subject: issue.subject } }
        end
        payload.merge(project: rule.project && { id: rule.project.id, identifier: rule.project.identifier, name: rule.project.name },
                      subject_template: rule.subject_template, month_locale: rule.month_locale,
                      create_missing: rule.create_missing, close_previous: rule.close_previous, months: months)
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
                  'of the month, or not booked) and folders without a rule from the last four weeks. Monthly rules show ' \
                  'their subject template and the subject and issue of this and the next month.'
      input_schema('type' => 'object', 'properties' => {}, 'additionalProperties' => false)

      private

      def perform(_arguments)
        rules = TimeAutopilotRule.for_user(user).includes(:issue, :project).order(:id)
        assigned = rules.select { |rule| rule.kind == 'folder' }.flat_map(&:folder_list)
        unassigned = TimeAutopilotDraft.for_user(user).where(spent_on: (user.today - 28)..user.today)
                                       .where.not(folder: assigned).group(:folder).sum(:hours)
        {
          rules: rules.map { |rule| rule_payload(rule) },
          unassigned: unassigned.map { |folder, hours| { folder: folder, hours_last_4_weeks: hours.to_f } },
          default_subject_template: RedmineTimeAutopilot::SubjectTemplate.default
        }
      end
    end

    RULE_PROPERTIES = {
      'folders' => { 'type' => 'array', 'items' => { 'type' => 'string' },
                     'description' => 'Project folder names. Required for kind folder; for exceptions empty = every folder.' },
      'kind' => { 'type' => 'string', 'enum' => TimeAutopilotRule::KINDS,
                  'description' => 'folder = default for the folders; path, branch, term = exception, checked first.' },
      'pattern' => { 'type' => 'string',
                     'description' => 'For path (a folder like www/src/Jobs or a glob), branch (e.g. feature/*) or term ' \
                                      '(word in summary, branch or paths).' },
      'target' => { 'type' => 'string', 'enum' => TimeAutopilotRule::TARGETS,
                    'description' => 'issue = fixed issue, monthly = issue of the month in a project, skip = not booked.' },
      'issue_id' => { 'type' => 'integer', 'description' => 'For target issue.' },
      'project' => { 'type' => %w[string integer], 'description' => 'For target monthly: project identifier or id.' },
      'subject_template' => { 'type' => 'string',
                              'description' => 'For target monthly: subject with {project}, {year}, {month}, {month_number}, ' \
                                               'e.g. "Maintenance - {year} - {month}". Omitted: the default from the plugin settings.' },
      'month_locale' => { 'type' => 'string', 'description' => 'Language of {month}, e.g. de, en, fr. Omitted: Redmine\'s default language.' },
      'create_missing' => { 'type' => 'boolean', 'description' => 'Create the issue of the month when booking. Defaults to true.' },
      'close_previous' => { 'type' => 'boolean', 'description' => 'Close the previous month\'s issue when creating. Defaults to false.' }
    }.freeze

    class TimeSaveRule < Base
      tool_name 'time_save_rule'
      title 'Time: save rule'
      description 'Time Autopilot: creates a rule, or changes one (with id; only the given fields change). Only with the ' \
                  'user\'s decision – never guess where work belongs. Returns the rule; monthly rules with the subjects ' \
                  'of this and the next month.'
      write true
      input_schema(
        'type' => 'object',
        'properties' => { 'id' => { 'type' => 'integer', 'description' => 'Rule to change; omitted: new rule.' } }.merge(RULE_PROPERTIES),
        'additionalProperties' => false
      )

      private

      def perform(arguments)
        rule = arguments['id'] ? TimeAutopilotRule.for_user(user).find_by(id: arguments['id']) : nil
        raise RedmineMcpPlugin::ToolError, "Rule #{arguments['id']} not found." if arguments['id'] && rule.nil?

        values = arguments.except('id', 'project')
        values['project_id'] = arguments['project'] if arguments.key?('project')
        editor = RedmineTimeAutopilot::RuleEditor.new(user, rule)
        raise RedmineMcpPlugin::ToolError, editor.rule.errors.full_messages.join(' ') unless editor.save(values)

        rule_payload(editor.rule.reload)
      end
    end

    class TimeDeleteRule < Base
      tool_name 'time_delete_rule'
      title 'Time: delete rule'
      description 'Time Autopilot: deletes one of the user\'s rules. Booked time stays; open drafts are assigned anew.'
      write true
      input_schema(
        'type' => 'object',
        'properties' => { 'id' => { 'type' => 'integer' } },
        'required' => %w[id],
        'additionalProperties' => false
      )

      private

      def perform(arguments)
        rule = TimeAutopilotRule.for_user(user).find_by(id: arguments['id'])
        raise RedmineMcpPlugin::ToolError, "Rule #{arguments['id']} not found." unless rule

        rule.destroy
        { deleted: rule.id }
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

    ALL = [TimeWeek, TimeAnswer, TimeBook, TimeUpload, TimeRules, TimeSaveRule, TimeDeleteRule, TimeSearchIssues].freeze
  end
end
