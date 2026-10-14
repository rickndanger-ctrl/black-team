import test from 'node:test';
import assert from 'node:assert/strict';
import {EMPTY_FORM, PERMISSIONS, formFor, inboxWords, leftText, needsAttention, resultWords, stateWords, whenText} from '../src/schedulesView.mjs';
import {approvableIds, defaultPickedIds, readyMessage} from '../src/setupPlan.mjs';

test('the form controls become the plain words the engine reads, and back again', () => {
  assert.equal(whenText({...EMPTY_FORM, every: 'every', gap: '30', unit: 'minutes'}), 'every 30 minutes');
  assert.equal(whenText({...EMPTY_FORM, every: 'every', gap: '2', unit: 'hours'}), 'every 2 hours');
  assert.equal(whenText({...EMPTY_FORM, every: 'daily', time: '09:30'}), 'daily at 09:30');
  assert.equal(whenText({...EMPTY_FORM, every: 'weekdays', time: '17:00'}), 'weekdays at 17:00');
  assert.equal(whenText({...EMPTY_FORM, every: 'once', date: '2026-10-14', time: '09:30'}), 'once at 2026-10-14 09:30');
  const saved = {id: 'a', name: 'Morning', project: 'p', kind: 'agent', message: 'Hi', model: '', permission: 'read-only'};
  for (const text of ['every 30 minutes', 'every 2 hours', 'daily at 09:30', 'weekdays at 17:00', 'once at 2026-10-14 09:30']) {
    assert.equal(whenText(formFor({...saved, whenText: text})), text);
  }
  assert.equal(formFor({...saved, whenText: 'daily at 09:30'}).permission, 'read-only');
});

test('the three permission levels are offered, ask first by default', () => {
  assert.deepEqual(PERMISSIONS.map(([id]) => id), ['ask', 'allow-in-project', 'read-only']);
  assert.equal(EMPTY_FORM.permission, 'ask');
});

test('words for states, results and the inbox', () => {
  assert.equal(stateWords('waiting'), 'Waiting for you');
  assert.equal(resultWords('not-approved'), 'Not approved');
  assert.equal(needsAttention('error'), true);
  assert.equal(needsAttention('done'), false);
  assert.equal(inboxWords('expired'), 'Nobody answered in time');
  assert.equal(leftText(100, 100 * 1000 + 5000), 'ran out');
  assert.equal(leftText(100 + 600, 100 * 1000), 'in 10 min');
  assert.equal(leftText(100 + 7200, 100 * 1000), 'in 2 h');
});

test('the background service step is listed but never ticked for the person', () => {
  const plan = {steps: [
    {id: 'connect:claude', kind: 'connect', state: 'will-do'},
    {id: 'background-service', kind: 'service', state: 'will-do', optIn: true},
  ]};
  assert.deepEqual(approvableIds(plan), ['connect:claude', 'background-service']);
  assert.deepEqual(defaultPickedIds(plan), ['connect:claude']);
  assert.equal(readyMessage({done: true, results: [{id: 'background-service', status: 'done', message: 'Black Team will keep running'}]}).title,
    'Ready: Black Team will keep running in the background from your next login');
});
