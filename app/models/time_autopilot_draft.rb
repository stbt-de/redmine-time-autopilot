# frozen_string_literal: true

# Ein erfasster Arbeitsabschnitt (z. B. eine Eingabe an Claude samt der
# Arbeit danach). Wohin er gebucht wird, ergibt sich erst beim Anzeigen aus
# den aktuellen Zuordnungen – so wirkt eine neue Zuordnung sofort auf alle
# offenen Entwürfe.
class TimeAutopilotDraft < ApplicationRecord
  STATUSES = %w[pending booked skipped].freeze

  belongs_to :user
  belongs_to :time_entry, optional: true

  validates :source_key, :spent_on, :folder, presence: true
  validates :source_key, uniqueness: { scope: :user_id }
  validates :status, inclusion: { in: STATUSES }
  validates :hours, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 24 }

  scope :for_user, ->(user) { where(user_id: user.id) }
  scope :pending, -> { where(status: 'pending') }
  scope :within, ->(range) { where(spent_on: range) }

  # Felder, die der Absender schicken darf
  UPLOAD_FIELDS = %w[spent_on started_at ended_at hours folder branch summary guess_issue_id source].freeze

  def path_list
    paths.to_s.split("\n").map(&:strip).reject(&:blank?)
  end

  def path_list=(list)
    self.paths = Array(list).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(200).join("\n")
  end

  def issue_ref_ids
    issue_refs.to_s.scan(/\d+/).map(&:to_i).uniq
  end

  def issue_ref_ids=(list)
    self.issue_refs = Array(list).map { |value| value.to_s[/\d+/] }.compact.uniq.join(' ')
  end

  # Text für Begriffs-Zuordnungen: Zusammenfassung, Branch und Dateipfade
  def search_text
    [summary, branch, *path_list].compact.join("\n").downcase
  end

  # Name des Absenders für die Anzeige
  def source_name
    source.presence || ::I18n.t(:label_time_autopilot_unknown_source)
  end

  def pending?
    status == 'pending'
  end
end
