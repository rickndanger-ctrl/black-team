'use strict';

const { spawn, execFileSync } = require('node:child_process');
const { planLaunch } = require('./launch.cjs');
const { cpuTopology } = require('./system.cjs');
const net = require('node:net');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { discoverModels, serverHeaders } = require('./local-server.cjs');
const { validateModelFiles } = require('./config.cjs');

function reservePort(network) {
  return new Promise((resolve, reject) => {
    const server = network.createServer();
    server.once('error', reject);
    server.listen({ host: '127.0.0.1', port: 0, exclusive: true }, () => {
      const port = server.address().port;
      server.close(error => error ? reject(error) : resolve(port));
    });
  });
}

function runtimeEnvironment() {
  // Keep hardware/runtime settings, without inheriting credentials or llama.cpp
  // options that could enable public listeners, remote models, RPC, or tools.
  const allowed = /^(?:PATH|HOME|LANG|LC_[A-Z_]+|LD_LIBRARY_PATH|LIBRARY_PATH|TMPDIR|XDG_CACHE_HOME|XDG_RUNTIME_DIR|CUDA_VISIBLE_DEVICES|HIP_VISIBLE_DEVICES|ROCR_VISIBLE_DEVICES|ZE_AFFINITY_MASK)$/;
  return Object.fromEntries(Object.entries(process.env).filter(([key]) => allowed.test(key)));
}

function removeCredentials(directory) {
  if (!directory) return;
  try { fs.rmSync(directory, { recursive: true, force: true }); } catch { /* The key remains protected by mode 0600 if cleanup fails. */ }
}

function delay(ms, signal) {
  return new Promise(resolve => {
    if (signal.aborted) return resolve();
    const done = () => { clearTimeout(timer); signal.removeEventListener('abort', done); resolve(); };
    const timer = setTimeout(done, ms);
    signal.addEventListener('abort', done, { once: true });
  });
}

class ModelRuntime {
  constructor(options) {
    if (!options?.configStore?.read) throw new Error('ModelRuntime requires a config store.');
    this.configStore = options.configStore;
    this._spawn = options.spawn || spawn;
    this._fetch = options.fetch || globalThis.fetch;
    this._reservePort = options.reservePort || (() => reservePort(options.net || net));
    this._startupTimeoutMs = options.startupTimeoutMs ?? 120000;
    this._pollIntervalMs = options.pollIntervalMs ?? 350;
    this._stopTimeoutMs = options.stopTimeoutMs ?? 3000;
    this._killTimeoutMs = options.killTimeoutMs ?? 1000;
    this._state = 'off';
    this._error = null;
    this._name = 'Local model';
    this._port = null;
    this._key = null;
    this._externalEndpoint = null;
    this._busy = false;
    this._launch = null;
    this._features = [];
    this._help = new Map(); // llama-server help text by executable, read once per build
    this._generation = 0;
    this._startPromise = null;
    this._stopPromise = null;
    this._abort = null;
  }

  status() {
    return { state: this._state, ready: this._state === 'ready', busy: this._busy, error: this._error, name: this._name, port: this._port, features: this._state === 'ready' && !this._externalEndpoint ? this._features : [] };
  }

  // The model process Black Team started, while it runs; a connected server is not ours.
  // What this build of llama-server accepts, so the launch plan adds only flags it knows.
  _helpFor(file) {
    let stamp = file;
    try { stamp = `${file}:${fs.statSync(file).mtimeMs}`; } catch {}
    if (!this._help.has(stamp)) {
      let text = '';
      try { text = execFileSync(file, ['--help'], { encoding: 'utf8', timeout: 8000, maxBuffer: 4 * 1024 * 1024, env: runtimeEnvironment(), stdio: ['ignore', 'pipe', 'pipe'] }); } catch (error) { text = `${error.stdout || ''}${error.stderr || ''}`; }
      this._help.set(stamp, text);
    }
    return this._help.get(stamp);
  }

  modelPid() { const child = this._launch && !this._launch.exited ? this._launch.child : null; return child?.pid || null; }

  requestHeaders() {
    if (this._externalEndpoint && this._state === 'ready') return serverHeaders(this._key || '');
    if (this._state !== 'ready' || !this._key) throw new Error('The local model is not ready.');
    return { Authorization: `Bearer ${this._key}` };
  }

  setBusy(value) {
    if (typeof value !== 'boolean') throw new Error('Busy state must be true or false.');
    if (value && this._state !== 'ready') throw new Error('The local model is not ready.');
    this._busy = value;
  }

  start() {
    if (this._stopPromise) return this._stopPromise.then(() => this.start());
    if (this._state === 'ready') return Promise.resolve(this._externalEndpoint || `http://127.0.0.1:${this._port}/v1`);
    if (this._startPromise) return this._startPromise;
    const generation = ++this._generation;
    this._abort = new AbortController();
    const operation = this._start(generation, this._abort.signal);
    this._startPromise = operation;
    operation.then(() => { if (this._startPromise === operation) this._startPromise = null; }, () => { if (this._startPromise === operation) this._startPromise = null; });
    return operation;
  }

  _assertCurrent(generation, launch) {
    if (generation !== this._generation) throw new Error('Model start cancelled.');
    if (launch?.error) throw new Error(launch.error);
    if (launch?.exited) throw new Error('The local model process exited before it was ready.');
  }

  async _start(generation, signal) {
    let launch;
    let credentialDirectory;
    this._state = 'starting';
    this._error = null;
    try {
      if (this._launch && !this._launch.exited) throw new Error('The previous model process has not stopped.');
      const config = this.configStore.read();
      validateModelFiles(config.model);
      this._name = config.model.name;
      if (config.model.source === 'server') {
        const found = await discoverModels({...config.model, fetch: this._fetch, signal});
        this._assertCurrent(generation);
        if (!found.models.includes(config.model.id)) throw new Error('The selected model is no longer available. Discover models again in Settings.');
        this._externalEndpoint = found.endpoint;
        this._key = config.model.apiKey || '';
        this._state = 'ready';
        return found.endpoint;
      }
      this._externalEndpoint = null;
      const port = await this._reservePort();
      this._assertCurrent(generation);
      if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Could not reserve a local model port.');
      this._port = port;
      this._key = crypto.randomBytes(32).toString('hex');
      // Command lines are visible to other Unix users. Put the private engine
      // credential in a restricted file instead of exposing it through argv.
      credentialDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'black-team-engine-'));
      fs.chmodSync(credentialDirectory, 0o700);
      const keyFile = path.join(credentialDirectory, 'api-key');
      fs.writeFileSync(keyFile, `${this._key}\n`, { mode: 0o600, flag: 'wx' });
      const plan = planLaunch({ model: config.model, port, keyFile, cores: cpuTopology().cores, help: this._helpFor(config.model.runtime) });
      const args = plan.args;
      this._features = plan.features;
      const child = this._spawn(config.model.runtime, args, { shell: false, windowsHide: true, stdio: ['ignore', 'ignore', 'ignore'], env: runtimeEnvironment() });
      launch = { child, exited: false, stopped: false, error: null, credentialDirectory };
      this._launch = launch;
      launch.exitPromise = new Promise(resolve => { launch.resolveExit = resolve; });
      const finish = (code, exitSignal, error) => {
        if (launch.exited) return;
        launch.exited = true;
        removeCredentials(launch.credentialDirectory);
        launch.error = error ? `Could not start llama-server (${error.code || 'process error'}).` : `The local model process exited (${exitSignal || `code ${code ?? 'unknown'}`}).`;
        launch.resolveExit();
        if (this._launch === launch) {
          this._port = null;
          this._key = null;
          this._busy = false;
          if (!launch.stopped) { this._state = 'error'; this._error = launch.error; }
        }
      };
      child.on('error', error => {
        // A failed kill can emit 'error' while the process is still alive. Only
        // failed spawn (no PID) establishes exit without an actual exit event.
        if (!child.pid) { finish(null, null, error); return; }
        launch.error = `The local model process reported an error (${error.code || 'process error'}).`;
        if (this._launch === launch && !launch.stopped) {
          this._state = 'error';
          this._error = launch.error;
          this._busy = false;
        }
      });
      child.once('exit', (code, exitSignal) => finish(code, exitSignal));
      const root = `http://127.0.0.1:${port}`;
      const deadline = Date.now() + this._startupTimeoutMs;
      while (Date.now() < deadline) {
        this._assertCurrent(generation, launch);
        try {
          const response = await this._fetch(`${root}/health`, { redirect: 'error', signal: AbortSignal.any([signal, AbortSignal.timeout(Math.max(1, Math.min(2000, deadline - Date.now())))]) });
          if (response.ok) {
            const health = await response.json();
            if (health.status === 'ok') {
              const headers = { Authorization: `Bearer ${this._key}` };
              const propsResponse = await this._fetch(`${root}/props`, { headers, redirect: 'error', signal: AbortSignal.any([signal, AbortSignal.timeout(2000)]) });
              if (propsResponse.status === 401 || propsResponse.status === 403) throw Object.assign(new Error('Another process answered on the model port. Please start the model again.'), { fatal: true });
              if (!propsResponse.ok) throw Object.assign(new Error('The runtime could not verify its model. Choose a current llama.cpp release.'), { fatal: true });
              const props = await propsResponse.json();
              let matchingModel = false;
              try { matchingModel = typeof props.model_path === 'string' && fs.realpathSync(props.model_path) === fs.realpathSync(config.model.file); } catch { /* An unreadable identity cannot establish ownership. */ }
              if (!matchingModel) {
                throw Object.assign(new Error('The runtime reported a different model. Start was cancelled.'), { fatal: true });
              }
              const unauthenticated = await this._fetch(`${root}/props`, { redirect: 'error', signal: AbortSignal.any([signal, AbortSignal.timeout(2000)]) });
              // /health is public; /props must enforce our launch-specific key.
              if (![401, 403].includes(unauthenticated.status)) throw Object.assign(new Error('The runtime did not enforce private authentication. Choose a current llama.cpp release.'), { fatal: true });
              await unauthenticated.body?.cancel();
              this._assertCurrent(generation, launch);
              this._state = 'ready';
              return `${root}/v1`;
            }
          } else {
            await response.body?.cancel();
          }
        } catch (error) {
          if (error.fatal) throw error;
          this._assertCurrent(generation, launch);
        }
        await delay(this._pollIntervalMs, signal);
      }
      throw new Error('The local model did not become ready in time. Check its size, runtime libraries, and available memory.');
    } catch (error) {
      if (launch && !launch.exited) {
        try { await this._terminate(launch); } catch (terminationError) { error = terminationError; }
      }
      if (!launch || launch.exited) removeCredentials(credentialDirectory);
      if (generation === this._generation) {
        this._state = 'error';
        this._error = error.message;
        this._port = null;
        this._key = null;
      }
      throw error;
    }
  }

  async _terminate(launch) {
    if (launch.exited) return;
    if (launch.termination) return launch.termination;
    launch.stopped = true;
    launch.termination = (async () => {
      const wait = async ms => {
        let timer;
        await Promise.race([launch.exitPromise, new Promise(resolve => { timer = setTimeout(resolve, ms); })]);
        clearTimeout(timer);
      };
      launch.child.kill('SIGTERM');
      await wait(this._stopTimeoutMs);
      if (!launch.exited) { launch.child.kill('SIGKILL'); await wait(this._killTimeoutMs); }
      if (!launch.exited) throw new Error('The owned model process did not stop. Close Black Team before trying again.');
    })();
    return launch.termination;
  }

  stop({ force = false } = {}) {
    if (this._busy && !force) return Promise.reject(new Error('Wait for the response to finish before stopping the model.'));
    if (this._stopPromise) return this._stopPromise;
    ++this._generation;
    this._abort?.abort();
    const pendingStart = this._startPromise;
    const operation = (async () => {
      try {
        if (this._launch) await this._terminate(this._launch);
        if (pendingStart) await pendingStart.catch(() => {});
        this._state = 'off';
        this._error = null;
        this._busy = false;
        this._port = null;
        this._key = null;
        this._launch = null;
        this._externalEndpoint = null;
      } catch (error) {
        this._state = 'error';
        this._error = error.message;
        throw error;
      }
    })();
    this._stopPromise = operation;
    operation.then(() => { if (this._stopPromise === operation) this._stopPromise = null; }, () => { if (this._stopPromise === operation) this._stopPromise = null; });
    return operation;
  }

  dispose() { return this.stop({ force: true }); }
}

module.exports = { ModelRuntime };
