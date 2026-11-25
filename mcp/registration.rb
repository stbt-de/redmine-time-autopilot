# frozen_string_literal: true

# Meldet die Time-Autopilot-Werkzeuge beim MCP-Server von redmine_mcp_plugin
# an. Dessen Werkzeugliste ist bewusst fest (RedmineMcpPlugin::Registry.all);
# solange es keine offizielle Schnittstelle für andere Plugins gibt, hängt
# Time Autopilot seine Werkzeuge hinten an. Läuft bei jedem Laden der Plugins
# (init.rb, in Redmines to_prepare) – nach einem Neuladen im Development-Modus
# werden die Klassen neu definiert.
module TimeAutopilotMcp
  module Registration
    module_function

    def available?
      Redmine::Plugin.installed?(:redmine_mcp_plugin) && defined?(::MCP::Tool) &&
        defined?(RedmineMcpPlugin::Registry) && defined?(RedmineMcpPlugin::Tools::Base)
    end

    def install
      return false unless available?

      silence_warnings { load File.expand_path('tools.rb', __dir__) }
      registry = RedmineMcpPlugin::Registry
      if registry.respond_to?(:register)
        # Offizielle Schnittstelle, falls redmine_mcp_plugin sie anbietet
        TimeAutopilotMcp::Tools::ALL.each { |tool| registry.register(tool) }
      else
        registry.singleton_class.prepend(Extension) unless registry.singleton_class < Extension
      end
      true
    end

    # Hängt die Werkzeuge an die feste Liste an
    module Extension
      def all
        names = super.map(&:tool_name)
        super + TimeAutopilotMcp::Tools::ALL.reject { |tool| names.include?(tool.tool_name) }
      end
    end
  end
end
