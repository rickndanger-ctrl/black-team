// What a Code run shows beside the conversation: its phase in plain words, the line under it, and which buttons make sense.
// The numbers come from the run record the engine saves with each reply (Engine/RunControl.swift); nothing is computed here but words.

export const PHASE_WORDS = {
  planning: 'Planning', working: 'Working', checking: 'Checking the work', waiting: 'Waiting for your approval',
  paused: 'Paused', done: 'Done', stopped: 'Stopped', failed: 'Failed',
};
const UNFINISHED = ['planning', 'working', 'checking', 'waiting', 'paused'];

export const money = value => value >= 1 ? `$${value.toFixed(2)}` : value >= 0.01 ? `$${value.toFixed(3)}` : `$${value.toFixed(4)}`;

// The run record of the newest reply that has one.
export const runOf = thread => thread?.messages?.findLast?.(item => item.run)?.run || null;

// The job's phase while it runs here; the saved one otherwise.
export function shownPhase({job, threadId, run}) {
  const live = job?.state === 'running' && job.threadId === threadId && job.phase;
  return live ? job.phase : (run?.phase || '');
}

export function runLine({phase, run, pausing}) {
  if (!phase) return '';
  let text = pausing && phase !== 'paused' ? 'Pausing after this step' : (PHASE_WORDS[phase] || phase);
  if (run?.steps && UNFINISHED.includes(phase)) text += ` · step ${run.steps}`;
  if (run?.tool && run.toolStatus === 'running' && phase === 'working') text += ` · using ${run.tool}`;
  if (run?.tokens) text += ` · ${run.tokens.toLocaleString('en-US')} tokens${run.estimated ? ' (counted by Black Team)' : ''}`;
  if (typeof run?.cost === 'number') text += ` · ${money(run.cost)} spent`;
  return text;
}

// A run that was cut off (Black Team closed) or stopped can be carried on from its saved state.
export function canContinue({phase, running, run}) {
  if (running || !phase) return false;
  if (UNFINISHED.includes(phase)) return true;
  return (phase === 'stopped' || phase === 'failed') && Boolean(run?.steps);
}

export const continueLabel = ({phase}) => UNFINISHED.includes(phase) ? 'Continue where it stopped' : 'Continue';

// Where it stopped, shown with the Continue button.
export function stoppedLine({phase, run}) {
  if (!run) return '';
  const where = run.steps ? `step ${run.steps}` : 'the start';
  const tool = run.tool && run.toolStatus === 'running' ? `, while using ${run.tool}` : '';
  const done = Array.isArray(run.todo) && run.todo.length ? ` ${run.todo.filter(item => item.done).length} of ${run.todo.length} to-do items were done.` : '';
  const how = UNFINISHED.includes(phase) ? 'It was cut off' : phase === 'failed' ? 'It failed' : 'It stopped';
  return `${how} at ${where}${tool}.${done}`;
}

// Validates and turns the settings form into what the service takes. Empty means "no limit".
export function limitsFrom({tokens, money: spend, inPrice, outPrice, cloud}) {
  const out = {};
  const whole = text => String(text ?? '').trim() === '' ? 0 : Number(String(text).replace(/,/g, ''));
  const tokenCount = whole(tokens);
  if (!Number.isInteger(tokenCount) || tokenCount < 0) return {error: 'The token limit must be a whole number, or 0 for no limit.'};
  out.tokenCeiling = tokenCount;
  if (cloud) {
    const amount = whole(spend);
    if (!Number.isFinite(amount) || amount < 0) return {error: 'The spending limit must be a number, or 0 for no limit.'};
    out.moneyCeiling = amount;
    if (String(inPrice ?? '').trim() !== '' || String(outPrice ?? '').trim() !== '') {
      const input = whole(inPrice), output = whole(outPrice);
      if (!Number.isFinite(input) || !Number.isFinite(output) || input < 0 || output < 0) return {error: 'Give both prices as numbers, per million tokens.'};
      out.price = {input, output};
    } else if (amount > 0) return {error: 'Enter both prices so the spending limit can work. Black Team has no price list.'};
  }
  return {value: out};
}
