# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class WeekTest < ActiveSupport::TestCase
  include RedmineTimeAutopilot::TestHelper

  fixtures(*FIXTURES)

  def setup
    setup_autopilot
  end

  def test_fragen_je_ordner_mit_stunden_und_tagen
    create_draft(folder: 'monitor', hours: 1, summary: 'Benachrichtigungen')
    create_draft(folder: 'monitor', hours: 2.5, spent_on: MONDAY + 4, summary: 'Deploy')
    create_draft(folder: 'shop', hours: 0.5)
    week = week_for
    assert_equal %w[monitor shop], week.questions.map(&:folder)
    monitor = week.questions.first
    assert_equal 3.5, monitor.hours
    assert_equal [MONDAY, MONDAY + 4], monitor.dates
    assert_equal %w[Benachrichtigungen Deploy], monitor.summaries
    assert_equal [2, 0, 0, 0, 1, 0, 0], week.days.map(&:question_count)
  end

  # Regression: Ein Tag nur mit „nicht buchen“ stand als „bereit“ in der
  # Wochenleiste, weil der Zustand an den erfassten Stunden hing statt an dem,
  # was wirklich zum Buchen bereitsteht.
  def test_tag_nur_mit_nicht_buchen_ist_nicht_bereit
    create_rule(target: 'skip')
    create_draft(hours: 3)
    create_rule(folder_list: ['shop-2'], issue: create_issue)
    create_draft(folder: 'shop-2', spent_on: MONDAY + 1)
    days = week_for.days
    assert_equal [3.0, 0.0], [days[0].hours.to_f, days[0].ready_hours.to_f]
    assert_equal 1.0, days[1].ready_hours.to_f
  end

  def test_ohne_angabe_die_aelteste_woche_mit_offenem
    create_draft(spent_on: MONDAY - 7)
    create_draft(spent_on: MONDAY + 1)
    week = RedmineTimeAutopilot::Week.new(@jsmith, today: MONDAY + 3)
    assert_equal MONDAY - 7, week.start
  end

  def test_ohne_offenes_die_laufende_woche
    week = RedmineTimeAutopilot::Week.new(@jsmith, today: MONDAY + 3)
    assert_equal MONDAY, week.start
  end

  def test_vorschlaege_aus_vermutung_und_letzten_buchungen
    guess = create_issue
    recent = Issue.find(1)
    TimeEntry.create!(project: recent.project, issue: recent, user: @jsmith, author: @jsmith, hours: 3,
                      spent_on: MONDAY, activity: TimeEntryActivity.shared.active.first)
    create_draft(guess_issue_id: guess.id)
    week = week_for
    suggestions = week.suggestions_for(week.questions.first)
    assert_equal guess, suggestions.first
    assert_includes suggestions, recent
  end
end
