// Probelauf des MCP-Servers gegen eine laufende Redmine-Instanz (nur lesend):
//   REDMINE_URL=… REDMINE_API_KEY=… node smoke.mjs [YYYY-MM-DD]
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const client = new Client({ name: 'smoke', version: '0.0.0' });
await client.connect(new StdioClientTransport({ command: process.execPath, args: [new URL('./server.mjs', import.meta.url).pathname], env: process.env }));
const { tools } = await client.listTools();
console.log('Tools:', tools.map((tool) => tool.name).join(', '));
for (const [name, args] of [['time_week', { week: process.argv[2] }], ['time_rules', {}], ['time_search_issues', { term: 'Wartung' }]]) {
  const result = await client.callTool({ name, arguments: args });
  console.log(`\n== ${name}${result.isError ? ' (Fehler)' : ''}\n${result.content.map((item) => item.text).join('\n')}`);
}
await client.close();
