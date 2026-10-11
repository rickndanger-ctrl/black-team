'use strict';
// The Black Team vault: local memory only. Plain Markdown notes joined by [[links]], kept in
// Black Team's own data folder, apart from any notes other tools or hosted assistants use.
//   Core.md                     what every conversation is told (edited by the user only)
//   Notes/<topic>.md            facts that are true everywhere
//   Projects/<name>/...         one folder per project: Overview, Journal and its own facts
//   Archive/...                 older material: kept, but left out of recall
const fs = require('node:fs');
const path = require('node:path');

const CORE = 'Core', NOTES = 'Notes', PROJECTS = 'Projects', ARCHIVE = 'Archive';
const NOTE_ID = /^(?!.*(?:^|\/)\.)(?!.*\/\/)[^\\\0<>:"|?*\n]{1,180}$/; // No hidden parts, no odd characters.
const LINK = /\[\[([^\]|#\n]{1,180})(?:#[^\]|\n]*)?(?:\|[^\]\n]*)?\]\]/g;
const MAX_NOTE = 200000;
// Limits for what the models write, so memory stays quick to search and cheap to read.
const LIMITS = {noteChars: 6000, journalEntries: 30, totalChars: 400000};
const STOP = new Set('about after again also because been before being could does doing done each ever every from have having here into just know like make many more most much must need only other over please really same should some such than that their them then there these they thing things this those through very want what when where which while will with would your yours could help tell show give think about'.split(' '));

function createMemory({vault, limits = LIMITS, now = Date.now} = {}) {
  if (typeof vault !== 'string' || !path.isAbsolute(vault)) throw new Error('The memory vault needs an absolute folder path.');
  fs.mkdirSync(vault, {recursive: true, mode: 0o700});
  if (fs.lstatSync(vault).isSymbolicLink()) throw new Error('The memory vault must not be a symbolic link.');
  const root = fs.realpathSync(vault);
  const fileFor = id => {
    if (typeof id !== 'string' || !NOTE_ID.test(id) || id.split('/').some(part => part === '..' || !part.trim())) throw new Error('That is not a valid note name.');
    const file = path.join(root, `${id}.md`);
    let existing = path.dirname(file);
    while (!fs.existsSync(existing)) existing = path.dirname(existing);
    const real = fs.realpathSync(existing);
    if (real !== root && !real.startsWith(root + path.sep)) throw new Error('Notes stay inside the vault.');
    return file;
  };
  const title = id => id.split('/').at(-1);

  function walk(dir = root, found = []) {
    for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
      if (entry.name.startsWith('.')) continue; // .obsidian, .trash
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full, found);
      else if (entry.isFile() && entry.name.endsWith('.md')) found.push(full);
    }
    return found;
  }
  function notes() {
    return walk().map(file => {
      const id = path.relative(root, file).slice(0, -3).split(path.sep).join('/');
      const stat = fs.statSync(file);
      const text = stat.size <= MAX_NOTE * 2 ? fs.readFileSync(file, 'utf8') : '';
      const links = [...new Set([...text.matchAll(LINK)].map(match => match[1].trim()))];
      return {id, title: title(id), folder: id.includes('/') ? id.split('/')[0] : '', updated: stat.mtimeMs, size: stat.size, links, kind: id === CORE ? 'core' : id.startsWith(`${ARCHIVE}/`) ? 'archive' : id.startsWith(`${PROJECTS}/`) ? 'project' : 'note'};
    }).sort((a, b) => b.updated - a.updated);
  }
  // Notes and the links between them. A link matches a note by name, as Obsidian does;
  // a link to a note that does not exist yet is kept as an empty node.
  function graph() {
    const all = notes();
    const byName = new Map();
    for (const note of all) {byName.set(note.id.toLowerCase(), note.id); if (!byName.has(note.title.toLowerCase())) byName.set(note.title.toLowerCase(), note.id);}
    const nodes = all.filter(note => note.kind !== 'archive').map(note => ({id: note.id, title: note.title, folder: note.folder, kind: note.kind, project: note.kind === 'project' ? note.id.split('/')[1] : '', updated: note.updated, missing: false}));
    const edges = [], seen = new Set(), ghosts = new Map();
    for (const note of all) if (note.kind !== 'archive') for (const link of note.links) {
      let target = byName.get(link.toLowerCase());
      if (!target) {target = `?${link}`; if (!ghosts.has(target)) ghosts.set(target, {id: target, title: link, folder: '', kind: 'missing', project: '', updated: 0, missing: true});}
      const key = `${note.id}\n${target}`;
      if (target !== note.id && !seen.has(key)) {seen.add(key); edges.push({from: note.id, to: target});}
    }
    return {nodes: [...nodes, ...ghosts.values()], edges};
  }
  function read(id) {
    const file = fileFor(id);
    if (!fs.existsSync(file)) throw new Error('No such note.');
    const stat = fs.statSync(file);
    if (stat.size > MAX_NOTE * 2) throw new Error('That note is too large to open here.');
    return {id, title: title(id), content: fs.readFileSync(file, 'utf8'), updated: stat.mtimeMs};
  }
  function write(id, content) {
    if (typeof content !== 'string' || content.length > MAX_NOTE) throw new Error('A note can hold up to 200,000 characters.');
    const file = fileFor(id);
    fs.mkdirSync(path.dirname(file), {recursive: true});
    fs.writeFileSync(`${file}.tmp`, content); fs.renameSync(`${file}.tmp`, file);
    return read(id);
  }
  // Removed notes go to the vault's .trash folder, as Obsidian does, so nothing is lost by a wrong click.
  function remove(id) {
    const file = fileFor(id);
    if (!fs.existsSync(file)) throw new Error('No such note.');
    const trash = path.join(root, '.trash'); fs.mkdirSync(trash, {recursive: true});
    fs.renameSync(file, path.join(trash, `${title(id)} ${Date.now()}.md`));
  }
  // Search reads the notes directly: the vault is kept small by its limits, so no outside tool is needed.
  async function search(query, {limit = 12, includeArchive = false} = {}) {
    if (typeof query !== 'string' || !query.trim() || query.length > 200) return [];
    const words = query.trim().toLowerCase().split(/\s+/).slice(0, 6);
    const hits = [];
    for (const file of walk()) {
      const id = path.relative(root, file).slice(0, -3).split(path.sep).join('/');
      if (!includeArchive && id.startsWith(`${ARCHIVE}/`)) continue;
      let stat; try {stat = fs.statSync(file);} catch {continue;}
      if (stat.size > MAX_NOTE * 2) continue;
      const name = id.toLowerCase();
      let found = 0;
      for (const [index, line] of fs.readFileSync(file, 'utf8').split('\n').entries()) {
        const text = line.trim(); if (!text) continue;
        const lower = text.toLowerCase();
        if (!words.some(word => lower.includes(word))) continue;
        hits.push({id, title: title(id), line: index + 1, text: text.slice(0, 260), score: words.filter(word => lower.includes(word) || name.includes(word)).length, updated: stat.mtimeMs});
        if (++found >= 4) break;
      }
    }
    // Best matches first; among equals, the most recently written note.
    return hits.sort((x, y) => y.score - x.score || y.updated - x.updated).slice(0, limit).map(({updated, ...hit}) => hit);
  }

  // --- What the models use -------------------------------------------------------------
  const stamp = () => new Date().toISOString().slice(0, 10);
  const clean = text => String(text).replace(/[\\\0<>:"|?*\n\r/]+/g, ' ').replace(/\s+/g, ' ').replace(/^[.\s]+/, '').trim().slice(0, 80);
  function core() {
    try {return fs.readFileSync(fileFor(CORE), 'utf8').trim().slice(0, 1500);} catch {return '';}
  }
  // A model saves one fact per note. Saving to an existing title adds a dated line instead of replacing it.
  const projectFolder = workspace => `${PROJECTS}/${clean(path.basename(workspace || '')) || 'workspace'}`;
  const isJournal = id => id.startsWith(`${PROJECTS}/`) && id.endsWith('/Journal');
  // With a workspace, the note is filed in that project's folder beside its journal.
  function remember(noteTitle, text, workspace) {
    const name = clean(noteTitle);
    if (!name || ['core', 'journal'].includes(name.toLowerCase())) throw new Error('Give the note a short title. Core memory is edited by the user only.');
    if (typeof text !== 'string' || !text.trim() || text.length > 4000) throw new Error('Give the fact to remember, up to 4,000 characters.');
    const id = `${workspace ? projectFolder(workspace) : NOTES}/${name}`; const file = fileFor(id);
    const entry = `- ${stamp()}: ${text.trim()}\n`;
    if (fs.existsSync(file)) fs.appendFileSync(file, entry);
    else write(id, `# ${name}\n\n${entry}`);
    return id;
  }
  // With a note name, returns that whole note; otherwise the lines that match. These are memory notes, not workspace files.
  // Inside a project, that project's own notes come first, so the model is not handed other projects' context.
  async function recall(query, note, workspace) {
    if (typeof note === 'string' && note.trim()) {
      const id = note.trim().replace(/^\[\[|\]\]$/g, '').replace(/\.md$/, '');
      try {return read(id).content.slice(0, limits.noteChars);} catch {return `There is no memory note named "${id}". Call recall with a query to see what exists.`;}
    }
    const here = workspace ? `${projectFolder(workspace)}/` : null;
    const found = await search(query, {limit: 24});
    const hits = (here ? [...found.filter(hit => hit.id.startsWith(here)), ...found.filter(hit => !hit.id.startsWith(`${PROJECTS}/`)), ...found.filter(hit => hit.id.startsWith(`${PROJECTS}/`) && !hit.id.startsWith(here))] : found).slice(0, 8);
    return hits.length ? `${hits.map(hit => `[[${hit.id}]] line ${hit.line}: ${hit.text}`).join('\n')}\n(These are memory notes, not files in the workspace. For a whole note, call recall with note set to its name.)` : 'Nothing saved matches that.';
  }
  // For Chat, which has no tools: find the few saved lines that share the message's distinctive words.
  // Returns nothing unless the match is real, so an ordinary message is not padded with noise.
  async function lookup(message, workspace, {limit = 4, maxChars = 700} = {}) {
    const words = [...new Set(String(message || '').toLowerCase().match(/[a-z0-9][a-z0-9_.-]{3,}/g) || [])].filter(word => !STOP.has(word)).sort((a, b) => b.length - a.length).slice(0, 6);
    if (!words.length) return [];
    const here = workspace ? `${projectFolder(workspace)}/` : null;
    const need = words.length >= 3 ? 2 : 1;
    const found = (await search(words.join(' '), {limit: 40})).filter(hit => hit.score >= need && hit.id !== CORE && !isJournal(hit.id) && !/^#/.test(hit.text));
    const ranked = found.sort((a, b) => (Number(Boolean(here) && b.id.startsWith(here)) - Number(Boolean(here) && a.id.startsWith(here))) || b.score - a.score);
    const picked = []; let used = 0; const seen = new Set();
    for (const hit of ranked) {
      const key = `${hit.id}:${hit.line}`; if (seen.has(key)) continue; seen.add(key);
      const text = hit.text.replace(/^[-*]\s*/, '').slice(0, 220);
      if (picked.length >= limit || used + text.length > maxChars) break;
      picked.push({id: hit.id, title: hit.title, text}); used += text.length;
    }
    return picked;
  }
  // Written by the engine after each Code turn, with no model call: what was asked, what was done.
  function journal(workspace, {request, log = [], outcome = ''}) {
    const name = clean(path.basename(workspace)) || 'workspace';
    const id = `${projectFolder(workspace)}/Journal`; const file = fileFor(id);
    const lines = [`\n## ${new Date().toISOString().slice(0, 16).replace('T', ' ')}`, `Asked: ${String(request).replace(/\s+/g, ' ').slice(0, 300)}`,
      ...(log.length ? ['Did:', ...log.slice(-12).map(line => `- ${line.slice(0, 200)}`)] : []), `Result: ${String(outcome).replace(/\s+/g, ' ').slice(0, 300) || '(no summary)'}`, ''];
    if (!fs.existsSync(file)) write(id, `# ${name} journal\n\nWork done in \`${workspace}\`, newest last. Written by Black Team after each Code turn.\n`);
    fs.appendFileSync(file, lines.join('\n'));
    return id;
  }

  // --- The keeper: holds memory within its limits ----------------------------------------
  const active = () => notes().filter(note => note.kind === 'note' || note.kind === 'project');
  function usage() {
    const mine = active();
    const chars = mine.reduce((sum, note) => sum + note.size, 0);
    return {notes: mine.length, chars, limit: limits.totalChars, percent: Math.round(chars / limits.totalChars * 100),
      oversized: mine.filter(note => !isJournal(note.id) && note.size > limits.noteChars).map(note => note.id), archived: notes().filter(note => note.kind === 'archive').length};
  }
  // Many notes share a title (every project has an Overview), so an archive name is never reused.
  function archive(id, content) {
    const base = `${ARCHIVE}/${clean(title(id))} ${new Date(now()).toISOString().slice(0, 10)} ${String(now()).slice(-5)}`;
    let name = base;
    for (let n = 2; fs.existsSync(fileFor(name)); n++) name = `${base} ${n}`;
    return write(name, content);
  }
  const unusable = new Map(); // Notes the model could not shorten, by size, so the same attempt is not repeated.
  // Housekeeping that needs no model: old journal entries and the stalest notes move to the archive.
  function sweep() {
    const actions = [];
    // Deleted notes leave the trash after 30 days.
    try {const trash = path.join(root, '.trash'); for (const entry of fs.readdirSync(trash)) {const file = path.join(trash, entry); if (now() - fs.statSync(file).mtimeMs > 30 * 86400000) fs.rmSync(file, {force: true});}} catch { /* No trash yet. */ }
    for (const note of active().filter(item => isJournal(item.id))) {
      const text = fs.readFileSync(fileFor(note.id), 'utf8');
      const [head, ...entries] = text.split(/\n(?=## )/);
      if (entries.length <= limits.journalEntries) continue;
      const old = entries.slice(0, entries.length - limits.journalEntries);
      archive(note.id.split('/').at(-2), `# ${note.id.split('/').at(-2)} journal (older entries)\n\n${old.join('\n')}`);
      write(note.id, [head, ...entries.slice(-limits.journalEntries)].join('\n'));
      actions.push(`Moved ${old.length} older journal entries for ${note.id.split('/').at(-2)} to the archive.`);
    }
    let mine = active(), total = mine.reduce((sum, note) => sum + note.size, 0);
    for (const note of [...mine].sort((a, b) => a.updated - b.updated)) {
      if (total <= limits.totalChars) break;
      archive(note.id, fs.readFileSync(fileFor(note.id), 'utf8')); fs.unlinkSync(fileFor(note.id)); total -= note.size;
      actions.push(`Memory was over its limit, so the oldest note, ${note.title}, moved to the archive.`);
    }
    return actions;
  }
  // One oversized note is rewritten shorter by the model it is delegated to. The original is archived first,
  // and a result that is empty, not shorter, or has lost its heading is thrown away.
  // Idle upkeep skips a note it already failed on; asking by hand (again: true) tries it once more.
  async function condense(delegate, {again = false} = {}) {
    const id = usage().oversized.find(item => again || unusable.get(item) !== fs.statSync(fileFor(item)).size);
    if (!id) return null;
    const original = fs.readFileSync(fileFor(id), 'utf8');
    unusable.set(id, fs.statSync(fileFor(id)).size);
    // A note too long to hand over whole is left alone rather than shortened from a part of it.
    if (original.length > 40000) return `${title(id)} is too long to condense automatically. Split it into smaller notes.`;
    const target = Math.floor(limits.noteChars * 0.6);
    const shorter = String(await delegate({title: title(id), content: original, target}) || '').trim();
    if (!shorter || shorter.length >= original.length || shorter.length > limits.noteChars) return `Tried to condense ${title(id)}, but the result was not usable. The note is unchanged.`;
    archive(id, original);
    write(id, `${shorter.startsWith('#') ? shorter : `# ${title(id)}\n\n${shorter}`}\n\n_Condensed by Black Team on ${new Date(now()).toISOString().slice(0, 10)}. The full earlier version is in the archive._\n`);
    return `Condensed ${title(id)} from ${original.length.toLocaleString()} to ${shorter.length.toLocaleString()} characters. The original is in the archive.`;
  }
  return {root, notes, graph, read, write, remove, search, core, remember, recall, lookup, journal, usage, sweep, condense, limits};
}

const MEMORY_TOOLS = [
  {type: 'function', function: {name: 'remember', description: 'Save one lasting fact or decision to memory for future conversations. Only things you have verified or the user has told you.', parameters: {type: 'object', properties: {title: {type: 'string', description: 'Short topic, e.g. "Deploy steps"'}, text: {type: 'string'}, project: {type: 'boolean', description: 'true if it is about this project only; false for something true everywhere'}}, required: ['title', 'text']}}},
  {type: 'function', function: {name: 'recall', description: 'Search memory from earlier conversations. Use it when a task refers to past work, preferences or decisions.', parameters: {type: 'object', properties: {query: {type: 'string', description: 'A few keywords'}, note: {type: 'string', description: 'Optional: a note name from an earlier recall, to get the whole note'}}}}},
];

module.exports = {createMemory, MEMORY_TOOLS, CORE, NOTES, PROJECTS, ARCHIVE, LIMITS};
