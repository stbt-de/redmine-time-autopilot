# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class TimeAutopilotTest < Redmine::IntegrationTest
  include RedmineTimeAutopilot::TestHelper

  fixtures(*FIXTURES)

  def setup
    setup_autopilot
  end

  def test_hochladen_per_api
    with_settings rest_api_enabled: '1' do
      payload = { drafts: [{ source_key: 'k1', spent_on: MONDAY.iso8601, hours: 0.75, folder: 'shop',
                             branch: 'main', paths: ['www/a.php'], issue_refs: ['#1'], summary: 'Fehler behoben' }] }
      post '/time_autopilot/drafts.json', params: payload.to_json,
                                          headers: { 'CONTENT_TYPE' => 'application/json', 'X-Redmine-API-Key' => @jsmith.api_key }
      assert_response :success
      assert_equal 1, response.parsed_body['created']
      draft = TimeAutopilotDraft.sole
      assert_equal [@jsmith, 'shop', ['www/a.php'], [1]], [draft.user, draft.folder, draft.path_list, draft.issue_ref_ids]
    end
  end

  def test_hochladen_ohne_recht_aufwand_zu_buchen
    with_settings rest_api_enabled: '1' do
      user = user_without_projects
      post '/time_autopilot/drafts.json', params: { drafts: [] }.to_json,
                                          headers: { 'CONTENT_TYPE' => 'application/json', 'X-Redmine-API-Key' => user.api_key }
      assert_response :forbidden
    end
  end

  def test_woche_fragen_beantworten_und_buchen
    issue = create_issue(subject: 'Kampagnen-Monitor')
    create_draft(folder: 'monitor', hours: 1.25, summary: 'Benachrichtigungen')
    log_user('jsmith', 'jsmith')

    get "/time_autopilot?week=#{MONDAY.iso8601}"
    assert_response :success
    assert_select '#top-menu a.time-autopilot'
    assert_select '.ta-question .ta-q-title', text: /monitor/
    assert_select '.ta-day.is-open', 1
    # Regression: als type=text fokussierte Redmine das Suchfeld beim Laden,
    # die Seite sprang auf dem Handy zur ersten Frage
    assert_select 'input[type=text].ta-search, input[type=text].ta-issue-search', 0
    assert_select 'input[type=search].ta-search', 1

    post "/time_autopilot/answer?week=#{MONDAY.iso8601}", params: { folder: 'monitor', issue_id: issue.id.to_s, remember: '1' }
    assert_redirected_to "/time_autopilot?week=#{MONDAY.iso8601}"
    follow_redirect!
    assert_select '.ta-question', 0
    assert_select '.ta-entry-title a', text: /Kampagnen-Monitor/

    key = "#{MONDAY.iso8601}-issue-#{issue.id}"
    post "/time_autopilot/book?week=#{MONDAY.iso8601}", params: { hours: { key => '1,5' } }
    entry = TimeEntry.where(user_id: @jsmith.id, issue_id: issue.id).sole
    assert_equal [1.5, MONDAY, 'Benachrichtigungen'], [entry.hours, entry.spent_on, entry.comments]
    follow_redirect!
    assert_select '.flash.notice', text: /1,5|1.5/
  end

  # Regression: Die Erklärung ohne Entwürfe kam mit sichtbaren Tags
  # („<b>Arbeit wird erfasst</b>“), weil Redmines l() HTML-Texte escaped.
  def test_erklaerung_ohne_entwuerfe_mit_formatierung
    log_user('jsmith', 'jsmith')
    get "/time_autopilot?week=#{MONDAY.iso8601}"
    assert_select '.ta-how li b', 3
    assert_not_includes response.body, '&lt;b&gt;'
  end

  def test_ohne_recht_kein_zugang
    user = user_without_projects
    log_user(user.login, 'nobody-1234-pw')
    get '/time_autopilot'
    assert_response :forbidden
    get '/time_autopilot/rules'
    assert_response :forbidden
  end

  def test_zuordnung_anlegen_aendern_loeschen
    log_user('jsmith', 'jsmith')
    get '/time_autopilot/rules/new?folders=shop'
    assert_response :success
    assert_select 'textarea[name="rule[folders]"]', text: /shop/

    post '/time_autopilot/rules', params: { rule: { folders: "shop\nwebsite", kind: 'folder', target: 'monthly',
                                                    project_id: @project.id, subject_term: 'Wartung', create_missing: '1' } }
    assert_redirected_to '/time_autopilot/rules'
    rule = TimeAutopilotRule.sole
    assert_equal [%w[shop website], 'monthly', @project], [rule.folder_list, rule.target, rule.project]

    get '/time_autopilot/rules'
    assert_select '.ta-rule b', text: 'website'
    get "/time_autopilot/rules/#{rule.id}/edit"
    assert_select '.ta-preview li', 3

    patch "/time_autopilot/rules/#{rule.id}", params: { rule: { target: 'skip' } }
    assert rule.reload.skip?
    assert_nil rule.project_id

    delete "/time_autopilot/rules/#{rule.id}"
    assert_equal 0, TimeAutopilotRule.count
  end

  def test_fremde_zuordnung_nicht_erreichbar
    rule = create_rule(user: @dlopper, target: 'skip')
    log_user('jsmith', 'jsmith')
    get "/time_autopilot/rules/#{rule.id}/edit"
    assert_response :not_found
    delete "/time_autopilot/rules/#{rule.id}"
    assert_response :not_found
    assert TimeAutopilotRule.exists?(rule.id)
  end

  def test_ticketsuche_nach_betreff_und_nummer
    match = create_issue(subject: 'Bewerber-Schnittstelle anbinden')
    closed = create_issue(subject: 'Bewerber alt', status: IssueStatus.find(5))
    hidden = hidden_issue
    hidden.update_column(:subject, 'Bewerber versteckt')
    log_user('jsmith', 'jsmith')

    get '/time_autopilot/issues', params: { term: 'bewerber' }
    assert_response :success, response.status.to_s
    ids = response.parsed_body.map { |item| item['id'] }
    assert_includes ids, match.id
    assert_not_includes ids, closed.id
    assert_not_includes ids, hidden.id
    item = response.parsed_body.detect { |candidate| candidate['id'] == match.id }
    assert_equal "##{match.id} Bewerber-Schnittstelle anbinden", item['value']
    assert_includes item['label'], @project.name

    get '/time_autopilot/issues', params: { term: "##{match.id}" }
    assert_equal match.id, response.parsed_body.first['id']
  end

  def test_antwort_mit_gesuchtem_ticket
    issue = create_issue(subject: 'Katalog-Filter')
    create_draft(folder: 'katalog')
    log_user('jsmith', 'jsmith')
    post "/time_autopilot/answer?week=#{MONDAY.iso8601}",
         params: { folder: 'katalog', choice: 'skip', issue_id: "##{issue.id} Katalog-Filter", remember: '1' }
    assert_equal issue, TimeAutopilotRule.sole.issue
  end

  def test_ungueltiges_ticket_in_zuordnung
    log_user('jsmith', 'jsmith')
    post '/time_autopilot/rules', params: { rule: { folders: 'shop', kind: 'folder', target: 'issue', issue_id: '999999' } }
    assert_response 422
    assert_equal 0, TimeAutopilotRule.count
  end
end
