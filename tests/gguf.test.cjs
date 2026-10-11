'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { describeModel, readMetadata } = require('../lib/gguf.cjs');

// A small, real GGUF header: version 3, no tensors, a few metadata pairs including a long array.
function gguf(file, pairs) {
  const parts = [Buffer.from('GGUF', 'ascii')];
  const u32 = n => { const b = Buffer.alloc(4); b.writeUInt32LE(n); return b; };
  const u64 = n => { const b = Buffer.alloc(8); b.writeBigUInt64LE(BigInt(n)); return b; };
  const str = s => Buffer.concat([u64(Buffer.byteLength(s)), Buffer.from(s, 'utf8')]);
  parts.push(u32(3), u64(0), u64(pairs.length));
  for (const [key, type, value] of pairs) {
    parts.push(str(key));
    if (type === 'string') parts.push(u32(8), str(value));
    else if (type === 'u32') parts.push(u32(4), u32(value));
    else if (type === 'u64') parts.push(u32(10), u64(value));
    else if (type === 'strings') { parts.push(u32(9), u32(8), u64(value.length)); for (const item of value) parts.push(str(item)); }
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, Buffer.concat(parts));
  return file;
}

test('reads a model file\'s name, architecture, context and layers from its header only', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bt-gguf-')); t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const tokens = Array.from({ length: 5000 }, (_, i) => `tok${i}`);
  const file = gguf(path.join(dir, 'm.gguf'), [
    ['general.architecture', 'string', 'qwen35'], ['general.name', 'string', 'Qwen3.8-27B'], ['general.size_label', 'string', '27B'],
    ['tokenizer.ggml.tokens', 'strings', tokens], ['qwen35.context_length', 'u32', 262144], ['qwen35.block_count', 'u64', 65],
  ]);
  assert.deepEqual(describeModel(file), { name: 'Qwen3.8-27B', architecture: 'qwen35', sizeLabel: '27B', trainingContext: 262144, layers: 65, experts: null });
  // The token table is skipped, not kept.
  const { metadata } = readMetadata(file, { wanted: key => key === 'general.name' });
  assert.deepEqual(Object.keys(metadata), ['general.name']);
  fs.writeFileSync(path.join(dir, 'not.gguf'), 'plain text that is long enough to read');
  assert.throws(() => describeModel(path.join(dir, 'not.gguf')), /Not a GGUF/);
});
