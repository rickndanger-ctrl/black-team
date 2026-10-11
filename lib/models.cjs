'use strict';

// The models a person has set up, so switching between them is one choice.
// config.json still holds the one model in use; this list sits beside it in its
// own file, so an older Black Team can read the same configuration after a rollback.

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const os = require('node:os');
const { validateModelFiles } = require('./config.cjs');
const { localEndpoint } = require('./local-server.cjs');

const LIMIT = 24;
const TEXT = ['name', 'file', 'runtime', 'source', 'endpoint', 'id', 'apiKey'];
const NUMBERS = ['context', 'gpuLayers', 'threads'];

// Two saved entries are the same model when they point at the same file, or the same model on the same server.
function keyOf(model) {
  const identity = model.source === 'server' ? ['server', model.endpoint, model.id] : ['gguf', model.file];
  return crypto.createHash('sha256').update(JSON.stringify(identity)).digest('hex').slice(0, 16);
}

function clean(entry) {
  if (!entry || typeof entry !== 'object' || !['gguf', 'server'].includes(entry.source)) return null;
  const model = {};
  for (const key of TEXT) {
    const value = entry[key] ?? '';
    if (typeof value !== 'string' || value.length > 4096 || /[\x00-\x1f\x7f]/.test(value)) return null;
    model[key] = value;
  }
  for (const key of NUMBERS) {
    if (!Number.isSafeInteger(entry[key]) || entry[key] < 0) return null;
    model[key] = entry[key];
  }
  if (!model.name.trim() || !(model.source === 'server' ? model.endpoint && model.id : model.file)) return null;
  return model;
}

function createSavedModels(stateDir) {
  if (typeof stateDir !== 'string' || !path.isAbsolute(stateDir)) throw new Error('State directory must be an absolute path.');
  const filename = path.join(stateDir, 'saved-models.json');

  // The list is a convenience: a missing or damaged file means an empty list, never a failed start.
  // Beside the models it keeps the keys of found models the user said "not now" to.
  function load() {
    try {
      const stat = fs.statSync(filename);
      if (!stat.isFile() || stat.size > 256 * 1024) return { models: [], ignored: [] };
      const saved = JSON.parse(fs.readFileSync(filename, 'utf8'));
      const seen = new Set();
      const models = (Array.isArray(saved?.models) ? saved.models : []).map(clean).filter(Boolean)
        .filter(model => !seen.has(keyOf(model)) && seen.add(keyOf(model))).slice(0, LIMIT);
      const ignored = (Array.isArray(saved?.ignored) ? saved.ignored : []).filter(key => typeof key === 'string' && /^[a-f0-9]{16}$/.test(key)).slice(0, 100);
      return { models, ignored };
    } catch { return { models: [], ignored: [] }; }
  }
  const read = () => load().models;
  const ignored = () => load().ignored;

  function write(models, keep = load().ignored) {
    fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    const temporary = path.join(stateDir, `.saved-models-${crypto.randomBytes(12).toString('hex')}.tmp`);
    try {
      // Entries can hold a local server key, so the file is private like config.json.
      fs.writeFileSync(temporary, `${JSON.stringify({ version: 1, models, ignored: keep }, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
      fs.renameSync(temporary, filename);
    } finally {
      try { fs.unlinkSync(temporary); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
  }

  function remember(input) {
    const model = clean(input);
    if (!model) throw new Error('This model cannot be saved to your list.');
    const key = keyOf(model);
    const others = read().filter(entry => keyOf(entry) !== key);
    if (others.length >= LIMIT) throw new Error(`Your list holds up to ${LIMIT} models. Remove one first.`);
    // A model that joins the list is no longer one the user passed over.
    write([...others, model], ignored().filter(entry => entry !== key));
    return key;
  }

  function forget(key) {
    const models = read();
    const kept = models.filter(entry => keyOf(entry) !== key);
    if (kept.length === models.length) throw new Error('That model is not in your list.');
    write(kept);
  }

  const find = key => read().find(entry => keyOf(entry) === key) || null;

  // "Not now" for a found model: the home page stops offering it; Settings still can.
  function ignore(key) {
    if (typeof key !== 'string' || !/^[a-f0-9]{16}$/.test(key)) throw new Error('Choose a found model to pass over.');
    const keys = ignored();
    if (!keys.includes(key)) write(read(), [...keys, key].slice(-100));
    return { ignored: true };
  }

  // What the interface may see: never the server key.
  function list(active) {
    const current = active && clean(active) ? keyOf(active) : '';
    return read().map(model => ({
      key: keyOf(model), name: model.name, source: model.source, context: model.context, active: keyOf(model) === current,
      where: model.source === 'server' ? model.endpoint.replace(/^https?:\/\//, '').replace(/\/v1\/?$/, '') : path.basename(model.file),
    }));
  }

  return { read, list, find, remember, forget, ignore, ignored };
}

// Stops whatever is loaded, then makes the chosen model the one in use. The next message starts it.
async function switchModel({ key, saved, configStore, runtime, busy }) {
  if (typeof key !== 'string') throw new Error('Choose a model from your list.');
  if (busy()) throw new Error('Wait for the current response before switching models.');
  const model = saved.find(key);
  if (!model) throw new Error('That model is not in your list.');
  try { validateModelFiles(model); }
  catch (error) { throw new Error(`${model.name} cannot be used right now: ${error.message}`); }
  await runtime.stop();
  if (busy()) throw new Error('Wait for the current response before switching models.');
  configStore.save({ model });
  return { switched: true, name: model.name };
}

// Adds models the finder turned up. Each is checked like one set up by hand; the first becomes
// the model in use when none was set up yet, so a new install is ready after one choice.
function addModels({ items, saved, configStore, threads = Math.max(1, Math.min(16, Math.floor(os.cpus().length / 2))) }) {
  if (!Array.isArray(items) || !items.length || items.length > LIMIT) throw new Error('Choose at least one model to add.');
  const base = configStore.read().model;
  const added = [], skipped = [];
  for (const item of items) {
    const title = typeof item?.name === 'string' && item.name.trim() ? item.name.trim().slice(0, 120) : 'Model';
    try {
      const context = Number.isSafeInteger(item?.context) ? Math.max(512, Math.min(131072, item.context)) : 4096;
      const model = item?.source === 'server'
        ? { source: 'server', endpoint: localEndpoint(item.endpoint), id: item.id, apiKey: '', name: title, file: '', runtime: '', context, gpuLayers: 0, threads }
        : { source: 'gguf', endpoint: base.endpoint, id: '', apiKey: '', name: title, file: item?.file, runtime: item?.runtime, context, gpuLayers: 0, threads };
      validateModelFiles(model);
      saved.remember(model);
      added.push(model);
    } catch (error) { skipped.push(`${title}: ${error.message}`); }
  }
  if (!added.length) throw new Error(`No model could be added. ${skipped[0]}`);
  const current = clean(base);
  const ready = current && (current.source === 'server' ? current.id : current.runtime);
  if (!ready) configStore.save({ model: added[0] });
  return { added: added.map(model => model.name), skipped, inUse: ready ? base.name : added[0].name };
}

function forgetModel({ key, saved, configStore }) {
  if (typeof key !== 'string') throw new Error('Choose a model from your list.');
  const active = clean(configStore.read().model);
  if (active && keyOf(active) === key) throw new Error('This model is in use. Switch to another model before removing it.');
  saved.forget(key);
  return { removed: true };
}

module.exports = { createSavedModels, switchModel, forgetModel, addModels, keyOf };
