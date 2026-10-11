import test from 'node:test';
import assert from 'node:assert/strict';
import {createCompanionInitializer} from '../src/companionConnection.mjs';
test('pairing retries after a transient failure, strips URL once and deduplicates concurrent polls',async()=>{
 const key='a'.repeat(64);let calls=0;const urls=[];
 const init=createCompanionInitializer({desktop:false,location:{hash:'#pair='+key,pathname:'/',search:''},replaceURL:url=>urls.push(url),post:async(route,data)=>{calls++;assert.equal(route,'/api/pair');assert.equal(data.key,key);if(calls===1)throw new Error('temporarily offline');}});
 const first=init();assert.equal(init(),first);await assert.rejects(first,/Pairing could not finish/);await init();await init();
 assert.equal(calls,2);assert.deepEqual(urls,['/']);
});
test('desktop/no-link never pairs and malformed keys never leave the browser',async()=>{
 for(const [desktop,hash] of [[true,'#pair=secret'],[false,''],[false,'#pair=bad']]){
  let calls=0;const init=createCompanionInitializer({desktop,location:{hash,pathname:'/',search:''},replaceURL:()=>{},post:async()=>{calls++;}});
  if(!desktop&&hash)await assert.rejects(init(),/Pairing could not finish/);else await init();assert.equal(calls,0);
 }
});
