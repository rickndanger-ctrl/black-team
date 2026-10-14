'use strict';
const {app,BrowserWindow,ipcMain,dialog,shell,Menu,session}=require('electron');
const path=require('node:path');
const os=require('node:os');
const fs=require('node:fs');
const {EngineClient,resolveEngine}=require('./engine-client.cjs');

const dataRoot=process.env.XDG_DATA_HOME && path.isAbsolute(process.env.XDG_DATA_HOME)?process.env.XDG_DATA_HOME:path.join(os.homedir(),'.local/share');
const stateDir=path.join(dataRoot,'black-team-data');
app.setName('Black Team');app.setPath('userData',path.join(stateDir,'desktop'));
function privateDirectory(dir){
  fs.mkdirSync(dir,{recursive:true,mode:0o700});
  if(fs.lstatSync(dir).isSymbolicLink())throw new Error('Private storage must not be a symbolic link.');
  fs.chmodSync(dir,0o700);
}
// Actions the window may ask for, sorted by whether they change something. Every answer comes from the Swift engine.
const READ_ACTIONS=new Set(['status','server-discover','models-find','model-inspect','installed-discover','hermes-inspect','phone-detect','phone-command','cloud-discover','agents-status','vision-cancel','starter-list','starter-cancel','setup-plan','setup-cancel']);
const CHANGE_ACTIONS=new Set(['integrations-save','harness-connect','harness-launch','setup-save','models-add','models-ignore','model-switch','model-forget','runtime-start','runtime-stop','phone-save','phone-setup','phone-off','phone-connect','phone-disconnect','cloud-save','project-cloud','agent-signin','agent-update','vision-install','starter-install','setup-apply','setup-dismiss']);
// Whether the engine's status reports a response or a model task running; read from every status answer the window gets.
// A finished job stays in the status so the window can show how it ended; only an unfinished one counts.
const isBusy=status=>Boolean(status&&((status.job&&status.job.state==='running')||(status.runtime&&status.runtime.busy)));
let window,engine,origin,quitting=false,shuttingDown=false,asking=false,busy=false;
if(!app.requestSingleInstanceLock())app.quit();
else {
  app.on('second-instance',()=>{if(window){if(window.isMinimized())window.restore();window.show();window.focus();}});
  app.whenReady().then(async()=>{
    if(process.platform!=='linux')throw new Error('This Black Team preview supports Linux.');
    privateDirectory(stateDir);
    // The engine serves the web app and the API on its own port; a failed start is shown like any other startup failure.
    engine=new EngineClient({command:resolveEngine({dirname:__dirname}),args:['desktop-service','--web',path.join(__dirname,'dist'),'--version',app.getVersion(),'--data',stateDir,'--scripts',path.join(__dirname,'scripts')]});
    const ready=await engine.start();
    origin=new URL(ready.origin).origin;
    // Only once it is running: a crash from here on is an error to show, while a failed start is reported above.
    engine.on('exit',({expected})=>{
      if(expected||quitting||shuttingDown)return;
      quitting=true;
      dialog.showErrorBox('Black Team Agent stopped','The local Black Team engine stopped unexpectedly. Reopen Black Team to continue.');
      app.quit();
    });
    session.defaultSession.setPermissionRequestHandler((_wc,_permission,callback)=>callback(false));
    session.defaultSession.setPermissionCheckHandler(()=>false);
    session.defaultSession.webRequest.onBeforeRequest((details,callback)=>{
      let allowed=false;try{allowed=new URL(details.url).origin===origin;}catch{}
      callback({cancel:!allowed});
    });
    const verify=event=>{
      if(!window || event.sender!==window.webContents || event.senderFrame!==window.webContents.mainFrame || new URL(event.senderFrame.url).origin!==origin)throw new Error('Desktop action is unavailable.');
    };
    let changing=false;
    ipcMain.handle('black-team:request',async(event,action,input={})=>{
      verify(event);
      if(typeof action!=='string'||!input||typeof input!=='object'||Array.isArray(input))throw new Error('Invalid desktop request.');
      if(READ_ACTIONS.has(action)){
        const result=await engine.request(action,input);
        if(action==='status')busy=isBusy(result);
        return result;
      }
      if(action==='setup-help'){
        if(!['hermes','ollama','lmstudio','tailscale'].includes(input.topic))throw new Error('Unsupported setup help.');
        const {url}=await engine.request(action,input);
        await shell.openExternal(url);return {opened:true};
      }
      if(action==='open-data'){const {path:folder}=await engine.request(action,input);const error=await shell.openPath(folder);if(error)throw new Error('Could not open the application data folder.');return {opened:true};}
      if(!CHANGE_ACTIONS.has(action))throw new Error('Unsupported desktop action.');
      if(changing)throw new Error('Another setup action is still running.');changing=true;
      try {
        return await engine.request(action,input);
      } finally {changing=false;}
    });
    ipcMain.handle('black-team:pick',async(event,kind)=>{
      verify(event);
      if(!['model','runtime','workspace','executable','hermes-source'].includes(kind))throw new Error('Unsupported chooser.');
      const options=['workspace','hermes-source'].includes(kind)?{title:kind==='workspace'?'Choose your workspace':'Choose your Hermes installation',properties:['openDirectory']}:
        {title:kind==='model'?'Choose a local GGUF model':kind==='runtime'?'Choose llama-server from its extracted release':'Choose the application executable',properties:['openFile'],...(kind==='model'?{filters:[{name:'GGUF models',extensions:['gguf']}]}:{})};
      const result=await dialog.showOpenDialog(window,options);return result.canceled?null:result.filePaths[0]||null;
    });
    window=new BrowserWindow({width:1320,height:900,minWidth:800,minHeight:620,title:'Black Team Agent',backgroundColor:'#08090c',icon:path.join(__dirname,'dist/black-team-512.png'),show:false,
      webPreferences:{preload:path.join(__dirname,'preload.cjs'),sandbox:true,contextIsolation:true,nodeIntegration:false,webSecurity:true,spellcheck:false,devTools:!app.isPackaged}});
    window.webContents.setWindowOpenHandler(()=>({action:'deny'}));
    window.webContents.on('will-navigate',(event,url)=>{if(url!==`${origin}/` && url!==`${origin}/index.html`)event.preventDefault();});
    window.webContents.on('will-attach-webview',event=>event.preventDefault());
    window.once('ready-to-show',()=>window.show());
    window.on('close',event=>{
      if(!quitting&&busy) {
        const choice=dialog.showMessageBoxSync(window,{type:'question',buttons:['Keep open','Stop response and quit'],defaultId:0,cancelId:0,message:'A local response is still running.',detail:'Keep Black Team open or minimized to continue from your phone.'});
        if(choice===0)event.preventDefault();
      }
    });
    Menu.setApplicationMenu(Menu.buildFromTemplate([
      {label:'Black Team Agent',submenu:[{label:'Open data folder',click:()=>shell.openPath(stateDir)},{type:'separator'},{role:'quit'}]},
      {label:'Edit',submenu:[{role:'undo'},{role:'redo'},{type:'separator'},{role:'cut'},{role:'copy'},{role:'paste'},{role:'selectAll'}]},
      {label:'View',submenu:[{role:'reload'},{role:'resetZoom'},{role:'zoomIn'},{role:'zoomOut'},{role:'togglefullscreen'}]},
    ]));
    await window.loadURL(ready.bootstrapURL);
  }).catch(async error=>{
    dialog.showErrorBox('Black Team Agent could not start',error.message);
    try{await engine?.stop();}catch{}quitting=true;app.quit();
  });
  app.on('window-all-closed',()=>app.quit());
  app.on('before-quit',event=>{
    if(quitting||!engine)return;
    event.preventDefault();if(shuttingDown||asking)return;
    asking=true;
    (async()=>{
      try{
        // Ask the engine now, so the prompt is about what is running at this moment.
        try{busy=isBusy(await engine.request('status'));}catch{busy=false;}
        if(busy&&window&&!window.isDestroyed()) {
          const choice=dialog.showMessageBoxSync(window,{type:'question',buttons:['Keep open','Stop response and quit'],defaultId:0,cancelId:0,message:'A local response is still running.',detail:'Quit stops the model and disconnects Companion until you reopen Black Team.'});
          if(choice===0)return;
        }
        shuttingDown=true;
        await engine.stop().catch(()=>{});
        quitting=true;app.quit();
      } finally {asking=false;}
    })();
  });
}
