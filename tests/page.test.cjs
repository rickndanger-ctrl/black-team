'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..');

test('the page has no inline script, so its Content Security Policy (script-src self) blocks nothing of its own', () => {
  const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
  const inline = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>/g)];
  assert.deepEqual(inline, []);
  assert.match(html, /<script src="\.\/theme\.js"><\/script>/);
  assert.ok(!/\son[a-z]+=/i.test(html), 'no inline event handlers');
});

test('the theme bootstrap applies a saved theme before paint and falls back to covert', () => {
  const source = fs.readFileSync(path.join(root, 'public/theme.js'), 'utf8');
  const run = storage => {
    const documentElement = { dataset: {} };
    vm.runInNewContext(source, { localStorage: storage, document: { documentElement } });
    return documentElement.dataset.theme;
  };
  assert.equal(run({ getItem: () => 'ghost' }), 'ghost');
  assert.equal(run({ getItem: () => 'light' }), 'light');
  assert.equal(run({ getItem: () => null }), 'covert');
  assert.equal(run({ getItem: () => 'neon' }), 'covert');
  assert.equal(run({ getItem: () => { throw new Error('storage blocked'); } }), 'covert');
});
