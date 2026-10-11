'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {localEndpoint,discoverModels}=require('../lib/local-server.cjs');
const {createConfigStore}=require('../lib/config.cjs');
const {ModelRuntime}=require('../lib/runtime.cjs');
const {prepareServerContext}=require('../lib/context.cjs');

test('local server URLs cannot redirect credentials to a remote host or embed credentials',async()=>{
 assert.equal(localEndpoint('http://localhost:11434/v1/'),'http://127.0.0.1:11434/v1');
 assert.equal(localEndpoint('http://[::1]:1234/v1'),'http://[::1]:1234/v1');
 for(const url of ['https://example.com/v1','http://192.168.1.2:1234/v1','http://localhost.evil.test:1234/v1','http://user:key@localhost:1234/v1','http://localhost:1234/v1?key=secret','http://localhost:1234/v1#x','file:///tmp/v1'])assert.throws(()=>localEndpoint(url));
 let calls=0;
 await assert.rejects(discoverModels({endpoint:'https://example.com/v1',fetch:()=>{calls++;}}));assert.equal(calls,0);
 const found=await discoverModels({endpoint:'http://localhost:1234/v1',apiKey:'fixture-secret',fetch:async(url,opts)=>{assert.equal(url,'http://127.0.0.1:1234/v1/models');assert.equal(opts.redirect,'error');assert.equal(opts.headers.Authorization,'Bearer fixture-secret');return Response.json({data:[{id:'qwen'},{id:'qwen'},{id:3}]});}});
 assert.deepEqual(found.models,['qwen']);assert.equal(JSON.stringify(found).includes('fixture-secret'),false);
 for(const response of [new Response('{}',{status:401}),Response.json({data:[]}),Response.json({unexpected:true})])await assert.rejects(discoverModels({endpoint:'http://localhost:1234/v1',fetch:async()=>response}));
});
test('fresh user can configure a server without GGUF files and disconnect without killing that server',async t=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'bt-server-config-'));t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
 const store=createConfigStore(path.join(dir,'state'));store.save({workspace:dir,model:{source:'server',endpoint:'http://localhost:1234/v1',id:'my-model',apiKey:'fixture-key'}});
 assert.equal(fs.statSync(path.join(dir,'state/config.json')).mode&0o777,0o600);
 let spawns=0;const runtime=new ModelRuntime({configStore:store,spawn:()=>{spawns++;throw Error('must not spawn');},fetch:async()=>Response.json({data:[{id:'my-model'}]})});
 assert.equal(await runtime.start(),'http://127.0.0.1:1234/v1');assert.equal(await runtime.start(),'http://127.0.0.1:1234/v1');assert.equal(runtime.requestHeaders().Authorization,'Bearer fixture-key');
 runtime.setBusy(true);await assert.rejects(runtime.stop(),/response/);runtime.setBusy(false);await runtime.stop();assert.equal(runtime.status().ready,false);assert.equal(spawns,0);
 store.save({model:{id:'missing'}});await assert.rejects(runtime.start(),/no longer available/);
});
test('generic server context is explicitly estimated and never edits protected messages or saved history',()=>{
 const system={role:'system',content:'instructions'};const latest={role:'user',content:'new question'};const messages=[system,...Array.from({length:10},()=>[{role:'user',content:'a'.repeat(200)},{role:'assistant',content:'b'.repeat(200)}]).flat(),latest];const original=structuredClone(messages);
 const result=prepareServerContext({messages,context:1024,endpoint:'http://127.0.0.1:1234/v1'});
 assert.equal(result.report.method,'estimated-bytes');assert.ok(result.report.omittedMessages>0);assert.deepEqual(result.messages[0],system);assert.deepEqual(result.messages.at(-1),latest);assert.deepEqual(messages,original);
 assert.throws(()=>prepareServerContext({messages:[system,{role:'user',content:'x'.repeat(2000)}],context:512,endpoint:'http://127.0.0.1:1234/v1'}),/exceed/);
});
