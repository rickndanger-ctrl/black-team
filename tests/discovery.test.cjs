'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {discoverInstalled,inspectHermes}=require('../lib/discovery.cjs');
function fixture(t){const home=fs.mkdtempSync(path.join(os.tmpdir(),'black-team-find-'));t.after(()=>fs.rmSync(home,{recursive:true,force:true}));return home;}
function executable(file){fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,'#!/bin/sh\nexit 99\n',{mode:0o700});return file;}
function hermes(home,venv='venv'){const source=path.join(home,'.hermes/hermes-agent');fs.mkdirSync(source,{recursive:true});for(const name of ['cli.py','hermes_bootstrap.py'])fs.writeFileSync(path.join(source,name),'# fixture');return {source,python:executable(path.join(source,venv,'bin/python'))};}
test('discovery finds installed Hermes and terminals without executing or changing them',t=>{
 const home=fixture(t),expected=hermes(home);const bin=path.join(home,'bin');executable(path.join(bin,'ghostty'));executable(path.join(bin,'codex'));executable(path.join(bin,'llama-server'));
 const found=discoverInstalled({home,env:{PATH:bin}});
 assert.deepEqual(found.hermes,[expected]);assert.deepEqual(found.terminals,[{name:'Ghostty',executable:path.join(bin,'ghostty'),args:['-e']}]);assert.equal(found.apps[0].name,'Codex');assert.equal(found.runtime,path.join(bin,'llama-server'));
 assert.equal(fs.readFileSync(expected.python,'utf8'),'#!/bin/sh\nexit 99\n');
});
test('discovery accepts saved custom installations and preserves venv symlink paths',t=>{
 const home=fixture(t),expected=hermes(home,'.venv');const real=executable(path.join(home,'python-real'));fs.unlinkSync(expected.python);fs.symlinkSync(real,expected.python);
 assert.deepEqual(inspectHermes(expected.source),expected);
 const custom=path.join(home,'custom');fs.renameSync(expected.source,custom);const saved={source:custom,python:path.join(custom,'.venv/bin/python')};
 assert.deepEqual(discoverInstalled({home,env:{PATH:''},saved}).hermes,[saved]);
});
test('missing/incomplete installs and relative PATH entries are not treated as connections',t=>{
 const home=fixture(t);assert.deepEqual(discoverInstalled({home,env:{PATH:'.:relative'}}),{hermes:[],apps:[],terminals:[],runtime:'',dictation:''});
 const expected=hermes(home);fs.unlinkSync(path.join(expected.source,'hermes_bootstrap.py'));assert.equal(inspectHermes(expected.source),null);assert.equal(inspectHermes('relative'),null);
});
