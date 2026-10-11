'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const os=require('node:os');
const {EventEmitter}=require('node:events');
const {PassThrough}=require('node:stream');
const {createIntegrations,launchHarness}=require('../lib/integrations.cjs');
const {createAgent}=require('../lib/agent.cjs');

function fixture(t){const dir=fs.mkdtempSync(path.join(os.tmpdir(),'bt-integrations-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));const exe=path.join(dir,'runtime');fs.writeFileSync(exe,'#!/bin/sh\nexit 0\n',{mode:0o700});fs.writeFileSync(path.join(dir,'hermes_bootstrap.py'),'# fixture');const store=createIntegrations(path.join(dir,'state'));const hermes={enabled:true,python:exe,source:dir,coding:true,browser:false,desktop:false};store.save({hermes,harnesses:[]});return {dir,exe,store,hermes};}
test('configured harness launch uses literal arguments and a local provider environment',async t=>{
 const {dir,exe,store}=fixture(t);store.save({harnesses:[{id:'test-cli',name:'Test CLI',executable:exe,args:['--model','{model}','{workspace}','$(touch should-not-exist)'],terminal:[]}]});
 let captured;const result=await launchHarness({id:'test-cli',store,config:{workspace:dir,model:{source:'server',id:'user-model'}},runtime:{start:async()=>'http://127.0.0.1:1234/v1',requestHeaders:()=>({Authorization:'Bearer fixture-secret'})},spawn:(file,args,opts)=>{captured={file,args,opts};const child=new EventEmitter();child.unref=()=>{};queueMicrotask(()=>child.emit('spawn'));return child;}});
 assert.equal(result.launched,true);assert.equal(captured.opts.shell,false);assert.deepEqual(captured.args,['--model','user-model',dir,'$(touch should-not-exist)']);assert.equal(captured.opts.env.OPENAI_BASE_URL,'http://127.0.0.1:1234/v1');assert.equal(captured.opts.env.OPENAI_API_KEY,'fixture-secret');assert.equal(captured.args.includes('fixture-secret'),false);
 assert.throws(()=>store.save({harnesses:[{id:'bad',name:'Bad',executable:exe,args:'shell string',terminal:[]}]}));
 await assert.rejects(launchHarness({id:'missing',store}),/Configure/);
});
test('Hermes host pins the local model, handles correlated approvals and keeps a resumable session',async t=>{
 const {dir,store}=fixture(t);let child,captured;const input=[];let saves=0;
 const host=createAgent({stateDir:path.join(dir,'state'),integrations:store,spawn:(file,args,opts)=>{captured={file,args,opts};child=new EventEmitter();child.pid=4242;child.stdin=new PassThrough();child.stdout=new PassThrough();child.stderr=new PassThrough();child.stdin.on('data',c=>input.push(JSON.parse(c.toString())));return child;}});
 const thread={id:'11111111-1111-1111-1111-111111111111',messages:[{role:'user',content:'Make a file'},{role:'assistant',content:''}]};const assistant=thread.messages[1],job={};const controller=new AbortController();
 const config={workspace:dir,model:{source:'server',endpoint:'http://127.0.0.1:1234/v1',id:'my-model',context:8192}};
 const runtime={requestHeaders:()=>({Authorization:'Bearer fixture-secret'})};
 const running=host.run({thread,assistant,config,runtime,endpoint:config.model.endpoint,job,signal:controller.signal,save:()=>saves++});
 const emit=e=>child.stdout.write(JSON.stringify(e)+'\n');
 const profile=JSON.parse(fs.readFileSync(path.join(captured.opts.env.HERMES_HOME,'config.yaml')));
 assert.equal(profile.model.default,'my-model');assert.equal(profile.model.base_url,config.model.endpoint);assert.equal(profile.auxiliary.compression.base_url,config.model.endpoint);assert.deepEqual(profile.auxiliary.compression.fallback_chain,[]);assert.equal(profile.plugins.enabled[0],'companion-tools');
 assert.equal(captured.opts.env.CUA_DRIVER_RS_ENABLE_WAYLAND,'0');assert.equal(captured.args.includes('fixture-secret'),false);
 emit({type:'system',session_id:'session-fixture'});emit({type:'companion_approval',id:'a',digest:'d',command:'test fixture-secret',description:'Approve?',expires:Date.now()+5000});
 assert.equal(job.approval.command,'test [redacted]');assert.throws(()=>job._approve('wrong','d','once'),/matching/);job._approve('a','d','once');assert.deepEqual(input,[{id:'a',digest:'d',choice:'once'}]);assert.equal(job.approval,undefined);
 emit({type:'tool_use',name:'file_write',input:{path:'example.txt'}});emit({type:'result',text:'Done',session_id:'session-fixture',exit_code:0});child.emit('close',0);await running;
 assert.equal(thread.hermesSession,'session-fixture');assert.equal(assistant.content,'Done');assert.equal(assistant.events[0].name,'file_write');assert.ok(saves);assert.equal(job._approve,undefined);
 assert.equal(fs.readdirSync(captured.opts.env.HERMES_HOME).some(name=>name.startsWith('query-')),false);
 const again=host.run({thread,assistant,config,runtime,endpoint:config.model.endpoint,job,signal:controller.signal,save:()=>{}});assert.ok(captured.args.includes('--resume'));emit({type:'result',text:'Resumed',exit_code:0});child.emit('close',0);await again;
 await assert.rejects(host.run({thread,assistant,config:{...config,model:{...config.model,id:'different'}},runtime,endpoint:config.model.endpoint,job,signal:controller.signal,save:()=>{}}),/new Agent conversation/);
});
test('agent cancellation stops only its owned process group and clears approvals',async t=>{
 const {dir,store}=fixture(t);let child;const signals=[];
 const host=createAgent({stateDir:path.join(dir,'state'),integrations:store,spawn:()=>{child=new EventEmitter();child.pid=9999;child.stdin=new PassThrough();child.stdout=new PassThrough();child.stderr=new PassThrough();return child;},kill:(pid,signal)=>{signals.push([pid,signal]);queueMicrotask(()=>child.emit('close',130));}});
 const thread={id:'22222222-2222-2222-2222-222222222222',messages:[{content:'work'},{content:''}]},job={},controller=new AbortController();
 const running=host.run({thread,assistant:thread.messages[1],config:{workspace:dir,model:{source:'server',endpoint:'http://127.0.0.1:1234/v1',id:'test',context:4096}},runtime:{requestHeaders:()=>({})},endpoint:'http://127.0.0.1:1234/v1',job,signal:controller.signal,save:()=>{}});
 controller.abort();await assert.rejects(running,/Agent stopped/);assert.deepEqual(signals,[[-9999,'SIGINT']]);assert.equal(job._approve,undefined);
});
