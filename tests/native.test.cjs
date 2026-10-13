'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { EventEmitter } = require('node:events');

const project = path.resolve(__dirname, '..');
const origin = 'http://127.0.0.1:18199';
const ready = {
  ready: true,
  origin,
  bootstrapURL: `${origin}/bootstrap?key=k`,
  dataFolder: '/data/black-team-data',
};
// Same rule as main.cjs: XDG_DATA_HOME when it is absolute, otherwise ~/.local/share.
const dataRoot = process.env.XDG_DATA_HOME && path.isAbsolute(process.env.XDG_DATA_HOME) ? process.env.XDG_DATA_HOME : path.join(os.homedir(), '.local/share');
const stateDir = path.join(dataRoot, 'black-team-data');
const hermesURL = 'https://github.com/NousResearch/hermes-agent#installation';
const settle = () => new Promise(resolve => setImmediate(resolve));

// Loads main.cjs with a mocked electron and a fake engine client. The fake engine echoes every request as {action, data}
// unless a test sets a reply in world.replies; the status it returns is world.status.
async function boot({ startError = null } = {}) {
  const captured = { errors: [], prompts: [], opened: [], quit: undefined };
  const world = {
    status: { job: { state: 'done' }, runtime: { busy: false } },
    messageChoice: 0,
    openPathError: '',
    replies: new Map(),
  };
  const handlers = new Map();
  const app = new EventEmitter();
  Object.assign(app, {
    setName: name => { captured.name = name; },
    setPath: (name, value) => { captured[name] = value; },
    requestSingleInstanceLock: () => true,
    whenReady: async () => {},
    getVersion: () => '0.1.0-test',
    quit: () => { captured.quit = true; },
    isPackaged: true,
  });
  class BrowserWindow extends EventEmitter {
    constructor(options) {
      super();
      captured.options = options;
      captured.window = this;
      this.webContents = new EventEmitter();
      this.webContents.mainFrame = { url: `${origin}/` };
      this.webContents.setWindowOpenHandler = callback => { captured.popup = callback; };
    }
    async loadURL(url) { captured.loaded = url; }
    show() {}
    focus() {}
    isMinimized() { return false; }
    isDestroyed() { return false; }
  }
  const defaultSession = {
    setPermissionRequestHandler: callback => { captured.permissionRequest = callback; },
    setPermissionCheckHandler: callback => { captured.permissionCheck = callback; },
    webRequest: { onBeforeRequest: callback => { captured.network = callback; } },
  };
  class FakeEngineClient extends EventEmitter {
    constructor(options) {
      super();
      this.options = options;
      this.requests = [];
      this.stopCalls = 0;
      this.onStop = null;
      captured.engine = this;
      captured.engineOptions = options;
    }
    async start() {
      if (startError) throw startError;
      return ready;
    }
    async request(action, data) {
      this.requests.push([action, data]);
      if (world.replies.has(action)) return world.replies.get(action)(data);
      if (action === 'status') return world.status;
      if (action === 'setup-help') return { url: hermesURL };
      if (action === 'open-data') return { path: stateDir };
      return { action, data };
    }
    async stop() {
      this.stopCalls++;
      if (this.onStop) this.onStop();
    }
  }
  const electron = {
    app, BrowserWindow,
    ipcMain: { handle: (name, callback) => { handlers.set(name, callback); } },
    dialog: {
      showErrorBox: (...args) => captured.errors.push(args),
      showMessageBoxSync: (_window, options) => { captured.prompts.push(options); return world.messageChoice; },
      showOpenDialog: async (_window, options) => { captured.dialogOptions = options; return { canceled: true, filePaths: [] }; },
    },
    shell: {
      openExternal: async value => { captured.opened.push(value); },
      openPath: async value => { captured.opened.push(value); return world.openPathError; },
    },
    Menu: {
      setApplicationMenu: () => {},
      buildFromTemplate: template => { captured.menu = template; return template; },
    },
    session: { defaultSession },
  };
  const mockedRequire = name => {
    if (name === 'electron') return electron;
    if (name === 'node:path' || name === 'node:os') return require(name);
    // The data folder is recorded, not created, so a test never touches the real one.
    if (name === 'node:fs') return {
      ...fs,
      mkdirSync: dir => { captured.privateDir = dir; },
      chmodSync: () => {},
      lstatSync: () => ({ isSymbolicLink: () => false }),
    };
    if (name === './engine-client.cjs') return {
      EngineClient: FakeEngineClient,
      resolveEngine: options => { captured.resolveOptions = options; return '/engine/black-team'; },
    };
    throw new Error(`Unexpected require in main.cjs: ${name}`);
  };
  vm.runInNewContext(fs.readFileSync(path.join(project, 'main.cjs'), 'utf8'), {
    require: mockedRequire, __dirname: project, process, URL, Buffer, console,
  }, { filename: 'main.cjs' });
  await settle();
  if (!startError) {
    assert.deepEqual(captured.errors, []);
    assert.ok(captured.window, 'main process completed setup');
  }
  const event = () => ({ sender: captured.window.webContents, senderFrame: captured.window.webContents.mainFrame });
  return { captured, world, handlers, event, app };
}

test('native boot keeps the renderer sandboxed and loads the engine bootstrap page', async () => {
  const { captured } = await boot();
  assert.equal(captured.name, 'Black Team');
  assert.equal(captured.userData, path.join(stateDir, 'desktop'));
  assert.equal(captured.options.webPreferences.sandbox, true);
  assert.equal(captured.options.webPreferences.contextIsolation, true);
  assert.equal(captured.options.webPreferences.nodeIntegration, false);
  assert.equal(captured.options.webPreferences.webSecurity, true);
  assert.equal(captured.options.webPreferences.devTools, false);
  assert.equal(captured.loaded, ready.bootstrapURL);
  // Nothing is asked of the engine during boot, so no model starts by itself.
  assert.deepEqual(captured.engine.requests, []);
});

test('the engine is started as desktop-service for this window with a private data folder', async () => {
  const { captured } = await boot();
  assert.equal(captured.resolveOptions.dirname, project);
  assert.equal(captured.engineOptions.command, '/engine/black-team');
  // Arrays cross the vm boundary, so compare them as JSON.
  assert.equal(JSON.stringify(captured.engineOptions.args), JSON.stringify([
    'desktop-service', '--web', path.join(project, 'dist'), '--version', '0.1.0-test',
    '--data', stateDir, '--scripts', path.join(project, 'scripts'),
  ]));
  assert.equal(captured.privateDir, stateDir);
});

test('native renderer blocks remote network, navigation, popup, webview and permission requests', async () => {
  const { captured } = await boot();
  for (const url of ['https://example.com/', 'http://127.0.0.1:18198/', 'file:///etc/passwd', 'http://localhost:18199/']) {
    let denied;
    captured.network({ url }, result => { denied = result.cancel; });
    assert.equal(denied, true, url);
  }
  let cancelled;
  captured.network({ url: 'http://127.0.0.1:18199/api/status' }, result => { cancelled = result.cancel; });
  assert.equal(cancelled, false);
  let permission;
  captured.permissionRequest(null, 'media', value => { permission = value; });
  assert.equal(permission, false);
  assert.equal(captured.permissionCheck(null, 'clipboard-read'), false);
  assert.equal(captured.popup({ url: 'https://example.com' }).action, 'deny');
  for (const url of ['https://example.com', 'file:///etc/passwd', `${origin}/other`]) {
    let blocked = false;
    captured.window.webContents.emit('will-navigate', { preventDefault: () => { blocked = true; } }, url);
    assert.equal(blocked, true, url);
  }
  let blocked = false;
  captured.window.webContents.emit('will-navigate', { preventDefault: () => { blocked = true; } }, `${origin}/`);
  assert.equal(blocked, false);
  captured.window.webContents.emit('will-attach-webview', { preventDefault: () => { blocked = true; } });
  assert.equal(blocked, true);
});

test('desktop IPC requires the exact owned main frame and only approved actions and chooser types', async () => {
  const { handlers, event, captured, world } = await boot();
  const request = handlers.get('black-team:request');
  const picker = handlers.get('black-team:pick');
  // The status is the engine's reply, passed through unchanged.
  assert.equal(await request(event(), 'status'), world.status);
  await assert.rejects(request({ ...event(), sender: new EventEmitter() }, 'status'), /unavailable/);
  await assert.rejects(request({ ...event(), senderFrame: { url: `${origin}/` } }, 'status'), /unavailable/);
  const mainFrame = captured.window.webContents.mainFrame;
  mainFrame.url = 'https://example.com/';
  await assert.rejects(request(event(), 'runtime-start'), /unavailable/);
  mainFrame.url = `${origin}/`;
  await assert.rejects(request(event(), 'exec-shell', { command: 'anything' }), /Unsupported/);
  await assert.rejects(request(event(), 'status', []), /Invalid desktop request/);
  await assert.rejects(picker(event(), 'arbitrary-file'), /Unsupported chooser/);
  assert.equal(await picker(event(), 'model'), null);
  assert.equal(captured.dialogOptions.filters[0].extensions[0], 'gguf');
  // Rejected calls never reach the engine; only the status above did.
  assert.deepEqual(captured.engine.requests.map(([action]) => action), ['status']);
});

test('preload bridge exposes no general IPC and rejects unapproved calls before IPC', async () => {
  let bridge;
  const invocations = [];
  vm.runInNewContext(fs.readFileSync(path.join(project, 'preload.cjs'), 'utf8'), {
    require: name => {
      assert.equal(name, 'electron');
      return {
        contextBridge: { exposeInMainWorld: (name, value) => { assert.equal(name, 'blackTeam'); bridge = value; } },
        ipcRenderer: { invoke: async (...args) => { invocations.push(args); return { ok: true }; } },
      };
    },
  }, { filename: 'preload.cjs' });
  assert.deepEqual(Object.keys(bridge).sort(), ['pick', 'request']);
  assert.equal(Object.isFrozen(bridge), true);
  await assert.rejects(bridge.request('exec', { command: 'anything' }), /Unsupported desktop action/);
  await assert.rejects(bridge.pick('directory-outside-contract'), /Unsupported chooser/);
  assert.equal(invocations.length, 0);
  await bridge.request('status');
  await bridge.pick('runtime');
  assert.equal(invocations[0][0], 'black-team:request');
  assert.equal(invocations[0][1], 'status');
  assert.equal(invocations[1][0], 'black-team:pick');
  assert.equal(invocations[1][1], 'runtime');
  const preload = fs.readFileSync(path.join(project, 'preload.cjs'), 'utf8');
  assert.match(preload, /'server-discover','model-inspect',/);
});

test('every read and change action is forwarded to the engine with its input and its reply returned', async () => {
  const { handlers, event } = await boot();
  const request = handlers.get('black-team:request');
  const actions = [
    'server-discover', 'models-find', 'model-inspect', 'installed-discover', 'hermes-inspect', 'phone-detect', 'phone-command',
    'integrations-save', 'harness-connect', 'harness-launch', 'setup-save', 'models-add', 'models-ignore', 'model-switch',
    'model-forget', 'runtime-start', 'runtime-stop', 'phone-save', 'phone-setup', 'phone-off', 'phone-connect', 'phone-disconnect',
  ];
  for (const action of actions) {
    const input = { probe: action };
    // The fake engine echoes what it was asked, so an equal reply proves both the action and the input were forwarded.
    assert.equal(JSON.stringify(await request(event(), action, input)), JSON.stringify({ action, data: input }), action);
  }
});

test('setup mutations stay locked until the engine answers and unlock after failure', async () => {
  let finish;
  const waiting = new Promise((_resolve, reject) => { finish = reject; });
  const { handlers, event, captured, world } = await boot();
  world.replies.set('phone-setup', () => waiting);
  const request = handlers.get('black-team:request');
  const setup = request(event(), 'phone-setup');
  const failure = assert.rejects(setup, /setup failed/);
  await assert.rejects(request(event(), 'runtime-start'), /Another setup action is still running\./);
  assert.deepEqual(captured.engine.requests.map(([action]) => action), ['phone-setup']);
  finish(new Error('setup failed'));
  await failure;
  await request(event(), 'runtime-start');
  assert.deepEqual(captured.engine.requests.map(([action]) => action), ['phone-setup', 'runtime-start']);
});

test('installation help only opens the engine-provided destination and new choosers retain native boundaries', async () => {
  const { handlers, event, captured } = await boot();
  const request = handlers.get('black-team:request');
  await assert.rejects(request(event(), 'setup-help', { topic: 'https://example.com' }), /Unsupported setup help\./);
  assert.deepEqual(captured.opened, []);
  assert.equal((await request(event(), 'setup-help', { topic: 'hermes' })).opened, true);
  assert.deepEqual(captured.opened, [hermesURL]);
  assert.deepEqual(captured.engine.requests, [['setup-help', { topic: 'hermes' }]]);
  const picker = handlers.get('black-team:pick');
  await picker(event(), 'hermes-source');
  assert.equal(captured.dialogOptions.properties[0], 'openDirectory');
  await picker(event(), 'executable');
  assert.equal(captured.dialogOptions.properties[0], 'openFile');
});

test('open-data asks the engine for the folder, the menu opens it too, and a failure is reported', async () => {
  const { handlers, event, captured, world } = await boot();
  const request = handlers.get('black-team:request');
  assert.equal((await request(event(), 'open-data')).opened, true);
  assert.deepEqual(captured.opened, [stateDir]);
  const openItem = captured.menu.find(item => item.label === 'Black Team Agent').submenu.find(item => item.label === 'Open data folder');
  await openItem.click();
  assert.deepEqual(captured.opened, [stateDir, stateDir]);
  world.openPathError = 'no application for folders';
  await assert.rejects(request(event(), 'open-data'), /Could not open the application data folder\./);
});

test('closing the window asks only while a response or model task is running', async () => {
  const { handlers, event, captured, world } = await boot();
  const request = handlers.get('black-team:request');
  const close = () => {
    const closing = { prevented: false, preventDefault() { this.prevented = true; } };
    captured.window.emit('close', closing);
    return closing;
  };
  // A finished job stays in the status so the window can show how it ended; it must not prompt.
  world.status = { job: { state: 'done' }, runtime: { busy: false } };
  await request(event(), 'status');
  assert.equal(close().prevented, false);
  assert.equal(captured.prompts.length, 0);

  world.status = { job: { state: 'running' }, runtime: { busy: false } };
  await request(event(), 'status');
  world.messageChoice = 0;
  assert.equal(close().prevented, true);
  assert.equal(captured.prompts.length, 1);
  assert.equal(captured.prompts[0].message, 'A local response is still running.');
  assert.equal(captured.prompts[0].detail, 'Keep Black Team open or minimized to continue from your phone.');

  world.messageChoice = 1;
  assert.equal(close().prevented, false);
  assert.equal(captured.prompts.length, 2);

  world.status = { job: { state: 'done' }, runtime: { busy: true } };
  await request(event(), 'status');
  world.messageChoice = 0;
  assert.equal(close().prevented, true);
  assert.equal(captured.prompts.length, 3);

  world.status = { job: { state: 'done' }, runtime: { busy: false } };
  await request(event(), 'status');
  assert.equal(close().prevented, false);
  assert.equal(captured.prompts.length, 3);
});

test('quitting asks the engine right away, keeps the app open on Keep open, and stops the engine on Stop', async () => {
  const { app, captured, world } = await boot();
  const quit = () => {
    const quitting = { prevented: false, preventDefault() { this.prevented = true; } };
    app.emit('before-quit', quitting);
    return quitting;
  };
  world.status = { job: { state: 'running' }, runtime: { busy: false } };
  world.messageChoice = 0;
  const kept = quit();
  await settle();
  assert.equal(kept.prevented, true);
  assert.equal(captured.prompts.length, 1);
  assert.equal(captured.prompts[0].message, 'A local response is still running.');
  assert.equal(captured.prompts[0].detail, 'Quit stops the model and disconnects Companion until you reopen Black Team.');
  assert.equal(captured.engine.stopCalls, 0);
  assert.equal(captured.quit, undefined);

  world.messageChoice = 1;
  quit();
  await settle();
  assert.equal(captured.prompts.length, 2);
  assert.equal(captured.engine.stopCalls, 1);
  assert.equal(captured.quit, true);
});

test('quitting with a finished job does not prompt, even if an earlier status was busy', async () => {
  const { app, handlers, event, captured, world } = await boot();
  const request = handlers.get('black-team:request');
  world.status = { job: { state: 'running' }, runtime: { busy: false } };
  await request(event(), 'status');
  world.status = { job: { state: 'done' }, runtime: { busy: false } };
  const quitting = { prevented: false, preventDefault() { this.prevented = true; } };
  app.emit('before-quit', quitting);
  await settle();
  assert.equal(quitting.prevented, true);
  assert.equal(captured.prompts.length, 0);
  assert.equal(captured.engine.stopCalls, 1);
  assert.equal(captured.quit, true);
});

test('quitting when the engine cannot report its status quits without a prompt', async () => {
  const { app, captured, world } = await boot();
  world.replies.set('status', async () => { throw new Error('engine busy'); });
  app.emit('before-quit', { preventDefault() {} });
  await settle();
  assert.equal(captured.prompts.length, 0);
  assert.equal(captured.engine.stopCalls, 1);
  assert.equal(captured.quit, true);
});

test('an unexpected engine exit shows the error and quits, while an expected exit does not', async () => {
  const { captured } = await boot();
  captured.engine.emit('exit', { expected: true, error: null, code: 0 });
  assert.deepEqual(captured.errors, []);
  assert.equal(captured.quit, undefined);
  captured.engine.emit('exit', { expected: false, error: null, code: 1 });
  assert.deepEqual(captured.errors, [['Black Team Agent stopped', 'The local Black Team engine stopped unexpectedly. Reopen Black Team to continue.']]);
  assert.equal(captured.quit, true);
});

test('an engine exit during a normal quit is not reported as a crash', async () => {
  const { app, captured } = await boot();
  captured.engine.onStop = () => captured.engine.emit('exit', { expected: false, error: null, code: 0 });
  app.emit('before-quit', { preventDefault() {} });
  await settle();
  assert.deepEqual(captured.errors, []);
  assert.equal(captured.quit, true);
});

test('a failed engine start is reported, the engine is stopped, and no window is opened', async () => {
  const { captured } = await boot({ startError: new Error('The Black Team engine did not start in time.') });
  assert.deepEqual(captured.errors, [['Black Team Agent could not start', 'The Black Team engine did not start in time.']]);
  assert.equal(captured.engine.stopCalls, 1);
  assert.equal(captured.quit, true);
  assert.equal(captured.window, undefined);
});
