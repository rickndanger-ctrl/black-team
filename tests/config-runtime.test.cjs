'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { createConfigStore, hardwareReport, estimateMemory, validateModelFiles, inspectModel, inspectRuntime } = require('../lib/config.cjs');
const { ModelRuntime } = require('../lib/runtime.cjs');

function fixture(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'black-team-runtime-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const model = path.join(dir, 'test model.gguf');
  const runtime = path.join(dir, 'llama-server');
  const header = Buffer.alloc(64);
  header.write('GGUF');
  header.writeUInt32LE(3, 4);
  fs.writeFileSync(model, header);
  const executable = Buffer.alloc(64);
  executable[0] = 0x7f;
  executable.write('ELF', 1);
  executable[4] = 2;
  executable[5] = 1;
  executable.writeUInt16LE(3, 16);
  executable.writeUInt16LE(process.arch === 'arm64' ? 183 : 62, 18);
  fs.writeFileSync(runtime, executable, { mode: 0o700 });
  const stateDir = path.join(dir, 'state');
  const store = createConfigStore(stateDir);
  const config = { model: { name: 'Test model', file: model, runtime }, workspace: dir };
  return { dir, model, runtime, stateDir, store, config };
}

function harness(t, changes = {}) {
  const files = fixture(t);
  files.store.save(files.config);
  const spawned = [];
  const requests = [];
  let key;
  const spawn = (file, args, options) => {
    const child = new EventEmitter();
    child.signals = [];
    child.kill = signal => {
      child.signals.push(signal);
      queueMicrotask(() => child.emit('exit', null, signal));
      return true;
    };
    key = fs.readFileSync(args[args.indexOf('--api-key-file') + 1], 'utf8').trim();
    spawned.push({ file, args, options, child });
    return child;
  };
  const fetch = async (url, options = {}) => {
    requests.push({ url, options });
    if (url.endsWith('/health')) return new Response(JSON.stringify({ status: 'ok' }));
    if (options.headers?.Authorization !== `Bearer ${key}`) return new Response('{}', { status: 401 });
    return new Response(JSON.stringify({ model_path: files.model, total_slots: 1 }));
  };
  const runtime = new ModelRuntime({ configStore: files.store, spawn, fetch, reservePort: async () => 45231, pollIntervalMs: 1, startupTimeoutMs: 50, stopTimeoutMs: 5, killTimeoutMs: 5, ...changes });
  t.after(() => runtime.dispose().catch(() => {}));
  return { ...files, runtime, spawned, requests };
}

test('defaults use this user and reading does not create state', t => {
  const { store, stateDir } = fixture(t);
  assert.equal(store.read().schemaVersion, 1);
  assert.equal(store.read().workspace, path.join(os.homedir(), 'Black Team'));
  assert.deepEqual(store.read().phone, { enabled: false, hostname: '', owner: '' });
  assert.equal(fs.existsSync(stateDir), false);
  const copy = store.read();
  copy.model.name = 'mutated';
  assert.equal(store.read().model.name, 'Local model');
});

test('atomic saves keep private modes and merge only approved settings', t => {
  const { store, stateDir, config } = fixture(t);
  store.save(config);
  fs.writeFileSync(path.join(stateDir, 'secret-token'), 'untouched', { mode: 0o600 });
  store.save({ model: { context: 8192 }, phone: { owner: 'Owner' } });
  assert.equal(store.read().model.file, config.model.file);
  assert.equal(store.read().model.context, 8192);
  assert.equal(store.read().phone.owner, 'Owner');
  assert.equal(fs.statSync(stateDir).mode & 0o777, 0o700);
  assert.equal(fs.statSync(path.join(stateDir, 'config.json')).mode & 0o777, 0o600);
  assert.equal(fs.readFileSync(path.join(stateDir, 'secret-token'), 'utf8'), 'untouched');
  const before = fs.readFileSync(path.join(stateDir, 'config.json'), 'utf8');
  for (const input of [{ apiKey: 'no' }, { model: { host: '0.0.0.0' } }, { phone: { token: 'no' } }, JSON.parse('{"__proto__":{"polluted":true}}'), { schemaVersion: 2 }]) {
    assert.throws(() => store.save(input), /Unsupported/);
  }
  assert.equal(fs.readFileSync(path.join(stateDir, 'config.json'), 'utf8'), before);
  assert.deepEqual(fs.readdirSync(stateDir).sort(), ['config.json', 'secret-token']);
});

test('configuration rejects corrupt, oversized and future schema files without replacing them', t => {
  const { store, stateDir, config } = fixture(t);
  store.save(config);
  for (const contents of ['{', JSON.stringify({ schemaVersion: 2 }), ' '.repeat(70000)]) {
    fs.writeFileSync(path.join(stateDir, 'config.json'), contents);
    assert.throws(() => store.read());
    assert.throws(() => store.save({ model: { name: 'changed' } }));
    assert.equal(fs.readFileSync(path.join(stateDir, 'config.json'), 'utf8'), contents);
  }
});

test('configuration validates limits and workspace before writing', t => {
  const { store, dir } = fixture(t);
  for (const input of [
    { model: { context: 0 } }, { model: { context: '4096' } }, { model: { threads: 0 } },
    { model: { gpuLayers: -1 } }, { model: { name: '' } }, { model: { runtime: './llama-server' } },
    { workspace: path.join(dir, 'absent') }, { workspace: '.' }, { phone: { enabled: 'yes' } },
    { phone: { hostname: 'https://example.com' } }, { model: { name: 'line\nbreak' } },
  ]) assert.throws(() => store.save(input));
});

test('GGUF and Linux runtime validation handles symlinks, truncation and wrong architectures', t => {
  const { dir, model, runtime } = fixture(t);
  assert.equal(validateModelFiles({ file: model, runtime }).model.version, 3);
  const modelLink = path.join(dir, 'linked.gguf');
  fs.symlinkSync(model, modelLink);
  assert.equal(inspectModel(modelLink).realPath, model);
  const bad = path.join(dir, 'bad.gguf');
  fs.writeFileSync(bad, 'not a model');
  assert.throws(() => inspectModel(bad), /truncated/);
  fs.writeFileSync(bad, Buffer.alloc(64));
  assert.throws(() => inspectModel(bad), /invalid or unsupported header/);
  assert.throws(() => inspectModel(dir), /not a regular file/);
  assert.throws(() => inspectModel(path.join(dir, 'missing')), /ENOENT/);
  assert.throws(() => inspectRuntime('/bin/sh'), /Choose the llama-server/);
  const data = fs.readFileSync(runtime);
  data.writeUInt16LE(0, 18);
  fs.writeFileSync(runtime, data);
  assert.throws(() => inspectRuntime(runtime), /native Linux/);
});

test('unreadable models and non-executable runtimes are rejected', { skip: process.getuid?.() === 0 }, t => {
  const { model, runtime } = fixture(t);
  fs.chmodSync(model, 0o000);
  assert.throws(() => inspectModel(model), /EACCES/);
  fs.chmodSync(model, 0o600);
  fs.chmodSync(runtime, 0o600);
  assert.throws(() => inspectRuntime(runtime), /EACCES/);
});

test('config symlinks are readable but saving replaces only the link', t => {
  const { store, dir, stateDir, config } = fixture(t);
  const saved = store.save(config);
  const external = path.join(dir, 'external.json');
  fs.writeFileSync(external, JSON.stringify(saved));
  fs.unlinkSync(path.join(stateDir, 'config.json'));
  fs.symlinkSync(external, path.join(stateDir, 'config.json'));
  assert.equal(store.read().model.name, 'Test model');
  store.save({ model: { name: 'New model' } });
  assert.equal(JSON.parse(fs.readFileSync(external)).model.name, 'Test model');
  assert.equal(fs.lstatSync(path.join(stateDir, 'config.json')).isSymbolicLink(), false);
});

test('memory estimates disclose headroom and hardware works before state exists', async t => {
  const { stateDir } = fixture(t);
  const GiB = 1024 ** 3;
  const warning = estimateMemory(7 * GiB, 8 * GiB, 4 * GiB);
  assert.equal(warning.exceedsTotal, true);
  assert.equal(warning.exceedsFree, true);
  assert.match(warning.note, /does not guarantee/);
  assert.equal(estimateMemory(GiB, 16 * GiB, 8 * GiB).warning, null);
  const hardware = await hardwareReport(stateDir);
  assert.ok(hardware.cpu.cores > 0);
  assert.ok(hardware.memory.total > 0);
  assert.equal(hardware.platform, process.platform);
  assert.equal(fs.existsSync(stateDir), false);
  if (hardware.disk) assert.ok(hardware.disk.available >= 0);
});

test('starts one owned, authenticated loopback model with no shell and no inherited override', async t => {
  const previous = process.env.LLAMA_ARG_HOST;
  process.env.LLAMA_ARG_HOST = '0.0.0.0';
  t.after(() => { if (previous === undefined) delete process.env.LLAMA_ARG_HOST; else process.env.LLAMA_ARG_HOST = previous; });
  const { runtime, spawned, model, requests } = harness(t);
  const first = runtime.start();
  const second = runtime.start();
  assert.equal(first, second);
  assert.equal(await first, 'http://127.0.0.1:45231/v1');
  assert.equal(spawned.length, 1);
  const { args, options, child } = spawned[0];
  assert.equal(args[args.indexOf('--host') + 1], '127.0.0.1');
  assert.equal(args[args.indexOf('--model') + 1], model);
  assert.equal(args[args.indexOf('--parallel') + 1], '1');
  assert.equal(options.shell, false);
  assert.equal(options.env.LLAMA_ARG_HOST, undefined);
  assert.deepEqual(options.stdio, ['ignore', 'ignore', 'ignore']);
  const token = runtime.requestHeaders().Authorization;
  assert.equal(JSON.stringify(runtime.status()).includes(token.slice(7)), false);
  assert.equal(args.includes('--api-key'), false);
  assert.equal(args.some(arg => arg.includes(token.slice(7))), false);
  const keyFile = args[args.indexOf('--api-key-file') + 1];
  assert.equal(fs.statSync(keyFile).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.dirname(keyFile)).mode & 0o777, 0o700);
  assert.equal(requests.filter(r => r.url.endsWith('/props')).length, 2);
  runtime.setBusy(true);
  await assert.rejects(runtime.stop(), /response to finish/);
  assert.deepEqual(child.signals, []);
  await runtime.stop({ force: true });
  assert.deepEqual(child.signals, ['SIGTERM']);
  assert.equal(fs.existsSync(path.dirname(keyFile)), false);
  assert.equal(runtime.status().state, 'off');
  assert.throws(() => runtime.requestHeaders(), /not ready/);
  await runtime.start();
  assert.notEqual(runtime.requestHeaders().Authorization, token);
});

test('startup failure kills only the spawned child and exposes a useful error', async t => {
  const { runtime, spawned } = harness(t, { fetch: async () => new Response('{}', { status: 503 }), startupTimeoutMs: 8 });
  await assert.rejects(runtime.start(), /did not become ready in time/);
  assert.equal(runtime.status().state, 'error');
  assert.deepEqual(spawned[0].child.signals, ['SIGTERM']);
  assert.equal(runtime.status().port, null);
});

test('authenticated identity failure never adopts an existing service', async t => {
  const { runtime, spawned } = harness(t, {
    fetch: async url => url.endsWith('/health') ? new Response('{"status":"ok"}') : new Response('{}', { status: 401 }),
  });
  await assert.rejects(runtime.start(), /Another process/);
  assert.equal(runtime.status().state, 'error');
  assert.deepEqual(spawned[0].child.signals, ['SIGTERM']);
});

test('a runtime that ignores authentication is rejected', async t => {
  let model;
  const { runtime, spawned, model: fixtureModel } = harness(t, {
    fetch: async url => new Response(JSON.stringify(url.endsWith('/health') ? { status: 'ok' } : { model_path: model })),
  });
  model = fixtureModel;
  await assert.rejects(runtime.start(), /did not enforce private authentication/);
  assert.deepEqual(spawned[0].child.signals, ['SIGTERM']);
});

test('different model identity is rejected', async t => {
  let wrongModel;
  const { runtime, dir } = harness(t, {
    fetch: async url => new Response(JSON.stringify(url.endsWith('/health') ? { status: 'ok' } : { model_path: wrongModel })),
  });
  wrongModel = path.join(dir, 'different.gguf');
  fs.writeFileSync(wrongModel, 'different');
  await assert.rejects(runtime.start(), /different model/);
});

test('unexpected exit clears ready, busy and authentication state', async t => {
  const { runtime, spawned } = harness(t);
  await runtime.start();
  runtime.setBusy(true);
  spawned[0].child.emit('exit', 1, null);
  assert.equal(runtime.status().state, 'error');
  assert.equal(runtime.status().ready, false);
  assert.equal(runtime.status().busy, false);
  assert.equal(runtime.status().port, null);
  assert.match(runtime.status().error, /code 1/);
  assert.throws(() => runtime.requestHeaders(), /not ready/);
});

test('stop during port selection prevents any process from launching', async t => {
  let release;
  const { runtime, spawned } = harness(t, { reservePort: () => new Promise(resolve => { release = resolve; }) });
  const start = runtime.start();
  const stop = runtime.stop();
  release(45231);
  await assert.rejects(start, /cancelled/);
  await stop;
  assert.equal(spawned.length, 0);
  assert.equal(runtime.status().state, 'off');
});

test('stop aborts an in-flight readiness request and waits for its own process', async t => {
  let requested;
  const entered = new Promise(resolve => { requested = resolve; });
  const { runtime, spawned } = harness(t, {
    fetch: (_url, { signal }) => new Promise((_resolve, reject) => {
      signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
      requested();
    }),
  });
  const start = runtime.start();
  await entered;
  const stopped = runtime.stop();
  await assert.rejects(start, /cancelled/);
  await stopped;
  assert.deepEqual(spawned[0].child.signals, ['SIGTERM']);
  assert.equal(runtime.status().state, 'off');
});

test('spawn errors are handled without uncaught events', async t => {
  const { runtime } = harness(t, {
    spawn: () => {
      const child = new EventEmitter();
      child.kill = () => true;
      queueMicrotask(() => child.emit('error', Object.assign(new Error('missing library'), { code: 'ENOENT' })));
      return child;
    },
    fetch: async () => { throw new Error('not listening'); },
  });
  await assert.rejects(runtime.start(), /Could not start llama-server \(ENOENT\)/);
  assert.equal(runtime.status().state, 'error');
});

test('SIGKILL escalation is confined to the owned process', async t => {
  let child;
  const { runtime } = harness(t, {
    spawn: () => {
      child = new EventEmitter();
      child.signals = [];
      child.kill = signal => {
        child.signals.push(signal);
        if (signal === 'SIGKILL') queueMicrotask(() => child.emit('exit', null, signal));
        return true;
      };
      return child;
    },
    fetch: async () => new Response('{}', { status: 503 }), startupTimeoutMs: 3,
  });
  await assert.rejects(runtime.start(), /did not become ready/);
  assert.deepEqual(child.signals, ['SIGTERM', 'SIGKILL']);
});

test('failed termination never treats an error event as proof the owned process exited', async t => {
  let child;
  const { runtime } = harness(t, {
    spawn: () => {
      child = new EventEmitter();
      child.pid = 987654;
      child.signals = [];
      child.kill = signal => {
        child.signals.push(signal);
        queueMicrotask(() => child.emit('error', Object.assign(new Error('cannot kill'), { code: 'EPERM' })));
        return false;
      };
      return child;
    },
    fetch: async () => new Response('{}', { status: 503 }), startupTimeoutMs: 3,
  });
  await assert.rejects(runtime.start(), /owned model process did not stop/);
  assert.equal(runtime.status().state, 'error');
  assert.deepEqual(child.signals, ['SIGTERM', 'SIGKILL']);
  await assert.rejects(runtime.start(), /previous model process has not stopped/);
  child.emit('exit', 1, null);
  await runtime.dispose();
  assert.equal(runtime.status().state, 'off');
});
