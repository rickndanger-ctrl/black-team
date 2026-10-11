'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {thinkingOptions} = require('../lib/thinking.cjs');

test('the thinking level follows the chosen mode, off for fast', () => {
  assert.deepEqual(thinkingOptions('fast'), {reasoning_effort: 'none', chat_template_kwargs: {enable_thinking: false, preserve_thinking: true}});
  assert.deepEqual(thinkingOptions('balanced'), {reasoning_effort: 'medium', thinking_budget_tokens: 512, chat_template_kwargs: {enable_thinking: true, preserve_thinking: true}});
  assert.equal(thinkingOptions('deep').reasoning_effort, 'high');
  assert.equal(thinkingOptions('extended').thinking_budget_tokens, 2048);
  assert.equal(thinkingOptions('nonsense').reasoning_effort, 'none', 'an unknown mode thinks no more than fast');
});
