'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { EventEmitter } = require('node:events');

const project = path.resolve(__dirname, '..');

async function boot({phoneSetup = async () => ({connected: true})} = {}) {
  const captured = { errors: [], starts: 0, writes: [], opened: [] };
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
      this.webContents.mainFrame = { url: 'http://127.0.0.1:18199/' };
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
  const backend = {
    origin: 'http://127.0.0.1:18199',
    bootstrapURL: 'http://127.0.0.1:18199/bootstrap?key=desktop-secret',
    listen: async () => {},
    status: async access => ({ access, checked: true }),
    close: async () => { captured.closed = true; },
    isBusy: () => false,
  };
  const electron = {
    app, BrowserWindow,
    ipcMain: { handle: (name, callback) => { handlers.set(name, callback); } },
    dialog: {
      showErrorBox: (...args) => captured.errors.push(args),
      showMessageBoxSync: () => 0,
      showOpenDialog: async (_window, options) => { captured.dialogOptions = options; return { canceled: true, filePaths: [] }; },
    },
    shell: { openExternal: async value => { captured.opened.push(value); }, openPath: async value => { captured.opened.push(value); return ''; } },
    Menu: { setApplicationMenu: () => {}, buildFromTemplate: template => template },
    session: { defaultSession },
  };
  const config = {
    read: () => ({ phone: { enabled: false, hostname: '', owner: '' } }),
    save: value => { captured.writes.push(value); return value; },
  };
  const mockedRequire = name => {
    if (name === './lib/integrations.cjs') return {createIntegrations:()=>({read:()=>({hermes:{enabled:false},harnesses:[]})})};
    if (name === './lib/agent.cjs') return {createAgent:()=>({})};
    if (name === 'electron') return electron;
    if (name === './lib/config.cjs') return { createConfigStore: () => config, validateModelFiles: input => { captured.inspected = input; return { model: { bytes: 7 } }; } };
    if (name === './lib/history.cjs') return { privateDirectory: () => {} };
    if (name === './lib/runtime.cjs') return { ModelRuntime: class {
      status() { return { state: 'off', ready: false }; }
      async start() { captured.starts++; }
      async stop() {}
    } };
    if (name === './lib/phone.cjs') return { PhoneManager: class { async setup() { return await phoneSetup(); } }, validatePhone: value => value, COMMAND: 'test command' };
    if (name === './lib/server.cjs') return { createBackend: () => backend };
    if (name === './lib/find-models.cjs') return { findModels: async () => ({ servers: [{ source: 'server', id: 'found' }], files: [], runtime: '', looked: { ports: [], folders: [] } }), describeFile: (file, bytes) => ({ name: 'Described', context: 16384, trainingContext: 262144, bytes }), companionsFor: () => ({ mmproj: '/m/mmproj.gguf', draft: '' }) };
    // The saved-model list is replaced so a test never reads the real data folder.
    if (name === './lib/models.cjs') return {
      createSavedModels: () => ({ read: () => [], list: () => [], ignored: () => ['abcdef0123456789'], ignore: key => { captured.ignored = key; return { ignored: true }; }, remember: model => { captured.remembered = model; } }),
      switchModel: async input => { captured.switched = input.key; return { switched: true, name: 'Other', busy: input.busy() }; },
      forgetModel: input => { captured.forgotten = input.key; return { removed: true }; },
      addModels: input => { captured.addedItems = input.items; return { added: ['One'], skipped: [], inUse: 'One' }; },
      keyOf: item => item.id || item.file,
    };
    return require(name.startsWith('./') ? path.join(project, name) : name);
  };
  vm.runInNewContext(fs.readFileSync(path.join(project, 'main.cjs'), 'utf8'), {
    require: mockedRequire, __dirname: project, process, URL, Buffer, console,
  }, { filename: 'main.cjs' });
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(captured.errors, []);
  assert.ok(captured.window, 'main process completed setup');
  const event = () => ({ sender: captured.window.webContents, senderFrame: captured.window.webContents.mainFrame });
  return { captured, handlers, event, app };
}

test('native boot keeps the renderer sandboxed and does not auto-launch a model', async () => {
  const { captured } = await boot();
  assert.equal(captured.name, 'Black Team');
  assert.equal(captured.options.webPreferences.sandbox, true);
  assert.equal(captured.options.webPreferences.contextIsolation, true);
  assert.equal(captured.options.webPreferences.nodeIntegration, false);
  assert.equal(captured.options.webPreferences.webSecurity, true);
  assert.equal(captured.options.webPreferences.devTools, false);
  assert.equal(captured.starts, 0);
  assert.equal(captured.loaded, 'http://127.0.0.1:18199/bootstrap?key=desktop-secret');
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
  for (const url of ['https://example.com', 'file:///etc/passwd', 'http://127.0.0.1:18199/other']) {
    let blocked = false;
    captured.window.webContents.emit('will-navigate', { preventDefault: () => { blocked = true; } }, url);
    assert.equal(blocked, true, url);
  }
  let blocked = false;
  captured.window.webContents.emit('will-navigate', { preventDefault: () => { blocked = true; } }, 'http://127.0.0.1:18199/');
  assert.equal(blocked, false);
  captured.window.webContents.emit('will-attach-webview', { preventDefault: () => { blocked = true; } });
  assert.equal(blocked, true);
});

test('desktop IPC requires the exact owned main frame and only approved actions and chooser types', async () => {
  const { handlers, event, captured } = await boot();
  const request = handlers.get('black-team:request');
  const picker = handlers.get('black-team:pick');
  assert.equal((await request(event(), 'status')).access, 'desktop');
  await assert.rejects(request({ ...event(), sender: new EventEmitter() }, 'status'), /unavailable/);
  await assert.rejects(request({ ...event(), senderFrame: { url: 'http://127.0.0.1:18199/' } }, 'status'), /unavailable/);
  const mainFrame = captured.window.webContents.mainFrame;
  mainFrame.url = 'https://example.com/';
  await assert.rejects(request(event(), 'runtime-start'), /unavailable/);
  mainFrame.url = 'http://127.0.0.1:18199/';
  await assert.rejects(request(event(), 'exec-shell', { command: 'anything' }), /Unsupported/);
  await assert.rejects(request(event(), 'status', []), /Invalid desktop request/);
  await assert.rejects(picker(event(), 'arbitrary-file'), /Unsupported chooser/);
  assert.equal(await picker(event(), 'model'), null);
  assert.equal(captured.dialogOptions.filters[0].extensions[0], 'gguf');
  assert.equal(captured.starts, 0);
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
});


test('saving a model adds it to the list, and switching and removing reach the list', async () => {
  const { handlers, event, captured } = await boot();
  const request = handlers.get('black-team:request');
  const model = { source: 'server', endpoint: 'http://127.0.0.1:11434/v1', id: 'local', name: 'Local' };
  assert.equal((await request(event(), 'setup-save', { model })).saved, true);
  assert.equal(captured.remembered.id, 'local');
  assert.equal(JSON.stringify(await request(event(), 'model-switch', { key: 'abc' })), JSON.stringify({ switched: true, name: 'Other', busy: false }));
  assert.equal(captured.switched, 'abc');
  assert.equal((await request(event(), 'model-forget', { key: 'abc' })).removed, true);
  assert.equal(captured.forgotten, 'abc');
  // A chosen model file is described and its companions found, through the same checks as a saved one.
  const described = await request(event(), 'model-inspect', { file: '/m/q.gguf' });
  assert.deepEqual(described, { name: 'Described', context: 16384, trainingContext: 262144, bytes: 7, mmproj: '/m/mmproj.gguf', draft: '' });
  assert.equal(captured.inspected.file, '/m/q.gguf');
  await assert.rejects(request(event(), 'model-inspect', { file: '/m/q.gguf', extra: 1 }), /Unsupported setup setting/);
  const found = await request(event(), 'models-find');
  assert.equal(found.servers[0].id, 'found');
  assert.equal(found.servers[0].saved, false);
  assert.equal(found.servers[0].key, 'found');
  assert.equal(found.servers[0].ignored, false);
  assert.deepEqual(await request(event(), 'models-ignore', { key: 'abc' }), { ignored: true });
  assert.equal(captured.ignored, 'abc');
  assert.equal((await request(event(), 'models-add', { items: [{ id: 'found' }] })).inUse, 'One');
  assert.equal(captured.addedItems[0].id, 'found');
  await assert.rejects(request(event(), 'models-add', { items: [], model: {} }), /Unsupported setup setting/);
  const preload = fs.readFileSync(path.join(project, 'preload.cjs'), 'utf8');
  assert.match(preload, /'server-discover','model-inspect',/);
});

test('setup mutations stay locked until async completion and unlock after failure', async () => {
  let finish;
  const waiting = new Promise((_resolve, reject) => { finish = reject; });
  const { handlers, event, captured } = await boot({phoneSetup: () => waiting});
  const request = handlers.get('black-team:request');
  const setup = request(event(), 'phone-setup');
  const failure = assert.rejects(setup, /setup failed/);
  await assert.rejects(request(event(), 'runtime-start'), /still running/);
  assert.equal(captured.starts, 0);
  finish(new Error('setup failed'));
  await failure;
  await request(event(), 'runtime-start');
  assert.equal(captured.starts, 1);
});

test('installation help only opens fixed destinations and new choosers retain native boundaries', async () => {
  const { handlers, event, captured } = await boot();
  const request = handlers.get('black-team:request');
  await assert.rejects(request(event(), 'setup-help', {topic: 'https://example.com'}), /Unsupported/);
  assert.deepEqual(captured.opened, []);
  await request(event(), 'setup-help', {topic: 'hermes'});
  assert.deepEqual(captured.opened, ['https://github.com/NousResearch/hermes-agent#installation']);
  const picker = handlers.get('black-team:pick');
  await picker(event(), 'hermes-source');
  assert.equal(captured.dialogOptions.properties[0], 'openDirectory');
  await picker(event(), 'executable');
  assert.equal(captured.dialogOptions.properties[0], 'openFile');
});
