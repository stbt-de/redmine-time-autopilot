#!/usr/bin/env node
// =============================================================================
// MCP-Server für Redmine Time Autopilot
//
// Gibt Agents (Claude Code u. a.) dieselben Möglichkeiten wie die Seite
// „Zeiten“: Woche lesen, Fragen beantworten, Vorschläge buchen, Entwürfe
// hochladen, Zuordnungen und Tickets nachsehen. Spricht nur mit der
// REST-Schnittstelle des Plugins, mit dem API-Schlüssel der Person – es gelten
// Redmines Rechte.
//
// Konfiguration über Umgebungsvariablen:
//   REDMINE_URL       z. B. https://redmine.example.com
//   REDMINE_API_KEY   Mein Konto → API-Zugriffsschlüssel
// =============================================================================
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';

const baseUrl = (process.env.REDMINE_URL || '').replace(/\/+$/, '');
const apiKey = process.env.REDMINE_API_KEY || '';

async function call(method, path, { query, body } = {}) {
  if (!baseUrl || !apiKey) {
    throw new Error('REDMINE_URL und REDMINE_API_KEY müssen gesetzt sein.');
  }
  const url = new URL(baseUrl + path);
  Object.entries(query || {}).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== '') url.searchParams.set(key, String(value));
  });
  const response = await fetch(url, {
    method,
    headers: { 'Content-Type': 'application/json', Accept: 'application/json', 'X-Redmine-API-Key': apiKey },
    body: body ? JSON.stringify(body) : undefined
  });
  const text = await response.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = { raw: text.slice(0, 500) }; }
  if (!response.ok) {
    const detail = data && data.errors ? data.errors.join(' · ') : (data && data.raw) || response.statusText;
    const error = new Error(`Redmine antwortet ${response.status}: ${detail}`);
    error.data = data;
    throw error;
  }
  return data;
}

const hours = (value) => {
  const number = Number(value || 0);
  return `${Number.isInteger(number) ? number : number.toFixed(2).replace(/0$/, '')} h`.replace('.', ',');
};
const day = (iso) => {
  const date = new Date(`${iso}T12:00:00`);
  return date.toLocaleDateString('de-DE', { weekday: 'short', day: 'numeric', month: 'numeric' });
};

// Woche als kurzer Text für den Chat – Schlüssel zum Buchen stehen dabei
function weekText(data) {
  const lines = [];
  lines.push(`${data.week.label} (${data.week.start} – ${data.week.finish}): gebucht ${hours(data.totals.logged)}, vorgeschlagen ${hours(data.totals.proposed)}` +
             (data.totals.target ? `, Ziel ${hours(data.totals.target)}` : ''));
  data.sources.forEach((source) => {
    lines.push(`Erfasst von ${source.name}: ${source.segments} Abschnitte in ${source.folders} Ordnern, zuletzt ${source.uploaded_at || '–'}`);
  });
  if (data.questions.length) {
    lines.push('', 'Offene Fragen (Arbeit ohne Zuordnung):');
    data.questions.forEach((question, index) => {
      const suggestions = question.suggestions.map((issue) => `#${issue.id} ${issue.subject}`).join(' | ') || 'keine Vorschläge';
      lines.push(`${index + 1}. Ordner „${question.folder}“, ${hours(question.hours)} (${question.dates.map(day).join(', ')}): ${question.summaries.slice(0, 3).join(' · ')}`);
      lines.push(`   Vorschläge: ${suggestions}`);
    });
  }
  if (data.proposals.length) {
    lines.push('', 'Vorschläge zum Buchen:');
    data.proposals.forEach((proposal) => {
      const target = proposal.issue ? `#${proposal.issue.id} ${proposal.issue.subject}` : `${proposal.planned_subject} (wird angelegt)`;
      lines.push(`- ${day(proposal.date)}  ${hours(proposal.hours)}  ${target}${proposal.project ? ` · ${proposal.project}` : ''}`);
      if (proposal.comments) lines.push(`    ${proposal.comments}`);
      lines.push(`    ${proposal.origin}  [key: ${proposal.key}]`);
    });
  } else {
    lines.push('', 'Keine Vorschläge zum Buchen.');
  }
  return lines.join('\n');
}

function result(text, data) {
  return { content: [{ type: 'text', text }], structuredContent: data && typeof data === 'object' && !Array.isArray(data) ? data : { items: data } };
}

function failure(error) {
  return { isError: true, content: [{ type: 'text', text: error.message }] };
}

const server = new McpServer({ name: 'redmine-time-autopilot', version: '0.1.0' });

server.registerTool('time_week', {
  title: 'Woche ansehen',
  description: 'Zeigt eine Woche aus Redmine Time Autopilot: gebuchte und vorgeschlagene Stunden, offene Fragen (Ordner ohne Zuordnung, mit Ticket-Vorschlägen) und die Vorschläge zum Buchen mit ihren Schlüsseln (key). Ohne week: die älteste Woche mit offenen Entwürfen.',
  inputSchema: { week: z.string().optional().describe('Ein Tag der Woche, ISO-Datum (YYYY-MM-DD)') },
  annotations: { readOnlyHint: true }
}, async ({ week }) => {
  try {
    const data = await call('GET', '/time_autopilot.json', { query: { week } });
    return result(weekText(data), data);
  } catch (error) { return failure(error); }
});

server.registerTool('time_answer', {
  title: 'Frage beantworten',
  description: 'Beantwortet eine offene Frage: Arbeit im Ordner geht auf ein Ticket oder wird nicht gebucht. Mit remember=true wird daraus die Zuordnung des Ordners (gilt sofort und künftig). Nur mit der Antwort der Person aufrufen, nicht raten.',
  inputSchema: {
    week: z.string().describe('Ein Tag der Woche, ISO-Datum'),
    folder: z.string().describe('Ordner aus der Frage'),
    issue_id: z.union([z.number().int(), z.string()]).optional().describe('Ticketnummer; leer lassen bei skip'),
    skip: z.boolean().optional().describe('true: nicht buchen'),
    remember: z.boolean().default(true).describe('Als Zuordnung merken')
  }
}, async ({ week, folder, issue_id, skip, remember }) => {
  try {
    const data = await call('POST', '/time_autopilot/answer.json', { query: { week }, body: { folder, issue_id, skip: !!skip, remember } });
    return result(skip ? `„${folder}“: nicht buchen${remember ? ' (gemerkt)' : ''}.` : `„${folder}“ → #${issue_id}${remember ? ' (gemerkt)' : ''}.`, data);
  } catch (error) { return failure(error); }
});

server.registerTool('time_book', {
  title: 'Vorschläge buchen',
  description: 'Bucht die Vorschläge einer Woche als normale Redmine-Zeitbuchungen. NUR aufrufen, nachdem die Person die Zusammenfassung gesehen und ausdrücklich zugestimmt hat. Optional: hours ändert Stunden je key (0 = nicht buchen), keys bucht nur diese Einträge. Fehlende Tickets des Monats werden dabei angelegt.',
  inputSchema: {
    week: z.string().describe('Ein Tag der Woche, ISO-Datum'),
    hours: z.record(z.string(), z.union([z.number(), z.string()])).optional().describe('Geänderte Stunden je key, z. B. {"2026-11-19-issue-45": 1.5}'),
    keys: z.array(z.string()).optional().describe('Nur diese Vorschläge buchen')
  },
  annotations: { destructiveHint: false, idempotentHint: false }
}, async ({ week, hours: changed, keys }) => {
  try {
    const data = await call('POST', '/time_autopilot/book.json', { query: { week }, body: { hours: changed || {}, keys } });
    const created = data.created_issues.length ? ` Neu angelegt: ${data.created_issues.map((issue) => `#${issue.id} ${issue.subject}`).join(', ')}.` : '';
    return result(`Gebucht: ${data.booked.length} Einträge, ${hours(data.booked_hours)}.${created}`, data);
  } catch (error) {
    if (error.data && error.data.failures) {
      const text = `${error.message}\n` + error.data.failures.map((item) => `- ${item.title}: ${item.message}`).join('\n') +
                   (error.data.booked.length ? `\nTrotzdem gebucht: ${error.data.booked.length} Einträge, ${hours(error.data.booked_hours)}.` : '');
      return { isError: true, content: [{ type: 'text', text }], structuredContent: error.data };
    }
    return failure(error);
  }
});

server.registerTool('time_upload', {
  title: 'Entwürfe hochladen',
  description: 'Lädt erfasste Arbeitsabschnitte als Entwürfe hoch. Gleiche source_key ersetzen offene Entwürfe; mit replace_from/replace_to werden offene Entwürfe im Zeitraum entfernt, die nicht mehr mitkommen. Keine Inhalte der Arbeit schicken – nur Stunden, Ordner, Branch, Dateipfade, Ticketnummern und eine kurze Zusammenfassung.',
  inputSchema: {
    drafts: z.array(z.object({
      source_key: z.string(),
      spent_on: z.string(),
      hours: z.number(),
      folder: z.string(),
      started_at: z.string().optional(),
      ended_at: z.string().optional(),
      branch: z.string().optional(),
      paths: z.array(z.string()).optional(),
      issue_refs: z.array(z.string()).optional(),
      summary: z.string().optional(),
      guess_issue_id: z.number().int().optional(),
      source: z.string().optional()
    })).describe('Abschnitte'),
    replace_from: z.string().optional(),
    replace_to: z.string().optional()
  }
}, async ({ drafts, replace_from, replace_to }) => {
  try {
    const data = await call('POST', '/time_autopilot/drafts.json', { body: { drafts, replace_from, replace_to } });
    return result(`Hochgeladen: ${data.created} neu, ${data.updated} aktualisiert, ${data.kept} schon gebucht, ${data.removed} entfernt.`, data);
  } catch (error) { return failure(error); }
});

server.registerTool('time_rules', {
  title: 'Zuordnungen ansehen',
  description: 'Listet die Zuordnungen der Person (welcher Ordner, welche Dateien, welcher Branch oder Begriff auf welches Ticket geht) und Ordner ohne Zuordnung.',
  inputSchema: {},
  annotations: { readOnlyHint: true }
}, async () => {
  try {
    const data = await call('GET', '/time_autopilot/rules.json');
    const lines = data.rules.map((rule) => `- ${rule.sentence}`);
    if (data.unassigned.length) lines.push('', 'Ohne Zuordnung: ' + data.unassigned.map((item) => `${item.folder} (${hours(item.hours_last_4_weeks)})`).join(', '));
    return result(lines.join('\n') || 'Noch keine Zuordnungen.', data);
  } catch (error) { return failure(error); }
});

server.registerTool('time_search_issues', {
  title: 'Ticket suchen',
  description: 'Sucht offene Tickets nach Nummer oder Betreff, nur in Projekten, in denen die Person Aufwand buchen darf.',
  inputSchema: { term: z.string().describe('Nummer (#123) oder Wörter aus dem Betreff') },
  annotations: { readOnlyHint: true }
}, async ({ term }) => {
  try {
    const data = await call('GET', '/time_autopilot/issues.json', { query: { term } });
    return result(data.map((issue) => `#${issue.id} ${issue.subject} · ${issue.project}`).join('\n') || 'Kein Ticket gefunden.', data);
  } catch (error) { return failure(error); }
});

await server.connect(new StdioServerTransport());
