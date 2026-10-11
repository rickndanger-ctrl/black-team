'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createConfigStore } = require('../lib/config.cjs');
const { createSavedModels, switchModel, forgetModel } = require('../lib/models.cjs');

const server = (id, port = 18081, extra = {}) => ({ source: 'server', endpoint: `http://127.0.0.1:${port}/v1`, id, apiKey: '', name: id, file: '', runtime: '', context: 32768, gpuLayers: 0, threads: 4, ...extra });
const fresh = t => { const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bt-models-')); t.after(() => fs.rmSync(dir, { recursive: true, force: true })); return dir; };

test('keeps each model once, hides keys, and marks the one in use', t => {
  const saved = createSavedModels(fresh(t));
  assert.deepEqual(saved.list(), []);
  const first = saved.remember(server('ornith', 18081, { apiKey: 'local-secret' }));
  const second = saved.remember(server('qwen', 18080));
  assert.notEqual(first, second);
  // Saving the same model again updates it in place.
  assert.equal(saved.remember(server('ornith', 18081, { context: 65536, apiKey: 'local-secret' })), first);
  const list = saved.list(server('qwen', 18080));
  assert.deepEqual(list.map(model => [model.name, model.active, model.where, model.context]), [['qwen', true, '127.0.0.1:18080', 32768], ['ornith', false, '127.0.0.1:18081', 65536]]);
  assert.equal(JSON.stringify(list).includes('local-secret'), false);
  assert.equal(saved.find(first).apiKey, 'local-secret');
});

test('the list file is private and a damaged one is an empty list', t => {
  const dir = fresh(t);
  const saved = createSavedModels(dir);
  saved.remember(server('ornith'));
  const file = path.join(dir, 'saved-models.json');
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  fs.writeFileSync(file, JSON.stringify({ models: [server('ok'), { source: 'cloud', name: 'x' }, { ...server('bad'), context: 'big' }, server('ok')] }));
  assert.deepEqual(saved.list().map(model => model.name), ['ok']);
  fs.writeFileSync(file, '{not json');
  assert.deepEqual(saved.list(), []);
  assert.throws(() => saved.remember({ source: 'server', name: '' }), /cannot be saved/);
});

test('switching stops the loaded model and makes the chosen one current', async t => {
  const dir = fresh(t);
  const saved = createSavedModels(dir), configStore = createConfigStore(dir);
  configStore.save({ model: server('ornith') });
  saved.remember(server('ornith'));
  const qwen = saved.remember(server('qwen', 18080, { context: 16384 }));
  const calls = [];
  const runtime = { stop: async () => { calls.push('stop'); } };
  let busy = true;
  await assert.rejects(switchModel({ key: qwen, saved, configStore, runtime, busy: () => busy }), /current response/);
  assert.deepEqual(calls, []);
  busy = false;
  assert.deepEqual(await switchModel({ key: qwen, saved, configStore, runtime, busy: () => busy }), { switched: true, name: 'qwen' });
  assert.deepEqual(calls, ['stop']);
  const now = configStore.read().model;
  assert.deepEqual([now.id, now.endpoint, now.context], ['qwen', 'http://127.0.0.1:18080/v1', 16384]);
  assert.deepEqual(saved.list(now).filter(model => model.active).map(model => model.name), ['qwen']);
  await assert.rejects(switchModel({ key: 'nope', saved, configStore, runtime, busy: () => false }), /not in your list/);
});

test('a model whose file has gone is refused and the current one stays', async t => {
  const dir = fresh(t);
  const saved = createSavedModels(dir), configStore = createConfigStore(dir);
  configStore.save({ model: server('ornith') });
  const gone = saved.remember({ ...server(''), source: 'gguf', endpoint: '', id: '', name: 'Gone', file: path.join(dir, 'gone.gguf'), runtime: path.join(dir, 'llama-server') });
  let stopped = false;
  await assert.rejects(switchModel({ key: gone, saved, configStore, runtime: { stop: async () => { stopped = true; } }, busy: () => false }), /Gone cannot be used right now/);
  assert.equal(stopped, false);
  assert.equal(configStore.read().model.id, 'ornith');
});

test('the model in use cannot be removed; others can', t => {
  const dir = fresh(t);
  const saved = createSavedModels(dir), configStore = createConfigStore(dir);
  configStore.save({ model: server('ornith') });
  const ornith = saved.remember(server('ornith')), qwen = saved.remember(server('qwen', 18080));
  assert.throws(() => forgetModel({ key: ornith, saved, configStore }), /in use/);
  assert.deepEqual(forgetModel({ key: qwen, saved, configStore }), { removed: true });
  assert.deepEqual(saved.list().map(model => model.name), ['ornith']);
  assert.throws(() => forgetModel({ key: qwen, saved, configStore }), /not in your list/);
});

test('a found model passed over stays out of the offer until it is added', t => {
  const dir = fresh(t);
  const saved = createSavedModels(dir);
  assert.deepEqual(saved.ignored(), []);
  const key = 'abcdef0123456789';
  assert.deepEqual(saved.ignore(key), { ignored: true });
  saved.ignore(key);
  assert.deepEqual(saved.ignored(), [key]);
  assert.throws(() => saved.ignore('nope'), /found model/);
  // Saving and removing models keeps the passed-over keys; adding the passed-over model clears its key.
  const ornith = saved.remember(server('ornith'));
  saved.forget(ornith);
  assert.deepEqual(saved.ignored(), [key]);
  saved.ignore(ornith);
  saved.remember(server('ornith'));
  assert.deepEqual(saved.ignored(), [key]);
});
