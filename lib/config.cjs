'use strict';

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');

const { localEndpoint, serverHeaders } = require('./local-server.cjs');
const MODEL_KEYS = ['name', 'file', 'runtime', 'context', 'gpuLayers', 'threads', 'source', 'endpoint', 'id', 'apiKey'];

const GiB = 1024 ** 3;
const DEFAULT_WORKSPACE = path.join(os.homedir(), 'Black Team');

function defaults() {
  return {
    schemaVersion: 1,
    model: { source: 'gguf', endpoint: 'http://127.0.0.1:11434/v1', id: '', apiKey: '', name: 'Local model', file: '', runtime: '', context: 4096, gpuLayers: 0, threads: 4 },
    workspace: DEFAULT_WORKSPACE,
    phone: { enabled: false, hostname: '', owner: '' },
  };
}

function object(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value) ||
      ![Object.prototype, null].includes(Object.getPrototypeOf(value))) {
    throw new Error(`${label} must be an object.`);
  }
}

function keys(value, allowed, label) {
  object(value, label);
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) throw new Error(`Unsupported ${label} setting: ${key}.`);
  }
}

function string(value, label, max = 4096) {
  if (typeof value !== 'string' || value.length > max || /[\x00-\x1f\x7f]/.test(value)) {
    throw new Error(`${label} must be text without control characters (maximum ${max} characters).`);
  }
}

function integer(value, label, min, max) {
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new Error(`${label} must be a whole number from ${min} to ${max}.`);
  }
}

function validateShape(config) {
  keys(config, ['schemaVersion', 'model', 'workspace', 'phone'], 'configuration');
  if (config.schemaVersion !== 1) throw new Error('Unsupported configuration version. Install a compatible Black Team version.');
  keys(config.model, MODEL_KEYS, 'model');
  if (!['gguf', 'server'].includes(config.model.source)) throw new Error('Choose a GGUF file or an existing local server.');
  localEndpoint(config.model.endpoint);
  serverHeaders(config.model.apiKey);
  string(config.model.id, 'Server model ID', 256);
  string(config.model.name, 'Model name', 120);
  if (!config.model.name.trim()) throw new Error('Enter a model name.');
  for (const key of ['file', 'runtime']) {
    string(config.model[key], `Model ${key}`);
    if (config.model[key] && !path.isAbsolute(config.model[key])) throw new Error(`Model ${key} must be an absolute local path.`);
  }
  integer(config.model.context, 'Context size', 512, 131072);
  integer(config.model.gpuLayers, 'GPU layers', 0, 999);
  integer(config.model.threads, 'CPU threads', 1, 1024);
  string(config.workspace, 'Workspace');
  if (!path.isAbsolute(config.workspace)) throw new Error('Workspace must be an absolute local path.');
  keys(config.phone, ['enabled', 'hostname', 'owner'], 'phone');
  if (typeof config.phone.enabled !== 'boolean') throw new Error('Phone enabled must be true or false.');
  string(config.phone.hostname, 'Phone hostname', 253);
  string(config.phone.owner, 'Phone owner', 120);
  if (config.phone.hostname && !/^(?=.{1,253}$)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/i.test(config.phone.hostname)) {
    throw new Error('Phone hostname must be a hostname without a scheme, path, or port.');
  }
  return config;
}

function readHeader(filename, length, label, accessMode = fs.constants.R_OK) {
  let fd;
  try {
    const stat = fs.statSync(filename);
    if (!stat.isFile()) throw new Error('not a regular file');
    fs.accessSync(filename, accessMode);
    fd = fs.openSync(filename, 'r');
    const header = Buffer.alloc(length);
    if (fs.readSync(fd, header, 0, length, 0) !== length) throw new Error('file is truncated');
    return { header, size: stat.size, realPath: fs.realpathSync(filename) };
  } catch (error) {
    throw new Error(`${label} cannot be read: ${error.code || error.message}.`);
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

function inspectModel(filename) {
  if (!filename || !path.isAbsolute(filename)) throw new Error('Choose a local GGUF model file first.');
  const info = readHeader(filename, 24, 'GGUF model');
  if (info.header.toString('ascii', 0, 4) !== 'GGUF' || ![2, 3].includes(info.header.readUInt32LE(4))) {
    throw new Error('Choose a GGUF version 2 or 3 model; this file has an invalid or unsupported header.');
  }
  return { bytes: info.size, version: info.header.readUInt32LE(4), realPath: info.realPath };
}

function inspectRuntime(filename) {
  if (process.platform !== 'linux') throw new Error('This Black Team release supports Linux.');
  if (!filename || !path.isAbsolute(filename) || path.basename(filename) !== 'llama-server') {
    throw new Error('Choose the llama-server executable from an extracted Linux llama.cpp release.');
  }
  const info = readHeader(filename, 64, 'llama-server', fs.constants.R_OK | fs.constants.X_OK);
  const header = info.header;
  const machine = { x64: 62, arm64: 183 }[process.arch];
  if (header[0] !== 0x7f || header.toString('ascii', 1, 4) !== 'ELF' || header[4] !== 2 ||
      header[5] !== 1 || ![2, 3].includes(header.readUInt16LE(16)) ||
      !machine || header.readUInt16LE(18) !== machine) {
    throw new Error(`llama-server must be a native Linux ${process.arch} executable. Keep it alongside its release libraries.`);
  }
  return { bytes: info.size, realPath: info.realPath };
}

function estimateMemory(modelBytes, totalBytes = os.totalmem(), freeBytes = os.freemem()) {
  const headroomBytes = Math.max(2 * GiB, Math.ceil(modelBytes * 0.25));
  const estimatedBytes = modelBytes + headroomBytes;
  return {
    modelBytes, headroomBytes, estimatedBytes,
    exceedsTotal: estimatedBytes > totalBytes,
    exceedsFree: estimatedBytes > freeBytes,
    warning: estimatedBytes > totalBytes
      ? 'This model plus basic headroom exceeds system RAM. Choose a smaller model or expect memory pressure.'
      : estimatedBytes > freeBytes
        ? 'This model plus basic headroom exceeds currently free RAM. Close other apps or choose a smaller model.'
        : null,
    note: 'Rough RAM estimate only. Context length, model architecture, GPU memory, and other apps affect actual usage; this does not guarantee the model will fit.',
  };
}

function validateModelFiles(model) {
  if (model?.source === 'server') {
    localEndpoint(model.endpoint);
    if (typeof model.id !== 'string' || !model.id.trim() || model.id.length > 256 || /[\x00-\x1f\x7f]/.test(model.id)) throw new Error('Choose a model reported by your local server.');
    serverHeaders(model.apiKey);
    return { server: true };
  }
  const file = inspectModel(model.file);
  const runtime = inspectRuntime(model.runtime);
  return { model: file, runtime, memory: estimateMemory(file.bytes) };
}

function validateWorkspace(workspace) {
  try {
    if (!fs.statSync(workspace).isDirectory()) throw new Error('not a directory');
    fs.accessSync(workspace, fs.constants.R_OK | fs.constants.W_OK | fs.constants.X_OK);
  } catch (error) {
    // The default workspace can be created later, when a feature actually uses it.
    if (error.code === 'ENOENT' && workspace === DEFAULT_WORKSPACE) return;
    throw new Error('Choose an existing, readable and writable workspace directory.');
  }
}

function ensureWorkspace(workspace) {
  validateWorkspace(workspace);
  if (workspace === DEFAULT_WORKSPACE && !fs.existsSync(workspace)) {
    fs.mkdirSync(workspace, { mode: 0o700 });
  }
  validateWorkspace(workspace);
  return workspace;
}

function createConfigStore(stateDir) {
  if (typeof stateDir !== 'string' || !path.isAbsolute(stateDir)) throw new Error('State directory must be an absolute path.');
  const filename = path.join(stateDir, 'config.json');

  function read() {
    let input;
    try {
      const stat = fs.statSync(filename);
      if (!stat.isFile() || stat.size > 64 * 1024) throw new Error('Configuration is not a valid small JSON file.');
      input = JSON.parse(fs.readFileSync(filename, 'utf8'));
    } catch (error) {
      if (error.code === 'ENOENT') return defaults();
      throw new Error(`Cannot read Black Team configuration: ${error.message}`);
    }
    keys(input, ['schemaVersion', 'model', 'workspace', 'phone'], 'configuration');
    if (input.schemaVersion !== 1) throw new Error('Unsupported configuration version. Install a compatible Black Team version.');
    if (input.model !== undefined) keys(input.model, MODEL_KEYS, 'model');
    if (input.phone !== undefined) keys(input.phone, ['enabled', 'hostname', 'owner'], 'phone');
    const base = defaults();
    return validateShape({ ...base, ...input, model: { ...base.model, ...input.model }, phone: { ...base.phone, ...input.phone } });
  }

  function save(input) {
    keys(input, ['schemaVersion', 'model', 'workspace', 'phone'], 'configuration');
    if (input.model !== undefined) keys(input.model, MODEL_KEYS, 'model');
    if (input.phone !== undefined) keys(input.phone, ['enabled', 'hostname', 'owner'], 'phone');
    const previous = read();
    const next = validateShape({ ...previous, ...input, model: { ...previous.model, ...input.model }, phone: { ...previous.phone, ...input.phone } });
    if (next.model.source !== 'server') {
      if (next.model.file) inspectModel(next.model.file);
      if (next.model.runtime) inspectRuntime(next.model.runtime);
    }
    validateWorkspace(next.workspace);
    fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
    if (fs.lstatSync(stateDir).isSymbolicLink()) throw new Error('Black Team state directory must not be a symbolic link.');
    fs.chmodSync(stateDir, 0o700);
    const temporary = path.join(stateDir, `.config-${crypto.randomBytes(12).toString('hex')}.tmp`);
    let fd;
    try {
      fd = fs.openSync(temporary, 'wx', 0o600);
      fs.writeFileSync(fd, `${JSON.stringify(next, null, 2)}\n`);
      fs.fsyncSync(fd);
      fs.closeSync(fd);
      fd = undefined;
      fs.renameSync(temporary, filename);
      const dirfd = fs.openSync(stateDir, 'r');
      try { fs.fsyncSync(dirfd); } finally { fs.closeSync(dirfd); }
    } finally {
      if (fd !== undefined) fs.closeSync(fd);
      try { fs.unlinkSync(temporary); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    return next;
  }

  return { read, save };
}

async function hardwareReport(stateDir = os.homedir()) {
  let disk = null;
  let probe = path.resolve(stateDir);
  while (!fs.existsSync(probe) && path.dirname(probe) !== probe) probe = path.dirname(probe);
  try {
    const stat = await fs.promises.statfs(probe);
    disk = { path: probe, total: stat.blocks * stat.bsize, free: stat.bfree * stat.bsize, available: stat.bavail * stat.bsize };
  } catch { /* Disk information is optional on unsupported filesystems. */ }
  const cpus = os.cpus();
  return { platform: os.platform(), arch: os.arch(), cpu: { name: cpus[0]?.model || 'Unknown CPU', cores: cpus.length }, memory: { total: os.totalmem(), free: os.freemem() }, disk };
}

module.exports = { createConfigStore, hardwareReport, hardware: hardwareReport, validateModelFiles, estimateMemory, inspectModel, inspectRuntime, ensureWorkspace };
