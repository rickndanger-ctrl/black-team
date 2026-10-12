'use strict';
// Builds a data folder exactly as the Node app (alpha.18, lib/*.cjs) writes it, for the Swift tests that prove the Swift engine reads
// it. Run from the repository root:   node macos/Tests/BlackTeamKitTests/Desktop/Fixtures/make-node-data.cjs macos/Tests/BlackTeamKitTests/Desktop/Fixtures/node-data
// The result has data/ (the black-team-data folder) and ws/ (a workspace). Absolute paths are written as @ROOT@/..., which the tests
// replace with their own temporary folder.
// lib/ left the repository after alpha.18: to regenerate, run this from a checkout of tag v0.1.0-alpha.18 with this file copied in.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const lib = name => require(path.join(__dirname, '../../../../../lib', name));
const {createConfigStore} = lib('config.cjs');
const {createSavedModels, keyOf} = lib('models.cjs');
const {createIntegrations} = lib('integrations.cjs');
const {History, writeJSON} = lib('history.cjs');
const {createMemory} = lib('memory.cjs');
const {createTools} = lib('tools.cjs');

const root = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'btfx-'));
const data = path.join(root, 'data'), ws = path.join(root, 'ws');
fs.mkdirSync(data, {mode: 0o700}); fs.mkdirSync(path.join(ws, 'garden'), {recursive: true});
const expected = {};

// config.json: a model on a local server, a phone setup with non-ASCII text.
const config = createConfigStore(data);
config.save({model: {source: 'server', endpoint: 'http://127.0.0.1:18081/v1', id: 'ornith-1.5-ünï', name: 'Ornith 1.5 ünï', context: 32768, threads: 6}, workspace: ws,
  phone: {enabled: true, hostname: 'bt-laptop.tail1234.ts.net', owner: 'rïck@example.com'}});

// saved-models.json
const saved = createSavedModels(data);
const serverModel = config.read().model;
saved.remember(serverModel);
const gguf = {source: 'gguf', endpoint: 'http://127.0.0.1:11434/v1', id: '', apiKey: '', name: 'Qwén 27B Q4', file: '/home/rick/Modèles/qwén 27b "Q4"/model-ü.gguf', runtime: '/opt/llama.cpp/llama-server', context: 16384, gpuLayers: 0, threads: 8, mmproj: '', draft: ''};
saved.remember(gguf);
saved.ignore('0123456789abcdef');
expected.keys = {server: keyOf(serverModel), gguf: keyOf(gguf)};

// integrations.json
createIntegrations(data).save({harnesses: [{id: 'claude', name: 'Claude Code', executable: '/bin/sh', args: ['--x', '{model}'], terminal: ['/bin/sh', '-e'], preset: 'claude'}], dictation: ''});

// conversations
const history = new History(data);
const uuid = () => crypto.randomUUID();
const hash = text => crypto.createHash('sha256').update(text).digest('hex');
const chat = history.create('Hello   there, how are you? Ünïcode ☕');
const chatRequest = {id: uuid(), hash: hash('chat'), state: 'done'};
chat.kind = 'chat'; chat.core = 'Prefers short answers.';
chat.messages.push(
  {id: uuid(), role: 'user', content: 'Hello there', state: 'done', recalled: [{id: 'Notes/Deploy steps', title: 'Deploy steps', text: 'run ./ship'}]},
  {id: uuid(), role: 'assistant', content: 'Hi! ☕', state: 'done', model: 'Ornith 1.5 ünï', finishReason: 'stop', context: {measuredInputTokens: 120, inputBudget: 2000, context: 32768}, meter: {read: 310, write: 14, used: 120, budget: 2000, window: 32768}});
chat.requests.push(chatRequest); history.remember(chat, chatRequest); history.save(chat);
const project = {id: uuid(), name: 'Garden', workspace: path.join(ws, 'garden'), created: new Date().toISOString()};
const agent = history.create('Fix the build');
const agentRequest = {id: uuid(), hash: hash('agent'), state: 'done'};
const artifactId = crypto.randomBytes(16).toString('hex');
agent.kind = 'agent'; agent.engine = 'black-team'; agent.project = project.id;
agent.messages.push({id: uuid(), role: 'user', content: 'Fix the build', state: 'done'},
  {id: uuid(), role: 'assistant', content: 'Fixed.', state: 'done', model: 'Ornith 1.5 ünï', events: [{type: 'tool_use', name: 'read', output: '{"path":"a.txt"}'}, {type: 'status', name: 'engine', output: 'ok'}], artifacts: [{id: artifactId, name: 'report ü.txt', size: 14}]});
agent.requests.push(agentRequest); history.remember(agent, agentRequest); history.save(agent);
// A reply that was still being written when the app closed: the next start marks it interrupted.
const cut = history.create('Cut off');
const cutRequest = {id: uuid(), hash: hash('cut'), state: 'running'};
cut.messages.push({id: uuid(), role: 'user', content: 'Cut off', state: 'done'}, {id: uuid(), role: 'assistant', content: 'partial', state: 'writing'});
cut.requests.push(cutRequest); history.save(cut);
expected.threads = {chat: chat.id, agent: agent.id, cut: cut.id}; expected.requests = {chat: chatRequest.id, cut: cutRequest.id}; expected.project = project.id; expected.artifact = artifactId;
fs.mkdirSync(path.join(data, 'artifacts'), {recursive: true, mode: 0o700});
fs.writeFileSync(path.join(data, 'artifacts', artifactId), 'hello artifact', {mode: 0o600});

// projects.json and keeper.json
writeJSON(path.join(data, 'projects.json'), [project]);
writeJSON(path.join(data, 'keeper.json'), [{text: 'Moved 3 older journal entries for Garden to the archive.', at: Date.now()}]);

// the vault
const vault = createMemory({vault: path.join(data, 'vault')});
vault.write('Notes/Deploy steps', '# Deploy steps\n\n- 2026-10-01: run ./ship\n');
vault.write('Notes/Café ☕', '# Café\n\nSee [[Deploy steps]] and [[Missing note]].\n');
vault.write(`Projects/garden/Overview`, `# Garden\n\nFolder: \`${project.workspace}\`\n`);
vault.remember('Watering', 'Tuesdays and Fridays', project.workspace);
vault.journal(project.workspace, {request: 'Water the plants', log: ['read a', 'edit b'], outcome: 'Done.'});
vault.write('Notes/Old', '# Old\n'); vault.remove('Notes/Old');

// phone.key and the secrets derived from it
const key = crypto.randomBytes(32).toString('hex');
fs.writeFileSync(path.join(data, 'phone.key'), key, {mode: 0o600});
const secret = kind => crypto.createHmac('sha256', key).update(JSON.stringify([kind, 'bt-laptop.tail1234.ts.net', 'rïck@example.com'])).digest('hex');
expected.phone = {pair: secret('pair'), session: secret('session'), hostname: 'bt-laptop.tail1234.ts.net', owner: 'rïck@example.com'};

// an edit the Code engine made, with its undo record (engine/undo)
const undoDir = path.join(data, 'engine', 'undo');
fs.mkdirSync(undoDir, {recursive: true, mode: 0o700});
fs.writeFileSync(path.join(ws, 'a.txt'), 'before\n');
const tools = createTools({workspace: ws, artifacts: path.join(data, 'artifacts'), undoDir, deny: [data], useRtk: false});
(async () => {
  const result = await tools.call('write', {path: 'a.txt', content: 'after\n'});
  const record = (result.changes || [result.change]).filter(Boolean)[0] || result.edit || {};
  expected.undoId = fs.readdirSync(undoDir).find(name => name.endsWith('.json')).slice(0, -5);
  // The engine's per-conversation memory and the measured speeds of the model.
  writeJSON(path.join(data, 'engine', `${agent.id}.json`), {messages: [{role: 'user', content: 'Fix the build'}], requests: [], log: ['read a.txt'], todo: [], readSpeed: 41.5, writeSpeed: 9.2, promptTokens: 1200, trims: 0, core: 'Prefers short answers.'});
  writeJSON(path.join(data, 'engine', 'models.json'), {'server:ornith-1.5-ünï': {readSpeed: 41.5, writeSpeed: 9.2, measured: new Date().toISOString()}});
  // Make every absolute path portable, then write what the tests expect.
  const portable = dir => {
    for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) portable(full);
      else if (entry.isFile() && /\.(json|md)$/.test(entry.name)) {
        const text = fs.readFileSync(full, 'utf8');
        if (text.includes(root)) fs.writeFileSync(full, text.split(root).join('@ROOT@'));
      }
    }
  };
  portable(data);
  fs.writeFileSync(path.join(root, 'expected.json'), JSON.stringify(expected, null, 2) + '\n');
  const target = path.resolve(process.argv[2] || path.join(__dirname, 'node-data'));
  fs.rmSync(target, {recursive: true, force: true});
  fs.cpSync(root, target, {recursive: true});
  fs.rmSync(root, {recursive: true, force: true});
  console.log(`Wrote ${target}`);
})();
