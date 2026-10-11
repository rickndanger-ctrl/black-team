'use strict';
const http=require('node:http');
const os=require('node:os');
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {History,ID}=require('./history.cjs');
const {hardwareReport,estimateMemory}=require('./config.cjs');
const {createCpuSampler,cpuTemperature,processMemory,memoryInfo,serverProcess}=require('./system.cjs');
const {prepareContext,prepareServerContext}=require('./context.cjs');
const {LOCAL_PORT,PHONE_PORT}=require('./phone.cjs');
const {spawn}=require('node:child_process');
const {writeJSON}=require('./history.cjs');
const {ensureWorkspace}=require('./config.cjs');
const {createMemory}=require('./memory.cjs');
const {createEngine}=require('./engine.cjs');
const {localEnvironment}=require('./integrations.cjs');
const MODES=['fast','balanced','deep','extended'];
const SYSTEM='You are Black Team, a helpful private AI assistant running on the user’s computer. This conversation has no tools: do not claim to read files, browse, run commands, or complete external actions. Ask for needed information and be clear about uncertainty.';
const MIME={'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8','.json':'application/json','.webmanifest':'application/manifest+json','.png':'image/png','.svg':'image/svg+xml','.woff2':'font/woff2','.txt':'text/plain; charset=utf-8'};
const fail=(message,status=400)=>Object.assign(new Error(message),{status});
function equal(a,b) {if(typeof a!=='string'||typeof b!=='string')return false;const aa=Buffer.from(a),bb=Buffer.from(b);return aa.length===bb.length&&crypto.timingSafeEqual(aa,bb);}
function securityHeaders(res) {
  res.setHeader('Cache-Control','no-store');
  res.setHeader('X-Content-Type-Options','nosniff');
  res.setHeader('X-Frame-Options','DENY');
  res.setHeader('Referrer-Policy','no-referrer');
  res.setHeader('Permissions-Policy','camera=(), microphone=(), geolocation=()');
  res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; worker-src 'self'; manifest-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'");
}
function json(res,status,data) {res.statusCode=status;res.setHeader('Content-Type','application/json; charset=utf-8');res.end(JSON.stringify(data));}
async function bodyJSON(req,limit=65536) {
  if(!String(req.headers['content-type']||'').toLowerCase().startsWith('application/json')) throw fail('Send JSON.',415);
  let size=0; const chunks=[];
  for await(const chunk of req) {size+=chunk.length; if(size>limit) throw fail('Request is too large.',413); chunks.push(chunk);}
  try {
    const body=JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if(!body || typeof body!=='object' || Array.isArray(body)) throw new Error();
    return body;
  } catch {throw fail('Invalid JSON request.');}
}
// Memory for Chat, which has no tools. Core memory is fixed when the conversation starts, and what was
// recalled for a message stays attached to it, so earlier turns are sent the same way every time and
// the model server's prompt cache keeps working.
function withMemory(message) {
  if(!Array.isArray(message.recalled)||!message.recalled.length)return message.content;
  return `${message.content}\n\n[From your memory. Use it only if it is relevant.]\n${message.recalled.map(item=>`- ${item.title}: ${item.text}`).join('\n')}`;
}
function messagesFor(thread) {
  const result=[{role:'system',content:typeof thread.core==='string'&&thread.core?`${SYSTEM}\n\nWhat you know about the user:\n${thread.core}`:SYSTEM}];
  for(let i=0;i<thread.messages.length-2;i++) {
    const user=thread.messages[i],assistant=thread.messages[i+1];
    if(user.role==='user' && assistant?.role==='assistant' && assistant.state==='done' && assistant.content) {
      result.push({role:'user',content:withMemory(user)},{role:'assistant',content:assistant.content});i++;
    }
  }
  result.push({role:'user',content:withMemory(thread.messages.at(-2))});
  return result;
}

async function readStream(response,onDelta,signal) {
  if(!response.body) throw fail('The local model returned no response.',502);
  const decoder=new TextDecoder(); let pending='',finished=false,finishReason=null,timings=null,usage=null;
  const processLine=line=>{
    if(!line.startsWith('data:')) return;
    const data=line.slice(5).trim(); if(!data) return;
    if(data==='[DONE]') {finished=true;return;}
    let item;try{item=JSON.parse(data);}catch{throw fail('The local model returned an invalid stream.',502);}
    if(item.error) throw fail('The local model could not complete the response. Check the model and context settings.',502);
    if(item.timings&&typeof item.timings==='object')timings=item.timings;
    if(item.usage&&typeof item.usage==='object')usage=item.usage;
    const choice=item.choices?.[0];
    if(choice?.delta) onDelta(choice.delta);
    if(choice?.finish_reason){finished=true;finishReason=choice.finish_reason;}
  };
  for await(const chunk of response.body) {
    if(signal.aborted) throw signal.reason;
    pending+=decoder.decode(chunk,{stream:true});
    if(pending.length>1024*1024) throw fail('The local model returned an oversized stream frame.',502);
    let newline;
    while((newline=pending.indexOf('\n'))!==-1){processLine(pending.slice(0,newline).replace(/\r$/,''));pending=pending.slice(newline+1);}
  }
  pending+=decoder.decode();if(pending.trim()) processLine(pending.trim());
  if(!finished) throw fail('Connection to the local model ended before the response finished.',502);
  return {finishReason,timings,usage};
}

function createBackend({stateDir,distDir,configStore,runtime,phone,savedModels=null,version='0.1.0-alpha.1',fetch:fetcher=globalThis.fetch,contextPlanner=prepareContext,port=LOCAL_PORT,integrations=null,agentRunner=null,memory,engine,dictation=()=>'',spawn:spawnImpl=spawn,now=Date.now}) {
  const history=new History(stateDir);
  // The Black Team vault: what the local models remember. It lives in the private data folder only.
  if(memory===undefined)memory=createMemory({vault:path.join(stateDir,'vault')});
  if(engine===undefined)engine=createEngine({stateDir,vault:memory,fetch:fetcher});
  // The keeper's record of its upkeep, newest first, so memory housekeeping is visible.
  const keeperFile=path.join(stateDir,'keeper.json');let keeperLog=[];
  try{const saved=JSON.parse(fs.readFileSync(keeperFile,'utf8'));if(Array.isArray(saved))keeperLog=saved.filter(item=>item&&typeof item.text==='string'&&Number.isFinite(item.at)).slice(0,40);}catch{}
  function keeperNote(actions){if(!actions.length)return;keeperLog=[...actions.map(text=>({text:String(text).slice(0,400),at:now()})).reverse(),...keeperLog].slice(0,40);writeJSON(keeperFile,keeperLog);}
  function sweepMemory(){if(!memory)return;try{keeperNote(memory.sweep());}catch{try{keeperNote(['Memory housekeeping could not finish. Check available disk space.']);}catch{ /* A full disk must not take the app down. */ }}}
  // Projects are made by the user: a name, a folder inside the workspace, and a folder of notes in memory.
  const projectsFile=path.join(stateDir,'projects.json');let projects=[];
  try{const saved=JSON.parse(fs.readFileSync(projectsFile,'utf8'));if(Array.isArray(saved))projects=saved.filter(item=>item&&ID.test(item.id)&&typeof item.name==='string'&&typeof item.workspace==='string'&&path.isAbsolute(item.workspace)).slice(0,200);}catch{}
  const projectNotes=project=>`Projects/${path.basename(project.workspace)}`;
  const projectList=()=>projects.map(project=>({id:project.id,name:project.name,workspace:project.workspace,exists:fs.existsSync(project.workspace),notes:projectNotes(project)}));
  function createProject(input) {
    const name=typeof input.name==='string'?input.name.trim():'';
    if(!/^[A-Za-z0-9][A-Za-z0-9 ._-]{0,59}$/.test(name))throw fail('Name the project with letters, numbers, spaces, dots or dashes (up to 60 characters).');
    const slug=name.toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-+|-+$/g,'');
    if(!slug)throw fail('Name the project with letters or numbers.');
    if(projects.length>=200)throw fail('Black Team keeps up to 200 projects.');
    let base;try{base=fs.realpathSync(ensureWorkspace(configStore.read().workspace));}catch(error){throw fail(error.message);}
    const workspace=path.join(base,slug);
    if(projects.some(project=>project.workspace===workspace||project.name.toLowerCase()===name.toLowerCase()))throw fail('A project with that name or folder already exists.');
    try{fs.mkdirSync(workspace,{recursive:true,mode:0o700});if(fs.realpathSync(workspace)!==workspace||!fs.statSync(workspace).isDirectory())throw new Error('not a folder');}
    catch{throw fail('That project folder could not be created inside your workspace.');}
    const project={id:crypto.randomUUID(),name,workspace,created:new Date(now()).toISOString()};
    projects=[...projects,project];writeJSON(projectsFile,projects);
    if(memory){const folder=projectNotes(project);try{memory.read(`${folder}/Overview`);}catch{try{memory.write(`${folder}/Overview`,`# ${name}\n\nFolder: \`${workspace}\`\nCreated ${project.created.slice(0,10)} in Black Team.\n\nWhat this project is for:\n\n\nSee its [[${folder}/Journal|journal]] for work done so far.\n`);}catch{ /* The project works without its overview note. */ }}}
    return {...project,exists:true,notes:projectNotes(project)};
  }
  const bootstrapKey=crypto.randomBytes(32).toString('hex');
  const sessionKey=crypto.randomBytes(32).toString('hex');
  const phoneKeyFile=path.join(stateDir,'phone.key');
  if(!fs.existsSync(phoneKeyFile))fs.writeFileSync(phoneKeyFile,crypto.randomBytes(32).toString('hex'),{flag:'wx',mode:0o600});
  if(fs.lstatSync(phoneKeyFile).isSymbolicLink())throw new Error('Phone pairing key must not be a symbolic link.');
  fs.chmodSync(phoneKeyFile,0o600);
  const phoneKey=fs.readFileSync(phoneKeyFile,'utf8');
  if(!/^[a-f0-9]{64}$/.test(phoneKey))throw new Error('The phone pairing key is damaged. Restore it from your backup.');
  const phoneSecret=kind=>{const p=configStore.read().phone;return crypto.createHmac('sha256',phoneKey).update(JSON.stringify([kind,p.hostname,p.owner])).digest('hex');};
  const origin=`http://127.0.0.1:${port}`;
  let job=null,abort=null,active=null,closing=false,lastActivity=now();
  let hardwareCache=null,hardwareAt=0;
  const cpuUsage=createCpuSampler();
  // Memory held by the model server: the one Black Team started, or the user's own on the configured port.
  let serverPidAt=0,serverPid=null;
  function modelMemory(config){
    let pid=typeof runtime.modelPid==='function'?runtime.modelPid():null;
    if(!pid&&config.model.source==='server'){
      if(Date.now()-serverPidAt>15000){let port=null;try{port=Number(new URL(config.model.endpoint).port);}catch{}serverPid=serverProcess(port);serverPidAt=Date.now();}
      pid=serverPid;
    }
    return pid?processMemory(pid):null;
  }

  async function status(access='desktop') {
    const config=configStore.read();const state=runtime.status();
    const {_approve,...publicJob}=job||{};
    const common={access,version,setupComplete:Boolean(config.model.source==='server'?config.model.id&&config.model.endpoint:config.model.file&&config.model.runtime),runtime:{state:state.state,ready:state.ready,busy:state.busy,name:config.model.name,error:state.error},threads:history.list(),job:job?publicJob:null,agentEnabled:true,hermesEnabled:Boolean(agentRunner&&integrations?.read().hermes.enabled),projects:projectList(),memory:Boolean(memory),dictation:access==='desktop'&&Boolean(dictation()),performance:(()=>{const memory=memoryInfo();return {cpu:cpuUsage(),cores:os.cpus().length,load:os.loadavg()[0],memory:{total:memory.total,free:memory.available,used:memory.used,swapTotal:memory.swapTotal,swapUsed:memory.swapUsed},temperature:cpuTemperature()?.celsius??null,model:modelMemory(config)};})()};
    if(access==='phone') return {...common,config:{model:{name:config.model.name}},phone:{enabled:true}};
    if(!hardwareCache || Date.now()-hardwareAt>5000) {
      const report=await hardwareReport(stateDir);let warnings=[];
      try {const estimate=estimateMemory(fs.statSync(config.model.file).size,report.memory.total,report.memory.free);if(estimate.warning)warnings.push(estimate.warning);}catch{}
      hardwareCache={...report,cores:report.cpu.cores,threads:report.cpu.threads,warnings};hardwareAt=Date.now();
    }
    const phoneState=await phone.status();
    const {apiKey, ...publicModel}=config.model;
    return {...common,config:{...config,model:publicModel},models:savedModels?savedModels.list(config.model):[],serverKeyConfigured:Boolean(apiKey),integrations:integrations?.read(),hardware:hardwareCache,phone:{...phoneState,url:phoneState.url?`${phoneState.url}#pair=${phoneSecret('pair')}`:''}};
  }

  function submit(input) {
    if(closing) throw fail('Black Team is closing.',503);
    const message=typeof input.message==='string'?input.message.trim():'';
    if(!message || message.length>16000) throw fail('Enter a message of up to 16,000 characters.');
    const kind=input.kind||'chat';if(!['chat','agent'].includes(kind))throw fail('Choose Chat or Agent work.');
    const mode=input.mode||'balanced';if(!MODES.includes(mode))throw fail('Choose a supported response length.');
    if(typeof input.requestId!=='string'||!ID.test(input.requestId)) throw fail('A valid request ID is required.');
    if(input.threadId && (typeof input.threadId!=='string'||!ID.test(input.threadId)))throw fail('Invalid conversation ID.');
    if(input.project!==undefined&&input.project!==null&&(typeof input.project!=='string'||!ID.test(input.project)))throw fail('Invalid project.');
    const hash=crypto.createHash('sha256').update(JSON.stringify([...(kind==='agent'?[input.threadId||null,message,mode,kind]:[input.threadId||null,message,mode]),...(input.project?[input.project]:[])])).digest('hex');
    const saved=history.requests.get(input.requestId);
    if(saved) {
      if(saved.hash!==hash)throw fail('Request ID was already used for another message.',409);
      return {id:saved.id,threadId:saved.threadId,state:saved.state};
    }
    if(active)throw fail('A response is already running. Wait or stop it before sending another.',409);
    const config=configStore.read();if(config.model.source==='server'?!config.model.id:(!config.model.file||!config.model.runtime))throw fail('Complete model setup in the desktop app first.',409);
    const existing=input.threadId?history.get(input.threadId):null;
    if(input.threadId&&!existing)throw fail('Conversation not found.',404);
    if(existing&&(existing.kind||'chat')!==kind)throw fail('Start a new conversation to change between Chat and Agent work.',409);
    // A conversation started inside a project belongs to it, and its Code work happens in the project's folder.
    const project=projects.find(item=>item.id===(existing?existing.project:input.project))||null;
    if(!existing&&input.project&&!project)throw fail('That project no longer exists.');
    // Code runs on Black Team's own engine. Hermes is used when the user chose it, and for conversations it started.
    const settings=kind==='agent'?integrations?.read():null;
    const agentEngine=kind!=='agent'?null:existing?(existing.engine||(existing.hermesSession?'hermes':'black-team')):(agentRunner&&settings?.hermes.enabled&&settings.engine==='hermes'?'hermes':'black-team');
    if(agentEngine==='hermes'&&(!agentRunner||!settings?.hermes.enabled))throw fail('This conversation uses Hermes. Enable it in desktop Settings, or start a new Code conversation.',409);
    if(agentEngine==='black-team'&&!engine)throw fail('Code is unavailable in this build.',409);
    const thread=existing?structuredClone(existing):history.create(message);thread.kind=kind;
    if(agentEngine)thread.engine=agentEngine;
    if(!existing&&project)thread.project=project.id;
    const workspace=project?.workspace||config.workspace;
    if(thread.messages.length>=1000||Buffer.byteLength(JSON.stringify(thread))>5*1024*1024)throw fail('This conversation is full. Start a new conversation.');
    const assistant={id:crypto.randomUUID(),role:'assistant',content:'',state:'writing',model:configStore.read().model.name};
    thread.messages.push({id:crypto.randomUUID(),role:'user',content:message,state:'done'},assistant);
    thread.updated=new Date().toISOString();
    const request={id:input.requestId,hash,state:'running'};
    thread.requests.push(request);history.save(thread);history.remember(thread,request);
    job={id:request.id,threadId:thread.id,kind,state:'running',progress:'Preparing local model…'};
    abort=new AbortController();const controller=abort;
    active=Promise.resolve().then(async()=>{
      try {
        controller.signal.throwIfAborted();
        const endpoint=await runtime.start();controller.signal.throwIfAborted();runtime.setBusy(true);
        if(kind==='agent'){
          if(agentEngine==='hermes'){
            job.progress='Starting Black Team harness with Hermes tools…';
            await agentRunner.run({thread,assistant,config:{...config,workspace},runtime,endpoint,job,signal:controller.signal,save:()=>history.save(thread)});
          } else {
            job.progress='Starting Black Team Code…';
            await engine.run({thread,assistant,config,runtime,endpoint,job,signal:controller.signal,save:()=>history.save(thread),mode,workspace});
          }
          controller.signal.throwIfAborted();
          assistant.state='done';request.state='done';job.state='done';job.progress='Agent task complete';
          return;
        }
        if(memory) {
          if(thread.core===undefined)thread.core=memory.core();
          const asked=thread.messages.at(-2);
          if(asked.recalled===undefined){try{asked.recalled=await memory.lookup(asked.content,project?.workspace);}catch{asked.recalled=[];}}
        }
        job.progress='Reading conversation context…';
        const prepared=await (config.model.source==='server'?prepareServerContext:contextPlanner)({messages:messagesFor(thread),context:config.model.context,mode,endpoint,headers:runtime.requestHeaders(),fetch:fetcher,signal:controller.signal});
        controller.signal.throwIfAborted();assistant.context=prepared.report;job.context=prepared.report;
        job.progress='Thinking…';
        const response=await fetcher(`${endpoint}/chat/completions`,{
          method:'POST',headers:{'Content-Type':'application/json',...runtime.requestHeaders()},redirect:'error',
          signal:AbortSignal.any([controller.signal,AbortSignal.timeout(30*60*1000)]),
          body:JSON.stringify({model:config.model.source==='server'?config.model.id:'black-team-local',messages:prepared.messages,stream:true,stream_options:{include_usage:true},max_tokens:prepared.maxTokens,temperature:0.7})
        });
        if(!response.ok){await response.body?.cancel();throw fail(`Local model request failed (${response.status}). Check your model and context settings.`,502);}
        let lastFlush=Date.now(),firstToken=0;
        const streamResult=await readStream(response,delta=>{
          if(!firstToken&&(delta.content||delta.reasoning_content||delta.reasoning))firstToken=Date.now();
          if(typeof delta.content==='string') {
            const available=256*1024-assistant.content.length;
            assistant.content+=delta.content.slice(0,available);job.progress='Writing a reply…';
            if(delta.content.length>available)throw fail('Response reached the storage limit. Ask for a shorter answer.');
          } else if(delta.reasoning_content || delta.reasoning)job.progress='Thinking…';
          if(Date.now()-lastFlush>750){history.save(thread);lastFlush=Date.now();}
        },controller.signal);
        assistant.finishReason=streamResult.finishReason;
        // Measured speed for the gauge. llama.cpp reports it; for other servers the clock gives the writing speed.
        const timed=streamResult.timings,written=streamResult.usage?.completion_tokens;
        const write=timed?.predicted_per_second>0?timed.predicted_per_second:(written>0&&firstToken?written/Math.max(0.05,(Date.now()-firstToken)/1000):0);
        if(write>0&&Number.isFinite(write)){
          const report=prepared.report||{};
          assistant.meter={...(timed?.prompt_n>=200&&timed.prompt_per_second>0?{read:Math.round(timed.prompt_per_second)}:{}),write:Math.max(1,Math.round(write)),
            ...(Number.isSafeInteger(report.measuredInputTokens)&&Number.isSafeInteger(report.inputBudget)?{used:report.measuredInputTokens,budget:report.inputBudget,window:report.context}:{})};
          job.meter=assistant.meter;
        }
        controller.signal.throwIfAborted();
        if(!assistant.content.trim()) throw fail('The model returned no visible answer. Try a larger response budget or a different model.');
        assistant.state='done';request.state='done';job.state='done';job.progress='Response complete';
      } catch(error) {
        const cancelled=controller.signal.aborted;
        assistant.state=cancelled?'interrupted':'error';request.state=assistant.state;job.state=assistant.state;
        assistant.error=cancelled?'Response stopped.':(error.message||'The local response failed.');
        job.progress=assistant.error;
      } finally {
        runtime.setBusy(false);thread.updated=new Date().toISOString();
        history.remember(thread,request);
        try{history.save(thread);}catch{job.state='error';job.progress='Could not save this conversation. Check available disk space.';}
        abort=null;active=null;lastActivity=now();sweepMemory();
      }
    });
    return {id:request.id,threadId:thread.id,state:'running'};
  }
  // One oversized note is rewritten shorter by the local model, only when it is already loaded and idle.
  // The keeper never starts a model on its own.
  function condenseMemory(again=false) {
    if(!memory||active||closing)return null;
    let oversized;try{oversized=memory.usage().oversized;}catch{return null;}
    if(!oversized.length)return null;
    const state=runtime.status();
    if(!state.ready||state.busy)return 'Start your model, then tidy memory again to condense the notes that are over their limit.';
    const current=job={id:crypto.randomUUID(),threadId:null,kind:'memory',state:'running',progress:'Tidying memory…'};
    abort=new AbortController();const controller=abort;
    active=Promise.resolve().then(async()=>{
      try {
        const endpoint=await runtime.start();controller.signal.throwIfAborted();runtime.setBusy(true);
        const config=configStore.read();
        const result=await memory.condense(async({title,content,target})=>{
          // A note that would not fit the model's window is left as it is.
          if(content.length/3>config.model.context*0.5)return '';
          const response=await fetcher(`${endpoint}/chat/completions`,{method:'POST',headers:{'Content-Type':'application/json',...runtime.requestHeaders()},redirect:'error',
            signal:AbortSignal.any([controller.signal,AbortSignal.timeout(15*60*1000)]),
            body:JSON.stringify({model:config.model.source==='server'?config.model.id:'black-team-local',stream:false,max_tokens:Math.min(1800,Math.floor(config.model.context/4)),temperature:0.2,messages:[
              {role:'system',content:'You maintain a notes file. Rewrite the note shorter. Keep every distinct fact, decision, name, path, number and date. Merge repeats. Drop only chatter and duplicates. Keep the newest version when two lines disagree. Output only the rewritten note in Markdown, starting with its # heading.'},
              {role:'user',content:`Note title: ${title}\nRewrite it in at most ${target} characters.\n\n${content}`}]})});
          if(!response.ok){await response.body?.cancel();throw new Error('The model could not condense the note.');}
          return (await response.json()).choices?.[0]?.message?.content||'';
        },{again});
        if(result)try{keeperNote([result]);}catch{}
        current.state='done';current.progress=result||'Memory is within its limits.';
      } catch {
        current.state=controller.signal.aborted?'interrupted':'error';current.progress=controller.signal.aborted?'Memory upkeep stopped.':'Memory upkeep could not finish. Nothing was changed.';
      } finally {try{runtime.setBusy(false);}catch{}abort=null;active=null;lastActivity=now();}
    });
    return 'Condensing one note with your local model…';
  }
  const keeper=setInterval(()=>{if(!active&&!closing&&now()-lastActivity>15*60*1000){lastActivity=now();sweepMemory();condenseMemory();}},60000);
  keeper.unref();
  function cancel() {
    if(abort){
      job.progress='Stopping response…';abort.abort(new Error('Response stopped.'));
      if(runtime.status().state==='starting')runtime.stop({force:true}).catch(()=>{});
    }
    return {stopping:Boolean(abort)};
  }

  async function authorize(req,url) {
    if(!['127.0.0.1','::1','::ffff:127.0.0.1'].includes(req.socket?.remoteAddress)) throw fail('Local access only.',403);
    const host=String(req.headers.host||'').toLowerCase();
    const local=host===`127.0.0.1:${port}`;
    const config=configStore.read();
    const remote=config.phone.enabled && host===`${config.phone.hostname}:${PHONE_PORT}`;
    if(!local&&!remote)throw fail('Unrecognized Black Team address.',403);
    const expectedOrigin=local?origin:`https://${config.phone.hostname}:${PHONE_PORT}`;
    if(req.headers.origin && req.headers.origin!==expectedOrigin)throw fail('Origin is not allowed.',403);
    if(!['GET','HEAD'].includes(req.method) && req.headers.origin!==expectedOrigin)throw fail('A same-origin request is required.',403);
    if(local && url.pathname==='/bootstrap' && req.method==='GET' && equal(url.searchParams.get('key'),bootstrapKey))return 'bootstrap';
    if(local) {
      const cookie=String(req.headers.cookie||'').split(';').map(x=>x.trim()).find(x=>x.startsWith('black_team_session='))?.slice(19);
      if(equal(cookie,sessionKey))return 'desktop';
    } else if(equal(req.headers['tailscale-user-login'],config.phone.owner) && (await phone.status()).connected) {
      const cookie=String(req.headers.cookie||'').split(';').map(x=>x.trim()).find(x=>x.startsWith('black_team_phone='))?.slice(17);
      if(equal(cookie,phoneSecret('session')))return 'phone';
      if(url.pathname==='/api/pair'&&req.method==='POST')return 'pairing';
      if(!url.pathname.startsWith('/api/')&&req.method==='GET')return 'unpaired';
    }
    throw fail('Open Black Team on this computer, or connect Companion using its saved Tailscale account.',401);
  }

  async function handler(req,res) {
    securityHeaders(res);
    try {
      let url;try{url=new URL(req.url,origin);}catch{throw fail('Invalid URL.');}
      const access=await authorize(req,url);
      if(access==='bootstrap') {
        res.statusCode=303;res.setHeader('Set-Cookie',`black_team_session=${sessionKey}; Path=/; HttpOnly; SameSite=Strict`);res.setHeader('Location','/');res.end();return;
      }
      if(url.pathname==='/api/pair'&&req.method==='POST'&&['pairing','phone'].includes(access)) {
        const input=await bodyJSON(req);
        if(!equal(input.key,phoneSecret('pair')))throw fail('Open the current pairing link from your Black Team desktop app.',401);
        res.setHeader('Set-Cookie',`black_team_phone=${phoneSecret('session')}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=2592000`);
        return json(res,200,{paired:true});
      }
      if(url.pathname==='/api/approval'&&req.method==='POST'){const input=await bodyJSON(req);if(!job?._approve)throw fail('No active approval.',409);try{job._approve(input.id,input.digest,input.choice);}catch{throw fail('No matching active approval.',409);}return json(res,200,{sent:true});}
      if(url.pathname.startsWith('/api/file/')&&req.method==='GET'){
        const id=url.pathname.slice('/api/file/'.length);
        if(!/^[a-f0-9]{32}$/.test(id))throw fail('File not found.',404);
        const artifact=[...history.rows.values()].flatMap(t=>t.messages.flatMap(m=>m.artifacts||[])).find(a=>a.id===id);
        if(!artifact)throw fail('File not found.',404);
        const file=path.join(stateDir,'artifacts',id);let stat;try{stat=fs.lstatSync(file);}catch{throw fail('File not found.',404);}
        if(!stat.isFile()||stat.isSymbolicLink())throw fail('File not found.',404);
        res.statusCode=200;res.setHeader('Content-Type','application/octet-stream');res.setHeader('Content-Disposition',"attachment; filename*=UTF-8''"+encodeURIComponent(artifact.name));res.setHeader('Content-Length',stat.size);fs.createReadStream(file).pipe(res);return;
      }
      if(url.pathname==='/api/status'&&req.method==='GET')return json(res,200,await status(access));
      // Plain errors from memory, projects and undo are messages meant for the user.
      const mine=async work=>{try{return await work();}catch(error){throw error.status?error:fail(error.message||'That could not be done.');}};
      if(url.pathname==='/api/project-create'&&req.method==='POST'){const input=await bodyJSON(req);return json(res,200,await mine(()=>createProject(input)));}
      // Undo one file edit the engine made. Refused while a task runs, so a file never changes under the agent.
      if(url.pathname==='/api/undo'&&req.method==='POST'){const input=await bodyJSON(req);if(!engine)throw fail('Not found.',404);if(active)throw fail('Wait for the running task to finish, or stop it, before undoing an edit.',409);return json(res,200,await mine(()=>engine.undo(input.id)));}
      // Dictation is the system's own local speech tool. The button only starts and stops it; the words are typed into the focused text bar.
      if(url.pathname==='/api/dictate'&&req.method==='POST'){
        await bodyJSON(req);
        if(access!=='desktop')throw fail('Use your phone keyboard’s microphone to dictate.',403);
        const tool=dictation();if(!tool)throw fail('No system dictation tool is set up on this computer.',404);
        const child=spawnImpl(tool,path.basename(tool)==='voxtype'?['record','toggle']:[],{detached:true,stdio:'ignore',shell:false,env:localEnvironment()});child.on('error',()=>{});child.unref();
        return json(res,200,{toggled:true});
      }
      if(url.pathname.startsWith('/api/memory')) {
        if(!memory)throw fail('Memory is unavailable in this build.',404);
        if(url.pathname==='/api/memory'&&req.method==='GET')return json(res,200,await mine(()=>({notes:memory.notes().map(({links,...note})=>note),graph:memory.graph(),keeper:{usage:memory.usage(),limits:memory.limits,actions:keeperLog.slice(0,12)}})));
        if(url.pathname==='/api/memory/note'&&req.method==='GET')return json(res,200,await mine(()=>memory.read(url.searchParams.get('id'))));
        if(url.pathname==='/api/memory/search'&&req.method==='GET')return json(res,200,{hits:await mine(()=>memory.search(url.searchParams.get('q')||'',{limit:30}))});
        if(req.method==='POST') {
          const input=await bodyJSON(req,url.pathname==='/api/memory/save'?900*1024:65536);
          if(url.pathname==='/api/memory/save')return json(res,200,await mine(()=>memory.write(input.id,input.content)));
          if(url.pathname==='/api/memory/delete')return json(res,200,await mine(()=>{memory.remove(input.id);return {removed:true};}));
          if(url.pathname==='/api/memory/remember')return json(res,200,await mine(()=>({id:memory.remember(input.title,input.text,projects.find(item=>item.id===input.project)?.workspace)})));
          if(url.pathname==='/api/memory/tidy'){if(active)return json(res,200,{message:'A task is running. Tidy memory when it finishes.'});sweepMemory();return json(res,200,{message:condenseMemory(true)||'Memory is within its limits.'});}
        }
        throw fail('Not found.',404);
      }
      if(url.pathname.startsWith('/api/thread/')&&req.method==='GET') {
        const thread=history.get(url.pathname.slice('/api/thread/'.length));if(!thread)throw fail('Conversation not found.',404);
        return json(res,200,{id:thread.id,title:thread.title,updated:thread.updated,kind:thread.kind||'chat',messages:thread.messages});
      }
      if(url.pathname.startsWith('/api/request/')&&req.method==='GET') {
        const request=history.requests.get(url.pathname.slice('/api/request/'.length));if(!request)throw fail('Request not found.',404);
        return json(res,200,{id:request.id,threadId:request.threadId,state:request.state});
      }
      if(url.pathname==='/api/chat'&&req.method==='POST')return json(res,202,submit(await bodyJSON(req)));
      if(url.pathname==='/api/cancel'&&req.method==='POST'){await bodyJSON(req);return json(res,200,cancel());}
      if(url.pathname.startsWith('/api/')||!['GET','HEAD'].includes(req.method))throw fail('Not found.',404);
      let relative;try{relative=decodeURIComponent(url.pathname);}catch{throw fail('Invalid path.');}
      if(relative==='/' || relative==='/index.html')relative='/index.html';
      if(relative.includes('\0')||relative.includes('\\')||relative.split('/').includes('..'))throw fail('Invalid path.');
      const file=path.resolve(distDir,`.${relative}`);const root=fs.realpathSync(distDir);
      if(!file.startsWith(root+path.sep))throw fail('Not found.',404);
      let real;try{real=fs.realpathSync(file);}catch{throw fail('Not found.',404);}
      if(!real.startsWith(root+path.sep)||!fs.statSync(real).isFile())throw fail('Not found.',404);
      const content=fs.readFileSync(real);res.statusCode=200;res.setHeader('Content-Type',MIME[path.extname(real)]||'application/octet-stream');
      res.setHeader('Content-Length',content.length);if(relative==='/sw.js')res.setHeader('Service-Worker-Allowed','/');
      res.end(req.method==='HEAD'?undefined:content);
    } catch(error) {json(res,error.status||500,{error:error.status?error.message:'Black Team could not complete this request. Check the desktop app.'});}
  }
  const server=http.createServer(handler);
  server.requestTimeout=15000;server.headersTimeout=10000;server.keepAliveTimeout=5000;
  return {handler,status,submit,cancel,history,origin,bootstrapURL:`${origin}/bootstrap?key=${bootstrapKey}`,
    isBusy:()=>Boolean(active),waitForIdle:()=>active||Promise.resolve(),
    listen:()=>new Promise((resolve,reject)=>{server.once('error',reject);server.listen({host:'127.0.0.1',port,exclusive:true},()=>{server.removeListener('error',reject);resolve();});}),
    close:async()=>{closing=true;clearInterval(keeper);cancel();await runtime.dispose();await active;await new Promise(resolve=>server.listening?server.close(resolve):resolve());},
  };
}
module.exports={createBackend,messagesFor,readStream,bodyJSON,equal};
