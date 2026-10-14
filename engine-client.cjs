'use strict';
// Runs the Swift engine (`black-team desktop-service`) as a child process and talks to it over its standard input and output:
// one JSON request per line in, one JSON reply per line out, matched on `id`. Logs from the engine go to this process's stderr.
const childProcess = require('node:child_process');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');

const READY_TIMEOUT_MS = 15000;
const STOP_WAIT_MS = 10000;
const TERM_WAIT_MS = 3000;
const KILL_WAIT_MS = 2000;
const MAX_LINE_BYTES = 64 * 1024 * 1024;

/// Finds the engine binary: BLACK_TEAM_ENGINE, then the packaged copy, then the newest build in this checkout
/// (the one scripts/build-engine.sh makes, or a swift build), so an old build left behind is never picked over a fresh one.
function resolveEngine({ env = process.env, dirname, exists = fs.existsSync, modified = file => fs.statSync(file).mtimeMs } = {}) {
  if (env.BLACK_TEAM_ENGINE) {
    if (!exists(env.BLACK_TEAM_ENGINE)) throw new Error(`The engine named by BLACK_TEAM_ENGINE is missing: ${env.BLACK_TEAM_ENGINE}`);
    return env.BLACK_TEAM_ENGINE;
  }
  const packaged = path.join(dirname, 'bin', 'black-team');
  const builds = ['engine', 'release', 'debug'].map(folder => path.join(dirname, 'macos', '.build', folder, 'black-team')).filter(candidate => exists(candidate));
  // A stable sort: builds of the same age keep the order above.
  const found = exists(packaged) ? packaged : builds.map(file => ({ file, at: modified(file) })).sort((a, b) => b.at - a.at)[0]?.file;
  if (!found) throw new Error('The Black Team engine is missing. Reinstall Black Team, or build it with: scripts/build-engine.sh (Linux) or cd macos && swift build -c release --product black-team');
  return found;
}

class EngineClient extends EventEmitter {
  constructor({ command, args = [], env = process.env, readyTimeoutMs = READY_TIMEOUT_MS, stopWaitMs = STOP_WAIT_MS,
    termWaitMs = TERM_WAIT_MS, killWaitMs = KILL_WAIT_MS, spawn = childProcess.spawn } = {}) {
    super();
    Object.assign(this, { command, args, env, readyTimeoutMs, stopWaitMs, termWaitMs, killWaitMs, spawn });
    this.child = null;
    this.ready = null;          // the ready line, once the engine has sent it
    this.nextId = 1;
    this.pending = new Map();
    this.buffer = '';
    this.exited = false;        // the child has gone and its output is read
    this.stopping = false;      // stop() was asked for, so an exit now is expected
    this.stopPromise = null;
    this.closed = new Promise(resolve => { this.resolveClosed = resolve; });
    this.startReject = null;
    this.startTimer = null;
  }

  /// Starts the engine and resolves with its ready line; rejects with the engine's own error, or on a timeout or a failed start.
  start() {
    if (this.child) return Promise.reject(new Error('The engine is already started.'));
    return new Promise((resolve, reject) => {
      this.startReject = reject;
      let child;
      try {
        child = this.spawn(this.command, this.args, { stdio: ['pipe', 'pipe', 'inherit'], env: this.env });
      } catch (error) {
        reject(new Error(`The Black Team engine could not start: ${error.message}`));
        return;
      }
      this.child = child;
      this.resolveStart = resolve;
      child.stdin.on('error', () => {});  // a write to a dead engine is reported through the request, not as a crash
      child.stdout.setEncoding('utf8');
      child.stdout.on('data', chunk => this.onData(chunk));
      child.on('error', error => { if (!child.pid) this.finish(error); });
      child.once('close', () => this.finish(null));
      this.startTimer = setTimeout(() => {
        this.failStart(new Error('The Black Team engine did not start in time.'));
        this.stop().catch(() => {});
      }, this.readyTimeoutMs);
    });
  }

  onData(chunk) {
    this.buffer += chunk;
    let index;
    while ((index = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, index).trim();
      this.buffer = this.buffer.slice(index + 1);
      if (line) this.onLine(line);
    }
    if (this.buffer.length > MAX_LINE_BYTES) {
      this.buffer = '';
      this.child.kill('SIGTERM');
    }
  }

  onLine(line) {
    let message;
    try { message = JSON.parse(line); } catch { process.stderr.write('engine-client: ignored a line that is not JSON.\n'); return; }
    if (!this.ready) {
      clearTimeout(this.startTimer);
      if (message && message.ready === true) {
        this.ready = message;
        this.resolveStart(message);
      } else {
        this.failStart(new Error((message && message.error) || 'The Black Team engine did not start.'));
        this.stop().catch(() => {});
      }
      return;
    }
    if (!message || typeof message !== 'object' || !this.pending.has(message.id)) return;
    const { resolve, reject } = this.pending.get(message.id);
    this.pending.delete(message.id);
    if (message.ok) resolve(message.result === undefined ? null : message.result);
    else reject(new Error(message.error || 'The Black Team engine request failed.'));
  }

  failStart(error) {
    clearTimeout(this.startTimer);
    if (this.startReject) { const reject = this.startReject; this.startReject = null; reject(error); }
  }

  /// Sends one action and resolves with its result. Rejects when the engine refuses it or is not running.
  request(action, data = {}) {
    if (!this.ready || this.exited || this.stopping) return Promise.reject(new Error('The Black Team engine is not running.'));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.child.stdin.write(`${JSON.stringify({ id, action, data })}\n`, error => {
        if (error && this.pending.delete(id)) reject(new Error('The Black Team engine stopped.'));
      });
    });
  }

  /// Called once the child has gone and its output has been read (or it never started).
  finish(error) {
    if (this.exited) return;
    this.exited = true;
    clearTimeout(this.startTimer);
    const stopped = new Error('The Black Team engine stopped.');
    for (const { reject } of this.pending.values()) reject(stopped);
    this.pending.clear();
    if (!this.ready) {
      this.failStart(error ? new Error(`The Black Team engine could not start: ${error.message}`) : new Error('The Black Team engine stopped before it was ready.'));
    }
    this.resolveClosed();
    this.emit('exit', { expected: this.stopping, error: error || null, code: this.child ? this.child.exitCode : null });
  }

  /// Ends the engine: closes its input (it stops, model included), then SIGTERM, then SIGKILL, each after a bounded wait.
  stop() {
    if (!this.child) return Promise.resolve();
    if (this.stopPromise) return this.stopPromise;
    this.stopping = true;
    this.stopPromise = (async () => {
      if (!this.exited) {
        try { this.child.stdin.end(); } catch {}
        if (!await this.waitClosed(this.stopWaitMs)) {
          this.signal('SIGTERM');
          if (!await this.waitClosed(this.termWaitMs)) {
            this.signal('SIGKILL');
            await this.waitClosed(this.killWaitMs);
          }
        }
      }
    })();
    return this.stopPromise;
  }

  waitClosed(ms) {
    let timer;
    const timeout = new Promise(resolve => { timer = setTimeout(() => resolve(false), ms); });
    return Promise.race([this.closed.then(() => true), timeout]).finally(() => clearTimeout(timer));
  }

  signal(name) {
    try { this.child.kill(name); } catch {}
  }
}

// ---- Attaching to the background service ------------------------------------------------------------------------------------------
//
// With "Keep Black Team running in the background" on, the engine is already running (`black-team service run`), and the window uses it
// instead of starting a second one. The service writes <data>/service.json (private, 0600) once it listens:
//   { protocol, version, pid, port, secret, bootstrap, started, dataFolder }
// `secret` is the service's session key: it is sent as the same cookie, Host and Origin the window's own pages send, so the service applies the
// checks it applies to every request. A file left by a crashed service fails the checks below and is ignored. Closing the window then only
// detaches: the service and any job it is running carry on.

const PROTOCOL = 1;
const PING_TIMEOUT_MS = 4000;
const REQUEST_TIMEOUT_MS = 10 * 60 * 1000;
const WATCH_INTERVAL_MS = 5000;

function connectionFile(dataDir) { return path.join(dataDir, 'service.json'); }

function processAlive(pid) {
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
}

/// One request to the service, as the window makes it. Resolves { status, body } (body parsed when it is JSON); rejects when nothing answers.
function serviceRequest(connection, method, requestPath, { body, timeoutMs = PING_TIMEOUT_MS, request = http.request, control = false } = {}) {
  return new Promise((resolve, reject) => {
    const origin = `http://127.0.0.1:${connection.port}`;
    const payload = body === undefined ? null : JSON.stringify(body);
    const headers = { Cookie: `black_team_session=${connection.secret}` };
    if (control) headers['X-Black-Team-Control'] = connection.control;
    if (payload !== null) Object.assign(headers, { Origin: origin, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) });
    const options = { host: '127.0.0.1', port: connection.port, method, path: requestPath, agent: false, timeout: timeoutMs, headers };
    const req = request(options, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { /* not JSON: the status says enough */ }
        resolve({ status: response.statusCode, body: parsed });
      });
    });
    req.on('timeout', () => req.destroy(new Error('The background service did not answer.')));
    req.on('error', reject);
    if (payload !== null) req.write(payload);
    req.end();
  });
}

function mismatchMessage(service, mine) {
  return `Black Team’s background service is version ${service}, but this window is version ${mine}. Restart the background service, then open Black Team again.`;
}

/// Looks for the service of a data folder. Resolves one of
///   { state: 'none' }                           no service file: start an engine of our own
///   { state: 'stale', reason }                  a file from a service that is gone or that does not answer: ignore it
///   { state: 'refused', reason }                a service is there but will not talk to us, or its file is open to others
///   { state: 'mismatch', connection, message }  a service of another version or protocol
///   { state: 'running', connection }            attach to it
async function findService({ dataDir, version, lstat = fs.lstatSync, read = fs.readFileSync, alive = processAlive, uid = process.getuid ? process.getuid() : null, request } = {}) {
  const file = connectionFile(dataDir);
  let info;
  try { info = lstat(file); } catch { return { state: 'none' }; }
  if (!info.isFile() || (uid !== null && info.uid !== uid)) return { state: 'stale', reason: 'The connection file is not ours.' };
  if ((info.mode & 0o077) !== 0) return { state: 'refused', reason: 'The connection file is open to other users, so it is not trusted.' };
  let connection;
  try { connection = JSON.parse(read(file, 'utf8')); } catch { return { state: 'stale', reason: 'The connection file is damaged.' }; }
  const valid = connection && Number.isInteger(connection.port) && connection.port > 0 && connection.port < 65536 && Number.isInteger(connection.pid) &&
    typeof connection.secret === 'string' && connection.secret && typeof connection.bootstrap === 'string' && typeof connection.control === 'string' && connection.control && typeof connection.version === 'string';
  if (!valid) return { state: 'stale', reason: 'The connection file is damaged.' };
  if (connection.dataFolder !== dataDir) return { state: 'stale', reason: 'The connection file is for another data folder.' };
  if (!alive(connection.pid)) return { state: 'stale', reason: 'The service that wrote it is gone.' };
  let answer;
  try { answer = await serviceRequest(connection, 'GET', '/api/service/ping', { request }); } catch { return { state: 'stale', reason: 'The service does not answer.' }; }
  if (answer.status === 401 || answer.status === 403) return { state: 'refused', reason: 'The background service refused this window.' };
  if (answer.status !== 200 || !answer.body || answer.body.pid !== connection.pid) return { state: 'stale', reason: 'Something else answers on the service’s port.' };
  if (answer.body.protocol !== PROTOCOL || (version !== undefined && answer.body.version !== version)) {
    return { state: 'mismatch', connection, message: mismatchMessage(answer.body.version, version === undefined ? `protocol ${PROTOCOL}` : version) };
  }
  return { state: 'running', connection };
}

/// Speaks to the service the way EngineClient speaks to its child: start() gives the ready line, request() runs one action, stop() lets go
/// without stopping anything. If the service stops answering, 'exit' is emitted (expected: false) so the window can say so.
class AttachedEngine extends EventEmitter {
  constructor({ connection, watchIntervalMs = WATCH_INTERVAL_MS, request, timeoutMs = REQUEST_TIMEOUT_MS } = {}) {
    super();
    Object.assign(this, { connection, watchIntervalMs, requestImpl: request, timeoutMs });
    this.attached = true;
    this.ready = null;
    this.exited = false;
    this.timer = null;
    this.misses = 0;
  }

  start() {
    const c = this.connection;
    this.ready = { ready: true, attached: true, origin: `http://127.0.0.1:${c.port}`, bootstrapURL: `http://127.0.0.1:${c.port}/bootstrap?key=${c.bootstrap}`, dataFolder: c.dataFolder, version: c.version };
    this.timer = setInterval(() => this.watch(), this.watchIntervalMs);
    if (this.timer.unref) this.timer.unref();
    return Promise.resolve(this.ready);
  }

  async watch() {
    if (this.exited) return;
    let alive = false;
    try {
      const answer = await serviceRequest(this.connection, 'GET', '/api/service/ping', { request: this.requestImpl });
      alive = answer.status === 200 && Boolean(answer.body) && answer.body.pid === this.connection.pid;
    } catch { alive = false; }
    this.misses = alive ? 0 : this.misses + 1;
    // Two missed checks in a row: one slow answer is not a stopped service.
    if (this.misses >= 2 && !this.exited) { this.exited = true; this.stopWatching(); this.emit('exit', { expected: false, error: null, code: null }); }
  }

  stopWatching() { if (this.timer) { clearInterval(this.timer); this.timer = null; } }

  async request(action, data = {}) {
    if (!this.ready || this.exited) throw new Error('The Black Team background service is not running.');
    let answer;
    try {
      answer = await serviceRequest(this.connection, 'POST', '/api/service/control', { body: { action, data }, timeoutMs: this.timeoutMs, request: this.requestImpl, control: true });
    } catch { throw new Error('The Black Team background service did not answer. Check it with: black-team service status'); }
    if (answer.status !== 200 || !answer.body || answer.body.ok !== true) {
      throw new Error((answer.body && answer.body.error) || 'The Black Team background service could not do that.');
    }
    return answer.body.result === undefined ? null : answer.body.result;
  }

  /// Detaches. The service, its model and any job it runs are left alone.
  stop() { this.exited = true; this.stopWatching(); return Promise.resolve(); }
}

class ServiceVersionError extends Error {
  constructor(message) { super(message); this.name = 'ServiceVersionError'; this.restartable = true; }
}

/// Chooses between attaching to the background service and starting an engine of our own.
///   spawn()           makes the EngineClient to start when there is no service
///   unitEnabled()     whether the person turned the background service on (its unit is installed and enabled); optional
///   startUnit()       asks the system to start it; optional
/// Returns { engine, ready, attached }. Throws ServiceVersionError for a service of another version, and an Error when the service refuses us:
/// a second engine beside a running service would fight it for the model and the port, so none is started.
async function openEngine({ dataDir, version, spawn, unitEnabled, startUnit, waitMs = 15000, pollMs = 250, sleep = ms => new Promise(resolve => setTimeout(resolve, ms)), find = findService, request, watchIntervalMs } = {}) {
  const look = () => find({ dataDir, version, request });
  let found = await look();
  if ((found.state === 'none' || found.state === 'stale') && unitEnabled && startUnit) {
    let enabled = false;
    try { enabled = await unitEnabled(); } catch { enabled = false; }
    if (enabled) {
      try { await startUnit(); } catch { /* it may already be starting; the wait below decides */ }
      for (let waited = 0; waited < waitMs; waited += pollMs) {
        found = await look();
        if (found.state !== 'none' && found.state !== 'stale') break;
        await sleep(pollMs);
      }
    }
  }
  if (found.state === 'mismatch') throw new ServiceVersionError(found.message);
  if (found.state === 'refused') throw new Error(`${found.reason} Restart the background service with: black-team service restart`);
  if (found.state === 'running') {
    const engine = new AttachedEngine({ connection: found.connection, request, watchIntervalMs });
    const ready = await engine.start();
    return { engine, ready, attached: true };
  }
  const engine = spawn();
  let ready;
  try { ready = await engine.start(); } catch (error) { await Promise.resolve(engine.stop && engine.stop()).catch(() => {}); throw error; }
  return { engine, ready, attached: false };
}

module.exports = { EngineClient, resolveEngine, READY_TIMEOUT_MS, AttachedEngine, ServiceVersionError, findService, openEngine, connectionFile, serviceRequest, PROTOCOL };

