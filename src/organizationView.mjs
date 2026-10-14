// What the Organization and Tickets screens decide apart from drawing them. The engine (Org/) works out every fact; these helpers only turn
// its answers into plain words and the page's controls into what it reads.

export const STAGES = ['intake', 'spec', 'design', 'plan', 'build', 'review', 'qa', 'ship'];
export const STAGE_TITLE = {intake: 'Intake', spec: 'Spec', design: 'Design', plan: 'Plan', build: 'Build', review: 'Review', qa: 'QA', ship: 'Ship'};

/** The stages that wait for the owner after toggling one, in pipeline order. */
export function gateChoices(gates, stage) {
  const next = new Set(gates);
  if (next.has(stage)) next.delete(stage); else next.add(stage);
  return STAGES.filter(item => next.has(item));
}

export function splitLines(text) {
  return String(text || '').split('\n').map(line => line.trim()).filter(Boolean);
}

export function moneyText(value) {
  return Number(value || 0).toFixed(2);
}

/** "Ornith · this computer", "Claude Code · paid, anthropic.com", or what is missing. */
export function agentChoice(view, choices = []) {
  const role = view.role;
  if (view.kind === 'none') return 'No model or agent yet';
  const name = role.agent ? (choices.find(item => item.kind === 'agent' && item.key === role.agent)?.name || role.agent) : (choices.find(item => item.kind === 'model' && item.key === role.modelKey)?.name || 'A saved model');
  return view.kind === 'cloud' ? `${name} · paid, ${view.provider}` : `${name} · this computer`;
}

export function roleStatusText(view) {
  if (view.status === 'working') return `Working on ${view.ticket || 'a ticket'}`;
  if (view.status === 'waiting') return `Waiting for you on ${view.ticket || 'a ticket'}`;
  if (view.status === 'paused') return 'Paused';
  if (view.status === 'idle') return 'Idle';
  return 'Not set up';
}

export function ceilingText(budget = {}) {
  const parts = [];
  if (budget.paidTokensPerDay != null) parts.push(`${Number(budget.paidTokensPerDay).toLocaleString('en-US')} paid tokens`);
  if (budget.moneyPerDay != null) parts.push(`${moneyText(budget.moneyPerDay)} money`);
  return parts.length ? `${parts.join(' and ')} a day` : 'none set';
}

// MARK: Tickets

export const TICKET_STATE = {ready: 'Waiting its turn', running: 'Being worked on', gate: 'Waiting for you', blocked: 'Stuck', done: 'Done', cancelled: 'Cancelled'};

/** The board: one column per stage for open tickets, and a last column for finished ones. */
export function boardColumns(tickets) {
  const open = tickets.filter(ticket => !['done', 'cancelled'].includes(ticket.state));
  const columns = STAGES.map(stage => ({id: stage, title: STAGE_TITLE[stage], tickets: open.filter(ticket => ticket.stage === stage).sort((a, b) => a.number - b.number)}));
  columns.push({id: 'finished', title: 'Finished', tickets: tickets.filter(ticket => ['done', 'cancelled'].includes(ticket.state)).sort((a, b) => b.number - a.number).slice(0, 30)});
  return columns;
}

export function needsOwner(ticket) {
  return ticket.state === 'gate' || ticket.state === 'blocked';
}

/** What to say a ticket is waiting for. */
export function waitingText(ticket) {
  if (ticket.state === 'blocked') return `Stuck: ${ticket.note || 'a run did not finish.'}`;
  if (ticket.state !== 'gate' || !ticket.gate) return '';
  if (ticket.gate.kind === 'question') return `It asks: ${ticket.gate.question}`;
  return ticket.gate.question;
}

/** The newest artifact of each name ("spec.md" and "spec-2.md" are one), newest last. */
export function latestArtifacts(artifacts = []) {
  const byBase = new Map();
  for (const item of artifacts) {
    const base = item.name.replace(/-\d+(\.[a-z]+)$/, '$1');
    byBase.set(base, item);
  }
  return [...byBase.values()];
}

export function artifactKind(name) {
  if (name.endsWith('.md')) return 'markdown';
  return 'code';
}

/** Words for how many times review or QA sent a ticket back. */
export function sendBackText(sendBacks = {}) {
  const parts = Object.entries(sendBacks).filter(([, n]) => n > 0).map(([stage, n]) => `${STAGE_TITLE[stage] || stage} ${n} ${n === 1 ? 'time' : 'times'}`);
  return parts.length ? `Sent back by ${parts.join(', ')}` : '';
}
