# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class ResolverTest < ActiveSupport::TestCase
  include RedmineTimeAutopilot::TestHelper

  fixtures(*FIXTURES)

  def setup
    setup_autopilot
    @maintenance = create_issue(subject: 'Wartung')
    @jobs = create_issue(subject: 'Bewerber-Schnittstelle')
  end

  def resolve(draft)
    RedmineTimeAutopilot::Resolver.new(@jsmith).resolve(draft)
  end

  def test_standard_des_ordners
    create_rule(issue: @maintenance)
    result = resolve(create_draft)
    assert_equal :rule, result.kind
    assert_equal @maintenance, result.issue
    assert result.ready?
  end

  def test_dateien_schlagen_den_standard
    create_rule(issue: @maintenance)
    create_rule(kind: 'path', pattern: 'www/src/Jobs/**', issue: @jobs)
    assert_equal @jobs, resolve(create_draft(path_list: ['www/src/Jobs/Service/Feed.php', 'README.md'])).issue
    assert_equal @maintenance, resolve(create_draft(path_list: ['www/src/Other/Jobs.php'])).issue
  end

  def test_pfad_ohne_platzhalter_gilt_fuer_den_ordner_darunter
    create_rule(kind: 'path', pattern: 'www/src/Jobs', issue: @jobs)
    assert_equal @jobs, resolve(create_draft(path_list: ['www/src/Jobs/A.php'])).issue
    assert_equal :open, resolve(create_draft(path_list: ['www/src/JobsOld/A.php'])).kind
  end

  def test_pfad_mit_muster
    create_rule(kind: 'path', pattern: '*.scss', issue: @jobs)
    assert_equal @jobs, resolve(create_draft(path_list: ['src/scss/components/_a.scss'])).issue
  end

  def test_branch_und_begriff
    branch_issue = create_issue
    create_rule(kind: 'branch', pattern: 'feature/filial*', issue: branch_issue)
    create_rule(kind: 'term', pattern: 'Bewerber', issue: @jobs)
    assert_equal branch_issue, resolve(create_draft(branch: 'feature/filialsuche')).issue
    assert_equal @jobs, resolve(create_draft(summary: 'Webhook für bewerber repariert')).issue
  end

  def test_dateien_vor_branch_vor_begriff
    branch_issue = create_issue
    create_rule(kind: 'term', pattern: 'feed', issue: create_issue)
    create_rule(kind: 'branch', pattern: 'main', issue: branch_issue)
    create_rule(kind: 'path', pattern: 'www/src/Jobs', issue: @jobs)
    draft = create_draft(branch: 'main', summary: 'Feed', path_list: ['www/src/Jobs/Feed.php'])
    assert_equal @jobs, resolve(draft).issue
    draft.update!(paths: '')
    assert_equal branch_issue, resolve(draft).issue
  end

  def test_ticketnummer_in_der_arbeit_gilt_immer
    create_rule(issue: @maintenance)
    result = resolve(create_draft(issue_ref_ids: ["##{@jobs.id}"]))
    assert_equal :ref, result.kind
    assert_equal @jobs, result.issue
  end

  def test_unsichtbare_ticketnummer_wird_ignoriert
    create_rule(issue: @maintenance)
    private_issue = hidden_issue
    assert_equal @maintenance, resolve(create_draft(issue_ref_ids: [private_issue.id])).issue
  end

  def test_gewaehltes_ticket_schlaegt_alles
    create_rule(issue: @maintenance)
    assert_equal @jobs, resolve(create_draft(chosen_issue_id: @jobs.id, issue_ref_ids: [@maintenance.id])).issue
  end

  def test_ohne_zuordnung_offen_oder_vermutung
    assert_equal :open, resolve(create_draft).kind
    result = resolve(create_draft(guess_issue_id: @jobs.id))
    assert_equal :guess, result.kind
    assert result.question?
  end

  def test_nicht_buchen
    create_rule(target: 'skip')
    assert resolve(create_draft).skip?
  end

  def test_zuordnung_gilt_nur_fuer_ihre_ordner
    create_rule(issue: @maintenance, folder_list: %w[shop website])
    create_rule(kind: 'term', pattern: 'jobs', folder_list: ['website'], issue: @jobs)
    assert_equal @maintenance, resolve(create_draft(folder: 'website', summary: 'x')).issue
    assert_equal @maintenance, resolve(create_draft(folder: 'shop', summary: 'jobs')).issue
    assert_equal @jobs, resolve(create_draft(folder: 'website', summary: 'jobs')).issue
    assert_equal :open, resolve(create_draft(folder: 'other')).kind
  end

  def test_ausnahme_ohne_ordner_gilt_ueberall
    create_rule(kind: 'term', pattern: 'jobs', folder_list: [], issue: @jobs)
    assert_equal @jobs, resolve(create_draft(folder: 'irgendwo', summary: 'jobs')).issue
  end

  def test_zuordnungen_anderer_personen_zaehlen_nicht
    create_rule(user: @dlopper, issue: @maintenance)
    assert_equal :open, resolve(create_draft).kind
  end
end
