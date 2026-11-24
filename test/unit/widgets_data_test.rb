# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

# Widgets „Wochenstunden“ und „Zeit buchen“ (bis 1.3 in Dashboard Blocks)
class WidgetsDataTest < ActiveSupport::TestCase
  include RedmineTimeAutopilot::TestHelper

  fixtures(*FIXTURES, :groups_users)

  def setup
    @user = User.find(2) # jsmith, Manager in Projekt 1
    User.current = @user
    Issue.where(assigned_to_id: @user.id).update_all(assigned_to_id: nil)
  end


  # --- Wochenstunden --------------------------------------------------------

  def test_woche_summiert_je_tag
    issue = Issue.find(1)
    start = RedmineTimeAutopilot::Calendar.week_start(@user.today)
    TimeEntry.where(user_id: @user.id).delete_all
    create_time_entry(@user, issue, hours: 2, spent_on: start)
    create_time_entry(@user, issue, hours: 1.5, spent_on: start)
    create_time_entry(@user, issue, hours: 3, spent_on: start - 1) # Vorwoche

    week = RedmineTimeAutopilot::WeekSummary.new(@user)
    assert_in_delta 3.5, week.total
    assert_in_delta 3.5, week.days.first.hours
    assert_equal [Project.find(1), 3.5], week.top_project
  end

  def test_freie_tage_nur_mit_buchung
    with_settings non_working_week_days: %w[6 7], start_of_week: '1' do
      TimeEntry.where(user_id: @user.id).delete_all
      week = RedmineTimeAutopilot::WeekSummary.new(@user)
      assert_equal (1..5).to_a, week.days.map { |day| day.date.cwday }

      # Gebucht am Samstag: Samstag und Sonntag erscheinen beide
      create_time_entry(@user, Issue.find(1), hours: 1, spent_on: week.start + 5)
      week = RedmineTimeAutopilot::WeekSummary.new(@user)
      assert_equal (1..7).to_a, week.days.map { |day| day.date.cwday }
    end
  end

  def test_woche_vor_und_zurueck
    with_settings start_of_week: '1' do
      TimeEntry.where(user_id: @user.id).delete_all
      current = RedmineTimeAutopilot::WeekSummary.new(@user)
      create_time_entry(@user, Issue.find(1), hours: 2, spent_on: current.previous_start + 1)

      previous = RedmineTimeAutopilot::WeekSummary.new(@user, date: current.previous_start.iso8601)
      assert_not previous.current?
      assert_equal current.start - 7, previous.start
      assert_in_delta 2, previous.total
      assert_in_delta 0, current.total
      assert_equal current.start, RedmineTimeAutopilot::WeekSummary.new(@user, date: 'kein-datum').start
      assert_equal 1, RedmineTimeAutopilot::WeekSummary.new(@user, date: '2026-01-01').number
    end
  end

  def test_stunden_eines_anderen_mitarbeiters
    dlopper = User.find(3) # Developer in Projekt 1
    TimeEntry.where(user_id: dlopper.id).delete_all
    start = RedmineTimeAutopilot::Calendar.week_start(@user.today)
    create_time_entry(dlopper, Issue.find(1), hours: 4, spent_on: start)

    assert_includes RedmineTimeAutopilot::WeekSummary.selectable_users(@user), dlopper
    assert_equal @user, RedmineTimeAutopilot::WeekSummary.selectable_users(@user).first
    person = RedmineTimeAutopilot::WeekSummary.resolve_user(@user, dlopper.id.to_s)
    assert_in_delta 4, RedmineTimeAutopilot::WeekSummary.new(@user, user: person).total
  end

  def test_fremde_stunden_nur_mit_recht
    dlopper = User.find(3)
    TimeEntry.where(user_id: dlopper.id).delete_all
    create_time_entry(dlopper, Issue.find(1), hours: 4, spent_on: @user.today)
    Role.find_each { |role| role.remove_permission!(:view_time_entries) }

    # Nicht wählbar: zurück auf den Betrachter …
    assert_equal @user, RedmineTimeAutopilot::WeekSummary.resolve_user(@user, dlopper.id.to_s)
    # … und auch direkt übergeben keine fremden Stunden
    assert_in_delta 0, RedmineTimeAutopilot::WeekSummary.new(@user, user: dlopper).total
  end

  def test_wochenziel_mit_komma_und_standard
    assert_in_delta 37.5, RedmineTimeAutopilot::WeekSummary.new(@user, target: '37,5').target
    assert_in_delta 40, RedmineTimeAutopilot::WeekSummary.new(@user, target: '').target
    assert_in_delta 40, RedmineTimeAutopilot::WeekSummary.new(@user, target: '-3').target
  end

  # Arbeitszeit je Wochentag: Ziel ist die Summe, freie Tage nach der Person
  def test_arbeitszeit_je_wochentag
    with_settings non_working_week_days: %w[6 7], start_of_week: '1' do
      TimeEntry.where(user_id: @user.id).delete_all
      RedmineTimeAutopilot::WorkSchedule.new(@user)
                                          .update('1' => '8', '2' => '8', '3' => '7,5', '4' => '8', '5' => '', '6' => '4')
      week = RedmineTimeAutopilot::WeekSummary.new(@user, target: '40')
      assert week.scheduled?
      assert_in_delta 35.5, week.target
      assert_equal [1, 2, 3, 4, 6], week.days.map { |day| day.date.cwday }
      assert_in_delta 7.5, week.days.third.target
      assert_in_delta 8, week.daily_target

      # Alles leer: Einstellung weg, wieder das Wochenziel des Blocks
      RedmineTimeAutopilot::WorkSchedule.new(@user).update('1' => '0')
      week = RedmineTimeAutopilot::WeekSummary.new(@user.reload, target: '30')
      assert_not week.scheduled?
      assert_in_delta 30, week.target
      assert_in_delta 6, week.days.first.target
    end
  end

  def test_arbeitszeit_kappt_unsinnige_werte
    RedmineTimeAutopilot::WorkSchedule.new(@user).update('1' => '30', '2' => '-4', '3' => 'abc', '9' => '8')
    assert_equal({ 1 => 24.0, 2 => 0.0, 3 => 0.0, 4 => 0.0, 5 => 0.0, 6 => 0.0, 7 => 0.0 },
                 RedmineTimeAutopilot::WorkSchedule.new(@user.reload).hours)
  end

  def test_arbeitszeit_aendern_nur_selbst_oder_admin
    dlopper = User.find(3)
    assert RedmineTimeAutopilot::WorkSchedule.editable?(@user, @user)
    assert_not RedmineTimeAutopilot::WorkSchedule.editable?(@user, dlopper)
    assert RedmineTimeAutopilot::WorkSchedule.editable?(User.find(1), dlopper)
  end

  # --- Zeit buchen: Suche ---------------------------------------------------

  def test_suche_nach_nummer_titel_und_projekt
    issue = create_assigned_issue(@user, subject: 'Versandarten nach Gewicht')
    quick = RedmineTimeAutopilot::QuickTimeEntry.new(@user)

    assert_equal issue, quick.search("##{issue.id}").first
    assert_includes quick.search('versandarten gewicht'), issue
    assert_includes quick.search("#{Project.find(1).name} versand"), issue
  end

  def test_suche_ohne_geschlossene_und_ohne_buchungsrecht
    closed = create_assigned_issue(@user, subject: 'Geschlossenes Zielticket', status: IssueStatus.find(5))
    # Projekt 2 (OnlineStore): jsmith ist dort nicht Mitglied, Projekt ist privat
    foreign = Issue.create!(project: Project.find(2), tracker: Project.find(2).trackers.first, author: User.find(1),
                            subject: 'Fremdes Zielticket', priority: IssuePriority.first)
    results = RedmineTimeAutopilot::QuickTimeEntry.new(@user).search('Zielticket')

    assert_not_includes results, closed
    assert_not_includes results, foreign
  end

  def test_zuletzt_gebuchte_tickets_neueste_zuerst
    TimeEntry.where(user_id: @user.id).delete_all
    first = create_assigned_issue(@user)
    second = create_assigned_issue(@user)
    create_time_entry(@user, first, hours: 1, spent_on: @user.today - 2)
    create_time_entry(@user, second, hours: 1, spent_on: @user.today - 1)
    create_time_entry(@user, first, hours: 1, spent_on: @user.today - 3)

    assert_equal [second, first], RedmineTimeAutopilot::QuickTimeEntry.new(@user).recent_issues
  end
end
