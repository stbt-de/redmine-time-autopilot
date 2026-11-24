# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# Widgets auf Meine Seite und Arbeitszeit in „Mein Konto“
class WidgetsTest < Redmine::IntegrationTest
  include RedmineTimeAutopilot::TestHelper

  fixtures(*FIXTURES, :groups_users)

  def setup
    @user = User.find(2) # jsmith
    log_user('jsmith', 'jsmith')
  end

  def test_widgets_stehen_zur_auswahl
    get '/my/page'
    assert_select 'select#block-select option[value=quick_time_entry]'
    assert_select 'select#block-select option[value=my_week]'
  end

  # Vorhandene Anordnung aus Dashboard Blocks: gleiche Blocknamen, kein Umbau nötig
  def test_vorhandene_bloecke_bleiben
    my_page_blocks(@user, :quick_time_entry, :my_week)
    get '/my/page'
    assert_select '#block-quick_time_entry .ta-quick-time'
    assert_select '#block-my_week .ta-mw'
    assert_select 'link[href*="time_autopilot_blocks"]'
  end

  def test_wochenziel_einstellen
    my_page_blocks(@user, :my_week)
    post '/my/page', params: { settings: { my_week: { target_hours: '32' } } }, xhr: true
    assert_response :success
    get '/my/page'
    assert_select '#block-my_week .ta-mw-total', text: /32/
    assert_select '#block-my_week a[href=?]', '/my/account#ta-work-hours'
  end

  # Arbeitszeit je Wochentag: in Mein Konto, gilt für Widget und Seite „Zeiten“
  def test_arbeitszeit_in_mein_konto
    get '/my/account'
    assert_select '#ta-work-hours input[name=?]', 'work_hours[5]'

    put '/my/account', params: { user: { firstname: @user.firstname }, pref: { time_zone: '' },
                                 work_hours: { '1' => '8', '2' => '8', '3' => '8', '4' => '8', '5' => '6', '6' => '', '7' => '' } }
    assert_redirected_to '/my/account'
    assert_equal '6.0', @user.reload.pref[:dashboard_blocks_work_hours]['5'].to_s

    get '/my/account'
    assert_select '#ta-work-hours input[name=?][value=?]', 'work_hours[5]', '6'

    my_page_blocks(@user, :my_week)
    get '/my/page'
    assert_select '#block-my_week .ta-mw-total', text: /38/
    assert_select '#block-my_week .ta-mw-day-target', minimum: 5
  end

  def test_konto_speichern_ohne_arbeitszeit_laesst_sie_stehen
    RedmineTimeAutopilot::WorkSchedule.new(@user).update('1' => '8')
    put '/my/account', params: { user: { firstname: @user.firstname }, pref: { time_zone: '' } }
    assert_equal '8.0', @user.reload.pref[:dashboard_blocks_work_hours]['1'].to_s
  end

  def test_fremde_arbeitszeit_nur_als_admin
    dlopper = User.find(3)
    put "/users/#{dlopper.id}", params: { user: { firstname: dlopper.firstname }, work_hours: { '1' => '2' } }
    assert_nil dlopper.reload.pref[:dashboard_blocks_work_hours]

    reset!
    log_user('admin', 'admin')
    get "/users/#{dlopper.id}/edit"
    assert_select '#ta-work-hours input[name=?]', 'work_hours[1]'
    put "/users/#{dlopper.id}", params: { user: { firstname: dlopper.firstname }, work_hours: { '1' => '4', '2' => '4' } }
    assert_equal '4.0', dlopper.reload.pref[:dashboard_blocks_work_hours]['1'].to_s

    reset!
    log_user('jsmith', 'jsmith')
    my_page_blocks(@user, :my_week)
    post '/my/page', params: { settings: { my_week: { user_id: dlopper.id.to_s } } }, xhr: true
    get '/my/page'
    assert_select '#block-my_week .ta-mw-total', text: /8/
    assert_select '#block-my_week .ta-work-hours-fixed', text: /#{dlopper.name}/
  end

  def test_woche_wechseln_und_mitarbeiter_waehlen
    my_page_blocks(@user, :my_week)
    dlopper = User.find(3)
    get '/my/page'
    assert_select '#block-my_week select[name=?] option[value=?]', 'settings[my_week][user_id]', dlopper.id.to_s

    previous = RedmineTimeAutopilot::Calendar.week_start(@user.today) - 7
    post '/my/page', params: { my_week_start: previous.iso8601, settings: { my_week: { user_id: dlopper.id.to_s } } },
                     xhr: true
    assert_response :success
    assert_includes response.body, previous.iso8601
    assert_includes response.body, 'ta-mw-current'
  end

  def test_woche_mehrfach_mit_eigener_person
    my_page_blocks(@user)
    post '/my/add_block', params: { block: 'my_week' }, xhr: true
    post '/my/add_block', params: { block: 'my_week__1' }, xhr: true
    assert_equal %w[my_week my_week__1], @user.reload.pref.my_page_layout.values.flatten.grep(/my_week/).sort
  end

  def test_wochenstunden_zeigen_vorschlaege
    create_rule(user: @user, issue: Issue.find(1))
    create_draft(user: @user, spent_on: RedmineTimeAutopilot::Calendar.week_start(@user.today), hours: 1.5)
    my_page_blocks(@user, :my_week)
    get '/my/page'
    assert_select '#block-my_week .ta-mw-pending', text: /1:30|1[,.]5/
    assert_select '#block-my_week .ta-mw-pending a[href^="/time_autopilot"]'
  end

  def test_assets_nur_auf_meiner_seite
    get '/projects/ecookbook'
    assert_select 'link[href*="time_autopilot_blocks"]', 0
  end

  # „Nicht buchen“ zählt nicht als offen
  def test_link_auf_aufgewendete_zeit
    create_draft(user: @user, hours: 2, spent_on: @user.today)
    create_rule(user: @user, folder_list: ['privat'], target: 'skip')
    create_draft(user: @user, hours: 5, folder: 'privat', spent_on: @user.today)
    get '/time_entries'
    assert_includes response.body, 'ta-timelog-link'
    assert_match(/(Zeiten|Time): 2 h/, response.body)
  end

  # --- Zeit buchen ----------------------------------------------------------

  def test_buchen_mit_stunden_und_minuten
    issue = create_assigned_issue(@user)
    assert_difference -> { TimeEntry.count }, 1 do
      post '/time_autopilot/entries',
           params: { issue_id: issue.id, hours: '1:30', spent_on: @user.today.to_s,
                     activity_id: TimeEntryActivity.shared.active.first.id, comments: 'Schnell gebucht' }
    end
    assert_response :success
    entry = TimeEntry.order(:id).last
    assert_in_delta 1.5, entry.hours
    assert_equal [issue, @user, 'Schnell gebucht'], [entry.issue, entry.user, entry.comments]
    assert response.parsed_body['undo']
  end

  def test_buchen_ohne_recht_verboten
    Role.find(1).remove_permission!(:log_time)
    issue = create_assigned_issue(@user)
    assert_no_difference -> { TimeEntry.count } do
      post '/time_autopilot/entries', params: { issue_id: issue.id, hours: '1', spent_on: @user.today.to_s }
    end
    assert_response 403
  end

  def test_fehlende_dauer_mit_fehler_und_link_zum_formular
    issue = create_assigned_issue(@user)
    post '/time_autopilot/entries', params: { issue_id: issue.id, hours: '', spent_on: @user.today.to_s }
    assert_response 422
    assert_equal "/issues/#{issue.id}/time_entries/new", response.parsed_body['form_url']
  end

  def test_rueckgaengig_nur_fuer_eigene_buchung
    issue = create_assigned_issue(@user)
    own = create_time_entry(@user, issue, hours: 1, spent_on: @user.today)
    foreign = create_time_entry(User.find(3), issue, hours: 1, spent_on: @user.today)
    delete "/time_autopilot/entries/#{foreign.id}"
    assert_response 404
    delete "/time_autopilot/entries/#{own.id}"
    assert_response :success
    assert_not TimeEntry.exists?(own.id)
  end

  def test_suche_liefert_projekt_und_kachel
    issue = create_assigned_issue(@user, subject: 'Kategorieseiten schneller laden')
    get '/time_autopilot/entries/issues', params: { q: 'kategorieseiten' }
    hit = response.parsed_body.detect { |entry| entry['id'] == issue.id }
    assert_equal ['Kategorieseiten schneller laden', issue.project.name], [hit['subject'], hit['project']]
    assert_includes hit['tile'], 'ta-project-tile'
  end

  def test_taetigkeiten_des_projekts
    issue = create_assigned_issue(@user)
    get '/time_autopilot/entries/activities', params: { issue_id: issue.id }
    assert_equal issue.project.activities.map(&:id), response.parsed_body.map { |activity| activity['id'] }
  end

  def test_ohne_anmeldung_kein_zugriff
    reset!
    get '/time_autopilot/entries/issues', params: { q: 'x' }, xhr: true
    assert_response 401
  end
end
