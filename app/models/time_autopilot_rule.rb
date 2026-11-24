# frozen_string_literal: true

# Eine Zuordnung: Arbeit in bestimmten Ordnern (optional nur bei bestimmten
# Dateien, Branch oder Begriff) geht auf ein Ticket, auf das Ticket des
# Monats oder wird nicht gebucht.
class TimeAutopilotRule < ApplicationRecord
  KINDS = %w[folder path branch term].freeze
  # Reihenfolge, in der Ausnahmen vor dem Standard des Ordners geprüft werden
  EXCEPTION_KINDS = %w[path branch term].freeze
  TARGETS = %w[issue monthly skip].freeze

  belongs_to :user
  belongs_to :issue, optional: true
  belongs_to :project, optional: true
  belongs_to :activity, class_name: 'TimeEntryActivity', optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :target, inclusion: { in: TARGETS }
  validates :pattern, presence: true, if: :exception?
  validates :issue_id, presence: true, if: -> { target == 'issue' }
  validates :project_id, :subject_term, presence: true, if: -> { target == 'monthly' }
  validate :folders_for_default

  scope :for_user, ->(user) { where(user_id: user.id) }

  def self.split_folders(value)
    value.to_s.split(/[\n,]/).map(&:strip).reject(&:blank?).uniq
  end

  def folder_list
    self.class.split_folders(folders)
  end

  def folder_list=(list)
    self.folders = Array(list).map(&:to_s).map(&:strip).reject(&:blank?).uniq.join("\n")
  end

  def exception?
    EXCEPTION_KINDS.include?(kind)
  end

  def skip?
    target == 'skip'
  end

  def monthly?
    target == 'monthly'
  end

  def applies_to_folder?(folder)
    list = folder_list
    list.empty? ? exception? : list.include?(folder)
  end

  def matches?(draft)
    return false unless applies_to_folder?(draft.folder)

    case kind
    when 'folder' then true
    when 'path' then draft.path_list.any? { |path| path_match?(path) }
    when 'branch' then draft.branch.present? && File.fnmatch?(pattern.strip, draft.branch, File::FNM_EXTGLOB)
    when 'term' then draft.search_text.include?(pattern.strip.downcase)
    else false
    end
  end

  private

  # Ohne Platzhalter: der Ordner und alles darunter („www/src/Jobs“);
  # „…/**“ ebenso; sonst Muster, bei dem * auch über / hinweg passt
  def path_match?(path)
    value = pattern.strip.delete_prefix('/').chomp('/')
    prefix = value.delete_suffix('/**')
    if prefix.include?('*') || prefix.include?('?')
      File.fnmatch?(value, path, File::FNM_EXTGLOB)
    else
      path == prefix || path.start_with?("#{prefix}/")
    end
  end

  def folders_for_default
    errors.add(:folders, :blank) if kind == 'folder' && folder_list.empty?
  end
end
