'use strict';
// The thinking level, chosen with the reply length: one choice that trades time for care.
// Local servers that know these fields (llama.cpp with a thinking-capable model) honour them;
// others ignore unknown fields, so the request still works everywhere.
const EFFORT = {balanced: 'medium', deep: 'high', extended: 'xhigh'};
const BUDGET = {balanced: 512, deep: 1024, extended: 2048};

function thinkingOptions(mode = 'balanced') {
  const on = Object.hasOwn(EFFORT, mode);
  return {
    reasoning_effort: on ? EFFORT[mode] : 'none',
    ...(on ? {thinking_budget_tokens: BUDGET[mode]} : {}),
    chat_template_kwargs: {enable_thinking: on, preserve_thinking: true},
  };
}
module.exports = {thinkingOptions};
