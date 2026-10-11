'use strict';

// How Black Team starts a model file well on this computer. The plan follows settings
// proven on a CPU laptop, and adds each one only when the llama-server build in use
// understands it, so a start never fails over a flag.

const path = require('node:path');
const GiB = 1024 ** 3;

// The flags a llama-server build accepts, read from its own help text.
function supportOf(help = '') {
  const text = String(help);
  const has = flag => new RegExp(`(^|[\\s,])${flag.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?=[\\s,]|$)`, 'm').test(text);
  return {
    threadsBatch: has('--threads-batch'), batch: has('--batch-size') && has('--ubatch-size'), cacheRam: has('--cache-ram'),
    flashAttn: has('--flash-attn'), cacheTypes: has('--cache-type-k') && has('--cache-type-v'),
    mmproj: has('--mmproj'), mmprojOffload: has('--no-mmproj-offload'), jinja: has('--jinja'),
    draft: has('--spec-draft-model') || has('--model-draft'), mtp: /draft-mtp/.test(text), specType: has('--spec-type'),
  };
}

// A context that fits: the model's training length, capped by the memory left beside the weights.
function suggestContext({ trainingContext = null, bytes = 0, totalMemory = 0 }) {
  const headroom = totalMemory - bytes - 4 * GiB;
  const cap = headroom >= 12 * GiB ? 32768 : headroom >= 6 * GiB ? 16384 : 8192;
  const trained = Number.isSafeInteger(trainingContext) && trainingContext >= 512 ? trainingContext : cap;
  return Math.max(512, Math.min(cap, trained, 131072));
}

function planLaunch({ model, port, keyFile, cores = 4, help = '' }) {
  const support = supportOf(help);
  const cpuOnly = !model.gpuLayers;
  const threads = Number.isSafeInteger(model.threads) && model.threads > 0 ? model.threads : Math.max(1, cores);
  const args = ['--host', '127.0.0.1', '--port', String(port), '--model', model.file,
    '--ctx-size', String(model.context), '--n-gpu-layers', String(model.gpuLayers || 0),
    '--threads', String(threads), '--parallel', '1', '--alias', 'black-team-local',
    '--api-key-file', keyFile, '--no-webui'];
  const features = [`${threads} threads`];
  if (support.threadsBatch) args.push('--threads-batch', String(threads));
  // Smaller batches keep prompt processing memory down on a CPU; a GPU wants the defaults.
  if (cpuOnly && support.batch) args.push('--batch-size', '256', '--ubatch-size', '128');
  // The prompt cache otherwise claims 8 GiB of RAM beside the model.
  if (support.cacheRam) args.push('--cache-ram', '1024');
  // Eight-bit KV cache halves context memory; it needs flash attention, which the CPU path provides.
  if (support.flashAttn && support.cacheTypes) { args.push('--flash-attn', 'on', '--cache-type-k', 'q8_0', '--cache-type-v', 'q8_0'); features.push('q8 cache'); }
  if (support.jinja) args.push('--jinja');
  if (model.mmproj && support.mmproj) { args.push('--mmproj', model.mmproj); if (cpuOnly && support.mmprojOffload) args.push('--no-mmproj-offload'); features.push('vision'); }
  if (model.draft && support.draft && support.specType) {
    const mtp = /(^|[-_.])mtp([-_.]|$)/i.test(path.basename(model.draft));
    if (!mtp || support.mtp) { args.push('--spec-type', mtp ? 'draft-mtp' : 'draft-simple', '--spec-draft-model', model.draft); features.push(mtp ? 'MTP draft' : 'draft model'); }
  }
  return { args, features, support };
}

module.exports = { planLaunch, supportOf, suggestContext };
