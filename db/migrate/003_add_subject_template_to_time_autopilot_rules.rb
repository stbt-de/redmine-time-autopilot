# frozen_string_literal: true

# Ticket des Monats: Vorlage für den Betreff („Nordlicht - {year} - {month}“)
# und Sprache der Monatsnamen statt „Betreff enthält“. Bestehende Zuordnungen
# bekommen die Vorlage „<Begriff> {month} {year}“ – so hießen die Tickets bisher.
class AddSubjectTemplateToTimeAutopilotRules < ActiveRecord::Migration[6.1]
  class Rule < ActiveRecord::Base
    self.table_name = 'time_autopilot_rules'
  end

  def up
    add_column :time_autopilot_rules, :subject_template, :string
    add_column :time_autopilot_rules, :month_locale, :string, limit: 10
    Rule.reset_column_information
    Rule.where(target: 'monthly').find_each do |rule|
      rule.update_columns(subject_template: "#{rule.subject_term.to_s.strip} {month} {year}".strip)
    end
    remove_column :time_autopilot_rules, :subject_term
  end

  def down
    add_column :time_autopilot_rules, :subject_term, :string
    Rule.reset_column_information
    Rule.where(target: 'monthly').find_each do |rule|
      rule.update_columns(subject_term: rule.subject_template.to_s.gsub(/\{\w+\}/, ' ').squish)
    end
    remove_column :time_autopilot_rules, :month_locale
    remove_column :time_autopilot_rules, :subject_template
  end
end
