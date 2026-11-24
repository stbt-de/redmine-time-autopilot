# frozen_string_literal: true

module RedmineTimeAutopilot
  # Woche als JSON für Agents (GET /time_autopilot.json): dieselben Fragen und
  # Vorschläge wie auf der Seite, mit Schlüsseln zum Beantworten und Buchen
  class WeekPayload
    def initialize(week, view)
      @week = week
      @view = view
    end

    def to_h
      {
        week: { start: @week.start, finish: @week.finish, label: @week.label, previous: @week.previous_week, next: @week.next_week },
        totals: { logged: @week.logged_hours, proposed: @week.ready_hours, skipped: @week.skipped_hours.to_f, target: @week.target_hours },
        sources: @week.sources.map { |source| { name: source.name, segments: source.segments, folders: source.folders, uploaded_at: source.uploaded_at } },
        days: @week.days.map { |day| { date: day.date, logged: day.logged_hours, proposed: day.ready_hours.to_f, target: day.target, questions: day.question_count } },
        questions: @week.questions.map { |question| question_json(question) },
        proposals: @week.entries.map { |entry| proposal_json(entry) }
      }
    end

    private

    def question_json(question)
      {
        folder: question.folder,
        hours: question.hours.to_f,
        dates: question.dates,
        summaries: question.summaries,
        suggestions: @week.suggestions_for(question).map { |issue| issue_json(issue) }
      }
    end

    def proposal_json(entry)
      {
        key: entry.key,
        date: entry.date,
        hours: entry.hours.to_f,
        issue: entry.issue && issue_json(entry.issue),
        to_create: entry.to_create?,
        planned_subject: entry.planned_subject,
        project: entry.project&.name,
        comments: entry.comments,
        reason: @view.ta_reason(entry.resolution),
        origin: @view.ta_entry_origin(entry)
      }
    end

    def issue_json(issue)
      { id: issue.id, subject: issue.subject, project: issue.project.name }
    end
  end
end
