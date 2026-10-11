'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const os=require('node:os');
const crypto=require('node:crypto');
const {History,writeJSON}=require('../lib/history.cjs');
function fixture(t) {
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'black-team-history-'));
  t.after(()=>fs.rmSync(directory,{recursive:true,force:true}));
  return {directory,stateDir:path.join(directory,'state')};
}
test('conversation saves are atomic, private and retain full content separately from request index',t=>{
  const {stateDir}=fixture(t);const history=new History(stateDir),thread=history.create('  A private\n conversation  ');
  const request={id:crypto.randomUUID(),hash:'a'.repeat(64),state:'done'};
  thread.messages=[{id:crypto.randomUUID(),role:'user',content:'original 🖤',state:'done'},{id:crypto.randomUUID(),role:'assistant',content:'completed response',state:'done'}];
  history.remember(thread,request);history.save(thread);
  const file=path.join(stateDir,'conversations',thread.id+'.json');
  assert.equal(fs.statSync(stateDir).mode&0o777,0o700);assert.equal(fs.statSync(path.dirname(file)).mode&0o777,0o700);assert.equal(fs.statSync(file).mode&0o777,0o600);
  assert.deepEqual(fs.readdirSync(path.dirname(file)),[thread.id+'.json']);
  const read=new History(stateDir);assert.deepEqual(read.get(thread.id).messages,thread.messages);
  assert.equal(read.requests.get(request.id).threadId,thread.id);assert.equal(read.requests.get(request.id).state,'done');
  assert.deepEqual(Object.keys(read.list()[0]).sort(),['id','title','updated']);
});
test('restart preserves partial replies and interrupts running request IDs without replay',t=>{
  const {stateDir}=fixture(t);const original=new History(stateDir),thread=original.create('question');
  thread.messages=[{id:crypto.randomUUID(),role:'user',content:'question',state:'done'},{id:crypto.randomUUID(),role:'assistant',content:'partial answer',state:'writing'}];
  const request={id:crypto.randomUUID(),hash:'a'.repeat(64),state:'running'};original.remember(thread,request);original.save(thread);
  const restarted=new History(stateDir);
  assert.equal(restarted.get(thread.id).messages[1].content,'partial answer');assert.equal(restarted.get(thread.id).messages[1].state,'interrupted');
  assert.equal(restarted.requests.get(request.id).state,'interrupted');
  const persisted=JSON.parse(fs.readFileSync(path.join(stateDir,'conversations',thread.id+'.json')));
  assert.equal(persisted.requests[0].state,'interrupted');assert.equal(persisted.messages[1].state,'interrupted');
});
test('damaged, mismatched and oversized conversation files are rejected without overwriting them',t=>{
  const {stateDir}=fixture(t);new History(stateDir);const id=crypto.randomUUID(),file=path.join(stateDir,'conversations',id+'.json');
  for(const contents of ['{',JSON.stringify({id:crypto.randomUUID(),messages:[]}),JSON.stringify({id,messages:'wrong'}),'x'.repeat(8*1024*1024+1)]) {
    fs.writeFileSync(file,contents);assert.throws(()=>new History(stateDir));assert.equal(fs.readFileSync(file,'utf8'),contents);
  }
});
test('state/conversation symlinks are rejected and writes do not modify a symlink target',t=>{
  const {directory,stateDir}=fixture(t);const target=path.join(directory,'target');fs.mkdirSync(target);fs.symlinkSync(target,stateDir);
  assert.throws(()=>new History(stateDir),/symbolic link/);fs.unlinkSync(stateDir);
  const history=new History(stateDir),thread=history.create('question');const outside=path.join(directory,'outside.json');fs.writeFileSync(outside,'preserve outside');
  const file=path.join(history.dir,thread.id+'.json');fs.symlinkSync(outside,file);
  assert.throws(()=>new History(stateDir),/symbolic links/);
  writeJSON(file,{value:'owned replacement'});assert.equal(fs.readFileSync(outside,'utf8'),'preserve outside');assert.equal(fs.lstatSync(file).isSymbolicLink(),false);
});
