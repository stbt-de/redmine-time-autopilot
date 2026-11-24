# frozen_string_literal: true

require File.expand_path('../../../test/test_helper', __dir__)

module RedmineTimeAutopilot
  module TestHelper
    FIXTURES = %i[
      projects users email_addresses user_preferences members member_roles roles
      issues issue_statuses trackers projects_trackers enabled_modules enumerations
      time_entries issue_categories versions workflows custom_fields custom_values
      custom_fields_projects custom_fields_trackers
    ].freeze

    MONDAY = Date.new(2026, 11, 16) # KW 47

    def setup_autopilot
      @jsmith = User.find(2) # Manager in Projekt 1: Aufwand buchen, Tickets anlegen
      @dlopper = User.find(3) # Developer in Projekt 1
      @project = Project.find(1)
      User.current = nil
    end

    def create_draft(user: @jsmith, **attributes)
      TimeAutopilotDraft.create!({ user: user, source_key: SecureRandom.hex(6), spent_on: MONDAY, hours: 1,
                                   folder: 'shop' }.merge(attributes))
    end

    def create_rule(user: @jsmith, **attributes)
      TimeAutopilotRule.create!({ user: user, kind: 'folder', folder_list: ['shop'], target: 'issue' }.merge(attributes))
    end

    def create_issue(project: @project, subject: nil, **attributes)
      Issue.create!({ project: project, tracker: project.trackers.first, author: User.find(2),
                      subject: subject || "Testticket #{SecureRandom.hex(3)}", status: IssueStatus.find(1),
                      priority: IssuePriority.default || IssuePriority.first }.merge(attributes))
    end

    # Privates Projekt ohne Mitglieder: für jsmith unsichtbar
    def hidden_issue
      project = Project.create!(name: 'Versteckt', identifier: "hidden-#{SecureRandom.hex(3)}", is_public: false,
                                tracker_ids: [1])
      create_issue(project: project)
    end

    # Ohne Projekt und ohne Recht über die Rolle „Nichtmitglied“
    def user_without_projects
      Role.non_member.remove_permission!(:log_time)
      User.generate!(login: "nobody-#{SecureRandom.hex(3)}", password: 'nobody-1234-pw', password_confirmation: 'nobody-1234-pw')
    end

    # Ticket im Projekt, dem Benutzer zugewiesen (direkt gesetzt: in
    # Unterprojekten ist der Benutzer nicht immer Mitglied)
    def create_assigned_issue(user, project: Project.find(1), status: IssueStatus.find(1), **attributes)
      issue = Issue.create!({ project: project, tracker: project.trackers.first, author: User.find(1),
                              subject: "Testticket #{SecureRandom.hex(3)}", status: status,
                              priority: IssuePriority.default || IssuePriority.first }.merge(attributes))
      Issue.where(id: issue.id).update_all(assigned_to_id: user.id)
      Issue.find(issue.id)
    end

    def create_time_entry(user, issue, hours:, spent_on:)
      TimeEntry.create!(project: issue.project, issue: issue, user: user, author: user, hours: hours,
                        spent_on: spent_on, activity: TimeEntryActivity.shared.active.first)
    end

    # Meine Seite eines Benutzers nur mit diesen Blöcken
    def my_page_blocks(user, *blocks)
      user.pref.my_page_layout = { 'top' => blocks.map(&:to_s) }
      user.pref.save!
    end

    def week_for(user = @jsmith, start = MONDAY)
      RedmineTimeAutopilot::Week.new(user, week: start.iso8601, today: start + 8)
    end
  end
end
