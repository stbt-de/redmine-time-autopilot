# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# Werkzeuge für den MCP-Server von redmine_mcp_plugin. Laufen nur mit dem
# Plugin (WITH_MCP=1 dev/run-tests.sh); ohne wird geprüft, dass nichts
# angemeldet wird.
class McpToolsTest < ActiveSupport::TestCase
  include RedmineTimeAutopilot::TestHelper

  fixtures(*FIXTURES)

  MCP_INSTALLED = Redmine::Plugin.installed?(:redmine_mcp_plugin)

  def setup
    setup_autopilot
    return unless MCP_INSTALLED

    @read_only = Setting.plugin_redmine_mcp_plugin
    Setting.plugin_redmine_mcp_plugin = RedmineMcpPlugin::Settings::DEFAULTS.merge('read_only' => '0')
    Setting.clear_cache
  end

  def teardown
    return unless MCP_INSTALLED

    Setting.plugin_redmine_mcp_plugin = @read_only
    Setting.clear_cache
  end

  def server_for(user)
    User.current = user
    RedmineMcpPlugin::McpServer.build(
      tools: RedmineMcpPlugin::Registry.all.select { |tool| tool.available_to?(user, oauth_scopes: nil) },
      server_context: { user: user, auth: { mode: :api_key } }
    )
  end

  def call(user, name, arguments = {})
    server_for(user).handle({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: name, arguments: arguments } })[:result]
  end

  def tool_names(user)
    server_for(user).handle({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} })[:result][:tools].map { |tool| tool[:name] }
  end

  def test_ohne_mcp_plugin_wird_nichts_angemeldet
    skip 'redmine_mcp_plugin installiert' if MCP_INSTALLED

    assert_not TimeAutopilotMcp::Registration.available?
    assert_not TimeAutopilotMcp::Registration.install
  end

  def test_werkzeuge_stehen_in_der_liste
    skip 'ohne redmine_mcp_plugin' unless MCP_INSTALLED

    names = tool_names(@jsmith)
    assert_includes names, 'get_issue' # die eigenen des MCP-Plugins bleiben
    %w[time_week time_answer time_book time_upload time_rules time_save_rule time_delete_rule time_search_issues].each { |name| assert_includes names, name }
  end

  def test_nur_lesen_blendet_schreibende_aus
    skip 'ohne redmine_mcp_plugin' unless MCP_INSTALLED

    Setting.plugin_redmine_mcp_plugin = RedmineMcpPlugin::Settings::DEFAULTS.merge('read_only' => '1')
    Setting.clear_cache
    names = tool_names(@jsmith)
    assert_includes names, 'time_week'
    assert_not_includes names, 'time_book'
    assert_not_includes names, 'time_answer'
    assert_not_includes names, 'time_save_rule'
  end

  # Regression: permission :log_time stand nur an der Basisklasse; die DSL
  # des MCP-Plugins vererbt sie nicht, die Werkzeuge waren für alle sichtbar.
  def test_ohne_recht_aufwand_zu_buchen_keine_werkzeuge
    skip 'ohne redmine_mcp_plugin' unless MCP_INSTALLED

    assert_empty tool_names(user_without_projects).grep(/\Atime_/)
    assert(TimeAutopilotMcp::Tools::ALL.all? { |tool| tool.mcp_permission == :log_time })
  end

  def test_hochladen_beantworten_buchen
    skip 'ohne redmine_mcp_plugin' unless MCP_INSTALLED

    issue = create_issue(subject: 'Kampagnen-Monitor')
    result = call(@jsmith, 'time_upload', 'drafts' => [{ 'source_key' => 'k1', 'spent_on' => MONDAY.iso8601, 'hours' => 1.5,
                                                        'folder' => 'monitor', 'summary' => 'Deploy', 'source' => 'Claude Code' }])
    assert_not result[:isError], result.inspect
    assert_equal 1, result[:structuredContent][:created]

    week = call(@jsmith, 'time_week', 'week' => MONDAY.iso8601)[:structuredContent]
    assert_equal ['monitor'], week[:questions].map { |question| question[:folder] }

    answer = call(@jsmith, 'time_answer', 'week' => MONDAY.iso8601, 'folder' => 'monitor', 'issue_id' => issue.id)
    assert_not answer[:isError], answer.inspect
    assert_equal issue, TimeAutopilotRule.sole.issue

    week = call(@jsmith, 'time_week', 'week' => MONDAY.iso8601)[:structuredContent]
    key = week[:proposals].sole[:key]
    booked = call(@jsmith, 'time_book', 'week' => MONDAY.iso8601, 'hours' => { key => 1 })
    assert_not booked[:isError], booked.inspect
    assert_equal 1.0, TimeEntry.where(issue_id: issue.id, user_id: @jsmith.id).sole.hours
  end

  def test_fehler_als_werkzeugfehler
    skip 'ohne redmine_mcp_plugin' unless MCP_INSTALLED

    create_draft(folder: 'monitor')
    result = call(@jsmith, 'time_answer', 'week' => MONDAY.iso8601, 'folder' => 'monitor', 'issue_id' => hidden_issue.id)
    assert result[:isError]
  end

  def test_zuordnung_mit_ticket_des_monats_speichern_und_loeschen
    skip 'ohne redmine_mcp_plugin' unless MCP_INSTALLED

    saved = call(@jsmith, 'time_save_rule', 'folders' => ['shop'], 'kind' => 'folder', 'target' => 'monthly',
                                            'project' => @project.identifier, 'subject_template' => 'Shop - {year} - {month}',
                                            'month_locale' => 'de')
    assert_not saved[:isError], saved.inspect
    rule = saved[:structuredContent]
    assert_equal 'Shop - {year} - {month}', rule[:subject_template]
    assert_match(/\AShop - \d{4} - \S+\z/, rule[:months].first[:subject])

    changed = call(@jsmith, 'time_save_rule', 'id' => rule[:id], 'close_previous' => true)[:structuredContent]
    assert_equal ['Shop - {year} - {month}', true], [changed[:subject_template], changed[:close_previous]]
    assert_equal [rule[:id]], call(@jsmith, 'time_rules')[:structuredContent][:rules].map { |r| r[:id] }

    assert_equal({ deleted: rule[:id] }, call(@jsmith, 'time_delete_rule', 'id' => rule[:id])[:structuredContent])
    assert_equal 0, TimeAutopilotRule.count
  end

  def test_zuordnung_ohne_recht_aufs_projekt_wird_abgelehnt
    skip 'ohne redmine_mcp_plugin' unless MCP_INSTALLED

    result = call(@jsmith, 'time_save_rule', 'folders' => ['shop'], 'kind' => 'folder', 'target' => 'issue', 'issue_id' => hidden_issue.id)
    assert result[:isError]
    result = call(@jsmith, 'time_save_rule', 'folders' => ['shop'], 'kind' => 'folder', 'target' => 'monthly',
                                             'project' => @project.identifier, 'subject_template' => 'Shop {year}')
    assert result[:isError]
    assert_equal 0, TimeAutopilotRule.count
    other = create_rule(user: @dlopper, target: 'skip')
    assert call(@jsmith, 'time_delete_rule', 'id' => other.id)[:isError]
  end

  def test_suche_und_zuordnungen
    skip 'ohne redmine_mcp_plugin' unless MCP_INSTALLED

    issue = create_issue(subject: 'Bewerber-Schnittstelle')
    create_rule(kind: 'path', pattern: 'src/Jobs', issue: issue)
    assert_equal [issue.id], call(@jsmith, 'time_search_issues', 'term' => 'bewerber')[:structuredContent][:issues].map { |i| i[:id] }
    assert_equal 'src/Jobs', call(@jsmith, 'time_rules')[:structuredContent][:rules].sole[:pattern]
  end
end
