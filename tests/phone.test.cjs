'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {PhoneManager,validatePhone,routeState,PHONE_PORT,TARGET}=require('../lib/phone.cjs');
const hostname='computer.testnet.ts.net';
const owner='owner@example.test';
const privateRoute=()=>({TCP:{[PHONE_PORT]:{HTTPS:true}},Web:{[`${hostname}:${PHONE_PORT}`]:{Handlers:{'/':{Proxy:TARGET}}}}});
function fixture(overrides={}) {
  let route=overrides.route||{};
  const phone={enabled:true,hostname,owner,...overrides.phone};
  const calls=[];
  const status=overrides.status||{BackendState:'Running',Self:{Online:true,DNSName:hostname+'.',UserID:1},User:{1:{LoginName:owner}}};
  const run=async(executable,args,options)=>{
    calls.push({executable,args,options});
    if(overrides.failure)throw overrides.failure;
    if(args[0]==='status')return {stdout:JSON.stringify(status)};
    if(args.join(' ')==='serve status --json')return {stdout:JSON.stringify(route)};
    if(args[0]==='serve'&&args.includes('off')){route={};return {stdout:''};}
    if(args[0]==='serve'&&args.includes(TARGET)){route=privateRoute();return {stdout:''};}
    throw new Error('Unexpected mocked Tailscale command');
  };
  return {manager:new PhoneManager({configStore:{read:()=>({phone:{...phone}})},run}),calls,phone};
}
test('phone input accepts private Tailscale DNS names only and rejects malformed login data',()=>{
  assert.deepEqual(validatePhone({enabled:true,hostname:'COMPUTER.testnet.ts.net.',owner}),{enabled:true,hostname,owner});
  for(const value of [null,{enabled:'yes'},{enabled:true,hostname:'example.com',owner},{enabled:true,hostname:'https://'+hostname,owner},
    {enabled:true,hostname:hostname+':8449',owner},{enabled:true,hostname,owner:'bad\nlogin'},{enabled:true,hostname,owner:''}])assert.throws(()=>validatePhone(value));
});
test('connect only creates the dedicated private route and verifies it after creation',async()=>{
  const {manager,calls}=fixture();const connected=await manager.connect();
  assert.equal(connected.connected,true);assert.equal(connected.url,`https://${hostname}:${PHONE_PORT}/`);
  const mutations=calls.filter(call=>call.args[0]==='serve'&&call.args[1]!=='status');
  assert.deepEqual(mutations.map(call=>call.args),[['serve','--bg',`--https=${PHONE_PORT}`,'--yes',TARGET]]);
  for(const call of calls){assert.equal(call.executable,'tailscale');assert.equal(call.options.shell,false);assert.ok(call.options.timeout<=10000);assert.equal(call.args.includes('funnel'),false);assert.equal(call.args.includes('reset'),false);}
  assert.ok(calls.filter(call=>call.args.join(' ')==='serve status --json').length>=2);
});
test('existing private route is reused without mutation; disabled phone performs no probes',async()=>{
  const {manager,calls}=fixture({route:privateRoute()});assert.equal((await manager.connect()).connected,true);
  assert.equal(calls.some(call=>call.args[0]==='serve'&&call.args[1]!=='status'),false);
  const disabled=fixture({phone:{enabled:false}});assert.equal((await disabled.manager.status()).connected,false);assert.equal(disabled.calls.length,0);
  await assert.rejects(disabled.manager.connect(),/enable Companion/);assert.equal(disabled.calls.length,0);
});
test('another route, extra handler, public Funnel or wrong owner can never be overwritten',async()=>{
  const other=privateRoute();other.Web[`${hostname}:${PHONE_PORT}`].Handlers['/'].Proxy='http://127.0.0.1:9999';
  const extra=privateRoute();extra.Web[`${hostname}:${PHONE_PORT}`].Handlers['/other']={Proxy:TARGET};
  const publicRoute=privateRoute();publicRoute.AllowFunnel={[`${hostname}:${PHONE_PORT}`]:true};
  for(const route of [other,extra,publicRoute,{TCP:{[PHONE_PORT]:{TCPForward:'127.0.0.1:8888'}}}]) {
    const {manager,calls}=fixture({route});await assert.rejects(manager.connect(),/will not overwrite/);
    assert.equal(calls.some(call=>call.args[0]==='serve'&&call.args[1]!=='status'),false);
  }
  const wrong=fixture({phone:{owner:'someone@example.test'}});await assert.rejects(wrong.manager.connect(),/saved computer and owner/);
  assert.equal(wrong.calls.some(call=>call.args[0]==='serve'),false);
});
test('disconnect removes only an owned route and refuses public or other routes',async()=>{
  const {manager,calls}=fixture({route:privateRoute()});assert.equal((await manager.disconnect()).connected,false);
  assert.deepEqual(calls.filter(call=>call.args.includes('off')).map(call=>call.args),[['serve',`--https=${PHONE_PORT}`,'off']]);
  const route=privateRoute();route.AllowFunnel={[`${hostname}:${PHONE_PORT}`]:true};
  const publicFixture=fixture({route});await assert.rejects(publicFixture.manager.disconnect(),/no longer belongs exclusively/);
  assert.equal(publicFixture.calls.some(call=>call.args.includes('off')),false);
});
test('missing Tailscale is a disconnected state and route identity is exact',async()=>{
  const {manager}=fixture({failure:Object.assign(new Error('private exception'),{code:'ENOENT'})});
  const detected=await manager.detect();assert.equal(detected.installed,false);assert.equal(detected.online,false);assert.equal(JSON.stringify(detected).includes('private exception'),false);
  assert.equal((await manager.status()).connected,false);
  assert.deepEqual(routeState(privateRoute(),hostname),{owned:true,publicRoute:false,occupied:true});
  assert.equal(routeState(privateRoute(),'different.testnet.ts.net').owned,false);
});
