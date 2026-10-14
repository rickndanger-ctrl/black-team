import {test} from 'node:test';
import assert from 'node:assert/strict';
import {downloadState, downloadRequest, timeLeft, picksOf, restOf, size, thirdParty, fitWords} from '../src/models.mjs';

test('the download state follows the engine, with a stop kept apart from a failure', () => {
  assert.equal(downloadState({}), 'idle');
  assert.equal(downloadState({running: true, paused: true}), 'running');
  assert.equal(downloadState({running: false, error: 'No room.'}), 'error');
  assert.equal(downloadState({running: false, paused: true, error: ''}), 'paused');
  assert.equal(downloadState({done: true, result: {ready: true}}), 'ready');
  assert.equal(downloadState({done: true}), 'idle');
});

test('a choice is sent by name only, never with a size, hash or address', () => {
  assert.deepEqual(downloadRequest({source: 'catalogue', id: 'qwen3.8-27b', bytes: 1, sha256: 'x'}, {vision: true}), {source: 'catalogue', id: 'qwen3.8-27b', vision: true, draft: false});
  assert.deepEqual(downloadRequest({source: 'hub', repo: 'a/b', file: 'x.gguf', url: 'https://evil.test'}), {source: 'hub', repo: 'a/b', file: 'x.gguf', vision: false, draft: false});
});

test('time left is only claimed when it can be worked out', () => {
  assert.equal(timeLeft({}, 1e9), '');
  assert.equal(timeLeft({bytesPerSecond: 1e6, fraction: 0.5}, 0), '');
  assert.equal(timeLeft({bytesPerSecond: 1e8, fraction: 0.5}, 1e9), 'less than a minute left');
  assert.equal(timeLeft({bytesPerSecond: 1e7, fraction: 0.5}, 2e10), 'about 17 min left');
  assert.equal(timeLeft({bytesPerSecond: 1e6, fraction: 0}, 1e10), 'about 2.8 hours left');
});

test('picks are merged when one model wins several, and the rest are listed once', () => {
  const models = [{id: 'a', picks: ['best', 'code']}, {id: 'b', picks: ['fastest']}, {id: 'c', picks: []}];
  const picks = picksOf({models, bestID: 'a', codeID: 'a', fastestID: 'b'});
  assert.deepEqual(picks.map(item => [item.entry.id, item.keys]), [['a', ['best', 'code']], ['b', ['fastest']]]);
  assert.deepEqual(restOf(models).map(entry => entry.id), ['c']);
  assert.deepEqual(picksOf({models: [], bestID: null}), []);
});

test('words for sizes, fit and the maker', () => {
  assert.equal(size(21_713_463_040), '21.7 GB');
  assert.equal(size(204_987_232), '205 MB');
  assert.equal(fitWords('tooBig'), 'Too big for this computer');
  assert.match(thirdParty('unsloth/Qwen3.8-27B-GGUF'), /Made by unsloth, not by Black Team/);
});
