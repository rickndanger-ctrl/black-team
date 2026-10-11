'use strict';

// Finds the models already on this computer, so setting up is choosing, not typing.
// It asks local servers for their model list and looks for GGUF files in the folders
// model tools use. Loopback requests and file names and sizes only: no file is opened
// beyond its 24-byte header, nothing is executed, and nothing leaves the computer.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { inspectModel, estimateMemory } = require('./config.cjs');
const { describeModel } = require('./gguf.cjs');
const { suggestContext } = require('./launch.cjs');
const { discoverModels } = require('./local-server.cjs');

const PORTS = { 11434: 'Ollama', 1234: 'LM Studio', 8080: 'llama.cpp', 1337: 'Jan', 5001: 'KoboldCpp', 8000: 'Local server' };
const SERVERS = /^(llama-server|llama-cpp-server|koboldcpp|local-ai|tabbyapi)$/;
const FOLDERS = ['models', 'Models', '.cache/lm-studio/models', '.lmstudio/models', '.cache/llama.cpp', 'llama.cpp/models',
  '.local/share/nomic.ai/GPT4All', '.cache/huggingface/hub', 'Downloads'];
// Helper files that sit beside a model but are not one: vision projectors, draft heads, later parts of a split file.
const NOT_A_MODEL = /(^|[-_.])(mmproj|mtp|draft)([-_.]|$)|-0000[2-9]-of-\d{5}\.gguf$|-000[1-9]\d-of-\d{5}\.gguf$/i;
const MIN_BYTES = 200 * 1024 * 1024;

const label = value => path.basename(value).replace(/\.gguf$/i, '').slice(0, 120);
const QUANT = /\b(I?Q\d[A-Z0-9_]*|BF16|F16|F32|UD-[A-Z0-9_]+)\b/;

// Files beside a model that belong to it: its vision projector and a draft model for faster replies.
function companionsFor(file) {
  const dir = path.dirname(file);
  let names = [];
  try { names = fs.readdirSync(dir).filter(name => /\.gguf$/i.test(name) && name !== path.basename(file)); } catch {}
  const pick = test => { const found = names.filter(test).sort(); return found.length ? path.join(dir, found[0]) : ''; };
  return {
    mmproj: pick(name => /(^|[-_.])mmproj([-_.]|$)/i.test(name)),
    draft: pick(name => /(^|[-_.])(mtp|draft)([-_.]|$)/i.test(name)),
  };
}

// What the file says about itself, for a good name and a context that fits.
function describeFile(file, bytes, memory) {
  let meta = {};
  try { meta = describeModel(file); } catch {}
  const quant = path.basename(file).match(QUANT)?.[0] || '';
  const name = (meta.name ? `${meta.name}${meta.sizeLabel && !meta.name.includes(meta.sizeLabel) ? ` ${meta.sizeLabel}` : ''}${quant && !meta.name.includes(quant) ? ` ${quant}` : ''}` : label(file)).slice(0, 120);
  return { name, trainingContext: meta.trainingContext ?? null, context: suggestContext({ trainingContext: meta.trainingContext, bytes, totalMemory: memory?.total ?? os.totalmem() }) };
}

// Model servers this user is already running, on whatever port they chose.
function runningServers(procRoot = '/proc') {
  const found = [];
  let entries = [];
  try { entries = fs.readdirSync(procRoot).filter(name => /^\d+$/.test(name)).slice(0, 20000); } catch { return found; }
  for (const pid of entries) {
    let argv;
    try { argv = fs.readFileSync(path.join(procRoot, pid, 'cmdline'), 'utf8').split('\0').filter(Boolean); } catch { continue; }
    if (!argv.length || !SERVERS.test(path.basename(argv[0]))) continue;
    const value = (...names) => { for (let i = 1; i < argv.length; i++) { for (const name of names) { if (argv[i] === name) return argv[i + 1]; if (argv[i].startsWith(`${name}=`)) return argv[i].slice(name.length + 1); } } };
    const port = Number(value('--port') ?? 8080);
    if (!Number.isInteger(port) || port < 1 || port > 65535) continue;
    let executable = '';
    try { executable = fs.readlinkSync(path.join(procRoot, pid, 'exe')); } catch {}
    found.push({ port, file: value('-m', '--model') || '', executable: path.basename(executable) === 'llama-server' ? executable : '' });
  }
  return found;
}

function ggufFiles(home, extra = []) {
  const roots = [...new Set([...FOLDERS.map(folder => path.join(home, folder)), ...extra])];
  const files = [], looked = [];
  let budget = 6000;
  const walk = (dir, depth) => {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const entry of entries) {
      if (--budget < 0 || files.length >= 60) return;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) { if (depth < 5 && !entry.name.startsWith('.git')) walk(full, depth + 1); continue; }
      if (!/\.gguf$/i.test(entry.name) || NOT_A_MODEL.test(entry.name)) continue;
      // Hugging Face keeps its files behind links; a linked file is fine, a linked folder is never followed.
      try { const info = inspectModel(full); if (info.bytes >= MIN_BYTES) files.push({ file: full, real: info.realPath, bytes: info.bytes }); } catch {}
    }
  };
  for (const root of roots) { try { if (fs.statSync(root).isDirectory()) { looked.push(root); walk(root, 0); } } catch {} }
  const seen = new Set();
  return { looked, files: files.filter(item => !seen.has(item.real) && seen.add(item.real)) };
}

async function contextOf(origin, fetcher, signal) {
  // llama.cpp says how much context it loaded; other servers do not, and the caller falls back.
  try {
    const response = await fetcher(`${origin}/props`, { redirect: 'error', signal });
    if (!response.ok) { await response.body?.cancel(); return 0; }
    const size = (await response.json())?.default_generation_settings?.n_ctx;
    return Number.isSafeInteger(size) && size >= 512 ? Math.min(size, 131072) : 0;
  } catch { return 0; }
}

async function findModels({ home = os.homedir(), fetch: fetcher = globalThis.fetch, procRoot = '/proc', runtime = '', folders = [], timeoutMs = 2500, memory } = {}) {
  const running = runningServers(procRoot);
  const ports = [...new Set([...Object.keys(PORTS).map(Number), ...running.map(item => item.port)])];
  const servers = [];
  await Promise.all(ports.map(async port => {
    const signal = AbortSignal.timeout(timeoutMs);
    let found;
    try { found = await discoverModels({ endpoint: `http://127.0.0.1:${port}/v1`, fetch: fetcher, signal }); } catch { return; }
    const context = await contextOf(`http://127.0.0.1:${port}`, fetcher, AbortSignal.timeout(timeoutMs));
    const own = running.find(item => item.port === port);
    for (const id of found.models.slice(0, 24)) {
      servers.push({ source: 'server', provider: own ? 'llama.cpp' : PORTS[port] || 'Local server', endpoint: found.endpoint, id, name: label(id),
        context: context || 4096, contextKnown: Boolean(context), file: own?.file || '' });
    }
  }));
  servers.sort((a, b) => a.endpoint.localeCompare(b.endpoint) || a.name.localeCompare(b.name));
  // A running llama-server is also a llama.cpp installation that can start other model files.
  const engine = runtime || running.find(item => item.executable)?.executable || '';
  const scan = ggufFiles(home, folders);
  const loaded = new Set(servers.map(item => { try { return fs.realpathSync(item.file); } catch { return item.file; } }).filter(Boolean));
  const files = scan.files.filter(item => !loaded.has(item.real)).sort((a, b) => a.file.localeCompare(b.file)).map(item => {
    const estimate = memory ? estimateMemory(item.bytes, memory.total, memory.free) : estimateMemory(item.bytes);
    const described = describeFile(item.file, item.bytes, memory);
    return { source: 'gguf', file: item.file, name: described.name, bytes: item.bytes, runtime: engine, context: described.context, trainingContext: described.trainingContext, ...companionsFor(item.file), tooBig: estimate.exceedsTotal, tight: !estimate.exceedsTotal && estimate.exceedsFree };
  });
  return { servers: servers.map(({ file, ...server }) => server), files, runtime: engine, looked: { ports: ports.sort((a, b) => a - b), folders: scan.looked } };
}

module.exports = { findModels, runningServers, ggufFiles, companionsFor, describeFile };
