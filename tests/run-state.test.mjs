import {test} from 'node:test';
import assert from 'node:assert/strict';
import {canContinue, continueLabel, limitsFrom, money, runLine, runOf, shownPhase, stoppedLine} from '../src/runState.mjs';

const run = {phase: 'working', steps: 7, tool: 'run', toolStatus: 'running', tokens: 12345, cost: 0.0123, todo: [{text: 'a', done: true}, {text: 'b', done: false}]};

test('the line under a running Code job says the phase, the step, the tool, the tokens and the cost in plain words', () => {
  assert.equal(runLine({phase: 'working', run}), 'Working · step 7 · using run · 12,345 tokens · $0.012 spent');
  assert.equal(runLine({phase: 'planning', run: {steps: 1, tokens: 520}}), 'Planning · step 1 · 520 tokens');
  assert.equal(runLine({phase: 'working', run, pausing: true}).startsWith('Pausing after this step'), true);
  assert.equal(runLine({phase: 'paused', run: {...run, toolStatus: 'done'}, pausing: true}).startsWith('Paused'), true);
  assert.equal(runLine({phase: 'checking', run: {steps: 4}}), 'Checking the work · step 4');
  assert.equal(runLine({phase: 'waiting', run: {steps: 2}}), 'Waiting for your approval · step 2');
  assert.equal(runLine({phase: 'done', run: {steps: 3, tokens: 100, estimated: true}}), 'Done · 100 tokens (counted by Black Team)');
  assert.equal(runLine({phase: '', run}), '');
  assert.equal(money(2), '$2.00'); assert.equal(money(0.5), '$0.500'); assert.equal(money(0.00056), '$0.0006');
});

test('the live phase wins while a job runs here, and the saved one is shown otherwise', () => {
  const job = {state: 'running', threadId: 't1', phase: 'paused'};
  assert.equal(shownPhase({job, threadId: 't1', run}), 'paused');
  assert.equal(shownPhase({job, threadId: 't2', run}), 'working');
  assert.equal(shownPhase({job: {...job, state: 'done'}, threadId: 't1', run: {phase: 'done'}}), 'done');
  assert.equal(runOf({messages: [{run: {phase: 'done'}}, {role: 'assistant'}]}).phase, 'done');
  assert.equal(runOf({messages: []}), null);
});

test('Continue is offered for a cut-off or stopped run, never while one is running, and says where it stopped', () => {
  assert.equal(canContinue({phase: 'working', running: false, run}), true);
  assert.equal(canContinue({phase: 'working', running: true, run}), false);
  assert.equal(canContinue({phase: 'done', running: false, run}), false);
  assert.equal(canContinue({phase: 'stopped', running: false, run}), true);
  assert.equal(canContinue({phase: 'failed', running: false, run: {}}), false);
  assert.equal(canContinue({phase: '', running: false, run: null}), false);
  assert.equal(continueLabel({phase: 'working'}), 'Continue where it stopped');
  assert.equal(continueLabel({phase: 'stopped'}), 'Continue');
  assert.equal(stoppedLine({phase: 'working', run}), 'It was cut off at step 7, while using run. 1 of 2 to-do items were done.');
  assert.equal(stoppedLine({phase: 'stopped', run: {steps: 3}}), 'It stopped at step 3.');
});

test('the limits form is checked before it is sent, and a spending limit needs prices', () => {
  assert.deepEqual(limitsFrom({tokens: '50,000', cloud: false}), {value: {tokenCeiling: 50000}});
  assert.deepEqual(limitsFrom({tokens: '', cloud: false}), {value: {tokenCeiling: 0}});
  assert.match(limitsFrom({tokens: '1.5', cloud: false}).error, /whole number/);
  assert.match(limitsFrom({tokens: '-1', cloud: false}).error, /whole number/);
  assert.deepEqual(limitsFrom({tokens: '0', money: '2.5', inPrice: '3', outPrice: '15', cloud: true}), {value: {tokenCeiling: 0, moneyCeiling: 2.5, price: {input: 3, output: 15}}});
  assert.match(limitsFrom({tokens: '0', money: '2.5', inPrice: '', outPrice: '', cloud: true}).error, /Enter both prices/);
  assert.match(limitsFrom({tokens: '0', money: 'lots', cloud: true}).error, /spending limit/);
  assert.match(limitsFrom({tokens: '0', money: '1', inPrice: '3', outPrice: 'x', cloud: true}).error, /both prices/);
  // A model on this computer has no money or prices.
  assert.deepEqual(limitsFrom({tokens: '10', money: '5', inPrice: '1', outPrice: '1', cloud: false}), {value: {tokenCeiling: 10}});
});
