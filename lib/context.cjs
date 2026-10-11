'use strict';

const OUTPUT_BUDGETS = Object.freeze({ fast: 512, balanced: 1024, deep: 2048, extended: 4096 });
const SAFETY_MARGIN = 128;
const MAX_HISTORY_TURNS = 64;

function conversationParts(messages) {
  if (!Array.isArray(messages) || messages.length === 0 || messages.length > 10000) {
    throw new Error('Context review needs a conversation with a latest user message (maximum 10,000 messages).');
  }
  const clean = messages.map(message => {
    if (!message || !['system', 'user', 'assistant'].includes(message.role) || typeof message.content !== 'string') {
      throw new Error('Context review supports plain text system, user, and assistant messages.');
    }
    return { role: message.role, content: message.content };
  });
  let index = 0;
  const system = [];
  while (clean[index]?.role === 'system') system.push(clean[index++]);
  const turns = [];
  for (; index < clean.length; index++) {
    const message = clean[index];
    if (message.role === 'system') throw new Error('System instructions must precede the conversation for context review.');
    if (message.role === 'user') turns.push([message]);
    else {
      if (!turns.length) throw new Error('Conversation history has an assistant response without a user turn.');
      turns[turns.length - 1].push(message);
    }
  }
  if (!turns.length || clean[clean.length - 1].role !== 'user') {
    throw new Error('Context review requires the latest message to be the user request.');
  }
  const latest = turns.pop();
  if (turns.some(turn => turn.length < 2)) {
    throw new Error('Remove unfinished earlier turns before context review. The latest user request is kept intact.');
  }
  return { system, turns, latest, originalLength: clean.length };
}

function localRoot(endpoint) {
  let parsed;
  try { parsed = new URL(endpoint); } catch { throw new Error('Context review requires the local model endpoint.'); }
  if (parsed.protocol !== 'http:' || parsed.hostname !== '127.0.0.1' || !parsed.port ||
      !['/v1', '/v1/'].includes(parsed.pathname) || parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new Error('Context review only connects to the owned model on 127.0.0.1.');
  }
  return parsed.origin;
}

async function prepareContext({ messages, context, mode = 'balanced', endpoint, headers, fetch: fetchImpl = globalThis.fetch, signal }) {
  const root = localRoot(endpoint);
  if (!Number.isSafeInteger(context) || context < 256) throw new Error('Context size must be a whole number of at least 256 tokens.');
  if (!Object.hasOwn(OUTPUT_BUDGETS, mode)) throw new Error('Choose fast, balanced, deep, or extended response mode.');
  if (!headers || typeof headers.Authorization !== 'string' || !headers.Authorization.startsWith('Bearer ')) {
    throw new Error('Context review requires the private local model authentication.');
  }
  const { system, turns, latest, originalLength } = conversationParts(messages);
  const request = async (route, body) => {
    signal?.throwIfAborted();
    let response;
    try {
      response = await fetchImpl(`${root}${route}`, {
        method: body === undefined ? 'GET' : 'POST',
        headers: { Authorization: headers.Authorization, 'Content-Type': 'application/json' },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        redirect: 'error',
        signal: AbortSignal.any([...(signal ? [signal] : []), AbortSignal.timeout(20000)]),
      });
    } catch (error) {
      signal?.throwIfAborted();
      throw new Error(`Local context review could not reach ${route}. Check that the model is running.`, { cause: error });
    }
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error(`Local context review requires working llama.cpp ${route} support (HTTP ${response.status}). Choose a current llama.cpp release.`);
    }
    try { return await response.json(); } catch {
      signal?.throwIfAborted();
      throw new Error(`Local context review received an invalid response from ${route}. Choose a current llama.cpp release.`);
    }
  };

  const props = await request('/props');
  const actualContext = props?.default_generation_settings?.n_ctx;
  if (!Number.isSafeInteger(actualContext) || actualContext < 256) {
    throw new Error('The local runtime did not report a usable context size. Choose a current llama.cpp release.');
  }
  const effectiveContext = Math.min(context, actualContext);
  const maxTokens = Math.max(64, Math.min(OUTPUT_BUDGETS[mode], Math.floor(effectiveContext / 4)));
  const inputBudget = effectiveContext - maxTokens - SAFETY_MARGIN;
  // This bounded suffix keeps review inexpensive even when the saved transcript
  // is long. It never edits the caller's complete, locally stored conversation.
  const recent = turns.slice(-MAX_HISTORY_TURNS);
  const measurements = new Map();
  const measure = async omittedTurns => {
    if (measurements.has(omittedTurns)) return measurements.get(omittedTurns);
    const selected = [...system, ...recent.slice(omittedTurns).flat(), ...latest];
    const rendered = await request('/apply-template', { messages: selected });
    if (typeof rendered?.prompt !== 'string') {
      throw new Error('The local runtime did not return a chat template. No estimated token count was substituted.');
    }
    const tokenized = await request('/tokenize', { content: rendered.prompt, add_special: true, parse_special: true });
    if (!Array.isArray(tokenized?.tokens) || !tokenized.tokens.every(token => Number.isSafeInteger(token) && token >= 0)) {
      throw new Error('The local runtime did not return valid token IDs. No estimated token count was substituted.');
    }
    const measured = { messages: selected, tokens: tokenized.tokens.length };
    measurements.set(omittedTurns, measured);
    return measured;
  };

  let result = await measure(0);
  if (result.tokens > inputBudget) {
    // First establish that the instructions and newest request fit without
    // changing either one. Older turns are the only content eligible for removal.
    let low = 0;
    let high = recent.length;
    result = await measure(high);
    if (result.tokens > inputBudget) {
      throw new Error(`Your latest request and system instructions use ${result.tokens} tokens, exceeding the ${inputBudget}-token input budget. Shorten the request or increase the model context in Settings.`);
    }
    while (high - low > 1) {
      const middle = Math.floor((low + high) / 2);
      const candidate = await measure(middle);
      if (candidate.tokens <= inputBudget) { high = middle; result = candidate; }
      else low = middle;
    }
  }
  return {
    messages: result.messages,
    maxTokens,
    report: {
      measuredInputTokens: result.tokens,
      context: effectiveContext,
      maxTokens,
      omittedMessages: originalLength - result.messages.length,
      method: 'local-tokenizer',
      inputBudget,
      safetyMargin: SAFETY_MARGIN,
      decision: originalLength === result.messages.length ? 'keep' : 'select_recent',
    },
  };
}

// Generic compatible servers do not share llama.cpp's tokenizer API. Keep this
// estimate explicit in the UI; never label it as a measured model token count.
function prepareServerContext({messages, context, mode = 'balanced', endpoint}) {
  require('./local-server.cjs').localEndpoint(endpoint);
  if (!Number.isSafeInteger(context) || context < 512 || context > 131072) throw new Error('Choose a context size from 512 to 131072.');
  if (!Object.hasOwn(OUTPUT_BUDGETS, mode)) throw new Error('Choose a supported response mode.');
  const {system, turns, latest, originalLength} = conversationParts(messages);
  const maxTokens = Math.max(64, Math.min(OUTPUT_BUDGETS[mode], Math.floor(context / 4)));
  const inputBudget = context - maxTokens - SAFETY_MARGIN;
  const recent = turns.slice(-MAX_HISTORY_TURNS);
  const estimate = selected => 128 + selected.reduce((total, message) => total + Buffer.byteLength(message.content, 'utf8') + 32, 0);
  let selected = [...system, ...recent.flat(), ...latest];
  while (estimate(selected) > inputBudget && recent.length) {
    recent.shift();
    selected = [...system, ...recent.flat(), ...latest];
  }
  const tokens = estimate(selected);
  if (tokens > inputBudget) throw new Error('Your latest request and system instructions exceed the estimated input budget. Shorten the request or increase context in both Black Team and your model server.');
  return {messages: selected, maxTokens, report: {
    measuredInputTokens: tokens, context, maxTokens, omittedMessages: originalLength - selected.length,
    method: 'estimated-bytes', inputBudget, safetyMargin: SAFETY_MARGIN,
    decision: originalLength === selected.length ? 'keep' : 'select_recent',
  }};
}
module.exports = { prepareContext, prepareServerContext };
