// What the Schedules and Inbox screens decide, apart from drawing them. The engine (Service/ServiceHooks.swift) works out every time; these
// helpers only turn the form's plain controls into the words it reads, and its answers into words for the page.

export const PERMISSIONS = [
  ['ask', 'Ask me first', 'It waits for your answer before it changes a file or runs a command.'],
  ['allow-in-project', 'Edit files in the project', 'It can change files inside the project folder without asking. It still asks before running a command.'],
  ['read-only', 'Read only', 'It can read and search the project. It cannot change anything or run commands, and it never asks.'],
];

export const EMPTY_FORM = {id: '', name: '', project: '', kind: 'agent', message: '', model: '', permission: 'ask', every: 'every', gap: '30', unit: 'minutes', time: '09:00', date: ''};

const two = value => String(value).padStart(2, '0');

/** The plain words the engine reads for the form's controls: "every 30 minutes", "daily at 09:00", "once at 2026-10-14 09:30". */
export function whenText(form) {
  const gap = Math.floor(Number(form.gap));
  if (form.every === 'every') return `every ${Number.isFinite(gap) ? gap : 0} ${form.unit === 'hours' ? 'hours' : 'minutes'}`;
  if (form.every === 'daily') return `daily at ${form.time}`;
  if (form.every === 'weekdays') return `weekdays at ${form.time}`;
  return `once at ${form.date} ${form.time}`;
}

/** The form's controls for a saved schedule (its `whenText` is the engine's own typed form). */
export function formFor(schedule) {
  const form = {...EMPTY_FORM, id: schedule.id, name: schedule.name, project: schedule.project || '', kind: schedule.kind, message: schedule.message, model: schedule.model || '', permission: schedule.permission};
  const text = schedule.whenText || '';
  let match;
  if ((match = /^every (\d+) (minutes|hours)$/.exec(text))) return {...form, every: 'every', gap: match[1], unit: match[2]};
  if ((match = /^(daily|weekdays) at (\d\d:\d\d)$/.exec(text))) return {...form, every: match[1], time: match[2]};
  if ((match = /^once at (\d{4}-\d\d-\d\d) (\d\d:\d\d)$/.exec(text))) return {...form, every: 'once', date: match[1], time: match[2]};
  return form;
}

/** A time for people: "Tue 9:30 am", or with the date when it is not this week. */
export function timeText(seconds, now = Date.now()) {
  if (!seconds) return '';
  const date = new Date(seconds * 1000);
  const soon = Math.abs(date.getTime() - now) < 6 * 24 * 3600 * 1000;
  return date.toLocaleString(undefined, soon ? {weekday: 'short', hour: 'numeric', minute: '2-digit'} : {month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'});
}

const STATE_WORDS = {running: 'Running now', waiting: 'Waiting for you', queued: 'Waiting for its turn', scheduled: 'Scheduled', paused: 'Paused', finished: 'Finished'};
export const stateWords = state => STATE_WORDS[state] || '';

const RESULT_WORDS = {done: 'Finished', error: 'Did not finish', 'not-approved': 'Not approved', stopped: 'Stopped', interrupted: 'Interrupted', skipped: 'Skipped', running: 'Running', waiting: 'Waiting for you'};
export const resultWords = state => RESULT_WORDS[state] || '';

/** Whether a result needs the person's eye. */
export const needsAttention = state => ['error', 'not-approved', 'interrupted'].includes(state);

const INBOX_WORDS = {waiting: 'Waiting', approved: 'You approved it', denied: 'You denied it', answered: 'Answered on another screen', expired: 'Nobody answered in time', ended: 'The run ended first'};
export const inboxWords = state => INBOX_WORDS[state] || '';

/** "in 3 h", "in 20 min", "ran out": how long a question has left. */
export function leftText(expires, now = Date.now()) {
  const seconds = Math.round(expires - now / 1000);
  if (seconds <= 0) return 'ran out';
  if (seconds < 90) return 'in under a minute';
  if (seconds < 5400) return `in ${Math.round(seconds / 60)} min`;
  return `in ${Math.round(seconds / 3600)} h`;
}

export {two};
