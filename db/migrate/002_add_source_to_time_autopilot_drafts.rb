# frozen_string_literal: true

# Absender eines Entwurfs, z. B. „Claude Code“ – steht auf der Seite „Zeiten“
class AddSourceToTimeAutopilotDrafts < ActiveRecord::Migration[6.1]
  def change
    add_column :time_autopilot_drafts, :source, :string, limit: 60
  end
end
