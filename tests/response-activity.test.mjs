import {test} from 'node:test';
import assert from 'node:assert/strict';
import {responseActivity} from '../src/responseActivity.mjs';

const thread = {id: 'current', messages: [{id: 'reply', role: 'assistant', state: 'writing', content: ''}]};
const job = {id: 'task', threadId: 'current', state: 'running', kind: 'chat', progress: 'Thinking…'};
const status = (changes = {}) => responseActivity({thread, threadId: 'current', job, connection: 'online', ...changes});

test('live thinking and streamed replies animate their assistant message', () => {
  assert.deepEqual(status(), {phase: 'thinking', label: 'Thinking', glowing: true, messageId: 'reply'});
  assert.equal(status({job: {...job, progress: 'Writing a reply…'}}).phase, 'responding');
});
test('saved writing state does not animate without a live job', () => {
  assert.equal(status({job: null}), null);
  for (const state of ['done', 'error', 'interrupted']) assert.equal(status({job: {...job, state}}), null);
});
test('a different conversation or a model-server operation cannot light the ring', () => {
  assert.equal(status({threadId: 'other'}), null);
  assert.equal(status({job: {...job, kind: 'start'}}), null);
  assert.equal(status({threadId: null}), null);
});
test('disconnected, approval and stopping states do not imply active inference', () => {
  assert.equal(status({connection: 'offline'}).glowing, false);
  assert.equal(status({job: {...job, kind: 'agent', approval: {id: 'request'}}}).phase, 'approval');
  assert.equal(status({job: {...job, approval: {id: 'request'}}}).glowing, false);
  assert.equal(status({job: {...job, progress: 'Stopping agent…'}}).glowing, false);
});
test('preparation before the assistant exists gets a temporary indicator', () => {
  const activity = status({thread: {id: 'current', messages: [{role: 'user', content: 'Hello'}]}});
  assert.equal(activity.messageId, null);
  assert.equal(activity.glowing, true);
  assert.equal(status({thread: null, job: {...job, progress: 'Preparing…'}}).phase, 'preparing');
});
test('thread fetch lag never associates the current job with the old conversation', () => {
  assert.equal(status({thread: {...thread, id: 'old'}}).messageId, null);
});
test('completed assistant does not glow while the final job update catches up', () => {
  const completed = {...thread, messages: [{...thread.messages[0], state: 'done'}]};
  assert.equal(status({thread: completed}), null);
});
test('agent tool work has an honest working label', () => {
  assert.equal(status({job: {...job, kind: 'agent', progress: 'Using read_file…'}}).phase, 'working');
});
