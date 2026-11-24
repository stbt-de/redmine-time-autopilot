# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class UploadAndAnswerTest < ActiveSupport::TestCase
  include RedmineTimeAutopilot::TestHelper

  fixtures(*FIXTURES)

  def setup
    setup_autopilot
  end

  def upload(items, **options)
    RedmineTimeAutopilot::Upload.new(@jsmith).call(items, **options)
  end

  def item(key, **attributes)
    { 'source_key' => key, 'spent_on' => MONDAY.iso8601, 'hours' => '0.5', 'folder' => 'shop' }.merge(attributes.stringify_keys)
  end

  def test_hochladen_anlegen_ersetzen_gebuchte_behalten
    result = upload([item('a', paths: ['www/a.php'], issue_refs: ['#12']), item('b')])
    assert_equal 2, result.created
    draft = TimeAutopilotDraft.find_by(source_key: 'a')
    assert_equal ['www/a.php'], draft.path_list
    assert_equal [12], draft.issue_ref_ids

    TimeAutopilotDraft.where(source_key: 'b').update_all(status: 'booked')
    result = upload([item('a', hours: '0.75'), item('b', hours: '9')])
    assert_equal [1, 1], [result.updated, result.kept]
    assert_equal 0.75, draft.reload.hours.to_f
    assert_equal 0.5, TimeAutopilotDraft.find_by(source_key: 'b').hours.to_f
  end

  def test_ersetzen_entfernt_veraltete_offene_entwuerfe
    upload([item('a'), item('b'), item('c', spent_on: (MONDAY + 14).iso8601)])
    result = upload([item('a')], replace_from: MONDAY.iso8601, replace_to: (MONDAY + 6).iso8601)
    assert_equal 1, result.removed
    assert_equal %w[a c], TimeAutopilotDraft.order(:source_key).pluck(:source_key)
  end

  def test_fehlerhafte_eintraege_werden_gemeldet
    result = upload([{ 'hours' => '1' }, item('x', folder: '')])
    assert_equal 2, result.errors.size
    assert_equal 0, TimeAutopilotDraft.count
  end

  def test_entwuerfe_sind_je_person_getrennt
    upload([item('a')])
    RedmineTimeAutopilot::Upload.new(@dlopper).call([item('a')])
    assert_equal 2, TimeAutopilotDraft.where(source_key: 'a').count
  end

  def test_antwort_merken_legt_zuordnung_an
    issue = create_issue
    create_draft(folder: 'monitor')
    answer = RedmineTimeAutopilot::Answer.new(@jsmith, week_for)
    assert answer.call(folder: 'monitor', issue_id: "##{issue.id}", remember: true)
    rule = TimeAutopilotRule.for_user(@jsmith).sole
    assert_equal [['monitor'], 'issue', issue], [rule.folder_list, rule.target, rule.issue]
    assert_empty week_for.questions
    assert_equal issue, week_for.entries.first.issue
  end

  def test_antwort_ohne_merken_gilt_nur_fuer_diese_woche
    issue = create_issue
    draft = create_draft(folder: 'monitor')
    assert RedmineTimeAutopilot::Answer.new(@jsmith, week_for).call(folder: 'monitor', issue_id: issue.id.to_s)
    assert_equal 0, TimeAutopilotRule.count
    assert_equal issue.id, draft.reload.chosen_issue_id
  end

  def test_nicht_buchen_merken
    draft = create_draft(folder: 'privat')
    assert RedmineTimeAutopilot::Answer.new(@jsmith, week_for).call(folder: 'privat', skip: true, remember: true)
    assert TimeAutopilotRule.sole.skip?
    assert draft.reload.pending?
    assert_equal 1.0, week_for.skipped_hours
  end

  def test_antwort_mit_fremdem_ticket_wird_abgelehnt
    create_draft(folder: 'monitor')
    private_issue = hidden_issue
    answer = RedmineTimeAutopilot::Answer.new(@jsmith, week_for)
    assert_not answer.call(folder: 'monitor', issue_id: private_issue.id.to_s, remember: true)
    assert_equal 0, TimeAutopilotRule.count
  end
end
