import React, {useState} from 'react';

const defaults = {hermes:{enabled:false,python:'',source:'',browserExecutable:'',desktopDriver:'',coding:true,browser:false,desktop:false},harnesses:[]};
export default function Integrations({status,busy,onAction}) {
  const [form,setForm]=useState(()=>structuredClone(status.integrations||defaults));
  const [error,setError]=useState('');
  const update=(field,value)=>setForm(previous=>({...previous,hermes:{...previous.hermes,[field]:value}}));
  const updateHarness=(index,field,value)=>setForm(previous=>({...previous,harnesses:previous.harnesses.map((item,i)=>i===index?{...item,[field]:value}:item)}));
  async function save(event){event.preventDefault();setError('');try{
    const harnesses=form.harnesses.map(item=>({...item,args:typeof item.args==='string'?JSON.parse(item.args):item.args,terminal:typeof item.terminal==='string'?JSON.parse(item.terminal):item.terminal}));
    await onAction('integrations-save',{...form,harnesses},'Harness settings saved.');
  }catch{setError('Arguments and terminal prefix must be JSON arrays of strings.');}}
  return <form className="setup-form" onSubmit={save}>
    <div className="panel-heading"><div><span className="eyebrow">BLACK TEAM HARNESS</span><h2>Local tools. Your models.</h2></div></div>
    <p className="section-intro">Use Black Team’s built-in agent harness with an installed Hermes Agent, or launch other harnesses you have configured for a local model. Install those tools separately.</p>
    <fieldset disabled={busy || status.runtime?.busy}>
      <label className="checkbox-field full"><input type="checkbox" checked={form.hermes.enabled} onChange={e=>update('enabled',e.target.checked)}/><span>Enable Black Team Agent with Hermes tools</span></label>
      <label className="form-field full">Hermes Python executable<input value={form.hermes.python} required={form.hermes.enabled} onChange={e=>update('python',e.target.value)} placeholder="/home/you/.hermes/hermes-agent/venv/bin/python"/><small>Use the Python environment in which Hermes and its dependencies are installed.</small></label>
      <label className="form-field full">Hermes Agent source folder<input value={form.hermes.source} required={form.hermes.enabled} onChange={e=>update('source',e.target.value)} placeholder="/home/you/.hermes/hermes-agent"/></label>
      {['coding','browser','desktop'].map(key=><label className="checkbox-field full" key={key}><input type="checkbox" checked={form.hermes[key]} onChange={e=>update(key,e.target.checked)}/><span>{{coding:'Terminal, file editing, search and task planning',browser:'Local browser tools (requires Hermes browser setup)',desktop:'Desktop control (requires Hermes computer-use driver)'}[key]}</span></label>)}
      {form.hermes.browser&&<label className="form-field full">Local browser executable (optional)<input value={form.hermes.browserExecutable||''} onChange={e=>update('browserExecutable',e.target.value)} placeholder="/absolute/path/to/chrome"/><small>Set this when Hermes cannot discover your installed browser.</small></label>}
      {form.hermes.desktop&&<label className="form-field full">Computer-use driver executable (optional)<input value={form.hermes.desktopDriver||''} onChange={e=>update('desktopDriver',e.target.value)} placeholder="/absolute/path/to/cua-driver"/></label>}
      <p className="inline-note full">Enabled tools operate as your Linux user. The workspace is a working folder, not a sandbox. Approvals appear in Black Team on desktop and phone. Browser actions can use the internet; local inference does not make external tool actions offline.</p>
      <h2 className="full">Other harnesses</h2>
      <p className="section-intro full">Add your installed local-model launchers. Black Team provides the selected endpoint, model and workspace. Each harness must be configured to use them; compatibility depends on that harness.</p>
      {form.harnesses.map((item,index)=><div className="harness-editor full" key={index}>
        <label className="form-field">ID<input required pattern="[a-z0-9-]{1,40}" value={item.id} onChange={e=>updateHarness(index,'id',e.target.value)} placeholder="hermes-terminal"/></label>
        <label className="form-field">Display name<input required value={item.name} onChange={e=>updateHarness(index,'name',e.target.value)} placeholder="Hermes Terminal"/></label>
        <label className="form-field full">Executable / wrapper<input required value={item.executable} onChange={e=>updateHarness(index,'executable',e.target.value)} placeholder="/home/you/bin/my-local-harness"/></label>
        <label className="form-field full">Arguments (JSON array)<input value={typeof item.args==='string'?item.args:JSON.stringify(item.args)} onChange={e=>updateHarness(index,'args',e.target.value)}/><small>Literal arguments. Supported placeholders: {'{endpoint}'}, {'{model}'}, {'{workspace}'}. No shell expansion.</small></label>
        <label className="form-field full">Terminal prefix (JSON array)<input value={typeof item.terminal==='string'?item.terminal:JSON.stringify(item.terminal)} onChange={e=>updateHarness(index,'terminal',e.target.value)}/><small>For a CLI, for example: ["/usr/bin/xterm", "-e"]. For a GUI executable: [].</small></label>
        <button type="button" className="text-button" onClick={()=>setForm(previous=>({...previous,harnesses:previous.harnesses.filter((_,i)=>i!==index)}))}>Remove harness</button>
      </div>)}
      <button type="button" className="secondary" disabled={form.harnesses.length>=20} onClick={()=>setForm(previous=>({...previous,harnesses:[...previous.harnesses,{id:'',name:'',executable:'',args:[],terminal:[]}]}))}>Add harness</button>
      <div className="form-actions full"><button className="primary">Save harness settings</button></div>
    </fieldset>
    {error&&<p role="alert" className="error-text">{error}</p>}
  </form>;
}
