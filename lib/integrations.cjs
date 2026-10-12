'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawn} = require('node:child_process');
const net = require('node:net');
const {privateDirectory, writeJSON} = require('./history.cjs');
const {ensureWorkspace} = require('./config.cjs');
const {PRESETS, applyPreset} = require('./presets.cjs');
const cleanText = (value, max = 4096) => typeof value === 'string' && value.length <= max && !/[\x00-\x1f\x7f]/.test(value);
function executable(value) {
  if (!cleanText(value) || !path.isAbsolute(value)) throw new Error('Choose an absolute executable path.');
  try {
    if (!fs.statSync(value).isFile()) throw new Error('not a file');
    fs.accessSync(value, fs.constants.X_OK);
  } catch { throw new Error('This application could not be opened. Choose an installed executable with permission to run.'); }
}
function createIntegrations(stateDir) {
  const file = path.join(stateDir, 'integrations.json');
  // engine: what runs Code conversations. dictation: an optional system dictation tool to toggle from the text bar.
  const defaults = () => ({hermes: {enabled:false, python:'', source:'', browserExecutable:'', desktopDriver:'', coding:true, browser:false, desktop:false}, harnesses:[], engine:'black-team', dictation:''});
  const read = () => fs.existsSync(file) ? {...defaults(), ...JSON.parse(fs.readFileSync(file, 'utf8'))} : defaults();
  function save(value) {
    if (!value || Object.keys(value).some(key => !['hermes','harnesses','engine','dictation'].includes(key))) throw new Error('Unsupported integration setting.');
    const next = {...read(), ...value};
    if (!['black-team','hermes'].includes(next.engine)) throw new Error('Choose Black Team or Hermes for Code conversations.');
    if (!cleanText(next.dictation)) throw new Error('Invalid dictation tool path.');
    if (next.dictation) executable(next.dictation);
    const h = next.hermes;
    if (!h || Object.keys(h).some(key => !['enabled','python','source','browserExecutable','desktopDriver','coding','browser','desktop'].includes(key)) ||
        !['enabled','coding','browser','desktop'].every(key => typeof h[key] === 'boolean') || !cleanText(h.python) || !cleanText(h.source)) throw new Error('Invalid Hermes settings.');
    for (const key of ['browserExecutable','desktopDriver']) {
      if(h[key]!==undefined && !cleanText(h[key])) throw new Error('Invalid tool executable path.');
      if(h[key]) executable(h[key]);
    }
    if (h.enabled) {
      executable(h.python);
      try {if (!path.isAbsolute(h.source) || !fs.statSync(h.source).isDirectory() || !fs.existsSync(path.join(h.source,'hermes_bootstrap.py'))) throw new Error('missing');}
      catch {throw new Error('Hermes was not found in this folder. Choose your installed Hermes Agent folder or use Find again.');}
    }
    if (!Array.isArray(next.harnesses) || next.harnesses.length > 20) throw new Error('Configure up to 20 harnesses.');
    const ids = new Set();
    for (const item of next.harnesses) {
      if (!item || Object.keys(item).some(key => !['id','name','executable','args','terminal','preset'].includes(key)) ||
          (item.preset !== undefined && !Object.hasOwn(PRESETS, item.preset)) ||
          !/^[a-z0-9-]{1,40}$/.test(item.id) || ids.has(item.id) || !cleanText(item.name, 100) || !item.name.trim() ||
          !Array.isArray(item.args) || item.args.length > 64 || !item.args.every(arg => cleanText(arg)) ||
          !Array.isArray(item.terminal) || item.terminal.length > 16 || !item.terminal.every(arg => cleanText(arg))) throw new Error('Invalid harness. Use unique IDs, a name, argument arrays and executable paths.');
      ids.add(item.id); executable(item.executable);
      if (item.terminal.length) executable(item.terminal[0]);
    }
    privateDirectory(stateDir); writeJSON(file, next); return next;
  }
  return {read, save};
}
function localEnvironment() {
  const allowed = /^(PATH|HOME|USER|LANG|LC_[A-Z_]+|TERM|DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR|XDG_CONFIG_HOME|XDG_DATA_HOME|XDG_CACHE_HOME|LD_LIBRARY_PATH|TMPDIR)$/;
  return Object.fromEntries(Object.entries(process.env).filter(([key]) => allowed.test(key)));
}
function modelEnvironment(config, runtime, endpoint) {
  const model = config.model.source === 'server' ? config.model.id : 'black-team-local';
  const key = runtime.requestHeaders().Authorization?.slice(7) || 'local';
  return {BLACK_TEAM_BASE_URL:endpoint, BLACK_TEAM_MODEL:model, BLACK_TEAM_WORKSPACE:config.workspace,
    OPENAI_BASE_URL:endpoint, OPENAI_API_KEY:key, OPENAI_MODEL:model};
}
function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once('error', reject);
    server.listen({host:'127.0.0.1', port:0, exclusive:true}, () => {
      const port = server.address().port;
      server.close(error => error ? reject(error) : resolve(port));
    });
  });
}
function openInBrowser(url) {
  const child = spawn('xdg-open', [url], {detached:true, stdio:'ignore'});
  child.once('error', () => { /* No browser opener: the address is still shown in the harness's terminal. */ });
  child.unref();
}
// A harness that serves a page is ready when the page answers. Only this computer's own address is ever opened.
// Newer DeepSeek Harness guards its page with a one-time address and opens the browser itself; its plain
// address then answers "not allowed", and Black Team leaves the opening to it.
async function openWhenReady(url, {fetch: fetcher, openPage, waitMs, tries}) {
  for (let attempt = 0; attempt < tries; attempt++) {
    try {
      const response = await fetcher(url, {redirect:'manual', signal:AbortSignal.timeout(3000)});
      await response.body?.cancel();
      if (response.status === 401 || response.status === 403) return;
      if (response.status < 400) return openPage(url);
    } catch { /* Not listening yet. */ }
    await new Promise(resolve => setTimeout(resolve, waitMs));
  }
}
async function launchHarness({id, store, config, runtime, stateDir, spawn: spawnImpl = spawn, reservePort = freePort, fetch: fetcher = globalThis.fetch, openPage = openInBrowser, pageWaitMs = 500, pageTries = 240}) {
  const item = store.read().harnesses.find(h => h.id === id);
  if (!item) throw new Error('Configure this harness in Settings first.');
  executable(item.executable); if (item.terminal.length) executable(item.terminal[0]);
  ensureWorkspace(config.workspace);
  const endpoint = await runtime.start();
  const base = modelEnvironment(config, runtime, endpoint);
  const values = {endpoint, model:base.BLACK_TEAM_MODEL, workspace:config.workspace};
  // A known harness gets the settings that point it at this model; the person's own arguments follow.
  const preset = item.preset ? applyPreset(item.preset, {endpoint, model:values.model, key:base.OPENAI_API_KEY, context:config.model.context, name:config.model.name}, stateDir) : {args:[], env:{}};
  const env = {...localEnvironment(), ...base, ...preset.env};
  const pagePort = preset.page ? await reservePort() : null;
  const args = [...preset.args, ...(pagePort ? ['--port', String(pagePort)] : []), ...item.args.map(arg => arg.replace(/\{(endpoint|model|workspace)\}/g, (_, key) => values[key]))];
  const command = [...item.terminal, item.executable, ...args];
  await new Promise((resolve, reject) => {
    const child = spawnImpl(command[0], command.slice(1), {cwd:config.workspace, env, shell:false, detached:true, stdio:'ignore'});
    child.once('error', () => reject(new Error('The harness could not launch. Check its executable, terminal and workspace.')));
    child.once('spawn', () => {child.unref(); resolve();});
  });
  if (pagePort) openWhenReady(`http://127.0.0.1:${pagePort}/`, {fetch:fetcher, openPage, waitMs:pageWaitMs, tries:pageTries}).catch(() => {});
  return {launched:true, name:item.name};
}
// One step from "found on this computer" to "opens with my model".
function connectHarness({id, store, found}) {
  const app = found.apps.find(item => item.id === id);
  if (!app) throw new Error('That app was not found on this computer.');
  const current = store.read();
  if (current.harnesses.some(item => item.id === app.id)) return {connected:true, name:app.name};
  const terminal = found.terminals[0];
  if (!terminal) throw new Error(`${app.name} runs in a terminal, and none was found. Install a terminal, then connect it again.`);
  store.save({harnesses:[...current.harnesses, {id:app.id, name:app.name, executable:app.executable, args:[], terminal:[terminal.executable, ...terminal.args], ...(app.preset ? {preset:app.id} : {})}]});
  return {connected:true, name:app.name};
}
module.exports = {createIntegrations, launchHarness, connectHarness, localEnvironment, modelEnvironment};
