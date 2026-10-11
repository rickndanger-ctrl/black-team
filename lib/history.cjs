'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const ID = /^[a-f0-9-]{36}$/;
function validThread(thread,id) {
  return thread && thread.id===id && typeof thread.title==='string' && thread.title.length<=200 &&
    typeof thread.updated==='string' && Number.isFinite(Date.parse(thread.updated)) &&
    Array.isArray(thread.messages) && thread.messages.length<=1002 && thread.messages.every(m=>m && ID.test(m.id) &&
      ['user','assistant'].includes(m.role) && typeof m.content==='string' && m.content.length<=270000 &&
      ['done','writing','interrupted','error'].includes(m.state)) &&
    Array.isArray(thread.requests) && thread.requests.every(r=>r && ID.test(r.id) && /^[a-f0-9]{64}$/.test(r.hash) && ['running','done','interrupted','error'].includes(r.state));
}
function privateDirectory(dir) {
  fs.mkdirSync(dir,{recursive:true,mode:0o700});
  if (fs.lstatSync(dir).isSymbolicLink()) throw new Error('Private storage must not be a symbolic link.');
  fs.chmodSync(dir,0o700);
}
function writeJSON(file,data) {
  const tmp = `${file}.${crypto.randomBytes(10).toString('hex')}.tmp`;
  let fd;
  try {
    fd=fs.openSync(tmp,'wx',0o600);
    fs.writeFileSync(fd,JSON.stringify(data)); fs.fsyncSync(fd); fs.closeSync(fd); fd=undefined;
    fs.renameSync(tmp,file);
  } finally {
    if(fd !== undefined) fs.closeSync(fd);
    try { fs.unlinkSync(tmp); } catch(e) { if(e.code !== 'ENOENT') throw e; }
  }
}
class History {
  constructor(stateDir) {
    privateDirectory(stateDir);
    this.dir=path.join(stateDir,'conversations'); privateDirectory(this.dir);
    this.rows = new Map(); this.requests = new Map();
    for(const name of fs.readdirSync(this.dir)) {
      if(!name.endsWith('.json') || !ID.test(name.slice(0,-5))) continue;
      const file=path.join(this.dir,name);
      if(fs.lstatSync(file).isSymbolicLink()) throw new Error('Conversation files must not be symbolic links.');
      if(fs.statSync(file).size>8*1024*1024) throw new Error('Conversation exceeds the supported storage size.');
      let thread;
      try { thread=JSON.parse(fs.readFileSync(file,'utf8')); } catch { throw new Error('A saved conversation is damaged. Restore it from your backup before opening Black Team.'); }
      if(!validThread(thread,name.slice(0,-5))) throw new Error('A saved conversation has an unsupported format. Restore it from your backup before opening Black Team.');
      let changed=false;
      for(const message of thread.messages) if(message.state==='writing') {message.state='interrupted';changed=true;}
      for(const request of thread.requests || []) {
        if(request.state==='running') {request.state='interrupted';changed=true;}
        this.requests.set(request.id,{...request,threadId:thread.id});
      }
      this.rows.set(thread.id,thread);
      if(changed) this.save(thread);
    }
  }
  list() { return [...this.rows.values()].map(({id,title,updated,kind,project})=>({id,title,updated,kind:kind||'chat',...(project?{project}:{})})).sort((a,b)=>b.updated.localeCompare(a.updated)); }
  get(id) { return this.rows.get(id) || null; }
  save(thread) { writeJSON(path.join(this.dir,`${thread.id}.json`),thread); this.rows.set(thread.id,thread); }
  create(message) {return {id:crypto.randomUUID(),title:message.replace(/\s+/g,' ').slice(0,72),updated:new Date().toISOString(),messages:[],requests:[]};}
  remember(thread,request) {
    const i=thread.requests.findIndex(r=>r.id===request.id);
    if(i>=0) thread.requests[i]=request; else thread.requests.push(request);
    this.requests.set(request.id,{...request,threadId:thread.id});
  }
}
module.exports={History,privateDirectory,writeJSON,validThread,ID};
