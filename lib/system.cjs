'use strict';

// What this computer is and how hard it is working, read from the kernel's own
// figures so the readout matches what `lscpu`, `free` and `df` would say.
// Everything here is a local file read; a missing file leaves that value out.

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const read = file => { try { return fs.readFileSync(file, 'utf8'); } catch { return ''; } };
const number = text => { const value = Number(String(text).trim()); return Number.isFinite(value) ? value : null; };

// Physical cores against the threads the scheduler sees; os.cpus() only knows threads.
function cpuTopology({ sysRoot = '/sys', procRoot = '/proc' } = {}) {
  const threads = os.cpus().length;
  const cores = new Set(), sockets = new Set();
  let base = path.join(sysRoot, 'devices/system/cpu');
  let listed = [];
  try { listed = fs.readdirSync(base).filter(name => /^cpu\d+$/.test(name)); } catch {}
  for (const cpu of listed) {
    const online = read(path.join(base, cpu, 'online')).trim();
    if (online === '0') continue;
    const core = read(path.join(base, cpu, 'topology/core_id')).trim();
    const socket = read(path.join(base, cpu, 'topology/physical_package_id')).trim();
    if (core === '') continue;
    cores.add(`${socket}:${core}`);
    sockets.add(socket);
  }
  const info = read(path.join(procRoot, 'cpuinfo'));
  const name = (info.match(/^model name\s*:\s*(.+)$/m)?.[1] || os.cpus()[0]?.model || 'Unknown CPU').replace(/\s+/g, ' ').replace(/\(R\)|\(TM\)|CPU\s+@.*$/g, '').trim();
  // Current speed, averaged over threads; the governor moves it with load.
  const speeds = listed.map(cpu => number(read(path.join(base, cpu, 'cpufreq/scaling_cur_freq')))).filter(value => value > 0).map(khz => khz / 1000);
  const fromInfo = [...info.matchAll(/^cpu MHz\s*:\s*([\d.]+)/gm)].map(match => Number(match[1]));
  const sample = speeds.length ? speeds : fromInfo;
  const mhz = sample.length ? Math.round(sample.reduce((sum, value) => sum + value, 0) / sample.length) : null;
  return { name, threads, cores: cores.size || threads, sockets: sockets.size || 1, mhz };
}

// MemAvailable is what the kernel can actually hand out: free pages plus cache it can drop.
function memoryInfo({ procRoot = '/proc' } = {}) {
  const text = read(path.join(procRoot, 'meminfo'));
  const kb = key => { const value = number(text.match(new RegExp(`^${key}:\\s*(\\d+)`, 'm'))?.[1]); return value === null ? null : value * 1024; };
  const total = kb('MemTotal') ?? os.totalmem();
  const available = kb('MemAvailable') ?? os.freemem();
  const swapTotal = kb('SwapTotal') ?? 0, swapFree = kb('SwapFree') ?? 0;
  return { total, available, free: kb('MemFree') ?? available, used: Math.max(0, total - available), swapTotal, swapUsed: Math.max(0, swapTotal - swapFree) };
}

// The CPU package temperature, from the sensor driver Intel and AMD chips expose.
function cpuTemperature({ sysRoot = '/sys' } = {}) {
  const hwmon = path.join(sysRoot, 'class/hwmon');
  let devices = [];
  try { devices = fs.readdirSync(hwmon); } catch {}
  for (const device of devices) {
    const dir = path.join(hwmon, device);
    if (!/^(coretemp|k10temp|zenpower|cpu_thermal|cpu-thermal)$/.test(read(path.join(dir, 'name')).trim())) continue;
    let inputs = [];
    try { inputs = fs.readdirSync(dir).filter(name => /^temp\d+_input$/.test(name)).sort(); } catch {}
    // Prefer the package reading over a single core's.
    const labelled = inputs.find(name => /package|tctl|tdie/i.test(read(path.join(dir, name.replace('_input', '_label')))));
    const value = number(read(path.join(dir, labelled || inputs[0] || 'none')));
    if (value !== null) return { celsius: Math.round(value / 1000), source: 'cpu' };
  }
  const zones = path.join(sysRoot, 'class/thermal');
  let listed = [];
  try { listed = fs.readdirSync(zones).filter(name => name.startsWith('thermal_zone')); } catch {}
  for (const zone of listed) {
    if (!/x86_pkg_temp|cpu[-_]thermal|soc[-_]thermal/i.test(read(path.join(zones, zone, 'type')))) continue;
    const value = number(read(path.join(zones, zone, 'temp')));
    if (value !== null) return { celsius: Math.round(value / 1000), source: 'cpu' };
  }
  return null;
}

// Resident and swapped memory of one process, such as the model server.
function processMemory(pid, { procRoot = '/proc' } = {}) {
  if (!Number.isInteger(pid) || pid <= 0) return null;
  const text = read(path.join(procRoot, String(pid), 'status'));
  if (!text) return null;
  const kb = key => (number(text.match(new RegExp(`^${key}:\\s*(\\d+)`, 'm'))?.[1]) ?? 0) * 1024;
  return { pid, resident: kb('VmRSS'), swapped: kb('VmSwap') };
}

// The user's own model server listening on a port, found by its command line.
function serverProcess(port, { procRoot = '/proc' } = {}) {
  if (!Number.isInteger(port) || port <= 0) return null;
  let entries = [];
  try { entries = fs.readdirSync(procRoot).filter(name => /^\d+$/.test(name)).slice(0, 20000); } catch { return null; }
  for (const pid of entries) {
    const argv = read(path.join(procRoot, pid, 'cmdline')).split('\0').filter(Boolean);
    if (!argv.length || !/^(llama-server|llama-cpp-server|ollama|lms|koboldcpp|local-ai|tabbyapi|jan)$/.test(path.basename(argv[0]))) continue;
    const given = argv.findIndex((arg, index) => index > 0 && (arg === '--port' || arg === '-p'));
    const value = given > 0 ? argv[given + 1] : argv.find(arg => arg.startsWith('--port='))?.slice(7);
    if (Number(value) === port || (value === undefined && port === { ollama: 11434, lms: 1234 }[path.basename(argv[0])])) return Number(pid);
  }
  return null;
}

// Whole-system CPU use between two readings. Readings closer than a second apart
// are too noisy to mean anything, so the last figure is kept until enough time passes.
function createCpuSampler({ cpus = os.cpus, now = Date.now, minimumMs = 1000 } = {}) {
  let previous = cpus(), at = now(), last = 0;
  return () => {
    const elapsed = now() - at;
    if (elapsed < minimumMs) return last;
    const current = cpus();
    let total = 0, idle = 0;
    current.forEach((cpu, index) => {
      for (const key of Object.keys(cpu.times)) {
        const delta = cpu.times[key] - (previous[index]?.times[key] || 0);
        total += delta;
        if (key === 'idle') idle += delta;
      }
    });
    previous = current; at = now();
    last = total > 0 ? Math.max(0, Math.min(100, Math.round(100 * (1 - idle / total)))) : last;
    return last;
  };
}

module.exports = { cpuTopology, memoryInfo, cpuTemperature, processMemory, serverProcess, createCpuSampler };
