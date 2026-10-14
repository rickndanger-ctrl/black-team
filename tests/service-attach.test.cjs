'use strict';
const { test, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { EngineClient, AttachedEngine, ServiceVersionError, findService, openEngine, connectionFile } = require('../engine-client.cjs');

// A stand-in for `black-team service run`: the same ping and control routes, the same cookie and origin checks, on a free loopback port.
const cleanups = [];
afterEach(async () => { while (cleanups.length) await cleanups.pop()(); });

function scratch() {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'service-attach-test-'));
  cleanups.push(() => fs.rmSync(folder, { recursive: true, force: true }));
  return folder;
}

async function fakeService({ version = '1.0.0', protocol = 1, secret = 'the-secret', pid = process.pid } = {}) {
  const seen = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => {
      const body = Buffer.concat(chunks).toString('utf8');
      seen.push({ method: req.method, url: req.url, headers: req.headers, body });
      const reply = (status, value) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(value)); };
      if (req.headers.cookie !== `black_team_session=${secret}`) return reply(401, { error: 'Open Black Team on this computer.' });
      if (req.method === 'POST' && req.headers.origin !== `http://127.0.0.1:${server.address().port}`) return reply(403, { error: 'A same-origin request is required.' });
      if (req.url === '/api/service/ping') return reply(200, { ok: true, protocol, version, pid, dataFolder: 'x', mode: 'background' });
      if (req.url === '/api/service/control') {
        if (req.headers['x-black-team-control'] !== 'the-control-key') return reply(403, { error: 'Desktop action is unavailable.' });
        const { action, data } = JSON.parse(body);
        if (action === 'fail') return reply(400, { error: 'Unsupported desktop action.' });
        return reply(200, { ok: true, result: { action, data } });
      }
      return reply(404, { error: 'Not found.' });
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  cleanups.push(() => new Promise(resolve => { server.closeAllConnections?.(); server.close(resolve); }));
  return { server, seen, port: server.address().port, secret, pid, version };
}

function writeConnection(dir, service, overrides = {}, mode = 0o600) {
  const connection = { protocol: 1, version: service.version, pid: service.pid, port: service.port, secret: service.secret, bootstrap: 'boot-key', control: 'the-control-key', started: 1, dataFolder: dir, ...overrides };
  const file = connectionFile(dir);
  fs.writeFileSync(file, JSON.stringify(connection), { mode });
  fs.chmodSync(file, mode);
  return connection;
}

test('with no connection file there is no service, and an engine of our own is started', async () => {
  const dir = scratch();
  assert.deepEqual(await findService({ dataDir: dir, version: '1.0.0' }), { state: 'none' });
  let spawned = 0;
  const fakeEngine = { start: async () => ({ ready: true, origin: 'http://127.0.0.1:1' }) };
  const opened = await openEngine({ dataDir: dir, version: '1.0.0', spawn: () => { spawned += 1; return fakeEngine; } });
  assert.equal(opened.attached, false);
  assert.equal(spawned, 1);
  assert.equal(opened.engine, fakeEngine);
});

test('a running service is found and the window attaches instead of spawning', async () => {
  const dir = scratch();
  const service = await fakeService();
  const connection = writeConnection(dir, service);
  const found = await findService({ dataDir: dir, version: '1.0.0' });
  assert.equal(found.state, 'running');
  assert.deepEqual(found.connection, connection);
  let spawned = 0;
  const opened = await openEngine({ dataDir: dir, version: '1.0.0', spawn: () => { spawned += 1; }, watchIntervalMs: 60000 });
  assert.equal(opened.attached, true);
  assert.equal(spawned, 0);
  assert.equal(opened.ready.origin, `http://127.0.0.1:${service.port}`);
  assert.equal(opened.ready.bootstrapURL, `http://127.0.0.1:${service.port}/bootstrap?key=boot-key`);
  assert.equal(opened.ready.dataFolder, dir);
  assert.ok(opened.engine instanceof AttachedEngine);
  // The window gets everything the control channel gives: actions go through the control route with the session cookie and the same origin.
  assert.deepEqual(await opened.engine.request('status', { a: 1 }), { action: 'status', data: { a: 1 } });
  assert.deepEqual(await opened.engine.request('models-find'), { action: 'models-find', data: {} });
  const control = service.seen.filter(entry => entry.url === '/api/service/control');
  assert.equal(control.length, 2);
  assert.equal(control[0].headers.cookie, 'black_team_session=the-secret');
  assert.equal(control[0].headers.origin, `http://127.0.0.1:${service.port}`);
  assert.equal(control[0].headers.host, `127.0.0.1:${service.port}`);
  assert.equal(control[0].headers['x-black-team-control'], 'the-control-key');
  // The ping, which the page could also make, carries no control key.
  assert.equal(service.seen.find(entry => entry.url === '/api/service/ping').headers['x-black-team-control'], undefined);
  assert.equal(control[0].headers['content-type'], 'application/json');
  assert.deepEqual(JSON.parse(control[0].body), { action: 'status', data: { a: 1 } });
  await assert.rejects(opened.engine.request('fail'), /Unsupported desktop action\./);
  await opened.engine.stop();
});

test('closing the window only detaches: the service is not asked to stop anything', async () => {
  const dir = scratch();
  const service = await fakeService();
  writeConnection(dir, service);
  const opened = await openEngine({ dataDir: dir, version: '1.0.0', spawn: () => assert.fail('must not spawn'), watchIntervalMs: 60000 });
  const before = service.seen.length;
  await opened.engine.stop();
  assert.equal(service.seen.length, before, 'stop() sent nothing');
  await assert.rejects(opened.engine.request('status'), /not running/);
});

test('a file left behind by a service that is gone is ignored and the window starts its own engine', async () => {
  const dir = scratch();
  const dead = require('node:child_process').spawnSync(process.execPath, ['-e', '0']);
  writeConnection(dir, { version: '1.0.0', pid: dead.pid, port: 1, secret: 's' });
  assert.equal((await findService({ dataDir: dir, version: '1.0.0' })).state, 'stale');
  // A live pid but nothing listening on the port.
  const quiet = await fakeService();
  const port = quiet.port;
  await new Promise(resolve => quiet.server.close(resolve));
  writeConnection(dir, { version: '1.0.0', pid: process.pid, port, secret: 's' });
  assert.equal((await findService({ dataDir: dir, version: '1.0.0' })).state, 'stale');
  // Damaged, or for another data folder.
  fs.writeFileSync(connectionFile(dir), '{nope', { mode: 0o600 });
  assert.equal((await findService({ dataDir: dir, version: '1.0.0' })).state, 'stale');
  writeConnection(dir, { version: '1.0.0', pid: process.pid, port, secret: 's' }, { dataFolder: '/somewhere/else' });
  assert.equal((await findService({ dataDir: dir, version: '1.0.0' })).state, 'stale');
  let spawned = 0;
  const opened = await openEngine({ dataDir: dir, version: '1.0.0', spawn: () => { spawned += 1; return { start: async () => ({ ready: true, origin: 'http://127.0.0.1:1' }) }; } });
  assert.equal(opened.attached, false);
  assert.equal(spawned, 1);
});

test('a process that is alive but is not the service named in the file is not trusted', async () => {
  const dir = scratch();
  const service = await fakeService({ pid: process.pid + 1 });
  writeConnection(dir, { ...service, pid: process.pid });
  assert.equal((await findService({ dataDir: dir, version: '1.0.0' })).state, 'stale');
});

test('a wrong secret is refused, and no engine is started beside the service', async () => {
  const dir = scratch();
  const service = await fakeService({ secret: 'the-secret' });
  writeConnection(dir, service, { secret: 'not-the-secret' });
  const found = await findService({ dataDir: dir, version: '1.0.0' });
  assert.equal(found.state, 'refused');
  await assert.rejects(openEngine({ dataDir: dir, version: '1.0.0', spawn: () => assert.fail('must not spawn') }), /refused this window\. Restart the background service/);
  // The service never saw a control request.
  assert.equal(service.seen.filter(entry => entry.url === '/api/service/control').length, 0);
});

test('a connection file open to other users is not trusted, and a link is not followed', async () => {
  const dir = scratch();
  const service = await fakeService();
  writeConnection(dir, service, {}, 0o644);
  const open = await findService({ dataDir: dir, version: '1.0.0' });
  assert.equal(open.state, 'refused');
  assert.match(open.reason, /open to other users/);
  fs.rmSync(connectionFile(dir));
  const real = path.join(dir, 'real.json');
  fs.writeFileSync(real, JSON.stringify({ port: service.port }), { mode: 0o600 });
  fs.symlinkSync(real, connectionFile(dir));
  assert.equal((await findService({ dataDir: dir, version: '1.0.0' })).state, 'stale');
});

test('a service of another version says to restart it, and the window does not fail oddly', async () => {
  const dir = scratch();
  const service = await fakeService({ version: '1.0.0' });
  writeConnection(dir, service);
  const found = await findService({ dataDir: dir, version: '1.1.0' });
  assert.equal(found.state, 'mismatch');
  assert.equal(found.message, 'Black Team’s background service is version 1.0.0, but this window is version 1.1.0. Restart the background service, then open Black Team again.');
  await assert.rejects(openEngine({ dataDir: dir, version: '1.1.0', spawn: () => assert.fail('must not spawn') }), error => {
    assert.ok(error instanceof ServiceVersionError);
    assert.equal(error.restartable, true);
    assert.match(error.message, /Restart the background service/);
    return true;
  });
  // The same version attaches; a different protocol is a mismatch whatever the version says.
  assert.equal((await findService({ dataDir: dir, version: '1.0.0' })).state, 'running');
  const other = await fakeService({ version: '1.0.0', protocol: 7 });
  writeConnection(dir, other);
  assert.equal((await findService({ dataDir: dir, version: '1.0.0' })).state, 'mismatch');
});

test('when the background service is turned on but not running, the window starts it and attaches', async () => {
  const dir = scratch();
  const service = await fakeService();
  let started = 0;
  const opened = await openEngine({
    dataDir: dir, version: '1.0.0', spawn: () => assert.fail('must not spawn'), watchIntervalMs: 60000, pollMs: 5, sleep: () => new Promise(resolve => setTimeout(resolve, 5)),
    unitEnabled: async () => true,
    // Starting the unit is what makes the service write its file.
    startUnit: async () => { started += 1; setTimeout(() => writeConnection(dir, service), 30); },
  });
  assert.equal(started, 1);
  assert.equal(opened.attached, true);
  await opened.engine.stop();
});

test('when the unit is on but never comes up, the window falls back to its own engine; when it is off the system is not asked', async () => {
  const dir = scratch();
  let asked = 0;
  const engine = () => ({ start: async () => ({ ready: true, origin: 'http://127.0.0.1:1' }) });
  const slow = await openEngine({ dataDir: dir, version: '1.0.0', spawn: engine, waitMs: 40, pollMs: 10, sleep: () => new Promise(resolve => setTimeout(resolve, 10)),
    unitEnabled: async () => true, startUnit: async () => { asked += 1; } });
  assert.equal(slow.attached, false);
  assert.equal(asked, 1);
  const off = await openEngine({ dataDir: dir, version: '1.0.0', spawn: engine, unitEnabled: async () => false, startUnit: async () => { asked += 1; } });
  assert.equal(off.attached, false);
  assert.equal(asked, 1, 'a unit that is not turned on is never started');
});

test('if the service stops answering, the window is told once (two missed checks, not one)', async () => {
  const dir = scratch();
  const service = await fakeService();
  const connection = writeConnection(dir, service);
  const engine = new AttachedEngine({ connection, watchIntervalMs: 20 });
  await engine.start();
  const exits = [];
  engine.on('exit', event => exits.push(event));
  await new Promise(resolve => setTimeout(resolve, 80));
  assert.equal(exits.length, 0, 'a service that answers is not reported');
  service.server.closeAllConnections?.();
  await new Promise(resolve => service.server.close(resolve));
  await new Promise(resolve => setTimeout(resolve, 200));
  assert.equal(exits.length, 1);
  assert.equal(exits[0].expected, false);
  await engine.stop();
});

test('the spawned engine path is unchanged: EngineClient still starts a child and stops it with the window', async () => {
  const fake = path.join(scratch(), 'fake.cjs');
  fs.writeFileSync(fake, "process.stdout.write(JSON.stringify({ready:true,origin:'http://127.0.0.1:1',bootstrapURL:'x',dataFolder:'/f',version:'t'})+'\\n');process.stdin.resume();");
  const engine = new EngineClient({ command: process.execPath, args: [fake] });
  const ready = await engine.start();
  assert.equal(ready.ready, true);
  assert.equal(engine.attached, undefined);
  await engine.stop();
});
