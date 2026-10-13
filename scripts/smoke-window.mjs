#!/usr/bin/env node
// A short end-to-end check of the Linux window, pressing its buttons the way a person would.
// It prints one PASS or FAIL line per step and exits non-zero if any step failed.
//
//   node scripts/smoke-window.mjs [--app <launcher>] [--data <folder>] [--install <starter id>] [--code] [--port <number>]
//
// --app      the installed launcher to test (for example ~/.local/bin/black-team-desktop); without it, this checkout is run
// --data     keep the app's data under this folder (it is used as XDG_DATA_HOME); without it a fresh folder is used and removed
// --install  when no model is set up yet, download this starter model first (for example qwen3.5-0.8b)
// --code     also run a small coding task in Code; needs a model that can use tools (Ornith 1.5 9B or better)
// --port     the local port the window is driven through (default 19333)
//
// The window appears on the screen while this runs. The app must not already be open on the same data folder.
import { spawn, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const options = { app: '', data: '', install: '', port: '19333', code: false };
for (let i = 2; i < process.argv.length; i++) {
  const name = process.argv[i].replace(/^--/, '');
  if (name === 'code') { options.code = true; continue; }
  if (!(name in options) || process.argv[i + 1] === undefined) { console.error(`Unknown option ${process.argv[i]}`); process.exit(2); }
  options[name] = process.argv[++i];
}
const fresh = !options.data;
const data = path.resolve(options.data || fs.mkdtempSync(path.join(os.tmpdir(), 'black-team-window-')));
fs.mkdirSync(data, { recursive: true, mode: 0o700 });

let failed = false;
const pass = name => console.log(`PASS  ${name}`);
const fail = (name, why = '') => { failed = true; console.log(`FAIL  ${name}${why ? `: ${String(why).replace(/\s+/g, ' ').slice(0, 300)}` : ''}`); };
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const seconds = since => Math.round((Date.now() - since) / 1000);
const modelServers = () => { try { return execFileSync('pgrep', ['-fc', '[l]lama-server'], { encoding: 'utf8' }).trim() | 0; } catch { return 0; } };
const before = modelServers();

const command = options.app ? path.resolve(options.app) : path.join(repo, 'node_modules/electron/dist/electron');
const args = [...(options.app ? [] : [repo]), `--remote-debugging-port=${options.port}`];
const child = spawn(command, args, { env: { ...process.env, XDG_DATA_HOME: data }, stdio: ['ignore', 'ignore', 'pipe'] });
let log = '';
child.stderr.on('data', chunk => { log = (log + chunk).slice(-4000); });
const exited = new Promise(resolve => child.on('exit', resolve));
child.on('error', error => { log += error.message; });

// The window is driven over the Chrome DevTools Protocol with Node's own WebSocket: no extra packages.
async function connect() {
  let target;
  for (let tries = 0; tries < 100 && !target && child.exitCode === null; tries++) {
    try { target = (await (await fetch(`http://127.0.0.1:${options.port}/json/list`)).json()).find(entry => entry.type === 'page' && entry.url.startsWith('http')); } catch {}
    if (!target) await sleep(300);
  }
  if (!target) throw new Error(`the window did not open. ${log.trim().split('\n').slice(-3).join(' ')}`);
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = () => reject(new Error('could not attach to the window')); });
  let last = 0; const waiting = new Map(); const errors = [];
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    if (message.id && waiting.has(message.id)) { waiting.get(message.id)(message); waiting.delete(message.id); }
    else if (message.method === 'Runtime.exceptionThrown') errors.push(message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);
    else if (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error') errors.push(message.params.args.map(arg => arg.value ?? arg.description ?? '').join(' '));
  };
  const send = (method, params = {}) => new Promise(resolve => { const id = ++last; waiting.set(id, resolve); socket.send(JSON.stringify({ id, method, params })); });
  await send('Runtime.enable');
  const run = async expression => {
    const reply = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (reply.result?.exceptionDetails) throw new Error(reply.result.exceptionDetails.exception?.description || 'the window refused a step');
    return reply.result?.result?.value;
  };
  return { send, run, errors, close: () => socket.close() };
}

let page;
const status = async () => JSON.parse(await page.run(`window.blackTeam.request('status').then(JSON.stringify)`));
// Presses the first enabled button whose label (its aria-label, else its text) matches, inside `within` when given.
const press = (label, within = 'document') => page.run(`(() => {
  const root = ${within}; if (!root) return 'the part of the page it belongs to is missing';
  const wanted = ${JSON.stringify(label)};
  const button = [...root.querySelectorAll('button')].find(entry => (entry.getAttribute('aria-label') || entry.innerText.trim()) === wanted);
  if (!button) return 'there is no button named ' + wanted;
  if (button.disabled) return 'the button ' + wanted + ' is switched off';
  button.scrollIntoView({block: 'center'}); button.click(); return '';
})()`);
const until = async (check, timeoutMs, everyMs = 500) => {
  const start = Date.now();
  for (;;) {
    const value = await check();
    if (value) return value;
    if (Date.now() - start > timeoutMs) return null;
    await sleep(everyMs);
  }
};
// What the page shows as a problem: its error banner and any alert.
const shownProblems = () => page.run(`[...document.querySelectorAll('[role=alert], .error-text')].map(entry => entry.innerText.trim()).filter(Boolean).join(' | ')`);

try {
  page = await connect();
  const version = JSON.parse(fs.readFileSync(options.app ? path.join(path.dirname(fs.realpathSync(command)), '../share/black-team/current/resources/app/package.json') : path.join(repo, 'package.json'), 'utf8')).version;
  console.log(`== Black Team Agent window ${version} on ${os.type()} ${os.arch()}, data: ${fresh ? 'a fresh folder' : data}`);

  const opened = await until(() => page.run(`Boolean(document.querySelector('[aria-label="Main navigation"]')) && document.body.innerText.includes('BLACK TEAM AGENT')`), 20000);
  if (opened) pass('the window opens on the command center'); else fail('the window opens on the command center', await page.run(`document.body.innerText.slice(0, 200)`));

  let state = await status();
  if (state.version === version) pass(`the window reports version ${version}`); else fail('the window reports its version', `it says ${state.version}, the package says ${version}`);

  if (!state.setupComplete) {
    const recommended = await until(() => page.run(`document.querySelector('.starter-models .starter-tag')?.closest('li').querySelector('strong').innerText || ''`), 15000);
    if (recommended) pass(`the starter list recommends a model (${recommended})`); else fail('the starter list recommends a model');
    if (options.install) {
      const start = Date.now();
      const list = JSON.parse(await page.run(`window.blackTeam.request('starter-list').then(JSON.stringify)`));
      const name = list.models.find(entry => entry.model.id === options.install)?.model.name;
      const pressed = name ? await press('Download', `[...document.querySelectorAll('.starter-models li')].find(entry => entry.querySelector('strong').innerText === ${JSON.stringify(name)})`) : `no starter model is called ${options.install}`;
      let problem = pressed;
      if (!pressed) {
        const progress = await until(async () => { const now = await status(); return now.starterInstall.running || now.setupComplete; }, 15000);
        if (!progress) problem = 'pressing Download started nothing';
        else {
          const done = await until(async () => { state = await status(); return state.setupComplete || state.starterInstall.error || !state.starterInstall.running; }, 30 * 60000, 1000);
          if (!done) problem = 'the download did not finish in 30 minutes';
          else if (state.starterInstall.error) problem = state.starterInstall.error;
        }
      }
      if (problem) fail(`the Download button sets up starter model ${options.install}`, problem); else { pass(`the Download button sets up starter model ${options.install}`); console.log(`      took ${seconds(start)} s`); }
    } else fail('no model is set up and --install was not given');
  }
  state = await status();
  if (state.setupComplete) pass('a model is set up'); else fail('a model is set up', await shownProblems());

  // Every page and every Settings section opens and shows something, with no error on it.
  const blank = []; let sectionCount = 0;
  for (const name of ['Workspace', 'Chat / Code', 'Room', 'Memory', 'Phone Companion', 'Settings']) {
    const problem = await press(name, `document.querySelector('[aria-label="Main navigation"]')`);
    await sleep(700);
    const text = problem ? '' : await page.run(`(document.querySelector('main') || document.body).innerText.trim()`);
    const shown = await shownProblems();
    if (problem || text.length < 40 || shown) blank.push(`${name}: ${problem || shown || 'the page is empty'}`);
    if (name !== 'Settings' || problem) continue;
    const sections = JSON.parse(await page.run(`JSON.stringify([...document.querySelectorAll('[aria-label="Settings sections"] button')].map(entry => entry.innerText.trim()))`));
    if (!sections.length) blank.push('Settings: no sections are listed');
    sectionCount = sections.length;
    for (const section of sections) {
      const missing = await press(section, `document.querySelector('[aria-label="Settings sections"]')`);
      await sleep(500);
      const body = missing ? '' : await page.run(`(document.querySelector('main') || document.body).innerText.trim()`);
      const alert = await shownProblems();
      if (missing || body.length < 40 || alert) blank.push(`Settings, ${section}: ${missing || alert || 'the section is empty'}`);
    }
  }
  if (blank.length) fail('every page and Settings section opens', blank.join('; ')); else pass(`every page and Settings section opens (6 pages, ${sectionCount} sections)`);

  // A chat, typed and sent the way a person does it.
  if (state.setupComplete) {
    const start = Date.now();
    let problem = await press('Chat / Code', `document.querySelector('[aria-label="Main navigation"]')`);
    await sleep(500);
    problem ||= await press('Black Team Chat');
    await sleep(500);
    problem ||= await page.run(`(() => { const box = document.querySelector('[aria-label="Message your local model"]'); if (!box) return 'there is no message box'; if (box.disabled) return 'the message box is switched off'; box.focus(); return ''; })()`);
    if (!problem) { await page.send('Input.insertText', { text: 'Say hello in one short sentence.' }); await sleep(300); problem = await press('Send message'); }
    let reply = '';
    if (!problem) {
      // Any answer with words in it passes: this tests that the window gets a reply from the model, not how clever the model is.
      // While the model is still loading or writing, the page shows a placeholder, which does not count.
      reply = await until(async () => {
        const now = await status();
        if (now.job && now.job.state === 'running') return '';
        const shown = await page.run(`[...document.querySelectorAll('[aria-label="Conversation"] .message.assistant .message-body')].pop()?.innerText.trim() || ''`);
        return /[\p{L}\p{N}]/u.test(shown) ? shown : '';
      }, 10 * 60000, 1000);
      if (!reply) problem = (await shownProblems()) || 'no reply appeared in 10 minutes';
    }
    if (problem) fail('a chat message typed in the window gets an answer', problem); else { pass('a chat message typed in the window gets an answer'); console.log(`      took ${seconds(start)} s: ${reply.replace(/\s+/g, ' ').slice(0, 80)}`); }
  }

  // A coding task in Code, approved by hand when the agent asks. It works in a folder of its own, never the person's workspace.
  if (options.code && state.setupComplete) {
    const start = Date.now();
    const workspace = path.join(data, 'smoke-workspace');
    fs.mkdirSync(workspace, { recursive: true });
    let problem = '';
    try {
      // The model has to be stopped to change the workspace, and the folder chooser is a system dialog a script cannot press,
      // so this one step asks the engine directly, the same request the Change folder button ends in.
      if (!['off', 'error'].includes((await status()).runtime.state)) {
        await page.run(`window.blackTeam.request('runtime-stop').then(() => '')`);
        await until(async () => ['off', 'error'].includes((await status()).runtime.state), 60000);
      }
      await page.run(`window.blackTeam.request('setup-save', {workspace: ${JSON.stringify(workspace)}}).then(() => '')`);
      if ((await status()).config.workspace !== workspace) problem = 'the workspace could not be set to the test folder';
    } catch (error) { problem = error.message; }
    problem ||= await press('Chat / Code', `document.querySelector('[aria-label="Main navigation"]')`);
    await sleep(500);
    problem ||= await press('Black Team Code');
    await sleep(500);
    problem ||= await page.run(`(() => { const box = document.querySelector('[aria-label="Describe a task for Code"]'); if (!box) return 'there is no task box'; if (box.disabled) return 'the task box is switched off'; box.focus(); return ''; })()`);
    if (!problem) { await page.send('Input.insertText', { text: 'Create a file named smoke.txt containing the single line: smoke test ok' }); await sleep(300); problem = await press('Run task'); }
    const written = () => { try { return fs.readFileSync(path.join(workspace, 'smoke.txt'), 'utf8').includes('smoke test ok'); } catch { return false; } };
    let approvals = 0;
    if (!problem) {
      await until(async () => (await status()).job?.state === 'running', 15000);
      const finished = await until(async () => {
        if (!(await press('Approve once'))) { approvals++; await sleep(1000); return false; }
        return (await status()).job?.state !== 'running';
      }, 20 * 60000, 1000);
      if (!finished) problem = 'the task was still running after 20 minutes';
      else if (!written()) problem = `smoke.txt is missing or wrong. ${await shownProblems() || await page.run(`[...document.querySelectorAll('[aria-label="Conversation"] .message.assistant .message-body')].pop()?.innerText.trim() || ''`)}`;
    }
    if (problem) fail('a coding task run from the window writes the file it was asked for', problem); else { pass('a coding task run from the window writes the file it was asked for'); console.log(`      took ${seconds(start)} s, ${approvals} approval${approvals === 1 ? '' : 's'} given`); }
  }

  if (page.errors.length) fail('the window reported no errors of its own', [...new Set(page.errors)].slice(0, 3).join(' | ')); else pass('the window reported no errors of its own');
} catch (error) {
  fail('the test could not continue', error.message);
}

// Closing the way the Quit menu does: the app stops its engine and its model before it exits.
page?.close();
if (child.exitCode === null) child.kill('SIGTERM');
const code = await Promise.race([exited, sleep(30000).then(() => 'timeout')]);
if (code === 'timeout') { fail('the window closes when asked', 'it was still open after 30 s'); child.kill('SIGKILL'); } else pass('the window closes when asked');
await sleep(2000);
const after = modelServers();
if (after <= before) pass('no model server was left running'); else fail('no model server was left running', `${before} before, ${after} after`);
if (fresh) fs.rmSync(data, { recursive: true, force: true });

console.log(failed ? '== SOMETHING FAILED' : '== ALL PASSED');
process.exit(failed ? 1 : 0);
