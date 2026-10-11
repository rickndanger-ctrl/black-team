const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {createMemory} = require('../lib/memory.cjs');

function vault(limits) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'black-team-vault-'));
  fs.mkdirSync(path.join(dir, '.obsidian')); fs.writeFileSync(path.join(dir, '.obsidian', 'app.md'), 'hidden');
  fs.writeFileSync(path.join(dir, 'PROJECT_INDEX.md'), '# Index\n\nSee [[BLACK_TEAM]] and [[Missing Note|a note not written yet]].\n');
  fs.writeFileSync(path.join(dir, 'BLACK_TEAM.md'), '# Black Team\n\nBack to [[PROJECT_INDEX#top]]. The compaction threshold is 28000 tokens.\n');
  return {dir, memory: createMemory({vault: dir, ...(limits ? {limits} : {})})};
}

test('notes, links and the graph follow Obsidian: names match, hidden folders are skipped, missing links are kept', () => {
  const {memory} = vault();
  assert.deepEqual(memory.notes().map(n => n.id).sort(), ['BLACK_TEAM', 'PROJECT_INDEX']);
  const graph = memory.graph();
  assert.deepEqual(graph.nodes.map(n => [n.id, n.missing]).sort(), [['?Missing Note', true], ['BLACK_TEAM', false], ['PROJECT_INDEX', false]]);
  assert.deepEqual(graph.edges.map(e => `${e.from}>${e.to}`).sort(), ['BLACK_TEAM>PROJECT_INDEX', 'PROJECT_INDEX>?Missing Note', 'PROJECT_INDEX>BLACK_TEAM']);
});

test('notes stay inside the vault and a removed note goes to the trash, not away', () => {
  const {dir, memory} = vault();
  for (const bad of ['../outside', '/etc/passwd', '.obsidian/app', 'a/../../b', 'x\0y', '', 'a//b']) assert.throws(() => memory.write(bad, 'x'), /valid note name|inside the vault/, bad);
  fs.symlinkSync(os.tmpdir(), path.join(dir, 'link'));
  assert.throws(() => memory.write('link/escape', 'x'), /inside the vault/);
  assert.equal(memory.write('Ideas/First', '# First\n').content, '# First\n');
  assert.equal(memory.read('Ideas/First').title, 'First');
  memory.remove('Ideas/First');
  assert.throws(() => memory.read('Ideas/First'), /No such note/);
  assert.equal(fs.readdirSync(path.join(dir, '.trash')).length, 1);
});

test('models remember dated facts in their own folder, by project when asked, and recall them', async () => {
  const {dir, memory} = vault();
  assert.equal(memory.remember('Deploy steps', 'Run the build before packaging.'), 'Notes/Deploy steps');
  memory.remember('Deploy steps', 'Checksums are written last.');
  assert.match(memory.read('Notes/Deploy steps').content, /^# Deploy steps\n\n- \d{4}-\d\d-\d\d: Run the build before packaging\.\n- \d{4}-\d\d-\d\d: Checksums are written last\.\n$/);
  assert.equal(memory.remember('Test command', 'npm test runs both suites.', '/home/rick/Projects/black-team'), 'Projects/black-team/Test command');
  assert.equal(memory.remember('../../etc/x: y', 'kept inside'), 'Notes/etc x y');
  for (const title of ['Core', 'journal', '   ']) assert.throws(() => memory.remember(title, 'x'), /short title/);
  assert.throws(() => memory.remember('Big', 'x'.repeat(4001)), /up to 4,000/);
  const found = await memory.recall('checksums');
  assert.match(found, /^\[\[Notes\/Deploy steps\]\] line 4: - \d{4}-\d\d-\d\d: Checksums are written last\.\n\(These are memory notes, not files in the workspace\./);
  assert.match(await memory.recall('', '[[Notes/Deploy steps]]'), /^# Deploy steps\n\n- .*Run the build before packaging\.\n- .*Checksums are written last\.\n$/);
  assert.match(await memory.recall('', 'No Such'), /no memory note named "No Such"/);
  assert.match(await memory.recall('compaction threshold'), /\[\[BLACK_TEAM\]\] line 3/);
  assert.equal(await memory.recall('zebra-nothing'), 'Nothing saved matches that.');
  assert.equal(memory.core(), '');
  fs.writeFileSync(path.join(dir, 'Core.md'), 'Prefers small diffs.\n');
  assert.equal(memory.core(), 'Prefers small diffs.');
});

test('the journal records each turn by project without a model, and the keeper holds everything within limits', async () => {
  let clock = Date.parse('2026-10-11T10:00:00Z');
  const {dir, memory} = vault({noteChars: 400, journalEntries: 3, totalChars: 3000});
  const more = createMemory({vault: dir, limits: memory.limits, now: () => clock++});
  for (let n = 1; n <= 5; n++) more.journal('/home/rick/Projects/black-team', {request: `Task ${n}`, log: [`edit a.js (+${n} −1 lines)`], outcome: `Done ${n}.`});
  const id = 'Projects/black-team/Journal';
  assert.equal((more.read(id).content.match(/^## /gm) || []).length, 5);
  assert.deepEqual(more.sweep(), ['Moved 2 older journal entries for black-team to the archive.']);
  const kept = more.read(id).content;
  assert.equal((kept.match(/^## /gm) || []).length, 3); assert.ok(kept.includes('Task 5') && kept.includes('Task 3') && !kept.includes('Task 2'));
  assert.match(await more.recall('Task'), /Task 5/);
  assert.ok(!(await more.recall('Task')).includes('Archive')); // Archived entries are kept but not recalled.
  assert.match((await more.search('Task 1', {includeArchive: true})).map(h => h.id).join(), /Archive\/black-team/);

  // A note past its limit is condensed by whatever it is delegated to; the original is archived first.
  const long = Array.from({length: 30}, (_, i) => `- 2026-10-0${i % 9 + 1}: The port is 18081 (said again, time ${i}).`).join('\n');
  more.write('Notes/Ports', `# Ports\n\n${long}\n`);
  assert.deepEqual(more.usage().oversized, ['Notes/Ports']);
  assert.match(await more.condense(async () => ''), /not usable/);
  // Idle upkeep does not ask the model about the same unchanged note twice; asking by hand does.
  assert.equal(await more.condense(async () => {throw new Error('must not be asked');}), null);
  assert.match(await more.condense(async ({content}) => content + ' longer', {again: true}), /not usable/);
  assert.ok(more.read('Notes/Ports').content.includes('time 29'));
  let asked;
  const done = await more.condense(async request => {asked = request; return '# Ports\n\n- The Ornith server listens on port 18081.';}, {again: true});
  assert.equal(asked.title, 'Ports'); assert.equal(asked.target, 240);
  assert.match(done, /^Condensed Ports from [\d,]+ to 51 characters\. The original is in the archive\.$/);
  assert.match(more.read('Notes/Ports').content, /^# Ports\n\n- The Ornith server listens on port 18081\.\n\n_Condensed by Black Team on 2026-10-11\./);
  assert.ok(more.notes().some(n => n.id.startsWith('Archive/Ports') && n.size > 1000));
  assert.deepEqual(more.usage().oversized, []); assert.equal(await more.condense(async () => 'x'), null);

  // Over the total limit, the stalest notes are archived first; the user's own notes and Core are never touched.
  fs.writeFileSync(path.join(dir, 'Core.md'), 'core');
  for (let n = 1; n <= 12; n++) {more.write(`Notes/Fact ${n}`, 'f'.repeat(380)); fs.utimesSync(path.join(dir, 'Notes', `Fact ${n}.md`), new Date(2026, 0, n), new Date(2026, 0, n));}
  const actions = more.sweep();
  assert.ok(actions.length >= 1 && actions.every(a => /oldest note, Fact \d+, moved to the archive/.test(a)), actions.join('|'));
  assert.match(actions[0], /Fact 1,/);
  const after = more.usage();
  assert.ok(after.chars <= 3000 && after.percent <= 100, JSON.stringify(after));
  assert.ok(more.notes().some(n => n.id === 'BLACK_TEAM') && more.core() === 'core' && more.notes().some(n => n.id === 'Notes/Fact 12'));
});

test('chat lookup finds the saved lines that share a message\u2019s distinctive words, the project\u2019s first, and stays quiet otherwise', async () => {
  const {dir, memory} = vault();
  memory.remember('Deploy steps', 'Checksums are written last, after the archive is packed.');
  memory.remember('Deploy steps', 'The archive is packed with tar and gzip.', '/home/rick/Projects/black-team');
  memory.remember('Coffee', 'The user drinks espresso in the morning.');
  fs.writeFileSync(path.join(dir, 'Core.md'), 'archive checksums core line');
  const general = await memory.lookup('How should the archive checksums be written for the release?');
  assert.deepEqual(general.map(hit => hit.id), ['Notes/Deploy steps']);
  assert.match(general[0].text, /^\d{4}-\d\d-\d\d: Checksums are written last/);
  const scoped = await memory.lookup('How do we pack the archive, and where do checksums go?', '/home/rick/Projects/black-team');
  assert.equal(scoped[0].id, 'Projects/black-team/Deploy steps'); assert.equal(scoped.length, 2);
  for (const quiet of ['Thanks, that helps!', 'what do you think about this', 'Tell me about zebras and giraffes']) assert.deepEqual(await memory.lookup(quiet), [], quiet);
  assert.ok((await memory.lookup('archive checksums archive checksums written packed tar gzip', null, {maxChars: 60})).length <= 1);
});

test('archiving notes that share a title in the same moment loses none of them',()=>{
  const {memory}=vault({noteChars:6000,journalEntries:30,totalChars:10});
  for(const name of ['a','b','c'])memory.write(`Projects/${name}/Overview`,`# ${name}\n\n${name.repeat(40)}\n`);
  memory.sweep();
  assert.equal(memory.notes().filter(note=>note.kind==='archive'&&note.title.startsWith('Overview')).length,3);
});

test('a new vault is ready on first start: folders and a Core note, with its guidance kept from the model', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'black-team-vault-'));
  const memory = createMemory({vault: dir});
  assert.deepEqual(fs.readdirSync(dir).sort(), ['Archive', 'Core.md', 'Notes', 'Projects']);
  assert.equal(fs.statSync(path.join(dir, 'Core.md')).mode & 0o777, 0o600);
  assert.equal(memory.core(), '', 'the template is guidance only until the user writes something');
  assert.deepEqual(memory.notes().map(n => [n.id, n.kind]), [['Core', 'core']]);
  assert.equal(memory.graph().nodes.length, 1);
  fs.writeFileSync(path.join(dir, 'Core.md'), '# Core\n\nShort answers. <!-- a note to self -->\nWorking on tides.\n');
  assert.equal(memory.core(), 'Short answers. \nWorking on tides.');
  // Opening the vault again changes nothing, and a vault that already has notes is left alone.
  createMemory({vault: dir});
  assert.equal(fs.readFileSync(path.join(dir, 'Core.md'), 'utf8').startsWith('# Core\n\nShort answers.'), true);
  const {dir: existing} = vault();
  assert.equal(fs.existsSync(path.join(existing, 'Core.md')), false);
  assert.equal(fs.existsSync(path.join(existing, 'Notes')), false);
});
