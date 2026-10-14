import {test} from 'node:test';
import assert from 'node:assert/strict';
import {approvableIds, cardView, readyMessage, resultKey, stateLabel} from '../src/setupPlan.mjs';
import {MODEL_READY_EVENT, offerSetupAfterModelReady, onModelReady} from '../src/setupOffer.mjs';

const plan = {steps: [
  {id: 'connect:claude', kind: 'connect', state: 'will-do'},
  {id: 'connect:codex', kind: 'connect', state: 'done'},
  {id: 'hermes-install', kind: 'install', state: 'needs-something'},
  {id: 'hermes-connect', kind: 'connect', state: 'will-do'},
  {id: 'agents-missing', kind: 'note', state: 'will-do'},
]};

test('only will-do steps can be approved and a note never can', () => {
  assert.deepEqual(approvableIds(plan), ['connect:claude', 'hermes-connect']);
  assert.deepEqual(approvableIds(null), []);
  assert.equal(stateLabel('will-do'), 'Will do');
});

test('the card appears when offered, never after Not now, always when asked, and shows progress and the result', () => {
  assert.equal(cardView({offer: {show: true}, run: {}}), 'plan');
  assert.equal(cardView({offer: {show: false}, run: {}}), null);
  assert.equal(cardView({offer: {show: true}, run: {}, hidden: true}), null);
  assert.equal(cardView({offer: {show: false}, run: {}, asked: true}), 'plan');
  assert.equal(cardView({offer: null, run: {}}), null);
  assert.equal(cardView({offer: {show: false}, run: {running: true}}), 'progress');
  assert.equal(cardView({offer: {show: false}, run: {done: true}}), 'result');
  assert.equal(cardView({offer: {show: false}, run: {done: true}, hidden: true}), null);
});

test('the ready message names Hermes tools only when Hermes was connected', () => {
  const run = results => ({done: true, results});
  assert.equal(readyMessage(run([{id: 'hermes-connect', status: 'done', message: 'Hermes is connected.'}])).title, 'Ready: Code can now use Hermes tools');
  assert.equal(readyMessage(run([{id: 'connect:claude', status: 'done', message: 'Claude Code is connected.'}])).title, 'Ready: your agents are connected');
  assert.equal(readyMessage(run([{id: 'hermes-install', status: 'failed', message: 'x'}])).ready, false);
  assert.equal(readyMessage(run([{id: 'connect:claude', status: 'done', message: 'Already done.'}])).title, 'Everything was already set up');
  assert.notEqual(resultKey(run([{id: 'a', status: 'done'}])), resultKey(run([{id: 'a', status: 'failed'}])));
});

test('the model-ready hook reaches a listener and stops when unsubscribed', () => {
  const target = new EventTarget();
  let calls = 0;
  const stop = onModelReady(() => { calls += 1; }, target);
  offerSetupAfterModelReady(target);
  assert.equal(calls, 1);
  stop();
  offerSetupAfterModelReady(target);
  assert.equal(calls, 1);
  assert.equal(MODEL_READY_EVENT, 'black-team:model-ready');
});
