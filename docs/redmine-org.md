# Redmine plugin directory – Time Autopilot

Fields for the entry on https://www.redmine.org/plugins (*Register a new plugin*).
Text fields use Redmine's Textile formatting.

## Plugin Name

Time Autopilot

## Identifier

redmine_time_autopilot

## Description

Time tracking for Redmine with proposals from recorded work – e.g. from AI coding agents.

* *Time* page per week: what an agent recorded is proposed per day and issue; you answer a few questions once and book the week with one click. Your own entries and what is logged sit next to it.
* Rules as sentences: work in a folder goes to an issue, to the issue of the month (subject from a template like “Maintenance - {year} - {month}”, month names in any Redmine language, created when missing) or is not booked; exceptions by files, branch or word. Issue numbers in the work always win.
* Working hours per weekday under *My account*; daily and weekly targets.
* Blocks for *My page*: *Log time* and *Weekly hours* (formerly in Dashboard Blocks).
* REST API, and tools for the MCP endpoint of "redmine_mcp_plugin":https://github.com/joaoperfig/redmine_mcp_plugin, so agents can show the week in a chat and book after an explicit okay.

Bookings are regular Redmine time entries with Redmine's permissions. Styled for the "Klar theme":https://github.com/stbt-de/redmine-klar-theme. English and German.

## Homepage

https://github.com/stbt-de/redmine-time-autopilot

## Code repository

https://github.com/stbt-de/redmine-time-autopilot

## Installation notes

The folder in @plugins/@ must be named <code>redmine_time_autopilot</code>.

<pre>
cd /path/to/redmine/plugins
git clone https://github.com/stbt-de/redmine-time-autopilot.git redmine_time_autopilot
bundle exec rake redmine:plugins:migrate NAME=redmine_time_autopilot RAILS_ENV=production
</pre>

Restart Redmine. Coming from Dashboard Blocks 1.3: install Time Autopilot, then update Dashboard Blocks to 2.0.

## Plugin version

0.2.4

## Redmine compatibility

Tick: **7.0.x**, **6.0.x** (tested).

## Updating this entry

On a new release: on redmine.org open the plugin → *Add a version*. Change texts here first, then copy them over.
