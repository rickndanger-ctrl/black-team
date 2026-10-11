'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { planLaunch, supportOf, suggestContext } = require('../lib/launch.cjs');

const MAINLINE = `-t, --threads N\n-tb, --threads-batch N\n-b, --batch-size N\n-ub, --ubatch-size N\n-cram, --cache-ram N\n-fa, --flash-attn [on|off|auto]\n-ctk, --cache-type-k TYPE\n-ctv, --cache-type-v TYPE\n-mm, --mmproj FILE\n--mmproj-offload, --no-mmproj-offload\n--jinja, --no-jinja\n--spec-draft-model, -md, --model-draft FNAME\n--spec-type none,draft-simple,draft-eagle3,draft-mtp,ngram-simple\n`;
const model = { file: '/m/q.gguf', context: 32768, gpuLayers: 0, threads: 0, mmproj: '/m/mmproj-F16.gguf', draft: '/m/mtp-q.gguf' };
const GiB = 1024 ** 3;

test('a full-featured build gets the tuned CPU settings, the projector and the MTP draft', () => {
  const plan = planLaunch({ model, port: 5000, keyFile: '/k', cores: 6, help: MAINLINE });
  const after = flag => plan.args[plan.args.indexOf(flag) + 1];
  assert.equal(after('--threads'), '6'); assert.equal(after('--threads-batch'), '6');
  assert.equal(after('--batch-size'), '256'); assert.equal(after('--ubatch-size'), '128');
  assert.equal(after('--cache-ram'), '1024'); assert.equal(after('--flash-attn'), 'on');
  assert.equal(after('--cache-type-k'), 'q8_0'); assert.equal(after('--cache-type-v'), 'q8_0');
  assert.equal(after('--mmproj'), '/m/mmproj-F16.gguf'); assert.ok(plan.args.includes('--no-mmproj-offload'));
  assert.equal(after('--spec-type'), 'draft-mtp'); assert.equal(after('--spec-draft-model'), '/m/mtp-q.gguf');
  assert.ok(plan.args.includes('--jinja') && plan.args.includes('--no-webui'));
  assert.deepEqual(plan.features, ['6 threads', 'q8 cache', 'vision', 'MTP draft']);
  assert.equal(after('--api-key-file'), '/k');
});

test('a build that knows none of the flags gets only the basic launch, and the user\'s own threads win', () => {
  const plan = planLaunch({ model: { ...model, threads: 4 }, port: 5000, keyFile: '/k', cores: 6, help: 'fixture runtime' });
  assert.deepEqual(plan.args, ['--host', '127.0.0.1', '--port', '5000', '--model', '/m/q.gguf', '--ctx-size', '32768', '--n-gpu-layers', '0', '--threads', '4', '--parallel', '1', '--alias', 'black-team-local', '--api-key-file', '/k', '--no-webui']);
  assert.deepEqual(plan.features, ['4 threads']);
});

test('a GPU launch keeps the default batches, and a plain draft or an MTP file picks the right type', () => {
  const gpu = planLaunch({ model: { ...model, gpuLayers: 40, draft: '' }, port: 1, keyFile: '/k', cores: 6, help: MAINLINE });
  assert.equal(gpu.args.includes('--batch-size'), false); assert.equal(gpu.args.includes('--no-mmproj-offload'), false);
  const plain = planLaunch({ model: { ...model, draft: '/m/small-draft.gguf' }, port: 1, keyFile: '/k', cores: 6, help: MAINLINE });
  assert.equal(plain.args[plain.args.indexOf('--spec-type') + 1], 'draft-simple');
  // An MTP file is left out of a build that cannot use it, rather than failing the start.
  const old = planLaunch({ model, port: 1, keyFile: '/k', cores: 6, help: MAINLINE.replace('draft-mtp,', '') });
  assert.equal(old.args.includes('--spec-type'), false);
  assert.equal(supportOf(MAINLINE).mtp, true); assert.equal(supportOf('').cacheTypes, false);
});

// A forked build seen on the author's laptop: no web UI switch (only --webui NAME), no alias,
// no GPU flag, and speculative decoding as --spec-type mtp:... read from heads inside the model.
const FORK = `--host HOST\n--port PORT\n-t, --threads N\n-tb, --threads-batch N\n-b, --batch-size N\n-ub, --ubatch-size N\n-np, --parallel N\n--cache-ram N\n-fa, --flash-attn [on|off|auto]\n-ctk, --cache-type-k TYPE\n-ctv, --cache-type-v TYPE\n--mmproj FILE\n--no-mmproj-offload\n--jinja\n--api-key-file FNAME\n--webui NAME controls which webui to server: none, auto\n-md, --model-draft FNAME\n--spec-type SPEC[:k=v,...] canonical speculative stage entry.\n  examples: --spec-type mtp:n_max=1,p_min=0.0\n`;

test('a fork without the basic flags is given only what it knows, and its own MTP heads', () => {
  const plan = planLaunch({ model, port: 7, keyFile: '/k', cores: 6, help: FORK });
  const after = flag => plan.args[plan.args.indexOf(flag) + 1];
  for (const flag of ['--no-webui', '--alias', '--n-gpu-layers', '--spec-draft-model']) assert.equal(plan.args.includes(flag), false, flag);
  assert.equal(after('--webui'), 'none'); assert.equal(after('--spec-type'), 'mtp:n_max=2,p_min=0.0');
  assert.equal(after('--api-key-file'), '/k'); assert.equal(after('--cache-type-k'), 'q8_0'); assert.equal(after('--mmproj'), '/m/mmproj-F16.gguf');
  assert.deepEqual(plan.features, ['6 threads', 'q8 cache', 'vision', 'MTP']);
  // A plain draft file means nothing to a build that cannot load one; a GPU count goes through -ngl when that is the spelling.
  const plain = planLaunch({ model: { ...model, draft: '/m/small-draft.gguf' }, port: 7, keyFile: '/k', cores: 6, help: FORK });
  assert.equal(plain.args.includes('--spec-type'), false);
  const ngl = planLaunch({ model: { ...model, gpuLayers: 20 }, port: 7, keyFile: '/k', cores: 6, help: `${FORK}-ngl, --gpu-layers N\n` });
  assert.equal(ngl.args[ngl.args.indexOf('-ngl') + 1], '20'); assert.equal(ngl.args.includes('--n-gpu-layers'), false);
  // A build with no web UI at all gets no web UI flag.
  const bare = planLaunch({ model, port: 7, keyFile: '/k', cores: 6, help: FORK.replace(/--webui NAME.*\n/, '') });
  assert.equal(bare.args.includes('--webui'), false); assert.equal(bare.args.includes('--no-webui'), false);
});

test('the suggested context follows the training length and the memory left beside the weights', () => {
  assert.equal(suggestContext({ trainingContext: 262144, bytes: 17 * GiB, totalMemory: 46 * GiB }), 32768);
  assert.equal(suggestContext({ trainingContext: 262144, bytes: 17 * GiB, totalMemory: 28 * GiB }), 16384);
  assert.equal(suggestContext({ trainingContext: 262144, bytes: 17 * GiB, totalMemory: 22 * GiB }), 8192);
  assert.equal(suggestContext({ trainingContext: 4096, bytes: GiB, totalMemory: 64 * GiB }), 4096);
  assert.equal(suggestContext({ trainingContext: null, bytes: GiB, totalMemory: 64 * GiB }), 32768);
});
