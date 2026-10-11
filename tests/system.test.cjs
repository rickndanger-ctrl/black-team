'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { cpuTopology, memoryInfo, cpuTemperature, processMemory, serverProcess, createCpuSampler } = require('../lib/system.cjs');

const fresh = t => { const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bt-system-')); t.after(() => fs.rmSync(dir, { recursive: true, force: true })); return dir; };
const put = (file, text) => { fs.mkdirSync(path.dirname(file), { recursive: true }); fs.writeFileSync(file, text); };

test('counts physical cores separately from threads and reads the chip name and speed', t => {
  const root = fresh(t), sys = path.join(root, 'sys'), proc = path.join(root, 'proc');
  // Two cores with two threads each, one thread offline, plus a second socket with one core.
  const layout = [[0, 0, 0], [1, 0, 0], [2, 0, 1], [3, 0, 1], [4, 1, 0]];
  for (const [cpu, socket, core] of layout) {
    put(path.join(sys, `devices/system/cpu/cpu${cpu}/topology/core_id`), `${core}\n`);
    put(path.join(sys, `devices/system/cpu/cpu${cpu}/topology/physical_package_id`), `${socket}\n`);
    put(path.join(sys, `devices/system/cpu/cpu${cpu}/cpufreq/scaling_cur_freq`), cpu === 3 ? '0\n' : '2400000\n');
  }
  put(path.join(sys, 'devices/system/cpu/cpu3/online'), '0\n');
  put(path.join(proc, 'cpuinfo'), 'processor\t: 0\nmodel name\t: Intel(R) Core(TM) i7-10810U CPU @ 1.10GHz\ncpu MHz\t\t: 900.000\n');
  const cpu = cpuTopology({ sysRoot: sys, procRoot: proc });
  assert.deepEqual({ ...cpu, threads: undefined }, { name: 'Intel Core i7-10810U', cores: 3, sockets: 2, mhz: 2400, threads: undefined });
  assert.equal(cpu.threads, os.cpus().length);
  // Without the sysfs layout the count falls back to threads rather than claiming a number.
  const bare = cpuTopology({ sysRoot: path.join(root, 'none'), procRoot: path.join(root, 'none') });
  assert.equal(bare.cores, bare.threads);
  assert.equal(bare.sockets, 1);
});

test('memory comes from meminfo, with available meaning what the kernel can hand out', t => {
  const proc = path.join(fresh(t), 'proc');
  put(path.join(proc, 'meminfo'), 'MemTotal:       48914564 kB\nMemFree:         4186292 kB\nMemAvailable:   12820388 kB\nSwapTotal:      81362636 kB\nSwapFree:       79079244 kB\n');
  const memory = memoryInfo({ procRoot: proc });
  assert.deepEqual(memory, { total: 48914564 * 1024, available: 12820388 * 1024, free: 4186292 * 1024, used: (48914564 - 12820388) * 1024, swapTotal: 81362636 * 1024, swapUsed: (81362636 - 79079244) * 1024 });
  const fallback = memoryInfo({ procRoot: path.join(proc, 'none') });
  assert.equal(fallback.total, os.totalmem());
  assert.equal(fallback.swapUsed, 0);
});

test('CPU temperature prefers the package sensor and otherwise a CPU thermal zone', t => {
  const sys = path.join(fresh(t), 'sys');
  put(path.join(sys, 'class/hwmon/hwmon0/name'), 'acpitz\n');
  put(path.join(sys, 'class/hwmon/hwmon0/temp1_input'), '25000\n');
  put(path.join(sys, 'class/hwmon/hwmon1/name'), 'coretemp\n');
  put(path.join(sys, 'class/hwmon/hwmon1/temp1_label'), 'Package id 0\n');
  put(path.join(sys, 'class/hwmon/hwmon1/temp1_input'), '41000\n');
  put(path.join(sys, 'class/hwmon/hwmon1/temp2_label'), 'Core 0\n');
  put(path.join(sys, 'class/hwmon/hwmon1/temp2_input'), '39000\n');
  assert.deepEqual(cpuTemperature({ sysRoot: sys }), { celsius: 41, source: 'cpu' });
  const arm = path.join(sys, 'arm');
  put(path.join(arm, 'class/thermal/thermal_zone0/type'), 'cpu-thermal\n');
  put(path.join(arm, 'class/thermal/thermal_zone0/temp'), '52500\n');
  assert.deepEqual(cpuTemperature({ sysRoot: arm }), { celsius: 53, source: 'cpu' });
  assert.equal(cpuTemperature({ sysRoot: path.join(sys, 'none') }), null);
});

test('finds the model server on a port and reads how much memory it holds', t => {
  const proc = path.join(fresh(t), 'proc');
  put(path.join(proc, '41/cmdline'), ['/opt/llama/llama-server', '-m', '/m/a.gguf', '--port', '18081'].join('\0') + '\0');
  put(path.join(proc, '41/status'), 'Name:\tllama-server\nVmRSS:\t27658952 kB\nVmSwap:\t  677328 kB\n');
  put(path.join(proc, '42/cmdline'), ['ollama', 'serve'].join('\0') + '\0');
  put(path.join(proc, '43/cmdline'), ['/usr/bin/python3', 'fake-server', '--port', '18080'].join('\0') + '\0');
  assert.equal(serverProcess(18081, { procRoot: proc }), 41);
  assert.equal(serverProcess(11434, { procRoot: proc }), 42);
  assert.equal(serverProcess(18080, { procRoot: proc }), null);
  assert.deepEqual(processMemory(41, { procRoot: proc }), { pid: 41, resident: 27658952 * 1024, swapped: 677328 * 1024 });
  assert.equal(processMemory(99, { procRoot: proc }), null);
  assert.equal(processMemory('41', { procRoot: proc }), null);
});

test('CPU use is measured between readings at least a second apart', () => {
  // Kernel counters only grow: busy and idle time each add up to the clock.
  let clock = 0, busy = 0;
  const cpus = () => [{ times: { user: busy, nice: 0, sys: 0, idle: clock - busy, irq: 0 } }];
  const sample = createCpuSampler({ cpus, now: () => clock });
  assert.equal(sample(), 0);
  // Half a second later the previous figure is repeated; a second later the delta is measured.
  clock = 500; busy = 250; assert.equal(sample(), 0);
  clock = 1000; assert.equal(sample(), 25);
  clock = 2000; busy = 1000; assert.equal(sample(), 75);
  clock = 3000; assert.equal(sample(), 0, 'a quiet second reads as idle');
});
