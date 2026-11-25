# frozen_string_literal: true

module RedmineTimeAutopilot
  # Betreff des Tickets des Monats aus einer Vorlage mit Platzhaltern:
  #
  #   {project}       Name des Projekts
  #   {year}          Jahr, z. B. 2026
  #   {month}         Monatsname in der gewählten Sprache, z. B. November
  #   {month_number}  Monat zweistellig, z. B. 11
  #
  # „Nordlicht - {year} - {month}“ → „Nordlicht - 2026 - November“. Die
  # Platzhalter sind in jeder Sprache gleich; nur {month} hängt von der
  # Sprache ab (Standard: Redmines Standardsprache – das Ticket sehen alle).
  class SubjectTemplate
    PLACEHOLDERS = %w[project year month month_number].freeze
    PLACEHOLDER = /\{(\w+)\}/

    attr_reader :source

    def initialize(source, project: nil, locale: nil)
      @source = source.to_s
      @project = project
      @locale = (locale.presence || Setting.default_language.presence || 'en').to_s
    end

    def self.default
      Setting.plugin_redmine_time_autopilot['subject_template'].presence || '{project} - {year} - {month}'
    end

    def placeholders
      @source.scan(PLACEHOLDER).flatten
    end

    def unknown_placeholders
      placeholders - PLACEHOLDERS
    end

    # Ohne Jahr und Monat hieße jedes Ticket gleich
    def names_month?
      placeholders.include?('year') && (placeholders & %w[month month_number]).any?
    end

    def render(date)
      @source.gsub(PLACEHOLDER) do
        case Regexp.last_match(1)
        when 'project' then @project&.name.to_s
        when 'year' then date.year.to_s
        when 'month' then month_names[date.month - 1]
        when 'month_number' then format('%02d', date.month)
        else Regexp.last_match(0)
        end
      end.squish
    end

    # Passt ein Betreff zur Vorlage, gleich für welchen Monat?
    def matches?(subject)
      pattern.match?(subject.to_s.squish)
    end

    # Gleicher Betreff (Groß-/Kleinschreibung und Leerzeichen egal)
    def same?(subject, date)
      subject.to_s.squish.casecmp?(render(date))
    end

    # Längstes festes Stück – grenzt die Suche in der Datenbank ein
    def fixed_part
      @source.gsub('{project}', @project&.name.to_s).split(PLACEHOLDER).each_slice(2).map(&:first)
             .map(&:squish).max_by(&:length).to_s
    end

    def month_names
      @month_names ||= begin
        names = ::I18n.t('date.month_names', locale: @locale, default: '')
        names = ::I18n.t('date.month_names', locale: :en) unless names.is_a?(Array)
        names.compact
      end
    end

    private

    def pattern
      @pattern ||= begin
        parts = @source.squish.split(PLACEHOLDER)
        regex = parts.each_with_index.map do |part, index|
          next literal(part) if index.even?

          case part
          when 'project' then literal(@project&.name.to_s)
          when 'year' then '\d{4}'
          when 'month' then "(?:#{month_names.map { |name| Regexp.escape(name) }.join('|')})"
          when 'month_number' then '\d{1,2}'
          else literal("{#{part}}")
          end
        end.join
        /\A#{regex}\z/i
      end
    end

    def literal(text)
      text.split(/\s+/, -1).map { |word| Regexp.escape(word) }.join('\s+')
    end
  end
end
