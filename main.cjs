'use strict';
const {app,BrowserWindow,ipcMain,dialog,shell,Menu,session}=require('electron');
const path=require('node:path');
const os=require('node:os');
const {createConfigStore,validateModelFiles}=require('./lib/config.cjs');
const {createIntegrations,launchHarness,connectHarness}=require('./lib/integrations.cjs');
const {createAgent}=require('./lib/agent.cjs');
const {discoverInstalled,inspectHermes}=require('./lib/discovery.cjs');
const {discoverModels}=require('./lib/local-server.cjs');
const {privateDirectory}=require('./lib/history.cjs');
const {ModelRuntime}=require('./lib/runtime.cjs');
const {PhoneManager,validatePhone,COMMAND}=require('./lib/phone.cjs');
const {createBackend}=require('./lib/server.cjs');
const {createSavedModels,switchModel,forgetModel,addModels,keyOf}=require('./lib/models.cjs');
const {findModels}=require('./lib/find-models.cjs');

const dataRoot=process.env.XDG_DATA_HOME && path.isAbsolute(process.env.XDG_DATA_HOME)?process.env.XDG_DATA_HOME:path.join(os.homedir(),'.local/share');
const stateDir=path.join(dataRoot,'black-team-data');
app.setName('Black Team');app.setPath('userData',path.join(stateDir,'desktop'));
let window,backend,runtime,quitting=false,shuttingDown=false;
if(!app.requestSingleInstanceLock())app.quit();
else {
  app.on('second-instance',()=>{if(window){if(window.isMinimized())window.restore();window.show();window.focus();}});
  app.whenReady().then(async()=>{
    if(process.platform!=='linux')throw new Error('This Black Team preview supports Linux.');
    privateDirectory(stateDir);
    const configStore=createConfigStore(stateDir);configStore.read();
    const savedModels=createSavedModels(stateDir);
    // Someone who set up a model before the list existed sees it there from the start.
    try{const current=configStore.read().model;if(!savedModels.read().length&&(current.source==='server'?current.id:current.file&&current.runtime))savedModels.remember(current);}catch{}
    const integrations=createIntegrations(stateDir);
    const agentRunner=createAgent({stateDir,integrations});
    runtime=new ModelRuntime({configStore});
    const phone=new PhoneManager({configStore});
    // Dictation uses a system tool when one is installed (Voxtype is found automatically); a saved choice wins.
    // What is installed is looked up once; graphify, when present, gives Code a map of the workspace.
    let found=null;const installed=()=>found||(found=discoverInstalled());
    const dictation=()=>integrations.read().dictation||installed().dictation||'';
    const graph=()=>installed().graph||'';
    backend=createBackend({stateDir,distDir:path.join(__dirname,'dist'),configStore,runtime,phone,savedModels,integrations,agentRunner,dictation,graph,version:app.getVersion()});
    try{await backend.listen();}catch(error){throw new Error(error.code==='EADDRINUSE'?'Black Team’s local port 18199 is already in use. Close the other copy or free this port, then reopen Black Team.':'Black Team could not open its local service. Check your system permissions.');}
    session.defaultSession.setPermissionRequestHandler((_wc,_permission,callback)=>callback(false));
    session.defaultSession.setPermissionCheckHandler(()=>false);
    session.defaultSession.webRequest.onBeforeRequest((details,callback)=>{
      let allowed=false;try{allowed=new URL(details.url).origin===backend.origin;}catch{}
      callback({cancel:!allowed});
    });
    const verify=event=>{
      if(!window || event.sender!==window.webContents || event.senderFrame!==window.webContents.mainFrame || new URL(event.senderFrame.url).origin!==backend.origin)throw new Error('Desktop action is unavailable.');
    };
    let changing=false;
    ipcMain.handle('black-team:request',async(event,action,input={})=>{
      verify(event);
      if(typeof action!=='string'||!input||typeof input!=='object'||Array.isArray(input))throw new Error('Invalid desktop request.');
      if(action==='status')return backend.status('desktop');
      if(action==='server-discover'){
        if(Object.keys(input).some(k=>!['endpoint','apiKey'].includes(k)))throw new Error('Unsupported server discovery setting.');
        const saved=configStore.read().model;
        return discoverModels({endpoint:input.endpoint,apiKey:input.apiKey ?? (input.endpoint===saved.endpoint?saved.apiKey:'')});
      }
      if(action==='models-find'){const found=await findModels({runtime:discoverInstalled().runtime});const have=new Set(savedModels.list().map(model=>model.key)),passed=new Set(savedModels.ignored());const mark=item=>({...item,key:keyOf(item),saved:have.has(keyOf(item)),ignored:passed.has(keyOf(item))});return {...found,servers:found.servers.map(mark),files:found.files.map(mark)};}
      if(action==='installed-discover')return discoverInstalled({saved:integrations.read().hermes});
      if(action==='hermes-inspect')return inspectHermes(input.source,input.python);
      if(action==='phone-detect')return phone.detect();
      if(action==='phone-command')return {command:COMMAND};
      if(action==='setup-help'){
        const links=new Map([['hermes','https://github.com/NousResearch/hermes-agent#installation'],['ollama','https://ollama.com/download/linux'],['lmstudio','https://lmstudio.ai/download'],['tailscale','https://tailscale.com/download']]);
        if(!links.has(input.topic))throw new Error('Unsupported setup help.');
        await shell.openExternal(links.get(input.topic));return {opened:true};
      }
      if(action==='open-data'){const error=await shell.openPath(stateDir);if(error)throw new Error('Could not open the application data folder.');return {opened:true};}
      if(!['integrations-save','harness-connect','harness-launch','setup-save','models-add','models-ignore','model-switch','model-forget','runtime-start','runtime-stop','phone-save','phone-setup','phone-off','phone-connect','phone-disconnect'].includes(action))throw new Error('Unsupported desktop action.');
      if(changing)throw new Error('Another setup action is still running.');changing=true;
      try {
        if(action==='integrations-save'){if(backend.isBusy())throw new Error('Wait for the current task before changing integrations.');integrations.save(input);return {saved:true};}
        if(action==='harness-launch'){if(backend.isBusy())throw new Error('Wait for the current task before launching another harness.');return await launchHarness({id:input.id,store:integrations,config:configStore.read(),runtime,stateDir});}
        if(action==='harness-connect'){if(backend.isBusy())throw new Error('Wait for the current task before changing integrations.');return connectHarness({id:input.id,store:integrations,found:discoverInstalled({saved:integrations.read().hermes})});}
        if(action==='setup-save') {
          if(backend.isBusy()||!['off','error'].includes(runtime.status().state))throw new Error('Stop the model before changing its configuration.');
          // Only the setup form's keys are accepted. Phone pairing is separate.
          if(Object.keys(input).some(k=>!['model','workspace'].includes(k)))throw new Error('Unsupported setup setting.');
          const previous=configStore.read().model;
          const model={...previous,...input.model};
          if(model.endpoint!==previous?.endpoint && input.model?.apiKey===undefined)model.apiKey='';
          validateModelFiles(model);const next=configStore.save({...input,model});
          // Every model that is set up joins the list, so going back to it later is one choice.
          let warning;try{savedModels.remember(next.model);}catch(error){warning=`Model saved. ${error.message}`;}
          return {saved:true,...(warning?{warning}:{})};
        }
        if(action==='models-add'){if(Object.keys(input).some(k=>k!=='items'))throw new Error('Unsupported setup setting.');return addModels({items:input.items,saved:savedModels,configStore});}
        if(action==='models-ignore')return savedModels.ignore(input.key);
        if(action==='model-switch')return await switchModel({key:input.key,saved:savedModels,configStore,runtime,busy:()=>backend.isBusy()});
        if(action==='model-forget')return forgetModel({key:input.key,saved:savedModels,configStore});
        if(action==='runtime-start'){runtime.start().catch(()=>{});return runtime.status();}
        if(action==='runtime-stop'){
          if(backend.isBusy())throw new Error('Stop the response before stopping the model.');
          await runtime.stop();return runtime.status();
        }
        if(action==='phone-save'){
          const next=validatePhone(input);const old=configStore.read().phone;
          if(next.enabled){const self=await phone.detect();if(!self.online||self.hostname!==next.hostname||self.owner!==next.owner)throw new Error('Detect the signed-in computer and account before saving private phone access.');}
          if(old.enabled && (next.hostname!==old.hostname||next.owner!==old.owner)) {
            const status=await phone.status({fresh:true});if(status.connected)throw new Error('Disconnect the current phone route before changing its computer or account.');
          }
          configStore.save({phone:next});return {saved:true};
        }
        if(action==='phone-setup')return await phone.setup();
        if(action==='phone-off')return await phone.disable();
        if(action==='phone-connect')return await phone.connect();
        if(action==='phone-disconnect')return await phone.disconnect();
      } finally {changing=false;}
    });
    ipcMain.handle('black-team:pick',async(event,kind)=>{
      verify(event);if(!['model','runtime','workspace','executable','hermes-source'].includes(kind))throw new Error('Unsupported chooser.');
      const options=['workspace','hermes-source'].includes(kind)?{title:kind==='workspace'?'Choose your workspace':'Choose your Hermes installation',properties:['openDirectory']}:
        {title:kind==='model'?'Choose a local GGUF model':kind==='runtime'?'Choose llama-server from its extracted release':'Choose the application executable',properties:['openFile'],...(kind==='model'?{filters:[{name:'GGUF models',extensions:['gguf']}]}:{})};
      const result=await dialog.showOpenDialog(window,options);return result.canceled?null:result.filePaths[0]||null;
    });
    window=new BrowserWindow({width:1320,height:900,minWidth:800,minHeight:620,title:'Black Team',backgroundColor:'#08090c',icon:path.join(__dirname,'dist/black-team-512.png'),show:false,
      webPreferences:{preload:path.join(__dirname,'preload.cjs'),sandbox:true,contextIsolation:true,nodeIntegration:false,webSecurity:true,spellcheck:false,devTools:!app.isPackaged}});
    window.webContents.setWindowOpenHandler(()=>({action:'deny'}));
    window.webContents.on('will-navigate',(event,url)=>{if(url!==`${backend.origin}/` && url!==`${backend.origin}/index.html`)event.preventDefault();});
    window.webContents.on('will-attach-webview',event=>event.preventDefault());
    window.once('ready-to-show',()=>window.show());
    window.on('close',event=>{
      if(!quitting&&backend.isBusy()) {
        const choice=dialog.showMessageBoxSync(window,{type:'question',buttons:['Keep open','Stop response and quit'],defaultId:0,cancelId:0,message:'A local response is still running.',detail:'Keep Black Team open or minimized to continue from your phone.'});
        if(choice===0)event.preventDefault();
      }
    });
    Menu.setApplicationMenu(Menu.buildFromTemplate([
      {label:'Black Team',submenu:[{label:'Open data folder',click:()=>shell.openPath(stateDir)},{type:'separator'},{role:'quit'}]},
      {label:'Edit',submenu:[{role:'undo'},{role:'redo'},{type:'separator'},{role:'cut'},{role:'copy'},{role:'paste'},{role:'selectAll'}]},
      {label:'View',submenu:[{role:'reload'},{role:'resetZoom'},{role:'zoomIn'},{role:'zoomOut'},{role:'togglefullscreen'}]},
    ]));
    await window.loadURL(backend.bootstrapURL);
  }).catch(async error=>{
    dialog.showErrorBox('Black Team could not start',error.message);
    try{await backend?.close();}catch{}quitting=true;app.quit();
  });
  app.on('window-all-closed',()=>app.quit());
  app.on('before-quit',event=>{
    if(quitting||!backend)return;
    event.preventDefault();if(shuttingDown)return;
    if(backend.isBusy()&&window&&!window.isDestroyed()) {
      const choice=dialog.showMessageBoxSync(window,{type:'question',buttons:['Keep open','Stop response and quit'],defaultId:0,cancelId:0,message:'A local response is still running.',detail:'Quit stops the model and disconnects Companion until you reopen Black Team.'});
      if(choice===0)return;
    }
    shuttingDown=true;
    backend.close().catch(()=>{}).finally(()=>{quitting=true;app.quit();});
  });
}
