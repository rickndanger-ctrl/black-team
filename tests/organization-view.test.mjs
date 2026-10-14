import test from 'node:test';
import assert from 'node:assert/strict';
import {STAGES, agentChoice, artifactKind, boardColumns, boardSwitch, ceilingText, folderName, gateChoices, paidRoles, sharedLocalModel, latestArtifacts, needsOwner, roleStatusText, sendBackText, splitLines, waitingText} from '../src/organizationView.mjs';

test('gates toggle and stay in pipeline order', () => {
  assert.deepEqual(gateChoices(['spec', 'ship'], 'review'), ['spec', 'review', 'ship']);
  assert.deepEqual(gateChoices(['spec', 'ship'], 'spec'), ['ship']);
  assert.deepEqual(gateChoices([], 'qa'), ['qa']);
  assert.deepEqual(STAGES, ['intake', 'spec', 'design', 'plan', 'build', 'review', 'qa', 'ship']);
});

test('the board has a column per stage and a finished column, open tickets in their stage', () => {
  const tickets = [
    {id: 'a', number: 2, stage: 'build', state: 'running'}, {id: 'b', number: 1, stage: 'build', state: 'ready'},
    {id: 'c', number: 3, stage: 'ship', state: 'done'}, {id: 'd', number: 4, stage: 'spec', state: 'gate'}, {id: 'e', number: 5, stage: 'qa', state: 'cancelled'},
  ];
  const columns = boardColumns(tickets);
  assert.deepEqual(columns.map(column => column.id), [...STAGES, 'finished']);
  assert.deepEqual(columns.find(column => column.id === 'build').tickets.map(ticket => ticket.number), [1, 2]);
  assert.deepEqual(columns.find(column => column.id === 'finished').tickets.map(ticket => ticket.number), [5, 3]);
  assert.equal(columns.find(column => column.id === 'spec').tickets.length, 1);
});

test('what a ticket waits for is said in plain words', () => {
  assert.equal(needsOwner({state: 'gate'}), true);
  assert.equal(needsOwner({state: 'blocked'}), true);
  assert.equal(needsOwner({state: 'ready'}), false);
  assert.equal(waitingText({state: 'blocked', note: 'The branch could not be made.'}), 'Stuck: The branch could not be made.');
  assert.equal(waitingText({state: 'gate', gate: {kind: 'question', question: 'Offline?'}}), 'It asks: Offline?');
  assert.equal(waitingText({state: 'gate', gate: {kind: 'approval', question: 'Approve the spec?'}}), 'Approve the spec?');
  assert.equal(waitingText({state: 'running'}), '');
});

test('the newest artifact of each name is the one shown, and send-backs are counted in words', () => {
  const artifacts = [{name: 'spec.md'}, {name: 'review.md'}, {name: 'review-2.md'}, {name: 'diff.patch'}];
  assert.deepEqual(latestArtifacts(artifacts).map(item => item.name), ['spec.md', 'review-2.md', 'diff.patch']);
  assert.equal(artifactKind('spec.md'), 'markdown');
  assert.equal(artifactKind('diff.patch'), 'code');
  assert.equal(sendBackText({review: 1, qa: 2}), 'Sent back by Review 1 time, QA 2 times');
  assert.equal(sendBackText({}), '');
});

test('roles say where they run and what they are doing', () => {
  const choices = [{kind: 'model', key: 'k', name: 'Ornith'}, {kind: 'agent', key: 'claude-code', name: 'Claude Code'}];
  assert.equal(agentChoice({kind: 'local', role: {modelKey: 'k'}}, choices), 'Ornith · this computer');
  assert.equal(agentChoice({kind: 'cloud', provider: 'anthropic.com', role: {agent: 'claude-code'}}, choices), 'Claude Code · paid, anthropic.com');
  assert.equal(agentChoice({kind: 'none', role: {}}, choices), 'No model or agent yet');
  assert.equal(roleStatusText({status: 'working', ticket: 'T-3'}), 'Working on T-3');
  assert.equal(roleStatusText({status: 'waiting', ticket: 'T-3'}), 'Waiting for you on T-3');
  assert.equal(roleStatusText({status: 'not set up'}), 'Not set up');
  assert.equal(ceilingText({}), 'none set');
  assert.equal(ceilingText({paidTokensPerDay: 50000, moneyPerDay: 2}), '50,000 paid tokens and 2.00 money a day');
  assert.deepEqual(splitLines(' a \n\n b\n'), ['a', 'b']);
});

test('the board switch says Start working or Stop, and the roles share one local model or none', () => {
  assert.deepEqual(boardSwitch(undefined), {on: false, label: 'Start working', busyLabel: 'Starting…'});
  assert.deepEqual(boardSwitch({working: false}), {on: false, label: 'Start working', busyLabel: 'Starting…'});
  assert.deepEqual(boardSwitch({working: true}), {on: true, label: 'Stop', busyLabel: 'Stopping…'});
  const choices = [{kind: 'model', key: 'a', cloud: false}, {kind: 'model', key: 'c', cloud: true}];
  assert.equal(sharedLocalModel({organization: {roles: [{modelKey: 'a'}, {modelKey: 'a'}]}, choices}), 'a');
  assert.equal(sharedLocalModel({organization: {roles: [{modelKey: 'a'}, {modelKey: 'b'}]}, choices}), '');
  assert.equal(sharedLocalModel({organization: {roles: [{modelKey: 'c'}]}, choices}), '', 'a paid model is not the local default');
  assert.equal(sharedLocalModel({}), '');
  assert.deepEqual(paidRoles({roles: [{kind: 'local', role: {name: 'Lead'}}, {kind: 'cloud', role: {name: 'Reviewer'}}]}), ['Reviewer']);
  assert.equal(folderName('/home/me/Vault/Black Team Org/Board'), 'Board');
});
