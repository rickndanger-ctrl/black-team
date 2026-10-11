'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { prepareContext } = require('../lib/context.cjs');

const system = { role: 'system', content: 'Private instructions 🖤' };
const latest = { role: 'user', content: 'Latest request with exact whitespace.  \n' };

function harness(options = {}) {
  const calls = [];
  const fetch = async (url, args) => {
    const route = new URL(url).pathname;
    const body = args.body ? JSON.parse(args.body) : undefined;
    calls.push({ url, route, args, body });
    if (options.respond) {
      const response = await options.respond(route, body, args);
      if (response) return response;
    }
    if (route === '/props') return new Response(JSON.stringify({ default_generation_settings: { n_ctx: options.actualContext || 4096 } }));
    if (route === '/apply-template') return new Response(JSON.stringify({ prompt: JSON.stringify(body.messages) }));
    if (route === '/tokenize') {
      const messages = JSON.parse(body.content);
      const count = options.count ? options.count(messages) : 100 + messages.length * 100;
      return new Response(JSON.stringify({ tokens: Array(count).fill(10) }));
    }
    throw new Error('Unexpected route');
  };
  return {
    calls,
    params: { messages: [system, latest], context: 4096, mode: 'balanced', endpoint: 'http://127.0.0.1:45231/v1', headers: { Authorization: 'Bearer private-test-key' }, fetch },
  };
}

test('measures the real chat template locally and preserves exact request and system content', async () => {
  const { calls, params } = harness();
  const original = structuredClone(params.messages);
  const result = await prepareContext(params);
  assert.deepEqual(result.messages, original);
  assert.deepEqual(params.messages, original);
  assert.deepEqual(result.report, { measuredInputTokens: 300, context: 4096, maxTokens: 1024, omittedMessages: 0, method: 'local-tokenizer', inputBudget:2944, safetyMargin:128, decision:'keep' });
  assert.equal(result.maxTokens, 1024);
  assert.deepEqual(calls.map(call => call.route), ['/props', '/apply-template', '/tokenize']);
  assert.equal(calls[2].body.add_special, true);
  assert.equal(calls[2].body.parse_special, true);
  for (const call of calls) {
    assert.equal(call.args.headers.Authorization, 'Bearer private-test-key');
    assert.equal(call.args.redirect, 'error');
    assert.equal(new URL(call.url).hostname, '127.0.0.1');
  }
  assert.equal(JSON.stringify(result.report).includes('private-test-key'), false);
});

test('mode budgets and runtime context clamp reserve space for generation', async () => {
  for (const [mode, expected] of Object.entries({ fast: 512, balanced: 1024, deep: 2048, extended: 4096 })) {
    const { params } = harness({ actualContext: 32768 });
    const result = await prepareContext({ ...params, context: 32768, mode });
    assert.equal(result.maxTokens, expected);
  }
  const { params } = harness({ actualContext: 2048 });
  const result = await prepareContext({ ...params, context: 4096, mode: 'extended' });
  assert.equal(result.report.context, 2048);
  assert.equal(result.maxTokens, 512);
  const largerRuntime = harness({ actualContext: 32768 });
  assert.equal((await prepareContext({ ...largerRuntime.params, context: 1024 })).report.context, 1024);
});

test('drops oldest complete turns while retaining recent context and stored history', async () => {
  const { params } = harness({ actualContext: 1024, count: messages => messages.reduce((sum, message) => sum + (message.role === 'system' ? 20 : 150), 0) });
  const messages = [system];
  for (let i = 0; i < 6; i++) messages.push({ role: 'user', content: `Question ${i}` }, { role: 'assistant', content: `Answer ${i}` });
  messages.push(latest);
  const snapshot = structuredClone(messages);
  const result = await prepareContext({ ...params, messages });
  assert.deepEqual(result.messages, [system, { role: 'user', content: 'Question 5' }, { role: 'assistant', content: 'Answer 5' }, latest]);
  assert.equal(result.report.measuredInputTokens, 470);
  assert.equal(result.report.omittedMessages, 10);
  assert.deepEqual(messages, snapshot);
});

test('the newest request is never silently shortened when it alone exceeds the budget', async () => {
  const { params } = harness({ actualContext: 512, count: () => 600 });
  await assert.rejects(prepareContext(params), /latest request.*600 tokens.*256-token input budget/);
  assert.deepEqual(params.messages, [system, latest]);
});

test('long saved history uses at most eight template/tokenizer checks and omits complete turns', async () => {
  const { params, calls } = harness({ actualContext: 4096 });
  const messages = [system];
  for (let i = 0; i < 1000; i++) messages.push({ role: 'user', content: `Q${i}` }, { role: 'assistant', content: `A${i}` });
  messages.push(latest);
  const result = await prepareContext({ ...params, messages });
  assert.ok(calls.filter(call => call.route === '/apply-template').length <= 8);
  assert.ok(result.report.omittedMessages > 1800);
  assert.equal(result.report.omittedMessages % 2, 0);
  assert.deepEqual(result.messages.at(-1), latest);
  assert.ok(result.report.measuredInputTokens + result.maxTokens + 128 <= result.report.context);
  assert.equal(messages.length, 2002);
});

test('unsupported local endpoints fail visibly without substituting character estimates', async () => {
  for (const route of ['/props', '/apply-template', '/tokenize']) {
    const { params } = harness({ respond: current => current === route ? new Response('{}', { status: 404 }) : null });
    await assert.rejects(prepareContext(params), /requires working llama.cpp.*HTTP 404/);
  }
});

test('malformed context, template and token responses are rejected', async () => {
  for (const [route, body, expected] of [
    ['/props', {}, /did not report a usable context/],
    ['/apply-template', {}, /did not return a chat template/],
    ['/tokenize', { tokens: ['fake'] }, /did not return valid token IDs/],
    ['/tokenize', {}, /did not return valid token IDs/],
  ]) {
    const { params } = harness({ respond: current => current === route ? new Response(JSON.stringify(body)) : null });
    await assert.rejects(prepareContext(params), expected);
  }
});

test('external URLs, redirects and incomplete conversations are not accepted', async () => {
  const { params, calls } = harness();
  for (const endpoint of ['https://example.com/v1', 'http://localhost:1234/v1', 'http://127.0.0.1:1234/v1?remote=true', 'http://user:password@127.0.0.1:1234/v1']) {
    await assert.rejects(prepareContext({ ...params, endpoint }), /only connects to the owned model/);
  }
  for (const messages of [
    [{ role: 'assistant', content: 'orphan' }, latest],
    [latest, { role: 'assistant', content: 'completed' }],
    [latest, system],
    [{ role: 'user', content: 'unfinished' }, latest],
    [{ role: 'user', content: [{ text: 'unsupported' }] }],
  ]) await assert.rejects(prepareContext({ ...params, messages }));
  assert.equal(calls.length, 0);
});

test('aborted context review performs no further requests', async () => {
  const abort = new AbortController();
  const { params, calls } = harness();
  abort.abort();
  await assert.rejects(prepareContext({ ...params, signal: abort.signal }), { name: 'AbortError' });
  assert.equal(calls.length, 0);
});
