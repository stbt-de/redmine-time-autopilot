# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class MonthlyIssueTest < ActiveSupport::TestCase
  include RedmineTimeAutopilot::TestHelper

  fixtures(*FIXTURES)

  def setup
    setup_autopilot
    @rule = create_rule(target: 'monthly', project: @project, subject_template: 'Wartung {month} {year}', month_locale: 'de',
                        create_missing: true)
  end

  def finder(user = @jsmith)
    RedmineTimeAutopilot::MonthlyIssue.new(user, @rule.reload)
  end

  def test_findet_ticket_mit_genau_diesem_betreff
    create_issue(subject: 'Wartung Oktober 2026')
    november = create_issue(subject: 'wartung  November 2026')
    create_issue(subject: 'Wartung November 2026 – Nachtrag')
    assert_equal november, finder.find(Date.new(2026, 11, 16))
    assert_nil finder.find(Date.new(2027, 11, 16))
  end

  def test_findet_ticket_ueber_laufzeit_wenn_betreff_zur_vorlage_passt
    issue = create_issue(subject: 'Wartung Dezember 2026', start_date: Date.new(2026, 11, 1), due_date: Date.new(2026, 11, 30))
    create_issue(subject: 'Etwas anderes', start_date: Date.new(2026, 11, 1), due_date: Date.new(2026, 11, 30))
    assert_equal issue, finder.find(Date.new(2026, 11, 16))
  end

  # Regression: erkannt wurde nur „November 2026“. Betreffs wie
  # „Nordlicht - 2026 - November“ (Jahr vorn, Beginn im Vormonat, ohne
  # Abgabedatum) galten nicht als Ticket des Monats – das Buchen hätte ein
  # zweites angelegt, Betreff „… - 2026 - November November 2026“.
  def test_jahr_vor_dem_monat
    @rule.update!(subject_template: 'Nordlicht - {year} - {month}')
    create_issue(subject: 'Nordlicht - 2026 - Oktober', start_date: Date.new(2026, 10, 1))
    november = create_issue(subject: 'Nordlicht - 2026 - November', start_date: Date.new(2026, 10, 28))
    assert_equal november, finder.find(Date.new(2026, 11, 16))
    assert_equal 'Nordlicht - 2026 - Dezember', finder.planned_subject(Date.new(2026, 12, 2))
  end

  # Regression: Vorlage war das letzte Ticket mit dem Begriff, auch ohne
  # Monat („Wartung Video auf Produktseite“) – der neue Betreff wurde
  # „Wartung Video auf Produktseite November 2026“.
  def test_vorlage_nur_ein_monatsticket
    create_issue(subject: 'Wartung Video auf Produktseite', start_date: Date.new(2026, 1, 15), estimated_hours: 3)
    assert_nil finder.template_for(Date.new(2026, 11, 3))
    assert_equal 'Wartung November 2026', finder.create!(Date.new(2026, 11, 3)).subject
  end

  def test_geschlossene_zaehlen_nicht_und_kein_zweites
    create_issue(subject: 'Wartung November 2026', status: IssueStatus.find(5))
    assert_nil finder.find(Date.new(2026, 11, 16))
    assert finder.closed_for?(Date.new(2026, 11, 16))
    resolution = RedmineTimeAutopilot::Resolver.new(@jsmith).resolve(create_draft(spent_on: Date.new(2026, 11, 16)))
    assert_equal :open, resolution.kind
  end

  def test_platzhalter_projekt_und_monatsnummer
    @rule.update!(subject_template: '{project} – Support {year}-{month_number}')
    assert_equal "#{@project.name} – Support 2026-03", finder.planned_subject(Date.new(2026, 3, 9))
    issue = create_issue(subject: "#{@project.name} – Support 2026-03")
    assert_equal issue, finder.find(Date.new(2026, 3, 20))
  end

  # Monatsnamen kommen aus Redmines Sprachdateien – jede Sprache geht
  def test_andere_sprache
    @rule.update!(subject_template: 'Maintenance {month} {year}', month_locale: 'fr')
    assert_equal 'Maintenance novembre 2026', finder.planned_subject(Date.new(2026, 11, 3))
  end

  def test_ohne_sprache_gilt_redmines_standardsprache
    @rule.update!(month_locale: nil)
    with_settings default_language: 'en' do
      assert_equal 'Wartung November 2026', finder.planned_subject(Date.new(2026, 11, 3))
      assert_equal 'Wartung March 2026', finder.planned_subject(Date.new(2026, 3, 3))
    end
    with_settings default_language: 'de' do
      assert_equal 'Wartung März 2026', finder.planned_subject(Date.new(2026, 3, 3))
    end
  end

  def test_vorlage_wird_geprueft
    rule = TimeAutopilotRule.new(user: @jsmith, kind: 'folder', folder_list: ['shop'], target: 'monthly', project: @project)
    rule.subject_template = 'Wartung {month}'
    assert_not rule.valid?
    rule.subject_template = 'Wartung {monat} {year}'
    assert_not rule.valid?
    rule.subject_template = 'Wartung {year} {month_number}'
    assert rule.valid?
    rule.month_locale = 'xx'
    assert_not rule.valid?
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
