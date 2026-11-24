# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class BookingTest < ActiveSupport::TestCase
  include RedmineTimeAutopilot::TestHelper

  fixtures(*FIXTURES)

  def setup
    setup_autopilot
    @maintenance = create_issue(subject: 'Wartung')
  end

  def book(week = week_for, hours: {})
    RedmineTimeAutopilot::Booking.new(@jsmith, week).call(hours: hours)
  end

  def test_je_tag_und_ticket_eine_buchung
    create_rule(issue: @maintenance)
    first = create_draft(hours: 0.5, summary: 'Updates')
    second = create_draft(hours: 0.25, summary: 'Cache geleert')
    create_draft(hours: 0.25, summary: 'Updates')
    create_draft(hours: 1, spent_on: MONDAY + 1, summary: 'Weiterleitung')
    booking = book
    assert_equal 2, booking.booked.size
    monday = booking.booked.detect { |entry| entry.spent_on == MONDAY }
    assert_equal 1.0, monday.hours
    assert_equal 'Updates; Cache geleert', monday.comments
    assert_equal @maintenance, monday.issue
    assert_equal @jsmith, monday.user
    assert_equal %w[booked booked], [first.reload.status, second.reload.status]
    assert_equal monday, first.time_entry
  end

  def test_stunden_aendern_und_null_heisst_nicht_buchen
    create_rule(issue: @maintenance)
    create_draft(hours: 1)
    other = create_draft(hours: 2, spent_on: MONDAY + 1)
    week = week_for
    keys = week.entries.map(&:key)
    booking = book(week, hours: { keys.first => '1,5', keys.last => '0' })
    assert_equal [1.5], booking.booked.map(&:hours)
    assert_equal 'skipped', other.reload.status
  end

  def test_fehlendes_monatsticket_wird_einmal_angelegt
    create_rule(target: 'monthly', project: @project, subject_term: 'Wartung', create_missing: true)
    create_issue(subject: 'Wartung Oktober 2026', start_date: Date.new(2026, 10, 1), due_date: Date.new(2026, 10, 31))
    create_draft(hours: 1)
    create_draft(hours: 2, spent_on: MONDAY + 2)
    week = week_for
    assert(week.entries.all?(&:to_create?))
    booking = book(week)
    assert_equal 1, booking.created_issues.size
    assert_equal 'Wartung November 2026', booking.created_issues.first.subject
    assert_equal [booking.created_issues.first], booking.booked.map(&:issue).uniq
  end

  def test_ohne_recht_bleibt_der_entwurf_stehen
    create_rule(issue: @maintenance)
    draft = create_draft
    Role.find(1).remove_permission!(:log_time)
    booking = book
    assert_empty booking.booked
    assert_equal 1, booking.failures.size
    assert draft.reload.pending?
  end

  def test_stunden_auf_viertelstunden_gerundet
    create_rule(issue: @maintenance)
    create_draft(hours: 0.37)
    create_draft(hours: 0.41)
    create_draft(hours: 0.05, spent_on: MONDAY + 1)
    assert_equal [0.75, 0.25], week_for.entries.map(&:hours)
    assert_equal [0.75, 0.25], book.booked.map(&:hours)
  end

  def test_gebuchte_entwuerfe_erscheinen_nicht_wieder
    create_rule(issue: @maintenance)
    create_draft
    book
    assert_empty week_for.entries
    assert_equal 1.0, week_for.booked_hours
  end
end
