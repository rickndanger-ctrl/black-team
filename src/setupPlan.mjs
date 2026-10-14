// What the "Set up your agents" card shows and decides, apart from drawing it. The engine (Desktop/DesktopSetup.swift) makes the
// plan and runs the steps; these helpers only read its answers.

const STATE_LABEL = {'done': 'Done', 'will-do': 'Will do', 'needs-something': 'Needs something'};
export const stateLabel = state => STATE_LABEL[state] || '';

/** The ids the person can approve: steps marked "will-do" (a note is never run). */
export const approvableIds = plan => (plan?.steps || []).filter(step => step.state === 'will-do' && step.kind !== 'note').map(step => step.id);

/** What is ticked for the person at first: every approvable step except the ones they have to choose for themselves (`optIn`). */
export const defaultPickedIds = plan => (plan?.steps || []).filter(step => step.state === 'will-do' && step.kind !== 'note' && !step.optIn).map(step => step.id);

/** What the card shows: progress while it runs, the result when it has finished, the plan when it is offered (or the person asked). */
export function cardView({offer, run, hidden = false, asked = false}) {
  if (run?.running) return 'progress';
  if (run?.done || run?.error) return hidden ? null : 'result';
  if (!offer) return null;
  if (asked) return 'plan';
  return offer.show && !hidden ? 'plan' : null;
}

/** The headline after a run: names Hermes only when Hermes is now connected. */
export function readyMessage(run) {
  const results = run?.results || [];
  const worked = id => results.some(result => result.id === id && result.status === 'done');
  const failed = results.filter(result => result.status === 'failed');
  const hermes = worked('hermes-connect') || worked('hermes-tools');
  const anything = results.some(result => result.status === 'done' && result.id !== 'background-service' && !/^Already done/.test(result.message));
  const background = worked('background-service') && !results.some(result => result.id === 'background-service' && /^Already done/.test(result.message));
  if (failed.length && !anything && !background) return {title: 'Setup did not finish', ready: false};
  if (hermes) return {title: 'Ready: Hermes is connected. Choose it for a Code conversation to use its tools', ready: true};
  if (anything) return {title: 'Ready: your agents are connected', ready: true};
  if (background) return {title: 'Ready: Black Team will keep running in the background from your next login', ready: true};
  return {title: 'Everything was already set up', ready: true};
}

/** A key that changes with each finished run, so a closed result stays closed. */
export const resultKey = run => JSON.stringify((run?.results || []).map(result => [result.id, result.status]));
