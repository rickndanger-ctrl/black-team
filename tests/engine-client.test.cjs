'use strict';
const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { EngineClient, resolveEngine } = require('../engine-client.cjs');

// A stand-in for `black-team desktop-service`: same ready line, same one-line-per-request protocol.
const FAKE_ENGINE = `
const mode = process.argv[2];
const out = o => process.stdout.write(JSON.stringify(o) + '\\n');
if (mode === 'notready') { out({ ready: false, error: 'Port 18199 is already in use.' }); process.exit(1); }
if (mode === 'silent') setInterval(() => {}, 1000);
if (mode === 'stubborn') { process.on('SIGTERM', () => {}); setInterval(() => {}, 1000); }
if (mode !== 'silent') out({ ready: true, origin: 'http://127.0.0.1:18199', bootstrapURL: 'http://127.0.0.1:18199/bootstrap?key=k', dataFolder: '/fixture', version: 'test' });
let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  buffer += chunk;
  let index;
  while ((index = buffer.indexOf('\\n')) >= 0) {
    const line = buffer.slice(0, index);
    buffer = buffer.slice(index + 1);
    const request = JSON.parse(line);
    if (request.action === 'slow') setTimeout(() => out({ id: request.id, ok: true, result: { action: 'slow', data: request.data } }), 150);
    else if (request.action === 'fail') out({ id: request.id, ok: false, error: 'Unsupported desktop action.' });
    else if (request.action === 'die') process.exit(3);
    else out({ id: request.id, ok: true, result: { action: request.action, data: request.data } });
  }
});
`;

let folder;
let fake;

before(() => {
  folder = fs.mkdtempSync(path.join(os.tmpdir(), 'engine-client-test-'));
  fake = path.join(folder, 'fake-engine.cjs');
  fs.writeFileSync(fake, FAKE_ENGINE);
});

after(() => {
  fs.rmSync(folder, { recursive: true, force: true });
});

function client(mode, options = {}) {
  return new EngineClient({ command: process.execPath, args: [fake, mode], ...options });
}

test('start resolves with the ready line and requests are matched by id even when replies come out of order', async () => {
  const engine = client('ready');
  const ready = await engine.start();
  assert.equal(ready.bootstrapURL, 'http://127.0.0.1:18199/bootstrap?key=k');
  const slow = engine.request('slow', { n: 1 });
  const fast = engine.request('status', { n: 2 });
  assert.deepEqual(await fast, { action: 'status', data: { n: 2 } });
  assert.deepEqual(await slow, { action: 'slow', data: { n: 1 } });
  assert.deepEqual(await engine.request('models-find'), { action: 'models-find', data: {} });
  await engine.stop();
  assert.equal(engine.exited, true);
});

test('an error reply rejects that request only', async () => {
  const engine = client('ready');
  await engine.start();
  await assert.rejects(engine.request('fail'), { message: 'Unsupported desktop action.' });
  assert.equal((await engine.request('status')).action, 'status');
  await engine.stop();
});

test('a not-ready start rejects with the engine error and the child is gone', async () => {
  const engine = client('notready');
  await assert.rejects(engine.start(), { message: 'Port 18199 is already in use.' });
  await engine.stop();
  assert.equal(engine.exited, true);
});

test('a start that never answers is rejected after the timeout', async () => {
  const engine = client('silent', { readyTimeoutMs: 300, stopWaitMs: 200, termWaitMs: 200, killWaitMs: 200 });
  await assert.rejects(engine.start(), { message: 'The Black Team engine did not start in time.' });
  await engine.stop();
  assert.equal(engine.exited, true);
});

test('a child that exits rejects its pending requests and reports an unexpected exit', async () => {
  const engine = client('ready');
  await engine.start();
  const exits = new Promise(resolve => engine.once('exit', resolve));
  const pending = engine.request('die');
  await assert.rejects(pending, { message: 'The Black Team engine stopped.' });
  const exit = await exits;
  assert.equal(exit.expected, false);
  assert.equal(exit.code, 3);
  await assert.rejects(engine.request('status'), { message: 'The Black Team engine is not running.' });
});

test('stop closes the input, waits for the child to exit, and the exit is expected', async () => {
  const engine = client('ready');
  await engine.start();
  const exits = new Promise(resolve => engine.once('exit', resolve));
  await engine.stop();
  assert.equal((await exits).expected, true);
  assert.equal(engine.exited, true);
});

test('stop escalates to SIGTERM and SIGKILL when the child will not stop', async () => {
  const engine = client('stubborn', { stopWaitMs: 200, termWaitMs: 200, killWaitMs: 2000 });
  await engine.start();
  const started = Date.now();
  await engine.stop();
  assert.equal(engine.exited, true);
  assert.ok(Date.now() - started < 5000, 'stop is bounded');
});

test('resolveEngine prefers BLACK_TEAM_ENGINE, then the packaged binary, then the macOS builds', () => {
  const dirname = '/app';
  const only = wanted => p => p === wanted;
  assert.equal(resolveEngine({ env: { BLACK_TEAM_ENGINE: '/x/engine' }, dirname, exists: p => p === '/x/engine' }), '/x/engine');
  assert.throws(() => resolveEngine({ env: { BLACK_TEAM_ENGINE: '/x/missing' }, dirname, exists: () => false }), /BLACK_TEAM_ENGINE is missing/);
  assert.equal(resolveEngine({ env: {}, dirname, exists: only('/app/bin/black-team') }), '/app/bin/black-team');
  assert.equal(resolveEngine({ env: {}, dirname, exists: only('/app/macos/.build/release/black-team') }), '/app/macos/.build/release/black-team');
  assert.equal(resolveEngine({ env: {}, dirname, exists: only('/app/macos/.build/debug/black-team') }), '/app/macos/.build/debug/black-team');
  assert.throws(() => resolveEngine({ env: {}, dirname, exists: () => false }), /engine is missing/);
});
