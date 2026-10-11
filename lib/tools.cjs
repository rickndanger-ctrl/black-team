'use strict';
// Black Team Code tools. Small schemas, small results: on a local model every token read costs time.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawn, execFile, execFileSync} = require('node:child_process');

const os = require('node:os');
const SECRET = /(^|\/)(\.ssh|\.gnupg|\.aws|\.env(\..*)?|.*\.key|.*\.pem|id_[a-z0-9]+|credentials(\..*)?|auth\.json|\.netrc)(\/|$)/i;
// Commands that change the system, reach the network, or delete things wait for the user's approval.
const RISKY = /(^|[;&|`(\s])(sudo|su|rm|rmdir|mv|dd|mkfs|shred|truncate|chmod|chown|kill|pkill|killall|shutdown|reboot|systemctl|loginctl|crontab|curl|wget|ssh|scp|sftp|rsync|nc|ncat|telnet|tailscale|docker|podman|pacman|yay|apt|dnf|pip3?\s+(install|uninstall)|uv\s+(pip|tool|add)|npm\s+(i|install|uninstall|publish|exec)|npx|pnpm|yarn|git\s+(push|reset|clean|rebase|checkout\s+--|restore|stash\s+drop|branch\s+-D))(\s|$)|(^|\s)(\/etc\/|\/usr\/|\/boot\/|\/var\/|~\/\.|\$HOME\/\.)|(^|[\s\/"'=])\.(config|local|ssh|gnupg|aws|kube|docker|pki|netrc|npmrc)(\/|\s|"|'|$)/;

// Every edit keeps what the file held before, so the change can be shown and undone.
const sha = text => crypto.createHash('sha256').update(text).digest('hex');
function recordChange(dir, root, file, before, after) {
  fs.mkdirSync(dir, {recursive: true, mode: 0o700});
  const id = crypto.randomBytes(12).toString('hex'), name = path.relative(root, file);
  const old = path.join(dir, `${id}.before`);
  fs.writeFileSync(old, before ?? '', {mode: 0o600});
  let diff = '';
  try {execFileSync('diff', ['-u', '--label', `a/${name}`, '--label', `b/${name}`, old, file], {encoding: 'utf8', maxBuffer: 8 * 1024 * 1024});}
  catch (error) {diff = error.status === 1 ? String(error.stdout) : '';}
  fs.rmSync(old, {force: true});
  const body = diff.split('\n').filter(line => !line.startsWith('+++') && !line.startsWith('---'));
  fs.writeFileSync(path.join(dir, `${id}.json`), JSON.stringify({root, file, existed: before !== null, before: before ?? '', after: sha(after)}), {mode: 0o600});
  const kept = fs.readdirSync(dir).filter(entry => entry.endsWith('.json')).map(entry => ({entry, at: fs.statSync(path.join(dir, entry)).mtimeMs})).sort((a, b) => b.at - a.at);
  for (const stale of kept.slice(300)) fs.rmSync(path.join(dir, stale.entry), {force: true});
  return {id, path: name, created: before === null, added: body.filter(line => line.startsWith('+')).length, removed: body.filter(line => line.startsWith('-')).length, diff: diff.length > 6000 ? `${diff.slice(0, 6000)}\n… the rest of this change is not shown …` : diff};
}
// Puts a file back as it was before one edit. Refuses when the file has changed again since, so a later edit is never lost.
function undoChange(dir, id) {
  if (typeof id !== 'string' || !/^[a-f0-9]{24}$/.test(id)) throw new Error('That change is no longer available.');
  const record = path.join(dir, `${id}.json`);
  let saved; try {saved = JSON.parse(fs.readFileSync(record, 'utf8'));} catch {throw new Error('That change is no longer available.');}
  const root = fs.realpathSync(saved.root), folder = fs.realpathSync(path.dirname(saved.file));
  if (folder !== root && !folder.startsWith(root + path.sep)) throw new Error('That file is no longer inside its workspace.');
  if (!fs.existsSync(saved.file) || sha(fs.readFileSync(saved.file, 'utf8')) !== saved.after) throw new Error('The file has changed since this edit, so it was not undone. Undo the later change first.');
  if (saved.existed) fs.writeFileSync(saved.file, saved.before); else fs.rmSync(saved.file);
  fs.rmSync(record, {force: true});
  return {path: path.relative(root, saved.file), removed: !saved.existed};
}

const param = (properties, required = []) => ({type: 'object', properties, required});
const SCHEMAS = [
  ['read', 'Read lines of a text file, numbered. Search first; read only what you need.', param({path: {type: 'string'}, start: {type: 'integer', description: 'First line, from 1'}, lines: {type: 'integer', description: 'How many lines'}}, ['path'])],
  ['search', 'Search file contents with a regular expression (ripgrep). Returns path:line:text.', param({pattern: {type: 'string'}, path: {type: 'string', description: 'File or folder; default workspace'}, glob: {type: 'string', description: 'e.g. *.py'}}, ['pattern'])],
  ['list', 'List a folder.', param({path: {type: 'string'}})],
  ['edit', 'Replace one exact piece of text in a file. `old` must match exactly once.', param({path: {type: 'string'}, old: {type: 'string'}, new: {type: 'string'}}, ['path', 'old', 'new'])],
  ['write', 'Create or overwrite a file in the workspace.', param({path: {type: 'string'}, content: {type: 'string'}}, ['path', 'content'])],
  ['run', 'Run a shell command in the workspace. Output is shortened; pipe long output through tail.', param({command: {type: 'string'}, timeout: {type: 'integer', description: 'Seconds, default 120'}}, ['command'])],
  ['todo', 'Replace your todo list. Keep it current: it survives when older tool output is trimmed.', param({items: {type: 'array', items: {type: 'object', properties: {text: {type: 'string'}, done: {type: 'boolean'}}, required: ['text']}}}, ['items'])],
  ['publish', 'Attach a finished workspace file to the conversation so it can be downloaded on the phone.', param({path: {type: 'string'}}, ['path'])],
  ['map', 'Ask the code map of the workspace which files and functions relate to a question. Returns names with paths and line numbers. Use it before reading many files. Code only.', param({question: {type: 'string'}, refresh: {type: 'boolean', description: 'Rebuild the map first, after large changes'}}, ['question'])],
].map(([name, description, parameters]) => ({type: 'function', function: {name, description, parameters}}));

function clip(text, limit) {
  if (text.length <= limit) return text;
  const head = Math.floor(limit * 0.6), tail = limit - head;
  return `${text.slice(0, head)}\n… ${text.length - limit} characters left out …\n${text.slice(-tail)}`;
}

// graph: the graphify executable, when installed; its map of the workspace is kept under graphDir, not in the project.
function createTools({workspace, artifacts, undoDir, home = os.homedir(), owner = 'The user', deny = [], limit = () => 8000, ask = async () => 'deny', signal, useRtk = true, graph = '', graphDir = ''}) {
  const root = fs.realpathSync(workspace);
  const HOME = fs.realpathSync(home);
  // Black Team's own data (settings, conversations, memory vault) is not the model's to read as files.
  const denied = deny.map(folder => {try {return fs.realpathSync(folder);} catch {return path.resolve(folder);}});
  const state = {todo: [], mapStale: false};
  const relative = file => path.relative(root, file) || '.';

  // Resolve a model-supplied path. Reads stay inside the home folder; writes stay inside the workspace.
  function resolve(input, {write = false} = {}) {
    if (typeof input !== 'string' || !input || input.includes('\0')) throw new Error('Give a file path.');
    const expanded = input.startsWith('~/') ? path.join(HOME, input.slice(2)) : input;
    const target = path.resolve(root, expanded);
    let existing = target;
    while (!fs.existsSync(existing)) existing = path.dirname(existing);
    const real = path.join(fs.realpathSync(existing), path.relative(existing, target));
    const inside = base => real === base || real.startsWith(base + path.sep);
    if (!(inside(root) || (!write && inside(HOME)))) throw new Error(`${write ? 'You can write only inside the workspace' : 'That path is outside the folders you can read'}. Use a path relative to the workspace, such as notes.txt or src/app.js. Call list with no path to see the workspace.`);
    if (SECRET.test(real)) throw new Error('That file holds credentials and is off limits.');
    if (denied.some(inside)) throw new Error('That folder is Black Team\u2019s private data and is off limits. Use recall for memory.');
    return real;
  }

  const tools = {
    read({path: input, start = 1, lines = 200}) {
      const file = resolve(input);
      const stat = fs.statSync(file);
      if (!stat.isFile()) throw new Error('Not a file. Use list for folders.');
      if (stat.size > 5 * 1024 * 1024) throw new Error('File is over 5 MB. Use search, or run with head/tail.');
      const all = fs.readFileSync(file, 'utf8').split('\n');
      if (all.at(-1) === '') all.pop();
      const from = Math.max(1, Math.floor(start) || 1), count = Math.max(1, Math.min(Math.floor(lines) || 200, 2000));
      const rows = [], budget = limit();
      let used = 0, last = from - 1;
      for (let n = from; n <= Math.min(all.length, from + count - 1); n++) {
        const row = `${n}|${all[n - 1].length > 400 ? all[n - 1].slice(0, 400) + '…' : all[n - 1]}`;
        if (used + row.length + 1 > budget && rows.length) break;
        rows.push(row); used += row.length + 1; last = n;
      }
      const more = last < all.length ? ` Next: start=${last + 1}.` : '';
      return {output: `${rows.join('\n')}\n(lines ${from}-${last} of ${all.length}.${more})`, log: `read ${relative(file)} ${from}-${last} of ${all.length}`};
    },
    async search({pattern, path: input = '.', glob}) {
      if (typeof pattern !== 'string' || !pattern) throw new Error('Give a pattern.');
      const target = resolve(input);
      const text = await grep(pattern, target, typeof glob === 'string' && glob ? glob : null);
      // Search recurses, so every result is held to the same rules as read: no credential files, no private data.
      const allowed = row => {
        const match = /^(.+?):\d+:/.exec(row); if (!match) return true;
        let real; try {real = fs.realpathSync(path.resolve(root, match[1]));} catch {return false;}
        return !SECRET.test(real) && !denied.some(folder => real === folder || real.startsWith(folder + path.sep));
      };
      const rows = text.split('\n').filter(Boolean).filter(allowed).map(row => row.startsWith(root + path.sep) ? row.slice(root.length + 1) : row);
      const shown = [], budget = limit();
      let used = 0;
      for (const row of rows) {if (used + row.length + 1 > budget || shown.length >= 80) break; shown.push(row); used += row.length + 1;}
      const note = rows.length > shown.length ? `\n(${rows.length - shown.length} more matches. Narrow the pattern or path.)` : '';
      return {output: shown.length ? shown.join('\n') + note : 'No matches.', log: `search ${JSON.stringify(pattern)} in ${relative(target)} → ${rows.length} lines`};
    },
    list({path: input = '.'} = {}) {
      const dir = resolve(input);
      const entries = fs.readdirSync(dir, {withFileTypes: true}).sort((a, b) => Number(b.isDirectory()) - Number(a.isDirectory()) || a.name.localeCompare(b.name));
      const rows = entries.slice(0, 200).map(entry => entry.isDirectory() ? `${entry.name}/` : `${entry.name}  ${fs.statSync(path.join(dir, entry.name), {throwIfNoEntry: false})?.size ?? '?'} bytes`);
      return {output: (rows.join('\n') || '(empty)') + (entries.length > 200 ? `\n(${entries.length - 200} more)` : ''), log: `list ${relative(dir)} (${entries.length})`};
    },
    edit({path: input, old, new: next}) {
      const file = resolve(input, {write: true});
      if (typeof old !== 'string' || !old || typeof next !== 'string') throw new Error('Give old and new text.');
      const text = fs.readFileSync(file, 'utf8');
      const count = text.split(old).length - 1;
      if (count === 0) throw new Error('`old` was not found. Read the lines again and copy them exactly.');
      if (count > 1) throw new Error(`\`old\` matches ${count} places. Include more surrounding text so it matches once.`);
      const updated = text.replace(old, () => next);
      atomicWrite(file, updated);
      const change = recordChange(undoDir, root, file, text, updated);
      state.mapStale = true;
      const delta = `+${change.added} −${change.removed} lines`;
      return {output: `Edited ${relative(file)} (${delta}).`, log: `edit ${relative(file)} (${delta})`, change};
    },
    write({path: input, content}) {
      const file = resolve(input, {write: true});
      if (typeof content !== 'string') throw new Error('Give the file content.');
      if (content.length > 400000) throw new Error('Content is too large for one write.');
      fs.mkdirSync(path.dirname(file), {recursive: true});
      const existed = fs.existsSync(file);
      const before = existed ? fs.readFileSync(file, 'utf8') : null;
      atomicWrite(file, content);
      const change = recordChange(undoDir, root, file, before, content);
      state.mapStale = true;
      return {output: `${existed ? 'Overwrote' : 'Created'} ${relative(file)} (${Buffer.byteLength(content)} bytes).`, log: `write ${relative(file)} (${Buffer.byteLength(content)} bytes)`, change};
    },
    async run({command, timeout = 120}) {
      if (typeof command !== 'string' || !command.trim() || command.length > 4000) throw new Error('Give one shell command.');
      if (RISKY.test(command) || SECRET.test(command) || denied.some(folder => command.includes(path.basename(folder)))) {
        const choice = await ask({command, description: 'Run this command on your computer?'});
        if (choice !== 'once') return {output: `${owner} declined this command. Do not retry it; continue another way or ask.`, log: `run declined: ${command.slice(0, 100)}`, error: true};
      }
      const actual = useRtk ? await rewrite(command) : command;
      if (signal?.aborted) throw new Error('Stopped before the command ran.');
      const seconds = Math.max(1, Math.min(Math.floor(timeout) || 120, 600));
      const result = await execute(actual, seconds);
      const status = result.timedOut ? `timed out after ${seconds}s` : `exit ${result.code}`;
      const lastLine = result.text.trim().split('\n').at(-1)?.slice(0, 120) || '';
      return {output: `${status}\n${clip(result.text.trim() || '(no output)', limit())}`, log: `run: ${command.slice(0, 100)} → ${status}${lastLine ? `: ${lastLine}` : ''}`, error: result.timedOut || result.code !== 0};
    },
    // The map is graphify's code graph of the workspace: built on first use, rebuilt after this
    // conversation edits files, after ten minutes, or on request. Queries stay within the result budget.
    async map({question, refresh = false}) {
      if (!graph || !graphDir) throw new Error('No code map tool is installed on this computer.');
      if (typeof question !== 'string' || !question.trim() || question.length > 500) throw new Error('Ask one question about the code.');
      const dir = path.join(graphDir, sha(root).slice(0, 16)), file = path.join(dir, 'graphify-out', 'graph.json');
      let age = Infinity;
      try {age = Date.now() - fs.statSync(file).mtimeMs;} catch {}
      let note = '';
      if (refresh === true || state.mapStale || age > 10 * 60 * 1000) {
        fs.mkdirSync(dir, {recursive: true, mode: 0o700});
        const built = await program(graph, ['extract', root, '--code-only', '--out', dir], 300);
        if (built.timedOut || !fs.existsSync(file)) throw new Error(`The code map could not be built${built.timedOut ? ' in five minutes' : ''}: ${built.text.trim().split('\n').at(-1)?.slice(0, 200) || 'no output'}`);
        state.mapStale = false;
        note = `Map ${age === Infinity ? 'built' : 'rebuilt'}. `;
      }
      const tokens = Math.max(400, Math.min(2000, Math.floor(limit() / 3.5 * 0.8)));
      const answer = await program(graph, ['query', question.trim(), '--graph', file, '--budget', String(tokens)], 120);
      const text = answer.text.trim();
      if (answer.timedOut || answer.code !== 0 || /^error:/im.test(text)) throw new Error(`The code map could not answer: ${text.split('\n').at(-1)?.slice(0, 200) || 'no output'}`);
      return {output: note + clip(text, limit()), log: `map: ${question.trim().slice(0, 80)}`};
    },
    todo({items}) {
      if (!Array.isArray(items) || items.length > 40) throw new Error('Give up to 40 items.');
      state.todo = items.map(item => ({text: String(item?.text ?? '').slice(0, 200), done: item?.done === true})).filter(item => item.text);
      return {output: renderTodo(state.todo), log: null};
    },
    publish({path: input}) {
      const file = resolve(input, {write: true});
      const stat = fs.statSync(file);
      if (!stat.isFile()) throw new Error('Publish a regular file; zip folders first.');
      if (stat.size > 250 * 1024 * 1024) throw new Error('File exceeds the 250 MB limit.');
      const id = crypto.randomBytes(16).toString('hex');
      const dest = path.join(artifacts, id);
      fs.copyFileSync(file, dest); fs.chmodSync(dest, 0o600);
      const artifact = {id, name: path.basename(file), size: stat.size, sha256: crypto.createHash('sha256').update(fs.readFileSync(dest)).digest('hex')};
      return {output: `Attached ${artifact.name} (${artifact.size} bytes) to the conversation.`, log: `publish ${relative(file)}`, artifact};
    },
  };

  // ripgrep when it is installed; plain grep otherwise, so search works on any Linux system.
  function grep(pattern, target, glob) {
    const run = (command, args) => new Promise(done => execFile(command, args, {cwd: root, timeout: 20000, maxBuffer: 4 * 1024 * 1024}, (error, stdout, stderr) => done({missing: error?.code === 'ENOENT', text: error && error.code !== 1 && !stdout ? `search failed: ${String(stderr || error.message).slice(0, 300)}` : stdout})));
    const rg = ['-n', '-H', '--no-heading', '--color', 'never', '--max-columns', '240', '--max-columns-preview', '-m', '20', '--sort', 'path', ...(glob ? ['-g', glob] : []), '-e', pattern, '--', target];
    const plain = ['-rnIEH', '-m', '20', '--exclude-dir=.git', '--exclude-dir=node_modules', ...(glob ? [`--include=${glob}`] : []), '-e', pattern, '--', target];
    return run('rg', rg).then(result => result.missing ? run('grep', plain).then(fallback => fallback.missing ? 'search failed: install ripgrep or grep.' : fallback.text.split('\n').map(row => row.slice(0, 300)).join('\n')) : result.text);
  }
  function atomicWrite(file, content) {
    const temporary = `${file}.${crypto.randomBytes(6).toString('hex')}.tmp`;
    const mode = fs.existsSync(file) ? fs.statSync(file).mode & 0o777 : 0o644;
    fs.writeFileSync(temporary, content, {mode});
    fs.renameSync(temporary, file);
  }
  // RTK shortens noisy command output. It is optional and fails open.
  function rewrite(command) {
    return new Promise(done => execFile('rtk', ['rewrite', command], {timeout: 2000}, (error, stdout) => {
      const code = error ? error.code : 0;
      done([0, 3].includes(code) && stdout.trim() ? stdout.trim() : command);
    }));
  }
  // A program run without a shell, with the same bounded environment and the same stop handling.
  const program = (file, args, seconds) => execute(null, seconds, [file, args]);
  function execute(command, seconds, direct = null) {
    return new Promise(done => {
      const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => /^(PATH|HOME|USER|LANG|LC_[A-Z_]+|TERM|TMPDIR|XDG_RUNTIME_DIR)$/.test(key)));
      const child = spawn(direct ? direct[0] : 'bash', direct ? direct[1] : ['-c', command], {cwd: root, env: {...env, TERM: 'dumb', NO_COLOR: '1'}, detached: true, stdio: ['ignore', 'pipe', 'pipe']});
      let text = '', timedOut = false, settled = false;
      const add = chunk => {if (text.length < 2 * 1024 * 1024) text += chunk;};
      const stop = () => {try {process.kill(-child.pid, 'SIGTERM');} catch {} setTimeout(() => {try {process.kill(-child.pid, 'SIGKILL');} catch {}}, 3000).unref();};
      const timer = setTimeout(() => {timedOut = true; stop();}, seconds * 1000);
      const finish = code => {if (settled) return; settled = true; clearTimeout(timer); signal?.removeEventListener('abort', stop); child.stdout.destroy(); child.stderr.destroy(); done({code: code ?? 1, text, timedOut});};
      signal?.addEventListener('abort', stop, {once: true});
      child.stdout.on('data', add); child.stderr.on('data', add);
      child.on('error', error => {add(String(error.message)); finish(127);});
      child.on('close', finish);
      // A command that leaves a background process holding the output open never closes; its own exit is enough.
      child.on('exit', code => setTimeout(() => finish(code), 500).unref());
    });
  }

  async function call(name, args) {
    if (!Object.hasOwn(tools, name)) return {output: `Unknown tool ${name}. Tools: ${Object.keys(tools).join(', ')}.`, error: true, log: null};
    try {return await tools[name](args && typeof args === 'object' ? args : {});}
    catch (error) {return {output: `Error: ${error.code === 'ENOENT' ? 'No such file or folder. Paths are relative to the workspace; call list with no path to see what is there.' : error.message}`, error: true, log: null};}
  }
  return {schemas: graph && graphDir ? SCHEMAS : SCHEMAS.filter(schema => schema.function.name !== 'map'), call, state};
}

function renderTodo(items) {
  return items.length ? items.map(item => `[${item.done ? 'x' : ' '}] ${item.text}`).join('\n') : '(empty)';
}

module.exports = {createTools, undoChange, renderTodo, clip, SCHEMAS, RISKY, SECRET};
