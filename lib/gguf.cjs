'use strict';

// Reads what a GGUF model says about itself: its name, architecture, training
// context and layer count. Only the header's key-value section is read, never
// the weights, so a 20 GB file costs a few kilobytes.

const fs = require('node:fs');

const TYPES = { 0: 'u8', 1: 'i8', 2: 'u16', 3: 'i16', 4: 'u32', 5: 'i32', 6: 'f32', 7: 'bool', 8: 'string', 9: 'array', 10: 'u64', 11: 'i64', 12: 'f64' };
const SIZES = { u8: 1, i8: 1, u16: 2, i16: 2, u32: 4, i32: 4, f32: 4, bool: 1, u64: 8, i64: 8, f64: 8 };
const LIMIT = 16 * 1024 * 1024;

function readMetadata(file, { wanted = null } = {}) {
  const fd = fs.openSync(file, 'r');
  try {
    let buffer = Buffer.alloc(64 * 1024), filled = fs.readSync(fd, buffer, 0, buffer.length, 0), at = 0;
    const need = bytes => {
      while (at + bytes > filled) {
        if (buffer.length >= LIMIT) throw new Error('GGUF metadata is larger than expected.');
        const bigger = Buffer.alloc(Math.min(LIMIT, buffer.length * 2));
        buffer.copy(bigger, 0, 0, filled); buffer = bigger;
        const more = fs.readSync(fd, buffer, filled, buffer.length - filled, filled);
        if (more <= 0) throw new Error('GGUF file ends inside its metadata.');
        filled += more;
      }
    };
    const scalar = type => {
      const size = SIZES[type]; need(size);
      const value = type === 'u8' ? buffer.readUInt8(at) : type === 'i8' ? buffer.readInt8(at) : type === 'u16' ? buffer.readUInt16LE(at) : type === 'i16' ? buffer.readInt16LE(at)
        : type === 'u32' ? buffer.readUInt32LE(at) : type === 'i32' ? buffer.readInt32LE(at) : type === 'f32' ? buffer.readFloatLE(at) : type === 'bool' ? buffer.readUInt8(at) !== 0
        : type === 'u64' ? Number(buffer.readBigUInt64LE(at)) : type === 'i64' ? Number(buffer.readBigInt64LE(at)) : buffer.readDoubleLE(at);
      at += size; return value;
    };
    const string = () => { const length = scalar('u64'); if (length > LIMIT) throw new Error('GGUF string is too long.'); need(length); const value = buffer.toString('utf8', at, at + length); at += length; return value; };
    const value = (type, keep) => {
      if (type === 'string') return string();
      if (type === 'array') {
        const inner = TYPES[scalar('u32')], count = scalar('u64');
        if (!inner || inner === 'array') throw new Error('Unsupported GGUF array.');
        // Token tables run to hundreds of thousands of entries; only skip through them unless wanted.
        const out = keep ? [] : null;
        for (let i = 0; i < count; i++) { const item = value(inner, false); if (keep && out.length < 64) out.push(item); }
        return out;
      }
      return scalar(type);
    };
    need(4);
    if (buffer.toString('ascii', 0, 4) !== 'GGUF') throw new Error('Not a GGUF file.');
    at = 4;
    const version = scalar('u32');
    if (![2, 3].includes(version)) throw new Error('Unsupported GGUF version.');
    scalar('u64'); // tensor count
    const pairs = scalar('u64');
    if (pairs > 100000) throw new Error('GGUF metadata is larger than expected.');
    const metadata = {};
    for (let i = 0; i < pairs; i++) {
      const key = string();
      const type = TYPES[scalar('u32')];
      if (!type) throw new Error('Unsupported GGUF value type.');
      const keep = !wanted || wanted(key);
      const read = value(type, keep);
      if (keep) metadata[key] = read;
    }
    return { version, metadata };
  } finally { fs.closeSync(fd); }
}

// The few facts Black Team uses to start a model well.
function describeModel(file) {
  const { metadata } = readMetadata(file, { wanted: key => /^general\.(name|architecture|basename|size_label|finetune|file_type)$|^[a-z0-9_]+\.(context_length|block_count|vocab_size|expert_count)$/.test(key) });
  const architecture = metadata['general.architecture'] || '';
  const number = key => Number.isSafeInteger(metadata[`${architecture}.${key}`]) ? metadata[`${architecture}.${key}`] : null;
  return {
    name: String(metadata['general.name'] || '').trim(),
    architecture,
    sizeLabel: String(metadata['general.size_label'] || '').trim(),
    trainingContext: number('context_length'),
    layers: number('block_count'),
    experts: number('expert_count'),
  };
}

module.exports = { readMetadata, describeModel };
