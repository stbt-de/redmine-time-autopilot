# frozen_string_literal: true

# Zuordnungen (Regeln je Person) und Entwürfe (erfasste Arbeitsabschnitte,
# die noch gebucht werden)
class CreateTimeAutopilotTables < ActiveRecord::Migration[6.1]
  def change
    create_table :time_autopilot_rules do |t|
      t.integer :user_id, null: false
      # Ordnernamen, je Zeile einer; leer = in jedem Ordner (nur Ausnahmen)
      t.text :folders
      # folder: Standard für die Ordner; path, branch, term: Ausnahmen
      t.string :kind, null: false, default: 'folder'
      t.string :pattern
      # issue: festes Ticket; monthly: Ticket des Monats; skip: nicht buchen
      t.string :target, null: false, default: 'issue'
      t.integer :issue_id
      t.integer :project_id
      t.string :subject_term
      t.boolean :create_missing, null: false, default: true
      t.boolean :close_previous, null: false, default: false
      t.integer :activity_id
      t.timestamps
    end
    add_index :time_autopilot_rules, :user_id

    create_table :time_autopilot_drafts do |t|
      t.integer :user_id, null: false
      # Kennung des Abschnitts beim Absender: erneutes Hochladen ersetzt ihn
      t.string :source_key, null: false
      t.date :spent_on, null: false
      t.string :started_at, limit: 5
      t.string :ended_at, limit: 5
      t.decimal :hours, precision: 6, scale: 2, null: false, default: 0
      t.string :folder, null: false
      t.string :branch
      t.text :paths
      t.string :issue_refs
      t.string :summary, limit: 1024
      t.integer :guess_issue_id
      # pending, booked, skipped
      t.string :status, null: false, default: 'pending'
      t.integer :chosen_issue_id
      t.integer :time_entry_id
      t.timestamps
    end
    add_index :time_autopilot_drafts, %i[user_id source_key], unique: true
    add_index :time_autopilot_drafts, %i[user_id spent_on]
  end
end
