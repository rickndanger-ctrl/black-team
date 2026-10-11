'use strict';
const http=require('node:http');
const os=require('node:os');
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const {History,ID}=require('./history.cjs');
const {hardwareReport,estimateMemory}=require('./config.cjs');
const {prepareContext,prepareServerContext}=require('./context.cjs');
const {LOCAL_PORT,PHONE_PORT}=require('./phone.cjs');
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
async function bodyJSON(req) {
  if(!String(req.headers['content-type']||'').toLowerCase().startsWith('application/json')) throw fail('Send JSON.',415);
  let size=0; const chunks=[];
  for await(const chunk of req) {size+=chunk.length; if(size>65536) throw fail('Request is too large.',413); chunks.push(chunk);}
  try {
    const body=JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if(!body || typeof body!=='object' || Array.isArray(body)) throw new Error();
    return body;
  } catch {throw fail('Invalid JSON request.');}
}
function messagesFor(thread) {
  const result=[{role:'system',content:SYSTEM}];
  for(let i=0;i<thread.messages.length-2;i++) {
    const user=thread.messages[i],assistant=thread.messages[i+1];
    if(user.role==='user' && assistant?.role==='assistant' && assistant.state==='done' && assistant.content) {
      result.push({role:'user',content:user.content},{role:'assistant',content:assistant.content});i++;
    }
  }
  result.push({role:'user',content:thread.messages.at(-2).content});
  return result;
}

async function readStream(response,onDelta,signal) {
  if(!response.body) throw fail('The local model returned no response.',502);
  const decoder=new TextDecoder(); let pending='',finished=false,finishReason=null;
  const processLine=line=>{
    if(!line.startsWith('data:')) return;
    const data=line.slice(5).trim(); if(!data) return;
    if(data==='[DONE]') {finished=true;return;}
    let item;try{item=JSON.parse(data);}catch{throw fail('The local model returned an invalid stream.',502);}
    if(item.error) throw fail('The local model could not complete the response. Check the model and context settings.',502);
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
  return {finishReason};
}

function createBackend({stateDir,distDir,configStore,runtime,phone,version='0.1.0-alpha.1',fetch:fetcher=globalThis.fetch,contextPlanner=prepareContext,port=LOCAL_PORT,integrations=null,agentRunner=null}) {
  const history=new History(stateDir);
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
  let job=null,abort=null,active=null,closing=false;
  let hardwareCache=null,hardwareAt=0;
  let previousCpu=os.cpus();
  function cpuUsage(){const current=os.cpus();let total=0,idle=0;current.forEach((cpu,i)=>{for(const key of Object.keys(cpu.times)){const delta=cpu.times[key]-(previousCpu[i]?.times[key]||0);total+=delta;if(key==='idle')idle+=delta;}});previousCpu=current;return total?Math.max(0,Math.min(100,Math.round(100*(1-idle/total)))):0;}

  async function status(access='desktop') {
    const config=configStore.read();const state=runtime.status();
    const {_approve,...publicJob}=job||{};
    const common={access,version,setupComplete:Boolean(config.model.source==='server'?config.model.id&&config.model.endpoint:config.model.file&&config.model.runtime),runtime:{state:state.state,ready:state.ready,busy:state.busy,name:config.model.name,error:state.error},threads:history.list(),job:job?publicJob:null,agentEnabled:Boolean(integrations?.read().hermes.enabled),performance:{cpu:cpuUsage(),cores:os.cpus().length,load:os.loadavg()[0],memory:{total:os.totalmem(),free:os.freemem()}}};
    if(access==='phone') return {...common,config:{model:{name:config.model.name}},phone:{enabled:true}};
    if(!hardwareCache || Date.now()-hardwareAt>5000) {
      const report=await hardwareReport(stateDir);let warnings=[];
      try {const estimate=estimateMemory(fs.statSync(config.model.file).size,report.memory.total,report.memory.free);if(estimate.warning)warnings.push(estimate.warning);}catch{}
      hardwareCache={...report,cores:report.cpu.cores,warnings};hardwareAt=Date.now();
    }
    const phoneState=await phone.status();
    const {apiKey, ...publicModel}=config.model;
    return {...common,config:{...config,model:publicModel},serverKeyConfigured:Boolean(apiKey),integrations:integrations?.read(),hardware:hardwareCache,phone:{...phoneState,url:phoneState.url?`${phoneState.url}#pair=${phoneSecret('pair')}`:''}};
  }

  function submit(input) {
    if(closing) throw fail('Black Team is closing.',503);
    const message=typeof input.message==='string'?input.message.trim():'';
    if(!message || message.length>16000) throw fail('Enter a message of up to 16,000 characters.');
    const kind=input.kind||'chat';if(!['chat','agent'].includes(kind))throw fail('Choose Chat or Agent work.');
    if(kind==='agent'&&(!agentRunner||!integrations?.read().hermes.enabled))throw fail('Enable Hermes in desktop Settings before using Agent work.',409);
    const mode=input.mode||'balanced';if(!MODES.includes(mode))throw fail('Choose a supported response length.');
    if(typeof input.requestId!=='string'||!ID.test(input.requestId)) throw fail('A valid request ID is required.');
    if(input.threadId && (typeof input.threadId!=='string'||!ID.test(input.threadId)))throw fail('Invalid conversation ID.');
    const hash=crypto.createHash('sha256').update(JSON.stringify(kind==='agent'?[input.threadId||null,message,mode,kind]:[input.threadId||null,message,mode])).digest('hex');
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
    const thread=existing?structuredClone(existing):history.create(message);thread.kind=kind;
    if(thread.messages.length>=1000||Buffer.byteLength(JSON.stringify(thread))>5*1024*1024)throw fail('This conversation is full. Start a new conversation.');
    const assistant={id:crypto.randomUUID(),role:'assistant',content:'',state:'writing'};
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
          job.progress='Starting Black Team harness with Hermes tools…';
          await agentRunner.run({thread,assistant,config,runtime,endpoint,job,signal:controller.signal,save:()=>history.save(thread)});
          controller.signal.throwIfAborted();
          assistant.state='done';request.state='done';job.state='done';job.progress='Agent task complete';
          return;
        }
        job.progress='Reading conversation context…';
        const prepared=await (config.model.source==='server'?prepareServerContext:contextPlanner)({messages:messagesFor(thread),context:config.model.context,mode,endpoint,headers:runtime.requestHeaders(),fetch:fetcher,signal:controller.signal});
        controller.signal.throwIfAborted();assistant.context=prepared.report;job.context=prepared.report;
        job.progress='Thinking…';
        const response=await fetcher(`${endpoint}/chat/completions`,{
          method:'POST',headers:{'Content-Type':'application/json',...runtime.requestHeaders()},redirect:'error',
          signal:AbortSignal.any([controller.signal,AbortSignal.timeout(30*60*1000)]),
          body:JSON.stringify({model:config.model.source==='server'?config.model.id:'black-team-local',messages:prepared.messages,stream:true,max_tokens:prepared.maxTokens,temperature:0.7})
        });
        if(!response.ok){await response.body?.cancel();throw fail(`Local model request failed (${response.status}). Check your model and context settings.`,502);}
        let lastFlush=Date.now();
        const streamResult=await readStream(response,delta=>{
          if(typeof delta.content==='string') {
            const available=256*1024-assistant.content.length;
            assistant.content+=delta.content.slice(0,available);job.progress='Writing a reply…';
            if(delta.content.length>available)throw fail('Response reached the storage limit. Ask for a shorter answer.');
          } else if(delta.reasoning_content || delta.reasoning)job.progress='Thinking…';
          if(Date.now()-lastFlush>750){history.save(thread);lastFlush=Date.now();}
        },controller.signal);
        assistant.finishReason=streamResult.finishReason;
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
        abort=null;active=null;
      }
    });
    return {id:request.id,threadId:thread.id,state:'running'};
  }
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
    close:async()=>{closing=true;cancel();await runtime.dispose();await active;await new Promise(resolve=>server.listening?server.close(resolve):resolve());},
  };
}
module.exports={createBackend,messagesFor,readStream,bodyJSON,equal};
