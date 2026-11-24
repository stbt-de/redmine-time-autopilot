# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# REST-Schnittstelle für Agents und den MCP-Server: Woche lesen, Fragen
# beantworten, buchen – mit API-Schlüssel, mit Redmines Rechten
class ApiTest < Redmine::IntegrationTest
  include RedmineTimeAutopilot::TestHelper

  fixtures(*FIXTURES)

  def setup
    setup_autopilot
    Setting.rest_api_enabled = '1'
  end

  def headers(user = @jsmith)
    { 'CONTENT_TYPE' => 'application/json', 'X-Redmine-API-Key' => user.api_key }
  end

  def test_woche_mit_fragen_und_vorschlaegen
    issue = create_issue(subject: 'Wartung')
    create_rule(issue: issue)
    create_draft(hours: 1.5, summary: 'Updates', source: 'Claude Code')
    create_draft(folder: 'monitor', hours: 2, summary: 'Deploy')

    get "/time_autopilot.json?week=#{MONDAY.iso8601}", headers: headers
    assert_response :success
    body = response.parsed_body
    assert_equal ['monitor'], body['questions'].map { |question| question['folder'] }
    proposal = body['proposals'].sole
    assert_equal ["#{MONDAY.iso8601}-issue-#{issue.id}", 1.5, issue.id, 'Updates'],
                 [proposal['key'], proposal['hours'], proposal['issue']['id'], proposal['comments']]
    assert_includes proposal['origin'], 'Claude Code'
    assert_equal 1.5, body['totals']['proposed']
    assert_equal ['Claude Code', I18n.t(:label_time_autopilot_unknown_source)].sort, body['sources'].map { |source| source['name'] }.sort
  end

  def test_frage_beantworten_und_buchen
    issue = create_issue(subject: 'Kampagnen-Monitor')
    create_draft(folder: 'monitor', hours: 2, summary: 'Deploy')

    post "/time_autopilot/answer.json?week=#{MONDAY.iso8601}",
         params: { folder: 'monitor', issue_id: issue.id, remember: true }.to_json, headers: headers
    assert_response :success
    assert_equal issue, TimeAutopilotRule.sole.issue

    key = "#{MONDAY.iso8601}-issue-#{issue.id}"
    post "/time_autopilot/book.json?week=#{MONDAY.iso8601}", params: { hours: { key => '1,5' } }.to_json, headers: headers
    assert_response :success
    assert_equal 1.5, response.parsed_body['booked_hours']
    assert_equal 1.5, TimeEntry.where(issue_id: issue.id, user_id: @jsmith.id).sole.hours
  end

  def test_nur_ausgewaehlte_eintraege_buchen
    issue = create_issue
    create_rule(issue: issue)
    create_draft(hours: 1)
    create_draft(hours: 2, spent_on: MONDAY + 1)
    keys = ["#{MONDAY.iso8601}-issue-#{issue.id}"]

    post "/time_autopilot/book.json?week=#{MONDAY.iso8601}", params: { keys: keys }.to_json, headers: headers
    assert_equal [MONDAY], TimeEntry.where(issue_id: issue.id).pluck(:spent_on)
    assert_equal 1, week_for.entries.size
  end

  def test_nicht_buchen_per_api
    create_draft(folder: 'privat')
    post "/time_autopilot/answer.json?week=#{MONDAY.iso8601}",
         params: { folder: 'privat', skip: true, remember: true }.to_json, headers: headers
    assert_response :success
    assert TimeAutopilotRule.sole.skip?
  end

  def test_fehler_als_json
    create_draft(folder: 'monitor')
    post "/time_autopilot/answer.json?week=#{MONDAY.iso8601}",
         params: { folder: 'monitor', issue_id: hidden_issue.id }.to_json, headers: headers
    assert_response 422
    assert response.parsed_body['errors'].any?
  end

  def test_zuordnungen_und_ticketsuche
    issue = create_issue(subject: 'Bewerber-Schnittstelle')
    create_rule(kind: 'path', pattern: 'www/src/Jobs', issue: issue)
    create_draft(folder: 'katalog')

    get '/time_autopilot/rules.json', headers: headers
    assert_response :success
    rule = response.parsed_body['rules'].sole
    assert_equal ['path', 'www/src/Jobs', issue.id], [rule['kind'], rule['pattern'], rule['issue']['id']]
    assert_includes rule['sentence'], 'www/src/Jobs'
    assert_equal ['katalog'], response.parsed_body['unassigned'].map { |item| item['folder'] }

    get '/time_autopilot/issues.json', params: { term: 'bewerber' }, headers: headers
    assert_equal issue.id, response.parsed_body.first['id']
  end

  def test_ohne_schluessel_kein_zugriff
    get "/time_autopilot.json?week=#{MONDAY.iso8601}"
    assert_response 401
    post "/time_autopilot/book.json?week=#{MONDAY.iso8601}", params: {}.to_json, headers: { 'CONTENT_TYPE' => 'application/json' }
    assert_response 401
  end
end
