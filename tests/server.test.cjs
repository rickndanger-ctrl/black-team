'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const crypto=require('node:crypto');
const {Readable}=require('node:stream');
const {createBackend,readStream,messagesFor,equal}=require('../lib/server.cjs');

function streamResponse(text,step=3) {
  const bytes=Buffer.from(text);
  return {ok:true,status:200,body:(async function*(){for(let i=0;i<bytes.length;i+=step)yield bytes.subarray(i,i+step);})()};
}
const answerStream='data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}\n\n'+
  'data: {"choices":[{"delta":{"content":"Private 🖤 café"}}]}\r\n\r\n'+
  'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n';
function fixture(t,options={}) {
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'black-team-server-'));
  const stateDir=path.join(directory,'state'),distDir=path.join(directory,'dist');
  fs.mkdirSync(distDir);fs.writeFileSync(path.join(distDir,'index.html'),'<title>Black Team</title>');
  fs.writeFileSync(path.join(distDir,'sw.js'),'/* local shell */');
  const config={model:{name:'Fixture model',file:'/private/model.gguf',runtime:'/private/llama-server',context:4096},workspace:'/private/work',phone:{enabled:true,hostname:'computer.testnet.ts.net',owner:'owner@example.test'}};
  let connected=true;
  const calls={starts:0,fetch:[],contexts:[],busy:[],disposals:0,stops:[]};
  const runtime={status:()=>({state:options.runtimeState||'off',ready:false,busy:false,endpoint:'http://127.0.0.1:5555/v1',apiKey:'never-expose-runtime-key'}),
    start:async()=>{calls.starts++;return options.start?options.start():'http://127.0.0.1:5555/v1';},
    requestHeaders:()=>({Authorization:'Bearer local-test-key'}),setBusy:value=>calls.busy.push(value),dispose:async()=>{calls.disposals++;},stop:async data=>{calls.stops.push(data);}};
  const configStore={read:()=>structuredClone(config)};
  const phone={status:async()=>({connected,enabled:config.phone.enabled,url:'https://computer.testnet.ts.net:8449/',command:'private configuration'})};
  const backends=[];
  function make() {
    const backend=createBackend({stateDir,distDir,configStore,runtime,phone,integrations:options.integrations,agentRunner:options.agentRunner,...options.backend,
      contextPlanner:async input=>{calls.contexts.push(input);return {messages:input.messages,maxTokens:512,report:{method:'fixture',omittedMessages:0}};},
      fetch:async(...args)=>{calls.fetch.push(args);return options.fetch?options.fetch(...args):streamResponse(answerStream);}});
    backends.push(backend);return backend;
  }
  const backend=make();
  t.after(async()=>{for(const item of backends)await item.close();fs.rmSync(directory,{recursive:true,force:true});});
  return {directory,stateDir,distDir,config,runtime,calls,backend,make,disconnect:()=>{connected=false;},reconnect:()=>{connected=true;}};
}
async function request(backend,url,options={}) {
  const data=options.raw!==undefined?Buffer.from(options.raw):options.body===undefined?null:Buffer.from(JSON.stringify(options.body));
  const req=Readable.from(data?[data]:[]);
  req.url=url;req.method=options.method||'GET';
  req.headers={host:new URL(backend.origin).host,...(data?{'content-type':'application/json'}:{}),...options.headers};
  req.socket={remoteAddress:options.address||'127.0.0.1'};
  const res={statusCode:200,headers:{},setHeader(name,value){this.headers[name.toLowerCase()]=value;},end(value){this.bytes=value===undefined?Buffer.alloc(0):Buffer.from(value);}};
  await backend.handler(req,res);
  res.text=res.bytes.toString('utf8');
  if(String(res.headers['content-type']).startsWith('application/json'))res.body=JSON.parse(res.text);
  return res;
}
async function desktop(backend) {
  const result=await request(backend,new URL(backend.bootstrapURL).pathname+new URL(backend.bootstrapURL).search);
  assert.equal(result.statusCode,303);
  return {cookie:result.headers['set-cookie'].split(';')[0],origin:backend.origin};
}

test('bootstrap is local, authenticated, cookie-only afterward and protected by security headers',async t=>{
  const {backend}=fixture(t);
  assert.equal((await request(backend,'/api/status')).statusCode,401);
  assert.equal((await request(backend,'/bootstrap?key=incorrect')).statusCode,401);
  const headers=await desktop(backend);
  const authenticated=await request(backend,'/api/status',{headers});
  assert.equal(authenticated.statusCode,200);
  assert.equal(authenticated.body.access,'desktop');
  assert.equal(authenticated.headers['cache-control'],'no-store');
  assert.match(authenticated.headers['content-security-policy'],/frame-ancestors 'none'/);
  assert.equal(authenticated.headers['referrer-policy'],'no-referrer');
  assert.equal((await request(backend,'/api/status',{headers,address:'192.168.1.4'})).statusCode,403);
  assert.equal((await request(backend,'/api/status',{headers:{...headers,host:'attacker.test:18199'}})).statusCode,403);
  assert.equal((await request(backend,'/api/status',{headers:{...headers,origin:'https://attacker.test'}})).statusCode,403);
  assert.equal((await request(backend,'/api/status',{headers:{...headers,'tailscale-user-login':'wrong'}})).statusCode,200);
});

test('phone status filters machine configuration and requires verified owner and private route',async t=>{
  const {backend,disconnect}=fixture(t);
  const headers={host:'computer.testnet.ts.net:8449','tailscale-user-login':'owner@example.test',origin:'https://computer.testnet.ts.net:8449'};
  assert.equal((await request(backend,'/api/status',{headers})).statusCode,401);
  assert.equal((await request(backend,'/',{headers})).statusCode,200);
  const desktopHeaders=await desktop(backend);
  const desktopStatus=await request(backend,'/api/status',{headers:desktopHeaders});
  const key=new URLSearchParams(new URL(desktopStatus.body.phone.url).hash.slice(1)).get('pair');
  assert.match(key,/^[a-f0-9]{64}$/);
  assert.equal((await request(backend,'/api/pair',{method:'POST',headers,body:{key:'wrong'}})).statusCode,401);
  const paired=await request(backend,'/api/pair',{method:'POST',headers,body:{key}});
  assert.equal(paired.statusCode,200);assert.equal(paired.body.paired,true);
  assert.match(paired.headers['set-cookie'],/HttpOnly; Secure; SameSite=Strict/);
  headers.cookie=paired.headers['set-cookie'].split(';')[0];
  const result=await request(backend,'/api/status',{headers});
  assert.equal(result.statusCode,200);assert.equal(result.body.access,'phone');
  assert.deepEqual(result.body.config,{model:{name:'Fixture model'}});
  assert.deepEqual(result.body.phone,{enabled:true});
  for(const value of ['/private','apiKey','local-test-key','owner@example.test','hardware','endpoint'])assert.equal(result.text.includes(value),false);
  assert.equal((await request(backend,'/api/status',{headers:{...headers,'tailscale-user-login':'other@example.test'}})).statusCode,401);
  assert.equal((await request(backend,'/api/status',{headers:{host:headers.host,cookie:desktopHeaders.cookie}})).statusCode,401);
  disconnect();assert.equal((await request(backend,'/api/status',{headers})).statusCode,401);
});

test('mutations enforce exact Origin and bounded JSON; unknown API routes remain inaccessible',async t=>{
  const {backend}=fixture(t);const headers=await desktop(backend);
  const payload={requestId:crypto.randomUUID(),message:'hello'};
  assert.equal((await request(backend,'/api/chat',{method:'POST',body:payload,headers:{cookie:headers.cookie}})).statusCode,403);
  assert.equal((await request(backend,'/api/chat',{method:'POST',body:payload,headers:{...headers,origin:'https://attacker.test'}})).statusCode,403);
  assert.equal((await request(backend,'/api/chat',{method:'POST',raw:'hello',headers:{...headers,'content-type':'text/plain'}})).statusCode,415);
  assert.equal((await request(backend,'/api/chat',{method:'POST',raw:'{',headers})).statusCode,400);
  assert.equal((await request(backend,'/api/chat',{method:'POST',raw:'[]',headers})).statusCode,400);
  assert.equal((await request(backend,'/api/chat',{method:'POST',raw:'x'.repeat(65537),headers})).statusCode,413);
  assert.equal((await request(backend,'/api/config',{method:'POST',body:{},headers})).statusCode,404);
  assert.equal((await request(backend,'/api/thread/'+crypto.randomUUID(),{headers})).statusCode,404);
});

test('static responses reject traversal and escaped symlinks; HEAD has no body',async t=>{
  const {backend,directory,distDir}=fixture(t);const headers=await desktop(backend);
  const outside=path.join(directory,'outside.txt');fs.writeFileSync(outside,'PRIVATE OUTSIDE');
  fs.symlinkSync(outside,path.join(distDir,'escape.txt'));
  const head=await request(backend,'/',{method:'HEAD',headers});
  assert.equal(head.statusCode,200);assert.equal(head.text,'');assert.ok(head.headers['content-length']>0);
  assert.equal((await request(backend,'/escape.txt',{headers})).statusCode,404);
  assert.equal((await request(backend,'/..%2foutside.txt',{headers})).statusCode,400);
  assert.equal((await request(backend,'/%00',{headers})).statusCode,400);
  assert.equal((await request(backend,'/%',{headers})).statusCode,400);
  assert.equal((await request(backend,'/missing',{headers})).statusCode,404);
  assert.equal((await request(backend,'/sw.js',{headers})).headers['service-worker-allowed'],'/');
});

test('one chat streams split UTF-8 safely, deduplicates retries and stays deduplicated after restart',async t=>{
  const {backend,calls,make}=fixture(t);
  const payload={requestId:crypto.randomUUID(),message:' A private question ',mode:'deep'};
  const sent=backend.submit(payload);assert.equal(sent.state,'running');
  assert.deepEqual(backend.submit(payload),sent);
  assert.throws(()=>backend.submit({...payload,message:'different'}),error=>error.status===409);
  assert.throws(()=>backend.submit({...payload,requestId:crypto.randomUUID()}),error=>error.status===409);
  await backend.waitForIdle();
  assert.equal(calls.starts,1);assert.equal(calls.fetch.length,1);
  assert.equal(backend.history.get(sent.threadId).messages.at(-1).content,'Private 🖤 café');
  assert.equal(backend.history.get(sent.threadId).messages.at(-1).state,'done');
  assert.equal(calls.contexts[0].mode,'deep');assert.equal(calls.contexts[0].messages.at(-1).content,'A private question');
  assert.equal(calls.fetch[0][1].redirect,'error');assert.equal(calls.fetch[0][1].headers.Authorization,'Bearer local-test-key');
  assert.equal(JSON.parse(calls.fetch[0][1].body).max_tokens,512);
  // The thinking level travels with every request, as one consistent set of fields.
  const requestBody=JSON.parse(calls.fetch[0][1].body);
  assert.equal(typeof requestBody.chat_template_kwargs.enable_thinking,'boolean');
  assert.equal(requestBody.reasoning_effort==='none',requestBody.chat_template_kwargs.enable_thinking===false);
  assert.deepEqual(calls.busy,[true,false]);
  await backend.close();const restarted=make();
  assert.equal(restarted.submit(payload).state,'done');assert.equal(calls.starts,1);
  assert.equal(restarted.isBusy(),false);
});

test('startup failure is saved and a retry ID never automatically restarts the model',async t=>{
  const {backend,calls,make}=fixture(t,{start:async()=>{throw new Error('Missing runtime library');}});
  const payload={requestId:crypto.randomUUID(),message:'hello'};const sent=backend.submit(payload);
  await backend.waitForIdle();
  assert.equal(calls.starts,1);assert.equal(calls.fetch.length,0);
  assert.equal(backend.history.get(sent.threadId).messages.at(-1).state,'error');
  assert.match(backend.history.get(sent.threadId).messages.at(-1).error,/Missing runtime/);
  assert.equal(backend.submit(payload).state,'error');assert.equal(calls.starts,1);
  await backend.close();assert.equal(make().submit(payload).state,'error');assert.equal(calls.starts,1);
});

test('cancel during startup is durable, sends no inference and does not retry after restart',async t=>{
  let finishStart;const starting=new Promise(resolve=>{finishStart=resolve;});
  const {backend,calls,make}=fixture(t,{start:()=>starting,runtimeState:'starting'});
  const payload={requestId:crypto.randomUUID(),message:'hello'};const sent=backend.submit(payload);
  await Promise.resolve();assert.equal(backend.cancel().stopping,true);
  finishStart('http://127.0.0.1:5555/v1');await backend.waitForIdle();
  assert.equal(calls.fetch.length,0);assert.equal(calls.contexts.length,0);
  assert.deepEqual(calls.stops,[{force:true}]);
  assert.equal(backend.history.get(sent.threadId).messages.at(-1).state,'interrupted');
  await backend.close();assert.equal(make().submit(payload).state,'interrupted');assert.equal(calls.starts,1);
});

test('interrupted persisted request is recovered without automatic model startup',async t=>{
  const {backend,calls,make}=fixture(t);
  const requestId=crypto.randomUUID(),message='recover this conversation';
  const thread=backend.history.create(message);
  thread.messages=[{id:crypto.randomUUID(),role:'user',content:message,state:'done'},{id:crypto.randomUUID(),role:'assistant',content:'partial',state:'writing'}];
  backend.history.remember(thread,{id:requestId,state:'running',hash:crypto.createHash('sha256').update(JSON.stringify([null,message,'balanced'])).digest('hex')});
  backend.history.save(thread);await backend.close();
  const restarted=make();assert.equal(restarted.submit({requestId,message}).state,'interrupted');
  assert.equal(restarted.history.get(thread.id).messages.at(-1).content,'partial');assert.equal(calls.starts,0);
});

test('incomplete inference is persisted as an error with no automatic retry',async t=>{
  const {backend,calls}=fixture(t,{fetch:async()=>streamResponse('data: {"choices":[{"delta":{"content":"partial"}}]}\n')});
  const payload={requestId:crypto.randomUUID(),message:'hello'};const sent=backend.submit(payload);
  await backend.waitForIdle();
  const assistant=backend.history.get(sent.threadId).messages.at(-1);
  assert.equal(assistant.state,'error');assert.equal(assistant.content,'partial');assert.match(assistant.error,/before the response finished/);
  assert.equal(backend.submit(payload).state,'error');assert.equal(calls.fetch.length,1);
});

test('empty visible answer is an error even when the model ends its stream normally',async t=>{
  const {backend}=fixture(t,{fetch:async()=>streamResponse('data: {"choices":[{"delta":{"reasoning_content":"hidden thought"}}]}\ndata: [DONE]\n')});
  const sent=backend.submit({requestId:crypto.randomUUID(),message:'hello'});await backend.waitForIdle();
  const assistant=backend.history.get(sent.threadId).messages.at(-1);
  assert.equal(assistant.state,'error');assert.equal(assistant.content,'');assert.match(assistant.error,/no visible answer/);
});

test('a failed first persistence does not mutate an existing conversation or poison retry IDs',async t=>{
  const {backend,calls}=fixture(t);
  const first=backend.submit({requestId:crypto.randomUUID(),message:'first'});await backend.waitForIdle();
  const before=structuredClone(backend.history.get(first.threadId)),save=backend.history.save;
  const payload={requestId:crypto.randomUUID(),threadId:first.threadId,message:'second'};
  backend.history.save=()=>{throw new Error('fixture disk full');};
  assert.throws(()=>backend.submit(payload),/fixture disk full/);
  assert.deepEqual(backend.history.get(first.threadId),before);assert.equal(backend.history.requests.has(payload.requestId),false);
  assert.equal(backend.isBusy(),false);assert.equal(calls.starts,1);
  backend.history.save=save;backend.submit(payload);await backend.waitForIdle();assert.equal(calls.starts,2);
});

test('an oversized single content delta cannot create history that fails to reopen',async t=>{
  const large='data: '+JSON.stringify({choices:[{delta:{content:'x'.repeat(300000)}}]})+'\ndata: [DONE]\n';
  const {backend,make}=fixture(t,{fetch:async()=>streamResponse(large,400000)});
  const sent=backend.submit({requestId:crypto.randomUUID(),message:'hello'});await backend.waitForIdle();
  const assistant=backend.history.get(sent.threadId).messages.at(-1);
  assert.equal(assistant.state,'error');assert.ok(assistant.content.length<=256*1024);
  await backend.close();assert.doesNotThrow(()=>make());
});

test('stream parser rejects malformed, provider-error, oversized and unfinished frames',async()=>{
  const signal=new AbortController().signal;
  for(const text of ['data: {bad json}\n','data: {"error":{"message":"provider private details"}}\n','data: '+ 'x'.repeat(1024*1024+1),'data: {"choices":[]}\n']) {
    await assert.rejects(readStream(streamResponse(text,1024*1024+100),()=>{},signal));
  }
  const deltas=[];
  await readStream(streamResponse('data: {"choices":[{"delta":{"content":"🖤"}}]}\ndata: [DONE]',1),d=>deltas.push(d),signal);
  assert.equal(deltas[0].content,'🖤');
});

test('context only includes completed historical pairs and the latest request',()=>{
  const thread={messages:[{role:'user',content:'old'},{role:'assistant',content:'complete',state:'done'},
    {role:'user',content:'failed'},{role:'assistant',content:'partial',state:'error'},
    {role:'user',content:'new'},{role:'assistant',content:'',state:'writing'}]};
  assert.deepEqual(messagesFor(thread).slice(1),[{role:'user',content:'old'},{role:'assistant',content:'complete'},{role:'user',content:'new'}]);
});

test('malformed Unicode credentials are rejected without timingSafeEqual exceptions',()=>{
  assert.equal(equal('a','a'),true);assert.equal(equal('a','b'),false);
  assert.equal(equal(undefined,'a'),false);assert.equal(equal('é','a'),false);
});

test('compatible server chat uses the selected model, explicit estimates, and never publishes its API key',async t=>{
 const {backend,config,calls}=fixture(t);
 Object.assign(config.model,{source:'server',endpoint:'http://127.0.0.1:5555/v1',id:'a-custom-model',apiKey:'private-server-credential'});
 const status=await backend.status();assert.equal(status.setupComplete,true);assert.equal(status.serverKeyConfigured,true);assert.equal(JSON.stringify(status).includes('private-server-credential'),false);
 backend.submit({message:'Hello',requestId:crypto.randomUUID()});await backend.waitForIdle();
 const body=JSON.parse(calls.fetch[0][1].body);assert.equal(body.model,'a-custom-model');assert.equal(calls.contexts.length,0);
 const thread=backend.history.get(backend.history.list()[0].id);assert.equal(thread.messages.at(-1).context.method,'estimated-bytes');assert.equal(thread.messages.at(-1).state,'done');
});

test('Agent mode uses Hermes host, exposes approvals without callbacks, and preserves kind on reload',async t=>{
 let runInput;let finish;
 const integrationSettings={hermes:{enabled:true},harnesses:[],engine:'hermes'};
 const {backend,calls}=fixture(t,{integrations:{read:()=>integrationSettings},agentRunner:{run:async input=>{runInput=input;input.job.approval={id:'approval',digest:'digest',expires:Date.now()+10000};input.job._approve=()=>{};await new Promise(resolve=>finish=resolve);input.assistant.content='Agent completed';input.thread.hermesSession='saved-session';}}});
 const result=backend.submit({message:'Create something',kind:'agent',requestId:crypto.randomUUID()});
 await new Promise(resolve=>setImmediate(resolve));
 assert.ok(runInput);assert.equal(calls.fetch.length,0);assert.equal(calls.contexts.length,0);
 const status=await backend.status();assert.equal(status.job.kind,'agent');assert.equal(status.job.approval.id,'approval');assert.equal('_approve' in status.job,false);assert.doesNotThrow(()=>structuredClone(status));
 finish();await backend.waitForIdle();const thread=backend.history.get(result.threadId);assert.equal(thread.kind,'agent');assert.equal(thread.hermesSession,'saved-session');assert.equal(thread.messages.at(-1).state,'done');
 assert.throws(()=>backend.submit({threadId:result.threadId,message:'chat',kind:'chat',requestId:crypto.randomUUID()}),/new conversation/);
});


test('phone pairing survives host restart and reconnect but honors disable, owner changes and key revocation',async t=>{
  const {backend,config,stateDir,make,disconnect,reconnect}=fixture(t);
  const headers={host:'computer.testnet.ts.net:8449','tailscale-user-login':'owner@example.test',origin:'https://computer.testnet.ts.net:8449'};
  const owner=await desktop(backend);
  const result=await request(backend,'/api/status',{headers:owner});
  const key=new URLSearchParams(new URL(result.body.phone.url).hash.slice(1)).get('pair');
  const paired=await request(backend,'/api/pair',{method:'POST',headers,body:{key}});
  assert.equal(paired.statusCode,200);
  headers.cookie=paired.headers['set-cookie'].split(';')[0];
  assert.match(paired.headers['set-cookie'],/Max-Age=2592000/);
  await backend.close();const restarted=make();
  assert.equal((await request(restarted,'/api/status',{headers})).statusCode,200);
  disconnect();assert.equal((await request(restarted,'/api/status',{headers})).statusCode,401);
  reconnect();assert.equal((await request(restarted,'/api/status',{headers})).statusCode,200);
  config.phone.enabled=false;
  assert.equal((await request(restarted,'/api/status',{headers})).statusCode,403);
  config.phone.enabled=true;
  assert.equal((await request(restarted,'/api/status',{headers})).statusCode,200);
  config.phone.owner='new-owner@example.test';
  assert.equal((await request(restarted,'/api/status',{headers})).statusCode,401);
  assert.equal((await request(restarted,'/api/status',{headers:{...headers,'tailscale-user-login':config.phone.owner}})).statusCode,401);
  config.phone.owner='owner@example.test';
  await restarted.close();fs.unlinkSync(path.join(stateDir,'phone.key'));const revoked=make();
  assert.equal((await request(revoked,'/api/status',{headers})).statusCode,401);
  assert.equal((await request(revoked,'/api/pair',{method:'POST',headers,body:{key}})).statusCode,401);
});

test('phone pairing and chat reject missing origin, cross-origin posts and direct network bypass',async t=>{
  const {backend}=fixture(t);
  const headers={host:'computer.testnet.ts.net:8449','tailscale-user-login':'owner@example.test',origin:'https://computer.testnet.ts.net:8449'};
  const owner=await desktop(backend);
  const result=await request(backend,'/api/status',{headers:owner});
  const key=new URLSearchParams(new URL(result.body.phone.url).hash.slice(1)).get('pair');
  for(const origin of [undefined,'https://untrusted.example','http://127.0.0.1:18199']) {
    assert.equal((await request(backend,'/api/pair',{method:'POST',headers:{...headers,origin},body:{key}})).statusCode,403);
  }
  assert.equal((await request(backend,'/api/pair',{method:'POST',headers,body:{key},address:'100.100.100.100'})).statusCode,403);
  const paired=await request(backend,'/api/pair',{method:'POST',headers,body:{key}});
  headers.cookie=paired.headers['set-cookie'].split(';')[0];
  const payload={requestId:crypto.randomUUID(),message:'phone test'};
  assert.equal((await request(backend,'/api/chat',{method:'POST',headers:{...headers,origin:undefined},body:payload})).statusCode,403);
  const sent=await request(backend,'/api/chat',{method:'POST',headers,body:payload});
  assert.equal(sent.statusCode,202);await backend.waitForIdle();
  const answer=await request(backend,'/api/thread/'+sent.body.threadId,{headers});
  assert.equal(answer.statusCode,200);assert.equal(answer.body.messages.at(-1).state,'done');
});

const timedStream='data: {"choices":[{"delta":{"content":"Use make ship."}}]}\n\n'+
  'data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":900,"completion_tokens":40},"timings":{"prompt_n":900,"prompt_per_second":48.6,"predicted_n":40,"predicted_per_second":11.7}}\n\ndata: [DONE]\n\n';

test('Chat is told Core once, recalls matching notes for a message, replays earlier turns unchanged and reports measured speed',async t=>{
  const {backend,calls}=fixture(t,{fetch:async()=>streamResponse(timedStream)});
  const owner=await desktop(backend);
  const send=(url,body)=>request(backend,url,{method:'POST',headers:owner,body});
  assert.equal((await send('/api/memory/save',{id:'Core',content:'Prefers one-sentence answers.'})).statusCode,200);
  assert.equal((await send('/api/memory/remember',{title:'Release process',text:'Deploy with make ship after the tests pass.'})).body.id,'Notes/Release process');
  const first=backend.submit({message:'How do I deploy after the tests pass?',requestId:crypto.randomUUID()});await backend.waitForIdle();
  const sent=JSON.parse(calls.fetch[0][1].body).messages;
  assert.match(sent[0].content,/What you know about the user:\nPrefers one-sentence answers\.$/);
  assert.match(sent[1].content,/^How do I deploy after the tests pass\?\n\n\[From your memory\. Use it only if it is relevant\.\]\n- Release process: .*make ship/);
  const thread=backend.history.get(first.threadId);
  assert.deepEqual(thread.messages[0].recalled.map(item=>item.title),['Release process']);
  assert.deepEqual(thread.messages[1].meter,{read:49,write:12});
  // An unrelated message is not padded with memory, and Core stays as it was when the conversation began.
  await send('/api/memory/save',{id:'Core',content:'Changed later.'});
  backend.submit({threadId:first.threadId,message:'Thanks!',requestId:crypto.randomUUID()});await backend.waitForIdle();
  const again=JSON.parse(calls.fetch[1][1].body).messages;
  assert.deepEqual(again.slice(0,2),sent);assert.equal(again.at(-1).content,'Thanks!');
  assert.deepEqual(backend.history.get(first.threadId).messages[2].recalled,[]);
  assert.deepEqual(messagesFor({messages:[{role:'user',content:'plain'},{role:'assistant',content:'',state:'writing'}]}).map(item=>item.role),['system','user']);
});

test('projects get a folder in the workspace and notes in memory; memory routes stay inside the vault',async t=>{
  const {backend,config,directory,stateDir}=fixture(t);
  config.workspace=path.join(directory,'work');fs.mkdirSync(config.workspace);
  const owner=await desktop(backend);
  const send=(url,body)=>request(backend,url,{method:'POST',headers:owner,body});
  const get=url=>request(backend,url,{headers:owner});
  const made=await send('/api/project-create',{name:'Night Shift'});
  assert.equal(made.statusCode,200);assert.equal(made.body.workspace,path.join(fs.realpathSync(config.workspace),'night-shift'));assert.ok(fs.statSync(made.body.workspace).isDirectory());
  for(const name of ['night shift','../x','','.hidden','x'.repeat(61)])assert.equal((await send('/api/project-create',{name})).statusCode,400,name);
  assert.deepEqual((await get('/api/status')).body.projects.map(item=>[item.name,item.exists,item.notes]),[['Night Shift',true,'Projects/night-shift']]);
  assert.match(fs.readFileSync(path.join(stateDir,'vault','Projects','night-shift','Overview.md'),'utf8'),/^# Night Shift\n/);
  assert.equal((await send('/api/memory/save',{id:'Plan',content:'# Plan\n\nShip it. See [[Later]].'})).statusCode,200);
  assert.equal((await get('/api/memory/note?id=Plan')).body.content,'# Plan\n\nShip it. See [[Later]].');
  const escape=await send('/api/memory/save',{id:'../escape',content:'x'});assert.equal(escape.statusCode,400);assert.match(escape.body.error,/valid note name/);assert.ok(!fs.existsSync(path.join(stateDir,'escape.md')));
  assert.equal((await get('/api/memory/search?q=ship')).body.hits[0].id,'Plan');
  const memory=(await get('/api/memory')).body;
  assert.ok(memory.graph.edges.some(edge=>edge.from==='Plan'&&edge.to==='?Later'));assert.equal(memory.keeper.limits.noteChars,6000);assert.equal(memory.keeper.usage.notes,2);
  assert.equal((await send('/api/memory/remember',{title:'House rule',text:'Small diffs.',project:made.body.id})).body.id,'Projects/night-shift/House rule');
  assert.equal((await send('/api/memory/remember',{title:'Core',text:'x'})).statusCode,400);
  assert.equal((await send('/api/memory/tidy',{})).body.message,'Memory is within its limits.');
  assert.equal((await send('/api/memory/delete',{id:'Plan'})).statusCode,200);assert.equal((await get('/api/memory/note?id=Plan')).statusCode,400);
  assert.equal((await send('/api/memory/nope',{})).statusCode,404);
  assert.throws(()=>backend.submit({message:'In a project',project:crypto.randomUUID(),requestId:crypto.randomUUID()}),/no longer exists/);
  // Projects survive a restart.
  await backend.close();
});

test('Code runs on the built-in engine in the project folder, keeps its engine, and undo waits for a running task',async t=>{
  let runInput,finish;const undone=[];
  const engine={run:async input=>{runInput=input;await new Promise(resolve=>finish=resolve);input.assistant.content='Edited.';},undo:id=>{undone.push(id);return {path:'a.txt',removed:false};}};
  const {backend,config,directory,calls}=fixture(t,{backend:{engine},integrations:{read:()=>({hermes:{enabled:false},harnesses:[],engine:'hermes'})},agentRunner:{run:async()=>{throw new Error('Hermes must not run');}}});
  config.workspace=path.join(directory,'work');fs.mkdirSync(config.workspace);
  const owner=await desktop(backend);
  const project=(await request(backend,'/api/project-create',{method:'POST',headers:owner,body:{name:'Alpha'}})).body;
  const result=backend.submit({message:'Change a.txt',kind:'agent',mode:'deep',project:project.id,requestId:crypto.randomUUID()});
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(runInput.workspace,project.workspace);assert.equal(runInput.mode,'deep');assert.equal(calls.fetch.length,0);
  assert.equal((await request(backend,'/api/undo',{method:'POST',headers:owner,body:{id:'a'.repeat(24)}})).statusCode,409);
  finish();await backend.waitForIdle();
  const thread=backend.history.get(result.threadId);
  assert.equal(thread.engine,'black-team');assert.equal(thread.project,project.id);assert.equal(thread.messages.at(-1).state,'done');
  assert.deepEqual(backend.history.list()[0],{id:thread.id,title:'Change a.txt',updated:thread.updated,kind:'agent',project:project.id});
  assert.deepEqual((await request(backend,'/api/undo',{method:'POST',headers:owner,body:{id:'a'.repeat(24)}})).body,{path:'a.txt',removed:false});assert.deepEqual(undone,['a'.repeat(24)]);
  // A conversation Hermes started is not silently moved to another engine.
  const old=backend.history.create('Old Hermes task');old.kind='agent';old.hermesSession='saved';
  old.messages.push({id:crypto.randomUUID(),role:'user',content:'x',state:'done'},{id:crypto.randomUUID(),role:'assistant',content:'y',state:'done'});backend.history.save(old);
  assert.throws(()=>backend.submit({threadId:old.id,message:'continue',kind:'agent',requestId:crypto.randomUUID()}),/uses Hermes/);
});

test('dictation toggles the system tool from the desktop only',async t=>{
  const spawned=[];let tool='/usr/bin/voxtype';
  const {backend}=fixture(t,{backend:{dictation:()=>tool,spawn:(command,args,options)=>{spawned.push([command,args,options.shell,options.detached]);return {on(){},unref(){}};}}});
  const owner=await desktop(backend);
  assert.equal((await request(backend,'/api/status',{headers:owner})).body.dictation,true);
  assert.equal((await request(backend,'/api/dictate',{method:'POST',headers:owner,body:{}})).statusCode,200);
  assert.deepEqual(spawned,[['/usr/bin/voxtype',['record','toggle'],false,true]]);
  tool='/opt/my-dictation';await request(backend,'/api/dictate',{method:'POST',headers:owner,body:{}});assert.deepEqual(spawned[1].slice(0,2),['/opt/my-dictation',[]]);
  tool='';assert.equal((await request(backend,'/api/dictate',{method:'POST',headers:owner,body:{}})).statusCode,404);
  assert.equal((await request(backend,'/api/status',{headers:owner})).body.dictation,false);
  const phone={host:'computer.testnet.ts.net:8449','tailscale-user-login':'owner@example.test',origin:'https://computer.testnet.ts.net:8449'};
  const key=new URLSearchParams(new URL((await request(backend,'/api/status',{headers:owner})).body.phone.url).hash.slice(1)).get('pair');
  phone.cookie=(await request(backend,'/api/pair',{method:'POST',headers:phone,body:{key}})).headers['set-cookie'].split(';')[0];
  tool='/usr/bin/voxtype';
  assert.equal((await request(backend,'/api/dictate',{method:'POST',headers:phone,body:{}})).statusCode,403);
  const remote=(await request(backend,'/api/status',{headers:phone})).body;assert.equal(remote.dictation,false);assert.equal(remote.memory,true);assert.deepEqual(remote.projects,[]);
  assert.equal((await request(backend,'/api/memory',{headers:phone})).statusCode,200);
});

test('the keeper condenses an oversized note with a loaded, idle model and never starts one itself',async t=>{
  const {createMemory}=require('../lib/memory.cjs');
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'black-team-keeper-'));t.after(()=>fs.rmSync(directory,{recursive:true,force:true}));
  const memory=createMemory({vault:path.join(directory,'vault'),limits:{noteChars:300,journalEntries:30,totalChars:400000}});
  memory.write('Notes/Long','# Long\n\n'+'- a repeated fact about the build\n'.repeat(30));
  let release;const gate=new Promise(resolve=>release=resolve);
  const {backend,runtime,calls}=fixture(t,{backend:{memory},fetch:async()=>{await gate;return {ok:true,status:200,json:async()=>({choices:[{message:{content:'# Long\n\n- The build fact, once.'}}]})};}});
  const owner=await desktop(backend);
  const tidy=()=>request(backend,'/api/memory/tidy',{method:'POST',headers:owner,body:{}});
  assert.match((await tidy()).body.message,/^Start your model/);assert.equal(calls.starts,0);assert.equal(calls.fetch.length,0);
  runtime.status=()=>({state:'ready',ready:true,busy:false});
  assert.match((await tidy()).body.message,/^Condensing one note/);
  assert.equal((await backend.status()).job.kind,'memory');
  assert.throws(()=>backend.submit({message:'Hello',requestId:crypto.randomUUID()}),/already running/);
  release();await backend.waitForIdle();
  const body=JSON.parse(calls.fetch[0][1].body);assert.equal(body.stream,false);assert.equal(calls.fetch[0][1].headers.Authorization,'Bearer local-test-key');
  assert.match(memory.read('Notes/Long').content,/^# Long\n\n- The build fact, once\.\n\n_Condensed by Black Team/);
  const state=(await request(backend,'/api/memory',{headers:owner})).body.keeper;
  assert.equal(state.usage.oversized.length,0);assert.equal(state.usage.archived,1);assert.match(state.actions[0].text,/^Condensed Long from/);
  assert.deepEqual(calls.busy,[true,false]);
});
