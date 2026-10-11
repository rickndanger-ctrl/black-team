'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { findModels, runningServers } = require('../lib/find-models.cjs');
const { createConfigStore } = require('../lib/config.cjs');
const { createSavedModels, addModels } = require('../lib/models.cjs');

const fresh = t => { const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bt-find-')); t.after(() => fs.rmSync(dir, { recursive: true, force: true })); return dir; };
// A sparse file with a valid GGUF header: large on paper, a few bytes on disk.
function gguf(file, bytes = 300 * 1024 * 1024) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const header = Buffer.alloc(24); header.write('GGUF', 0, 'ascii'); header.writeUInt32LE(3, 4);
  const fd = fs.openSync(file, 'w'); fs.writeSync(fd, header); fs.ftruncateSync(fd, bytes); fs.closeSync(fd);
  return file;
}
function proc(root, pid, argv) { fs.mkdirSync(path.join(root, String(pid)), { recursive: true }); fs.writeFileSync(path.join(root, String(pid), 'cmdline'), argv.join('\0') + '\0'); }
const json = value => new Response(JSON.stringify(value), { headers: { 'content-type': 'application/json' } });

test('reads the port and model of model servers this user is running', t => {
  const root = path.join(fresh(t), 'proc');
  proc(root, 100, ['/opt/llama/bin/llama-server', '-m', '/models/a.gguf', '--host', '127.0.0.1', '--port', '18081']);
  proc(root, 101, ['llama-server', '--model=/models/b.gguf', '--port=18080']);
  proc(root, 102, ['/usr/bin/python3', 'server.py', '--port', '9999']);
  proc(root, 103, ['llama-server', '--port', 'not-a-port']);
  fs.mkdirSync(path.join(root, 'self'));
  assert.deepEqual(runningServers(root).map(item => [item.port, item.file]), [[18081, '/models/a.gguf'], [18080, '/models/b.gguf']]);
  assert.deepEqual(runningServers(path.join(root, 'missing')), []);
});

test('finds running servers and model files, and leaves helper files out', async t => {
  const dir = fresh(t), home = path.join(dir, 'home'), root = path.join(dir, 'proc');
  const loaded = gguf(path.join(home, 'models/ornith/Ornith-35B-Q4.gguf'));
  gguf(path.join(home, 'models/qwen/Qwen-27B-Q4.gguf'));
  gguf(path.join(home, 'models/qwen/mmproj-F16.gguf'));
  gguf(path.join(home, 'models/qwen/mtp-Qwen-27B.gguf'));
  gguf(path.join(home, 'models/split/Big-00002-of-00003.gguf'));
  gguf(path.join(home, 'Downloads/tiny.gguf'), 1024 * 1024);
  fs.mkdirSync(path.join(home, 'Downloads'), { recursive: true });
  fs.writeFileSync(path.join(home, 'Downloads/notes.gguf'), 'not a model at all, just text padding');
  proc(root, 7, ['/opt/llama-server', '-m', loaded, '--port', '18081']);
  const asked = [];
  const fetch = async url => {
    asked.push(url);
    if (url === 'http://127.0.0.1:18081/v1/models') return json({ data: [{ id: loaded }] });
    if (url === 'http://127.0.0.1:18081/props') return json({ default_generation_settings: { n_ctx: 65536 } });
    if (url === 'http://127.0.0.1:11434/v1/models') return json({ data: [{ id: 'llama3:8b' }, { id: 'qwen:7b' }] });
    if (url === 'http://127.0.0.1:11434/props') return new Response('no', { status: 404 });
    throw new Error('connection refused');
  };
  const found = await findModels({ home, fetch, procRoot: root, runtime: '/usr/bin/llama-server', memory: { total: 64 * 1024 ** 3, free: 32 * 1024 ** 3 } });
  assert.deepEqual(found.servers.map(item => [item.provider, item.name, item.context, item.contextKnown]),
    [['Ollama', 'llama3:8b', 4096, false], ['Ollama', 'qwen:7b', 4096, false], ['llama.cpp', 'Ornith-35B-Q4', 65536, true]]);
  // The model a server already has loaded is not offered a second time as a file.
  assert.deepEqual(found.files.map(item => [item.name, item.runtime, item.context, item.tooBig]), [['Qwen-27B-Q4', '/usr/bin/llama-server', 8192, false]]);
  assert.ok(found.looked.ports.includes(18081) && found.looked.ports.includes(1234));
  assert.deepEqual(found.looked.folders, [path.join(home, 'models'), path.join(home, 'Downloads')]);
  assert.ok(asked.every(url => url.startsWith('http://127.0.0.1:')), 'only loopback addresses are contacted');
});

test('an empty computer gives an empty answer, not an error', async t => {
  const dir = fresh(t);
  const found = await findModels({ home: dir, fetch: async () => { throw new Error('refused'); }, procRoot: path.join(dir, 'proc') });
  assert.deepEqual([found.servers, found.files, found.runtime, found.looked.folders], [[], [], '', []]);
});

test('adding found models fills the list and puts the first one in use on a new install', t => {
  const dir = fresh(t), state = path.join(dir, 'state');
  const saved = createSavedModels(state), configStore = createConfigStore(state);
  const result = addModels({ saved, configStore, threads: 6, items: [
    { source: 'server', endpoint: 'http://localhost:18081/v1', id: 'ornith', name: 'Ornith', context: 65536 },
    { source: 'server', endpoint: 'https://example.com/v1', id: 'remote', name: 'Remote', context: 4096 },
    { source: 'gguf', file: path.join(dir, 'missing.gguf'), runtime: '/usr/bin/llama-server', name: 'Missing', context: 8192 },
    { source: 'server', endpoint: 'http://127.0.0.1:11434/v1', id: 'llama3:8b', name: 'Llama', context: 9e9 },
  ] });
  assert.deepEqual(result.added, ['Ornith', 'Llama']);
  assert.equal(result.inUse, 'Ornith');
  assert.equal(result.skipped.length, 2);
  assert.match(result.skipped[0], /^Remote: Use a loopback/);
  const now = configStore.read().model;
  assert.deepEqual([now.id, now.endpoint, now.context, now.threads], ['ornith', 'http://127.0.0.1:18081/v1', 65536, 6]);
  assert.deepEqual(saved.list(now).map(model => [model.name, model.active, model.context]), [['Ornith', true, 65536], ['Llama', false, 131072]]);
  // With a model already in use, adding more leaves it alone.
  const more = addModels({ saved, configStore, items: [{ source: 'server', endpoint: 'http://127.0.0.1:1234/v1', id: 'phi', name: 'Phi', context: 8192 }] });
  assert.equal(more.inUse, 'Ornith');
  assert.equal(configStore.read().model.id, 'ornith');
  assert.throws(() => addModels({ saved, configStore, items: [] }), /at least one/);
  assert.throws(() => addModels({ saved, configStore, items: [{ source: 'server', endpoint: 'ftp://x', id: 'a', name: 'Bad' }] }), /No model could be added\. Bad:/);
});
