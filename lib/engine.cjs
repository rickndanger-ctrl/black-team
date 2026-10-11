'use strict';
// Black Team Code engine: an agent loop written for local models.
//
// Three ideas shape it:
//  1. Reading is the slow part on local hardware, so the engine measures the model's real
//     speed and sizes its working budget and tool-output caps from that. A faster model
//     gets more room.
//  2. Local servers cache the prompt prefix, so history is only ever appended to. Nothing
//     in the middle is rewritten between trims.
//  3. Trimming needs no model call. A work log and the todo list are kept as the task
//     runs; when the budget is reached the oldest steps are replaced by that record.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {createTools, renderTodo, undoChange} = require('./tools.cjs');
const {MEMORY_TOOLS} = require('./memory.cjs');
const {privateDirectory, writeJSON} = require('./history.cjs');
const {ensureWorkspace} = require('./config.cjs');

const MAX_STEPS = 48, RUN_SECONDS = 1800, APPROVAL_SECONDS = 300;
const MIN_CONTEXT = 8192;
const OUTPUT_TOKENS = {fast: 2048, balanced: 4096, deep: 6144, extended: 8192};
const CHARS_PER_TOKEN = 3.5;

const SYSTEM = workspace => `You are Black Team Code, a coding agent running on the user's own computer. Your workspace is ${workspace}.

Work with the tools. Never state a result you have not seen in a tool result.
Give file paths relative to the workspace, such as notes.txt or src/app.js.
Reading is slow on this machine: search before you read, and read only the lines you need.
Keep your todo list current. As a task grows, older tool output is trimmed from your memory; your todo list and a log of what you did are what remain, and you can read any file again.
After a change, run its check and read the result. When the task is done, reply with a short summary of what changed and what you verified.`;

// Budgets derived from how fast this model reads. Twelve minutes is the longest cold
// re-read worth risking; one minute is the most a single tool result should cost.
// The working budget never passes 60% of the model's window, whatever the speed.
function budgets(readSpeed, contextWindow) {
  const working = Math.round(Math.min(contextWindow * 0.6, Math.max(12000, readSpeed * 720)));
  // A single tool result is also kept to under a third of the working budget.
  const resultChars = Math.round(Math.min(Math.max(6000, Math.min(readSpeed * 60 * CHARS_PER_TOKEN, 48000)), working * CHARS_PER_TOKEN * 0.3));
  return {working, resultChars};
}

const estimate = messages => Math.ceil(messages.reduce((sum, message) => sum + 12 + (message.content?.length || 0) + (message.tool_calls ? JSON.stringify(message.tool_calls).length : 0), 0) / CHARS_PER_TOKEN);

// Replace the oldest steps with the record kept so far. Cuts only at a step boundary, so
// a tool call is never separated from its result.
function trim(memory, budget) {
  const messages = memory.messages;
  const keepTokens = Math.floor(budget * 0.25);
  // A step starts at a user or assistant message; its tool results follow it.
  let cut = -1, kept = 0;
  for (let index = messages.length - 1; index >= 1; index--) {
    kept += estimate([messages[index]]);
    if (messages[index].role === 'tool') continue;
    if (kept > keepTokens && cut !== -1) break;
    cut = index; // The newest step is always kept, even when it alone is over the allowance.
  }
  if (cut < 1) return false;
  const dropped = messages.slice(0, cut);
  // The record itself is sized to the budget, so a small context window is not refilled by its own summary.
  const lines = Math.max(10, Math.min(80, Math.floor(budget / 150))), each = Math.max(300, Math.min(2000, Math.floor(budget / 8)));
  const earlier = memory.requests.length > 8 ? [`- (${memory.requests.length - 8} earlier requests not listed)`] : [];
  const requests = [...earlier, ...memory.requests.slice(-8).map(text => `- ${text.length > each ? text.slice(0, each) + '…' : text}`)].join('\n');
  const notes = dropped.filter(message => message.role === 'assistant' && message.content?.trim()).slice(-3).map(message => `- ${message.content.trim().slice(0, 400)}`).join('\n');
  const log = memory.log.length > lines ? [`(${memory.log.length - lines} earlier steps not listed)`, ...memory.log.slice(-lines)] : memory.log;
  const record = `[Earlier steps were trimmed to keep you fast. This record is what you keep. Files can be read again.]

The user's requests in this conversation:
${requests || '- (none recorded)'}

Your todo list:
${renderTodo(memory.todo)}

What you have done so far, oldest first:
${log.join('\n') || '(nothing yet)'}${notes ? `\n\nYour recent notes:\n${notes}` : ''}`;
  const rest = messages.slice(cut);
  memory.messages = rest[0]?.role === 'user' ? [{role: 'user', content: `${record}\n\n[Latest request]\n${rest[0].content}`}, ...rest.slice(1)] : [{role: 'user', content: record}, ...rest];
  memory.trims = (memory.trims || 0) + 1;
  return true;
}

// One streamed completion. Returns the text, any tool calls, and the two measured speeds.
async function complete({endpoint, headers = {}, body, signal, idleMs, fetch: fetcher, onText, now = Date.now}) {
  const sent = now();
  // A local model can be silent for minutes while it reads; it is only stuck when the gap passes the allowance.
  const idle = new AbortController();
  let timer;
  const alive = () => {clearTimeout(timer); timer = setTimeout(() => idle.abort(new Error('The model stopped sending data. What it wrote so far is saved.')), idleMs);};
  alive();
  try {
    const response = await fetcher(`${endpoint}/chat/completions`, {method: 'POST', headers: {'Content-Type': 'application/json', ...headers}, redirect: 'error', signal: AbortSignal.any([signal, idle.signal]), body: JSON.stringify(body)});
    if (!response.ok) {
      let detail = '';
      try {detail = (await response.json()).error?.message || '';} catch {}
      throw Object.assign(new Error(`The model returned HTTP ${response.status}. ${String(detail).slice(0, 200)}`.trim()), {status: response.status, overflow: /exceed|context length|too long/i.test(detail)});
    }
    if (!response.body) throw new Error('The local model returned no response.');
    const decoder = new TextDecoder();
    const calls = [];
    let pending = '', text = '', finish = null, usage = null, timings = null, first = 0;
    const line = row => {
      if (!row.startsWith('data:') || row === 'data: [DONE]') return;
      let data; try {data = JSON.parse(row.slice(5));} catch {return;}
      if (data.error) throw new Error(data.error.message || 'The model stream failed.');
      if (data.usage) usage = data.usage;
      if (data.timings) timings = data.timings;
      const choice = data.choices?.[0];
      if (!choice) return;
      if (!first && (choice.delta?.content || choice.delta?.tool_calls)) first = now();
      if (typeof choice.delta?.content === 'string' && choice.delta.content) {text += choice.delta.content; if (text.length > 256 * 1024) throw new Error('The reply reached the storage limit.'); onText(text);}
      for (const part of choice.delta?.tool_calls || []) {
        const slot = calls[part.index ?? 0] ||= {id: '', name: '', arguments: ''};
        if (part.id) slot.id = part.id;
        if (part.function?.name) slot.name += part.function.name;
        if (part.function?.arguments) slot.arguments += part.function.arguments;
        if (slot.arguments.length > 1024 * 1024) throw new Error('A tool call was too large.');
      }
      if (choice.finish_reason) finish = choice.finish_reason;
    };
    for await (const chunk of response.body) {
      if (signal.aborted) throw signal.reason;
      if (idle.signal.aborted) throw idle.signal.reason;
      alive();
      pending += decoder.decode(chunk, {stream: true});
      if (pending.length > 2 * 1024 * 1024) throw new Error('The local model returned an oversized stream frame.');
      let newline;
      while ((newline = pending.indexOf('\n')) >= 0) {line(pending.slice(0, newline).trim()); pending = pending.slice(newline + 1);}
    }
    if (pending.trim()) line(pending.trim());
    if (!finish) throw new Error('The model stream ended before it finished. Send a message to continue.');
    // llama.cpp reports its own timings. Other local servers do not, and the clock gives the same
    // two speeds: time to the first token is the read, the rest is the write.
    if (!timings && usage?.prompt_tokens && first) {
      const read = Math.max(0.05, (first - sent) / 1000), write = Math.max(0.05, (now() - first) / 1000);
      timings = {prompt_n: usage.prompt_tokens, prompt_per_second: usage.prompt_tokens / read, predicted_n: usage.completion_tokens || 0, predicted_per_second: (usage.completion_tokens || 0) / write};
    }
    return {text, calls: calls.filter(Boolean), finish, usage, timings};
  } catch (error) {
    if (idle.signal.aborted && !signal.aborted) throw idle.signal.reason;
    throw error;
  } finally {clearTimeout(timer);}
}

// graph: returns the graphify executable when one is installed, so Code can ask a map of the workspace.
function createEngine({stateDir, vault = null, fetch: fetcher = globalThis.fetch, now = Date.now, graph = () => ''}) {
  const dir = path.join(stateDir, 'engine'), undoDir = path.join(dir, 'undo'), artifacts = path.join(stateDir, 'artifacts');
  privateDirectory(dir); privateDirectory(undoDir); privateDirectory(artifacts);
  const memoryFile = threadId => path.join(dir, `${threadId}.json`);
  // Each model's measured speed is remembered, so a new conversation starts calibrated.
  const profileFile = path.join(dir, 'models.json');
  const profiles = () => {try {return JSON.parse(fs.readFileSync(profileFile, 'utf8'));} catch {return {};}};
  function loadMemory(threadId, model) {
    try {return JSON.parse(fs.readFileSync(memoryFile(threadId), 'utf8'));}
    catch {
      const known = profiles()[model] || {};
      return {messages: [], requests: [], log: [], todo: [], readSpeed: known.readSpeed > 0 ? known.readSpeed : 40, writeSpeed: known.writeSpeed > 0 ? known.writeSpeed : 12, promptTokens: 0, trims: 0};
    }
  }
  const saveMemory = (threadId, memory) => writeJSON(memoryFile(threadId), memory);
  function saveProfile(model, memory) {
    writeJSON(profileFile, {...profiles(), [model]: {readSpeed: Math.round(memory.readSpeed * 10) / 10, writeSpeed: Math.round(memory.writeSpeed * 10) / 10, measured: new Date(now()).toISOString()}});
  }

  async function run({thread, assistant, config, runtime, endpoint, job, signal, save, mode = 'balanced', workspace = config.workspace}) {
    const contextWindow = config.model.context;
    if (contextWindow < MIN_CONTEXT) throw new Error(`Code needs a context window of at least ${MIN_CONTEXT.toLocaleString()} tokens. Raise it in Settings, and in your model server if you use one.`);
    ensureWorkspace(workspace);
    const model = config.model.source === 'server' ? config.model.id : 'black-team-local';
    const identity = `${config.model.source || 'gguf'}:${config.model.source === 'server' ? config.model.id : path.basename(config.model.file)}`;
    const headers = runtime.requestHeaders();
    const key = headers.Authorization?.slice(7) || '';
    const redact = value => (key ? String(value).replaceAll(key, '[redacted]') : String(value));
    assistant.events = []; assistant.artifacts = [];
    const started = now();
    const event = item => {assistant.events.push(item); if (assistant.events.length > 200) assistant.events.splice(0, assistant.events.length - 200);};
    const note = (name, output) => event({type: 'status', name, output});
    let lastSave = 0;
    const persist = force => {if (force || now() - lastSave > 700) {save(); lastSave = now();}};

    // Approval card: resolves when the user answers in the app, or denies itself after five minutes.
    let cancelApproval = null;
    const ask = ({command, description}) => new Promise(resolve => {
      const id = crypto.randomUUID(), digest = crypto.createHash('sha256').update(command).digest('hex');
      const finish = choice => {clearTimeout(timer); cancelApproval = null; delete job.approval; delete job._approve; resolve(choice);};
      const timer = setTimeout(() => finish('deny'), APPROVAL_SECONDS * 1000);
      cancelApproval = () => finish('deny');
      job.approval = {id, digest, command: redact(command).slice(0, 8000), description, expires: now() + APPROVAL_SECONDS * 1000};
      job._approve = (answerId, answerDigest, choice) => {
        if (answerId !== id || answerDigest !== digest || !['once', 'deny'].includes(choice)) throw new Error('No matching active approval.');
        job.progress = choice === 'once' ? 'Approved. Continuing…' : 'Declined. Continuing…';
        finish(choice);
      };
      job.progress = 'Waiting for your approval'; persist(true);
    });
    const stop = () => cancelApproval?.();
    signal.addEventListener('abort', stop, {once: true});

    const memory = loadMemory(thread.id, identity);
    let limits = budgets(memory.readSpeed, contextWindow);
    const mapper = typeof graph === 'function' ? graph() : '';
    const tools = createTools({workspace, artifacts, undoDir, deny: [stateDir], limit: () => limits.resultChars, ask, signal, graph: mapper, graphDir: mapper ? path.join(stateDir, 'graphs') : ''});
    tools.state.todo = memory.todo;
    const remembers = Boolean(vault);
    const schemas = remembers ? [...tools.schemas, ...MEMORY_TOOLS] : tools.schemas;
    // Core memory is read once per conversation and then left alone, so the cached prompt stays valid.
    if (remembers && memory.core === undefined) memory.core = vault.core();
    const system = SYSTEM(workspace) + (mapper ? '\nThe map tool knows this code: ask it which files and functions matter before reading many files. It answers with paths and line numbers.' : '') + (remembers ? `\nYou have a memory that lasts across conversations. Use recall when a task refers to earlier work or to the user's preferences, and remember to save a lasting fact once you have verified it.${memory.core ? `\n\nWhat you already know about the user:\n${memory.core}` : ''}` : '');
    const dispatch = async (name, args) => {
      if (!remembers || !['remember', 'recall'].includes(name)) return tools.call(name, args);
      try {
        if (name === 'recall') return {output: await vault.recall(args.query, args.note, workspace), log: `recall ${JSON.stringify(String(args.note || args.query).slice(0, 60))}`};
        const id = vault.remember(args.title, args.text, args.project === true ? workspace : undefined);
        return {output: `Saved to memory as [[${id}]].`, log: `remember ${id}`};
      } catch (error) {return {output: `Error: ${error.message}`, error: true, log: null};}
    };
    const logStart = memory.log.length;
    const request = thread.messages.at(-2).content;
    memory.requests.push(request); memory.messages.push({role: 'user', content: request});
    note('Black Team engine', `Ready · reads about ${Math.round(memory.readSpeed)} tokens/s · working budget ${limits.working.toLocaleString()} of ${contextWindow.toLocaleString()} tokens`);
    job.progress = 'Reading the task…';

    // Shown live beside the mode switch: measured speeds, and how full the working budget is.
    const gauge = used => {job.meter = {read: Math.round(memory.readSpeed), write: Math.round(memory.writeSpeed), used, budget: limits.working, window: contextWindow, trims: memory.trims || 0};};
    gauge(memory.promptTokens || 0);
    const maxTokens = Math.min(OUTPUT_TOKENS[mode] || 4096, Math.floor(contextWindow / 4));
    let finalText = '', unfinished = '', stuck = '';
    const repeats = new Map();
    try {
      for (let step = 1; ; step++) {
        signal.throwIfAborted();
        if (step > MAX_STEPS) {unfinished = `I stopped at the limit of ${MAX_STEPS} steps for one turn, and the task is not finished. Send "continue" and I will pick up from my todo list.`; break;}
        if ((now() - started) / 1000 > RUN_SECONDS) {unfinished = 'I stopped at the time limit for one turn, and the task is not finished. Send "continue" and I will pick up from my todo list.'; break;}
        const size = Math.max(memory.promptTokens ? memory.promptTokens + estimate(memory.messages.slice(memory.counted || 0)) : 0, estimate(memory.messages) + 900);
        if (size > limits.working) {
          memory.todo = tools.state.todo;
          if (trim(memory, limits.working)) {
            memory.promptTokens = 0; memory.counted = 0;
            job.progress = 'Trimming earlier steps…';
            note('Context', `Trimmed earlier steps: about ${size.toLocaleString()} → ${(estimate(memory.messages) + 900).toLocaleString()} tokens. Work log and todo kept. No model call needed.`);
          }
        }
        const expected = estimate(memory.messages) + 900;
        // Allow for a cold read of everything at half the measured speed, plus slack.
        const idleMs = Math.round(Math.max(180, Math.min(180 + expected / Math.max(5, memory.readSpeed / 2), 2700)) * 1000);
        let result;
        try {
          result = await complete({
            endpoint, headers, signal, idleMs, fetch: fetcher, now,
            onText: text => {assistant.content = redact(text); job.progress = 'Writing a reply…'; persist();},
            body: {model, messages: [{role: 'system', content: system}, ...memory.messages], tools: schemas, stream: true, stream_options: {include_usage: true}, max_tokens: maxTokens, temperature: 0.7},
          });
        } catch (error) {
          // The server's count is exact and ours is an estimate; if it says too long, trim harder once.
          if (error.overflow && trim(memory, Math.floor(limits.working / 2))) {memory.promptTokens = 0; memory.counted = 0; note('Context', 'The model reported its window was full. Trimmed further and retried.'); continue;}
          throw error;
        }
        if (result.timings?.prompt_n >= 300 && result.timings.prompt_per_second > 0) memory.readSpeed = memory.readSpeed * 0.5 + result.timings.prompt_per_second * 0.5;
        if (result.timings?.predicted_n >= 20 && result.timings.predicted_per_second > 0) memory.writeSpeed = memory.writeSpeed * 0.5 + result.timings.predicted_per_second * 0.5;
        limits = budgets(memory.readSpeed, contextWindow);
        gauge(result.usage?.prompt_tokens ? result.usage.prompt_tokens + (result.usage.completion_tokens || 0) : expected);
        const message = {role: 'assistant', content: result.text || ''};
        if (result.calls.length) message.tool_calls = result.calls.map(item => ({id: item.id || crypto.randomBytes(8).toString('hex'), type: 'function', function: {name: item.name, arguments: item.arguments || '{}'}}));
        memory.messages.push(message);
        if (result.usage?.prompt_tokens) {memory.promptTokens = result.usage.prompt_tokens + (result.usage.completion_tokens || 0); memory.counted = memory.messages.length;}
        if (result.text.trim()) finalText = result.text.trim();
        if (!result.calls.length) {
          if (result.finish === 'length') finalText += '\n\n(The reply reached its length limit. Send "continue" for the rest.)';
          break;
        }
        for (const item of message.tool_calls) {
          let args; try {args = JSON.parse(item.function.arguments || '{}');} catch {args = null;}
          const name = String(item.function.name).slice(0, 60);
          event({type: 'tool_use', name, output: redact(args === null ? item.function.arguments : JSON.stringify(args)).slice(0, 4000)});
          job.progress = `Using ${name}…`; persist(true);
          const outcome = args === null ? {output: 'Error: the arguments were not valid JSON. Call the tool again with valid JSON.', error: true, log: null} : await dispatch(name, args);
          signal.throwIfAborted();
          // A model that repeats a call and gets the same answer is stuck. Say so, then stop the turn.
          const repeat = `${name} ${item.function.arguments} ${outcome.output}`;
          const seen = (repeats.get(repeat) || 0) + 1; repeats.set(repeat, seen);
          if (seen === 3) outcome.output += '\n\n[You have made this exact call three times with the same result. Repeating it will not help. Try a different approach, or tell the user what is blocking you.]';
          if (seen >= 5) stuck = `I stopped because I was repeating the same ${name} call without progress. The last result was: ${outcome.output.split('\n')[0].slice(0, 200)}`;
          if (outcome.artifact && assistant.artifacts.length < 100) assistant.artifacts.push(outcome.artifact);
          if (outcome.log) memory.log.push(outcome.log);
          memory.todo = tools.state.todo;
          memory.messages.push({role: 'tool', tool_call_id: item.id, content: outcome.output});
          event({type: 'tool_result', name, output: redact(outcome.output).slice(0, 4000), error: Boolean(outcome.error), ...(outcome.change ? {change: {...outcome.change, diff: redact(outcome.change.diff)}} : {})});
          job.progress = `Finished ${name}`;
        }
        saveMemory(thread.id, memory); persist(true);
        if (stuck) {unfinished = stuck; break;}
      }
      // A turn that stopped early says so plainly; it never borrows an earlier sentence as its answer.
      assistant.content = redact(unfinished || finalText || 'Done.').slice(0, 256 * 1024);
      if (unfinished) assistant.note = 'This turn stopped before the task was finished.';
      assistant.meter = job.meter;
      if (remembers) try {vault.journal(workspace, {request, log: memory.log.slice(logStart), outcome: assistant.content});} catch { /* A journal entry is a convenience; the turn itself succeeded. */ }
      saveMemory(thread.id, memory); saveProfile(identity, memory);
    } catch (error) {
      try {saveMemory(thread.id, memory);} catch { /* The original failure is the one to report. */ }
      throw signal.aborted ? error : new Error(redact(error.message || 'The agent ended unexpectedly.'));
    } finally {
      signal.removeEventListener('abort', stop);
      delete job.approval; delete job._approve;
    }
  }
  return {run, undo: id => undoChange(undoDir, id), undoDir};
}

module.exports = {createEngine, trim, budgets, estimate, complete, SYSTEM, MIN_CONTEXT};
