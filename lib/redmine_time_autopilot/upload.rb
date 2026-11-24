# frozen_string_literal: true

module RedmineTimeAutopilot
  # Nimmt Entwürfe vom Absender an (REST-API). Je Abschnitt eine Kennung
  # (source_key): erneutes Hochladen ersetzt offene Entwürfe, gebuchte und
  # übersprungene bleiben unberührt. Mit replace_from/replace_to werden offene
  # Entwürfe im Zeitraum entfernt, die nicht mehr mitgeschickt wurden.
  class Upload
    MAX_ITEMS = 5000

    Result = Struct.new(:created, :updated, :kept, :removed, :errors, keyword_init: true)

    def initialize(user)
      @user = user
    end

    def call(items, replace_from: nil, replace_to: nil)
      result = Result.new(created: 0, updated: 0, kept: 0, removed: 0, errors: [])
      items = Array(items).first(MAX_ITEMS)
      keys = []
      TimeAutopilotDraft.transaction do
        items.each_with_index { |item, index| store(item.to_h.stringify_keys, index, result, keys) }
        result.removed = remove_stale(keys, replace_from, replace_to) if replace_from && replace_to
      end
      result
    end

    private

    def store(item, index, result, keys)
      key = item['source_key'].to_s.strip
      if key.blank?
        result.errors << { index: index, message: 'source_key fehlt' }
        return
      end
      keys << key
      draft = TimeAutopilotDraft.for_user(@user).find_or_initialize_by(source_key: key)
      unless draft.new_record? || draft.pending?
        result.kept += 1
        return
      end

      created = draft.new_record?
      draft.attributes = item.slice(*TimeAutopilotDraft::UPLOAD_FIELDS)
      draft.path_list = item['paths'] if item.key?('paths')
      draft.issue_ref_ids = item['issue_refs'] if item.key?('issue_refs')
      draft.summary = draft.summary.to_s.truncate(1024).presence
      draft.source = draft.source.to_s.strip.truncate(60).presence
      if draft.save
        created ? result.created += 1 : result.updated += 1
      else
        result.errors << { index: index, source_key: key, message: draft.errors.full_messages.to_sentence }
      end
    end

    def remove_stale(keys, from, to)
      range = Date.iso8601(from.to_s)..Date.iso8601(to.to_s)
      TimeAutopilotDraft.for_user(@user).pending.within(range).where.not(source_key: keys).delete_all
    rescue Date::Error
      0
    end
  end
end
