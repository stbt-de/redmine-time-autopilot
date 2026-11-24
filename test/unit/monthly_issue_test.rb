# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class MonthlyIssueTest < ActiveSupport::TestCase
  include RedmineTimeAutopilot::TestHelper

  fixtures(*FIXTURES)

  def setup
    setup_autopilot
    @rule = create_rule(target: 'monthly', project: @project, subject_term: 'Wartung', create_missing: true)
  end

  def finder(user = @jsmith)
    RedmineTimeAutopilot::MonthlyIssue.new(user, @rule)
  end

  def test_findet_ticket_ueber_laufzeit
    create_issue(subject: 'Wartung Oktober 2026', start_date: Date.new(2026, 10, 1), due_date: Date.new(2026, 10, 31))
    november = create_issue(subject: 'Wartung November 2026', start_date: Date.new(2026, 11, 1), due_date: Date.new(2026, 11, 30))
    create_issue(subject: 'Etwas anderes', start_date: Date.new(2026, 11, 1), due_date: Date.new(2026, 11, 30))
    assert_equal november, finder.find(Date.new(2026, 11, 16))
    assert_nil finder.find(Date.new(2026, 12, 2))
  end

  def test_findet_ticket_ueber_monat_im_betreff
    november = create_issue(subject: 'Wartung November 2026')
    assert_equal november, finder.find(Date.new(2026, 11, 16))
    assert_nil finder.find(Date.new(2027, 11, 16))
  end

  def test_geschlossene_zaehlen_nicht
    create_issue(subject: 'Wartung November 2026', status: IssueStatus.find(5))
    assert_nil finder.find(Date.new(2026, 11, 16))
  end

  def test_betreff_bekommt_den_neuen_monat
    create_issue(subject: 'Wartung Oktober 2026', start_date: Date.new(2026, 10, 1), due_date: Date.new(2026, 10, 31))
    assert_equal 'Wartung November 2026', finder.planned_subject(Date.new(2026, 11, 3))
  end

  def test_betreff_englisch_und_ohne_monat
    @rule.update!(subject_term: 'Maintenance')
    create_issue(subject: 'Maintenance December 2025', start_date: Date.new(2025, 12, 1))
    assert_equal 'Maintenance January 2026', finder.planned_subject(Date.new(2026, 1, 5))
    @rule.update!(subject_term: 'Support')
    assert_match(/\ASupport \S+ 2026\z/, finder.planned_subject(Date.new(2026, 1, 5)))
  end

  def test_legt_ticket_aus_vormonat_an_und_schliesst_ihn
    @rule.update!(close_previous: true)
    october = create_issue(subject: 'Wartung Oktober 2026', start_date: Date.new(2026, 10, 1), due_date: Date.new(2026, 10, 31),
                           estimated_hours: 10, assigned_to: @jsmith)
    issue = finder.create!(Date.new(2026, 11, 16))
    assert_equal 'Wartung November 2026', issue.subject
    assert_equal [Date.new(2026, 11, 1), Date.new(2026, 11, 30)], [issue.start_date, issue.due_date]
    assert_equal 10, issue.estimated_hours
    assert_equal @jsmith, issue.assigned_to
    assert_equal @jsmith, issue.author
    assert_not issue.closed?
    assert october.reload.closed?
    assert_equal issue, finder.find(Date.new(2026, 11, 20))
  end

  def test_ohne_recht_kein_neues_ticket
    @rule.update!(user: @dlopper)
    Role.find(2).remove_permission!(:add_issues)
    assert_not finder(@dlopper).can_create?
    assert_raises(RedmineTimeAutopilot::BookingError) { finder(@dlopper).create!(Date.new(2026, 11, 16)) }
  end
end
