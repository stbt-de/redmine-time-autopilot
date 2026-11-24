# frozen_string_literal: true

module TimeAutopilotHelper
  # Projekt als kleine Kachel: Icon aus redmine_project_icons, wenn das
  # Plugin installiert ist und für das Projekt eins gilt; sonst der
  # Anfangsbuchstabe auf neutraler Fläche
  def time_autopilot_project_tile(project, size: 20)
    if respond_to?(:project_icon_tag)
      icon = project_icon_tag(project, size: size)
      return icon if icon.present?
    end

    content_tag(:span, project.name.to_s.strip[0].to_s.upcase,
                class: 'ta-project-tile', style: "--ta-tile-size: #{size.to_i}px", 'aria-hidden': 'true')
  end

  # Stunden wie in Redmine formatiert („1:30 h“ bzw. „1.50 h“, je nach
  # Einstellung „Zeitspannenformat“)
  def time_autopilot_hours(hours)
    l_hours_short(hours)
  end

  # Wo die Arbeitszeit einer Person gepflegt wird: eigene in „Mein Konto“,
  # fremde (nur Admins) in der Benutzerverwaltung
  def time_autopilot_work_hours_path(person, own)
    own ? my_account_path(anchor: 'ta-work-hours') : edit_user_path(person, anchor: 'ta-work-hours')
  end

  # Stunden ohne überflüssige Nullen, mit Komma je nach Sprache: 1,75 · 0,5 · 2
  def ta_hours(hours)
    number_with_precision(hours.to_f, precision: 2, strip_insignificant_zeros: true)
  end

  def ta_issue_label(issue)
    "##{issue.id} #{issue.subject}"
  end

  def ta_issue_link(issue)
    link_to ta_issue_label(issue), issue_path(issue)
  end

  def ta_entry_title(entry)
    entry.issue ? ta_issue_label(entry.issue) : entry.planned_subject
  end

  def ta_day_label(date)
    "#{ta_day_abbr(date.cwday)} #{date.strftime('%-d.%-m.')}"
  end

  def ta_day_short(date)
    "#{ta_day_abbr(date.cwday)} #{date.day}."
  end

  def ta_day_abbr(cwday)
    ::I18n.t('date.abbr_day_names')[cwday % 7]
  end

  # Herkunft eines Vorschlags: Absender · Ordner · Zeit · Grund der Zuordnung
  def ta_entry_origin(entry)
    drafts = entry.drafts
    timing = if drafts.size == 1 && drafts.first.started_at.present?
               [drafts.first.started_at, drafts.first.ended_at].compact.join('–')
             elsif drafts.size > 1
               l(:text_time_autopilot_segments, count: drafts.size)
             end
    [drafts.map(&:source_name).uniq.join(', '), drafts.map(&:folder).uniq.join(', '), timing, ta_reason(entry.resolution)]
      .compact_blank.join(' · ')
  end

  # Warum ein Eintrag dort landet – ein Satz
  def ta_reason(resolution)
    rule = resolution.rule
    case resolution.kind
    when :chosen then l(:text_time_autopilot_reason_chosen)
    when :ref then l(:text_time_autopilot_reason_ref)
    when :monthly
      if resolution.to_create?
        l(:text_time_autopilot_reason_monthly_new, template: ta_template_label(resolution))
      else
        l(:text_time_autopilot_reason_monthly, term: rule.subject_term)
      end
    when :rule
      case rule.kind
      when 'path' then l(:text_time_autopilot_reason_path, pattern: rule.pattern)
      when 'branch' then l(:text_time_autopilot_reason_branch, pattern: rule.pattern)
      when 'term' then l(:text_time_autopilot_reason_term, pattern: rule.pattern)
      else l(:text_time_autopilot_reason_folder, folders: rule.folder_list.join(', '))
      end
    else ''
    end
  end

  def ta_template_label(resolution)
    template = RedmineTimeAutopilot::MonthlyIssue.new(User.current, resolution.rule).template_for(resolution.month)
    template ? "##{template.id}" : l(:text_time_autopilot_no_template)
  end

  # „wenn …“-Teil einer Zuordnung
  def ta_rule_condition(rule)
    case rule.kind
    when 'path' then safe_join([l(:text_time_autopilot_if_path), ' ', content_tag(:code, rule.pattern)])
    when 'branch' then safe_join([l(:text_time_autopilot_if_branch), ' ', content_tag(:code, rule.pattern)])
    when 'term' then safe_join([l(:text_time_autopilot_if_term), ' ', content_tag(:code, rule.pattern)])
    else
      safe_join([l(:text_time_autopilot_if_folder), ' ',
                 safe_join(rule.folder_list.map { |folder| content_tag(:b, folder) }, l(:text_time_autopilot_and))])
    end
  end

  # „… geht auf …“-Teil einer Zuordnung
  def ta_rule_target(rule)
    case rule.target
    when 'skip' then content_tag(:span, l(:label_time_autopilot_target_skip), class: 'ta-to')
    when 'monthly'
      current = RedmineTimeAutopilot::MonthlyIssue.new(User.current, rule).find(User.current.today)
      safe_join([content_tag(:span, l(:text_time_autopilot_monthly_target, term: rule.subject_term), class: 'ta-to'),
                 content_tag(:span, current ? " · #{l(:text_time_autopilot_now, issue: ta_issue_label(current))}" : '', class: 'ta-hint')])
    else
      rule.issue ? content_tag(:span, ta_issue_link(rule.issue), class: 'ta-to') : content_tag(:span, l(:text_time_autopilot_issue_missing), class: 'ta-to')
    end
  end

  # Zuordnungen nach Ordner-Standard gruppiert; Ausnahmen beim passenden
  # Standard, Ausnahmen für jeden Ordner gesondert, „nicht buchen“ am Ende
  def ta_rule_groups(rules)
    defaults = rules.select { |rule| rule.kind == 'folder' && !rule.skip? }
    exceptions = rules.select(&:exception?)
    groups = defaults.map do |rule|
      { default: rule, exceptions: exceptions.select { |ex| ex.folder_list.present? && ex.folder_list.intersect?(rule.folder_list) } }
    end
    attached = groups.flat_map { |group| group[:exceptions] }
    { groups: groups,
      everywhere: exceptions - attached,
      skipped: rules.select { |rule| rule.kind == 'folder' && rule.skip? } }
  end

  # Vorschau für das Ticket des Monats: Vormonat, dieser und nächster Monat
  def ta_monthly_preview(rule)
    finder = RedmineTimeAutopilot::MonthlyIssue.new(User.current, rule)
    today = User.current.today
    [today.prev_month, today, today.next_month].map do |date|
      issue = finder.find(date.beginning_of_month + 14)
      label = if issue then ta_issue_label(issue)
              elsif rule.create_missing then l(:text_time_autopilot_will_create, subject: finder.planned_subject(date))
              else l(:text_time_autopilot_none_yet)
              end
      [::I18n.l(date, format: '%B %Y'), label, issue.present?]
    end
  end
end
