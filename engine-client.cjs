'use strict';
// Runs the Swift engine (`black-team desktop-service`) as a child process and talks to it over its standard input and output:
// one JSON request per line in, one JSON reply per line out, matched on `id`. Logs from the engine go to this process's stderr.
const childProcess = require('node:child_process');
const { EventEmitter } = require('node:events');
const fs = require('node:fs');
const path = require('node:path');

const READY_TIMEOUT_MS = 15000;
const STOP_WAIT_MS = 10000;
const TERM_WAIT_MS = 3000;
const KILL_WAIT_MS = 2000;
const MAX_LINE_BYTES = 64 * 1024 * 1024;

/// Finds the engine binary: BLACK_TEAM_ENGINE, then the packaged copy, then a macOS build (release, then debug).
function resolveEngine({ env = process.env, dirname, exists = fs.existsSync } = {}) {
  if (env.BLACK_TEAM_ENGINE) {
    if (!exists(env.BLACK_TEAM_ENGINE)) throw new Error(`The engine named by BLACK_TEAM_ENGINE is missing: ${env.BLACK_TEAM_ENGINE}`);
    return env.BLACK_TEAM_ENGINE;
  }
  const candidates = [
    path.join(dirname, 'bin', 'black-team'),
    path.join(dirname, 'macos', '.build', 'release', 'black-team'),
    path.join(dirname, 'macos', '.build', 'debug', 'black-team'),
  ];
  const found = candidates.find(candidate => exists(candidate));
  if (!found) throw new Error('The Black Team engine is missing. Reinstall Black Team, or build it with: cd macos && swift build -c release --product black-team');
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

module.exports = { EngineClient, resolveEngine, READY_TIMEOUT_MS };
