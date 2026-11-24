# frozen_string_literal: true

module RedmineTimeAutopilot
  # Arbeitszeit speichern: in „Mein Konto“ (eigene) und in der
  # Benutzerverwaltung (Admins, für andere). Die Felder work_hours[1..7]
  # stehen im selben Formular wie Redmines Einstellungen; gespeichert wird
  # vor Redmines eigener Aktion, nur wenn die Felder mitkommen.
  module WorkHoursPatch
    module MyAccount
      def self.included(base)
        base.before_action :save_time_autopilot_work_hours, only: :account
      end

      private

      def save_time_autopilot_work_hours
        return unless request.put? || request.patch? || request.post?
        return unless params[:work_hours].respond_to?(:to_unsafe_h)

        WorkSchedule.new(User.current).update(params[:work_hours].to_unsafe_h)
      end
    end

    module Users
      def self.included(base)
        base.before_action :save_time_autopilot_work_hours, only: :update
      end

      private

      def save_time_autopilot_work_hours
        return unless params[:work_hours].respond_to?(:to_unsafe_h)

        user = User.find_by(id: params[:id])
        return unless user && WorkSchedule.editable?(User.current, user)

        WorkSchedule.new(user).update(params[:work_hours].to_unsafe_h)
      end
    end
  end
end
