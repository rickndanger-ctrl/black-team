import React, {useEffect, useState} from 'react';
import {native} from './desktop.mjs';

const defaults = {hermes:{enabled:false,python:'',source:'',browserExecutable:'',desktopDriver:'',coding:true,browser:false,desktop:false},harnesses:[],engine:'black-team',dictation:''};
const basename = value => value.split('/').filter(Boolean).at(-1) || 'My app';

function Arguments({label, values, onChange}) {
  return <div className="argument-list"><strong>{label}</strong>{values.map((value,index)=><div className="button-row" key={index}><input aria-label={`${label} ${index+1}`} value={value} onChange={e=>onChange(values.map((item,i)=>i===index?e.target.value:item))}/><button type="button" className="text-button" aria-label={`Remove ${label.toLowerCase()} ${index+1}`} onClick={()=>onChange(values.filter((_,i)=>i!==index))}>Remove</button></div>)}<button type="button" className="secondary" onClick={()=>onChange([...values,''])}>Add argument</button></div>;
}

export default function Integrations({status,busy,onAction,onChat}) {
  const [form,setForm]=useState(()=>structuredClone(status.integrations||defaults));
  const [installed,setInstalled]=useState(null);
  const [detecting,setDetecting]=useState(true);
  const [selected,setSelected]=useState('0');
  const [error,setError]=useState('');
  const [appChoice,setAppChoice]=useState('');
  const disabled=busy || status.runtime?.busy || detecting;
  const update=(field,value)=>setForm(previous=>({...previous,hermes:{...previous.hermes,[field]:value}}));
  const updateHarness=(id,field,value)=>setForm(previous=>({...previous,harnesses:previous.harnesses.map(item=>item.id===id?{...item,[field]:value}:item)}));
  useEffect(()=>{
    let active=true;
    native('installed-discover').then(value=>{if(active){setInstalled(value);if(value.hermes?.length===1)setForm(previous=>({...previous,hermes:{...previous.hermes,source:previous.hermes.source||value.hermes[0].source,python:previous.hermes.python||value.hermes[0].python}}));}}).catch(cause=>{if(active)setError(cause.message);}).finally(()=>{if(active)setDetecting(false);});
    return ()=>{active=false;};
  },[]);
  const scan=async()=>{setDetecting(true);setError('');try{setInstalled(await native('installed-discover'));setSelected('0');}catch(cause){setError(cause.message);}finally{setDetecting(false);}};
  const save=async next=>{
    setError('');
    const result=await onAction('integrations-save',next,'Agent connections saved.');
    if(result)setForm(next);
    return result;
  };
  const connect=async()=>{
    const found=installed?.hermes?.[Number(selected)];
    if(!found)return;
    await save({...form,hermes:{...form.hermes,...found,enabled:true}});
  };
  const browseHermes=async()=>{
    setError('');
    try{
      const source=await window.blackTeam.pick('hermes-source');
      if(!source)return;
      const found=await native('hermes-inspect',{source});
      if(!found){setError('No ready Hermes Python environment found in this folder. Finish Hermes installation, or choose its Python interpreter under Advanced setup.');update('source',source);return;}
      setInstalled(previous=>({...previous,hermes:[found]}));setSelected('0');setForm(previous=>({...previous,hermes:{...previous.hermes,...found}}));
    }catch(cause){setError(cause.message);}
  };
  const pick=async(field,id)=>{
    try{
      const value=await window.blackTeam.pick('executable');
      if(!value)return;
      if(id)updateHarness(id,field,value);else update(field,value);
    }catch(cause){setError(cause.message);}
  };
  const addApp=async()=>{
    setError('');
    try{
      let found=installed?.apps?.find(item=>item.executable===appChoice);
      const executable=found?.executable || await window.blackTeam.pick('executable');
      if(!executable)return;
      // A known harness chosen by hand is connected the same way as one found automatically.
      const known=!found&&installed?.presets?.find(item=>item.command===basename(executable));
      if(known)found={id:known.id,name:known.name,executable,preset:true};
      if(found && !installed?.terminals?.length){setError('A terminal is needed to open this command-line app. Install a terminal, then choose Find again.');return;}
      const terminal=found?installed.terminals[0]:null;
      const item={id:crypto.randomUUID(),name:found?.name||basename(executable),executable,args:[],terminal:terminal?[terminal.executable,...terminal.args]:[],...(found?.preset?{preset:found.id}:{})};
      setForm(previous=>({...previous,harnesses:[...previous.harnesses,item]}));
    }catch(cause){setError(cause.message);}
  };
  const found=installed?.hermes?.[Number(selected)];
  const connected=status.integrations?.hermes?.enabled;
  return <section className="setup-form agent-setup">
    <div className="panel-heading"><div><span className="eyebrow">AGENTS & APPS</span><h2>Give your model tools</h2></div></div>
    <p className="section-intro">Code is built in and needs no setup. Hermes is optional, for its browser and desktop tools. Add other apps below to open them from your workspace.</p>
    <fieldset disabled={disabled}>
      <div className="connection-card full"><div><h3>Black Team Code</h3><p>Black Team’s own engine, built for local models: it measures your model’s speed and sizes its work to match. Reads, searches and edits files, runs commands, shows every change with Undo, and remembers across conversations.</p><span className="connection-label ready" role="status">Built in</span></div>
        <button type="button" className="primary" disabled={!status.setupComplete} onClick={onChat}>Open Code</button>
      </div>
      {connected&&<div className="full engine-choice"><div className="mode-toggle" role="group" aria-label="What runs new Code conversations">{[['black-team','Black Team'],['hermes','Hermes']].map(([id,label])=><button type="button" key={id} className={(form.engine||'black-team')===id?'selected':''} aria-pressed={(form.engine||'black-team')===id} onClick={()=>save({...form,engine:id})}>{label}</button>)}</div><small>Runs new Code conversations. Existing ones keep the engine they started with.</small></div>}
      <div className="connection-card full"><div><h3>Hermes</h3><p>The Hermes agent, if you have it installed. Slower to start on a local model; adds browser and desktop tools.</p><span className="connection-label" role="status">{connected?'Connected':detecting?'Looking for Hermes…':found?'Hermes found on this computer':'Hermes installation needed'}</span></div>
        {connected?null:found?<button type="button" className="primary" onClick={connect}>Connect Hermes</button>:<button type="button" className="secondary" onClick={browseHermes}>Choose Hermes folder</button>}
      </div>
      {!connected&&installed?.hermes?.length>1&&<label className="form-field full">Choose an installation<select value={selected} onChange={e=>setSelected(e.target.value)}>{installed.hermes.map((item,index)=><option value={index} key={item.source}>{item.source}</option>)}</select></label>}
      {!connected&&!found&&!detecting&&<p className="inline-note full"><button type="button" className="text-button" onClick={()=>onAction("setup-help",{topic:"hermes"})}>Install Hermes Agent</button>, then choose Find again. If it is already installed elsewhere, choose its folder. Black Team never downloads an agent without your action.</p>}
      <div className="button-row full"><button type="button" className="text-button" onClick={scan}>Find again</button>{found&&!connected&&<button type="button" className="text-button" onClick={browseHermes}>Choose another installation</button>}</div>
      {(connected||found)&&<p className="inline-note full">Code and Hermes use file and terminal tools as your Linux user. Your model must support tool calls. Browser and desktop control stay optional.</p>}
      <details className="full advanced-settings"><summary>Tools and advanced setup</summary><div className="form-grid">
        <label className="checkbox-field full"><input type="checkbox" checked={form.hermes.enabled} onChange={e=>update('enabled',e.target.checked)}/>Enable Hermes</label>
        <label className="form-field full">Hermes source folder<div className="button-row"><input value={form.hermes.source} onChange={e=>update('source',e.target.value)}/><button className="secondary" type="button" onClick={browseHermes}>Browse</button></div></label>
        <label className="form-field full">Hermes Python<div className="button-row"><input value={form.hermes.python} onChange={e=>update('python',e.target.value)}/><button className="secondary" type="button" onClick={()=>pick('python')}>Browse</button></div></label>
        {['coding','browser','desktop'].map(key=><label className="checkbox-field full" key={key}><input type="checkbox" checked={form.hermes[key]} onChange={e=>update(key,e.target.checked)}/><span>{{coding:'Files, terminal, search and planning',browser:'Browser tools — requires Hermes browser setup',desktop:'Desktop control — requires a computer-use driver'}[key]}</span></label>)}
        {form.hermes.browser&&<label className="form-field full">Browser executable (optional)<input value={form.hermes.browserExecutable||''} onChange={e=>update('browserExecutable',e.target.value)}/></label>}
        {form.hermes.desktop&&<label className="form-field full">Desktop driver (optional)<input value={form.hermes.desktopDriver||''} onChange={e=>update('desktopDriver',e.target.value)}/></label>}
        <p className="inline-note full">The workspace is a working folder, not a sandbox. Tool approvals appear in the conversation. Browser tools may access the internet.</p>
      </div></details>
      <div className="full"><h3>Other apps</h3><p className="section-intro">Open an installed app in its own window. Set that app to use your local provider first; these launchers do not mirror its sessions to your phone.</p></div>
      {form.harnesses.map(item=><div className="harness-editor full" key={item.id}>
        <label className="form-field full">App name<input value={item.name} onChange={e=>updateHarness(item.id,'name',e.target.value)}/></label>
        <span className="file-path full">{item.executable}</span>
        <details className="full"><summary>Launch options</summary><div className="form-grid">
          <button type="button" className="secondary full" onClick={()=>pick('executable',item.id)}>Choose executable</button>
          <label className="form-field full">Open in<select value={!item.terminal.length?'window':installed?.terminals?.some(t=>JSON.stringify([t.executable,...t.args])===JSON.stringify(item.terminal))?item.terminal[0]:'custom'} onChange={e=>{const terminal=installed?.terminals?.find(t=>t.executable===e.target.value);updateHarness(item.id,'terminal',terminal?[terminal.executable,...terminal.args]:e.target.value==='window'?[]:item.terminal);}}><option value="window">Its own app window</option>{installed?.terminals?.map(t=><option value={t.executable} key={t.executable}>{t.name}</option>)}{item.terminal.length>0&&!installed?.terminals?.some(t=>JSON.stringify([t.executable,...t.args])===JSON.stringify(item.terminal))&&<option value="custom">Custom terminal</option>}</select></label>
          <div className="full"><Arguments label="App argument" values={item.args} onChange={value=>updateHarness(item.id,'args',value)}/><small>One value per field. Use {'{endpoint}'}, {'{model}'} or {'{workspace}'} where your app expects them. Values are passed literally.</small></div>
          <details className="full"><summary>Custom terminal command</summary><Arguments label="Terminal argument" values={item.terminal} onChange={value=>updateHarness(item.id,'terminal',value)}/><small>First value: absolute terminal executable. Following values: its launch arguments.</small></details>
        </div></details>
        <button type="button" className="text-button" onClick={()=>setForm(previous=>({...previous,harnesses:previous.harnesses.filter(h=>h.id!==item.id)}))}>Remove {item.name}</button>
      </div>)}
      <div className="button-row full"><label className="form-field">Add an app<select value={appChoice} onChange={e=>setAppChoice(e.target.value)}><option value="">Choose an app file…</option>{installed?.apps?.map(app=><option key={app.executable} value={app.executable}>{app.name} — installed</option>)}</select></label><button type="button" className="secondary" disabled={form.harnesses.length>=20} onClick={addApp}>Add app</button></div>
      <div className="form-actions full"><button type="button" className="primary" onClick={()=>save(form)}>Save changes</button><small>Saved apps appear on your workspace.</small></div>
    </fieldset>
    {error&&<p role="alert" className="error-text inline-note">{error}</p>}
  </section>;
}
