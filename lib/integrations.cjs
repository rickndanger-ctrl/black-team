'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawn} = require('node:child_process');
const {privateDirectory, writeJSON} = require('./history.cjs');
const {ensureWorkspace} = require('./config.cjs');
const cleanText = (value, max = 4096) => typeof value === 'string' && value.length <= max && !/[\x00-\x1f\x7f]/.test(value);
function executable(value) {
  if (!cleanText(value) || !path.isAbsolute(value)) throw new Error('Choose an absolute executable path.');
  if (!fs.statSync(value).isFile()) throw new Error('The executable must be a file.');
  fs.accessSync(value, fs.constants.X_OK);
}
function createIntegrations(stateDir) {
  const file = path.join(stateDir, 'integrations.json');
  const defaults = () => ({hermes: {enabled:false, python:'', source:'', browserExecutable:'', desktopDriver:'', coding:true, browser:false, desktop:false}, harnesses:[]});
  const read = () => fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : defaults();
  function save(value) {
    if (!value || Object.keys(value).some(key => !['hermes','harnesses'].includes(key))) throw new Error('Unsupported integration setting.');
    const next = {...read(), ...value};
    const h = next.hermes;
    if (!h || Object.keys(h).some(key => !['enabled','python','source','browserExecutable','desktopDriver','coding','browser','desktop'].includes(key)) ||
        !['enabled','coding','browser','desktop'].every(key => typeof h[key] === 'boolean') || !cleanText(h.python) || !cleanText(h.source)) throw new Error('Invalid Hermes settings.');
    for (const key of ['browserExecutable','desktopDriver']) {
      if(h[key]!==undefined && !cleanText(h[key])) throw new Error('Invalid tool executable path.');
      if(h[key]) executable(h[key]);
    }
    if (h.enabled) {
      executable(h.python);
      if (!path.isAbsolute(h.source) || !fs.statSync(h.source).isDirectory() || !fs.existsSync(path.join(h.source,'hermes_bootstrap.py'))) throw new Error('Choose your installed Hermes Agent source directory.');
    }
    if (!Array.isArray(next.harnesses) || next.harnesses.length > 20) throw new Error('Configure up to 20 harnesses.');
    const ids = new Set();
    for (const item of next.harnesses) {
      if (!item || Object.keys(item).some(key => !['id','name','executable','args','terminal'].includes(key)) ||
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
async function launchHarness({id, store, config, runtime, spawn: spawnImpl = spawn}) {
  const item = store.read().harnesses.find(h => h.id === id);
  if (!item) throw new Error('Configure this harness in Settings first.');
  executable(item.executable); if (item.terminal.length) executable(item.terminal[0]);
  ensureWorkspace(config.workspace);
  const endpoint = await runtime.start();
  const env = {...localEnvironment(), ...modelEnvironment(config, runtime, endpoint)};
  const values = {endpoint, model:env.BLACK_TEAM_MODEL, workspace:config.workspace};
  const args = item.args.map(arg => arg.replace(/\{(endpoint|model|workspace)\}/g, (_, key) => values[key]));
  const command = [...item.terminal, item.executable, ...args];
  await new Promise((resolve, reject) => {
    const child = spawnImpl(command[0], command.slice(1), {cwd:config.workspace, env, shell:false, detached:true, stdio:'ignore'});
    child.once('error', () => reject(new Error('The harness could not launch. Check its executable, terminal and workspace.')));
    child.once('spawn', () => {child.unref(); resolve();});
  });
  return {launched:true, name:item.name};
}
module.exports = {createIntegrations, launchHarness, localEnvironment, modelEnvironment};
