import React, {useState} from 'react';
import {native} from './desktop.mjs';

const baseModel={source:'server',endpoint:'http://127.0.0.1:11434/v1',id:'',name:'',file:'',runtime:'',context:4096,gpuLayers:0,threads:4};
const filename=value=>value.split('/').filter(Boolean).at(-1)||'';
const modelLabel=value=>filename(value).replace(/\.gguf$/i,'').slice(0,120);
const providers=[['ollama','Ollama','Use models downloaded in Ollama','http://127.0.0.1:11434/v1'],['lmstudio','LM Studio','Use its running local server','http://127.0.0.1:1234/v1'],['gguf','Model file','Choose a GGUF on this computer'],['custom','Another server','Enter a local address']];
const providerFor=model=>model.source==='gguf'?'gguf':providers.find(p=>p[3]===model.endpoint)?.[0]||'custom';

export default function ModelSetup({status,onSave,onAction,busy,settings=false}) {
  const [form,setForm]=useState(()=>({model:{...baseModel,...status.config?.model,...(!status.setupComplete?{source:'server',name:''}:{})},workspace:status.config?.workspace||''}));
  const [provider,setProvider]=useState(()=>providerFor(form.model));
  const [models,setModels]=useState([]);
  const [checking,setChecking]=useState(false);
  const [error,setError]=useState('');
  const [message,setMessage]=useState('');
  const running=status.runtime?.ready||['starting','running'].includes(status.runtime?.state);
  const server=provider!=='gguf';
  const update=(key,value)=>setForm(previous=>({...previous,model:{...previous.model,[key]:value}}));
  const discover=async(endpoint=form.model.endpoint,apiKey=form.model.apiKey)=>{
    setError('');setMessage('');setChecking(true);setModels([]);
    try{
      const result=await native('server-discover',{endpoint,...(apiKey===undefined?{}:{apiKey})});
      setModels(result.models);
      setForm(previous=>{const id=result.models.includes(previous.model.id)?previous.model.id:result.models[0];return {...previous,model:{...previous.model,id,name:modelLabel(id)}};});
      setMessage(`${result.models.length} ${result.models.length===1?'model found':'models found'}. Choose one below.`);
    }catch(cause){setError(cause.message);}
    finally{setChecking(false);}
  };
  const chooseProvider=async id=>{
    setProvider(id);setError('');setModels([]);setMessage('');
    const endpoint=providers.find(p=>p[0]===id)?.[3];
    setForm(previous=>({...previous,model:{...previous.model,source:id==='gguf'?'gguf':'server',...(endpoint?{endpoint,id:'',name:'',...(endpoint===previous.model.endpoint?{}:{apiKey:''})}:{})}}));
    if(endpoint)await discover(endpoint,endpoint===form.model.endpoint?form.model.apiKey:'');
    if(id==='gguf'&&!form.model.runtime){
      setChecking(true);
      try{const found=await native('installed-discover');if(found.runtime)update('runtime',found.runtime);}catch(cause){setError(cause.message);}finally{setChecking(false);}
    }
  };
  const pick=async kind=>{
    setError('');
    try{
      const value=await window.blackTeam.pick(kind);
      if(!value)return;
      if(kind==='workspace')setForm(previous=>({...previous,workspace:value}));
      else setForm(previous=>({...previous,model:{...previous.model,[kind==='model'?'file':'runtime']:value,...(kind==='model'?{name:filename(value).replace(/\.gguf$/i,'').slice(0,120)}:{})}}));
    }catch(cause){setError(cause.message);}
  };
  const save=event=>{
    event.preventDefault();
    const model={...form.model,name:(form.model.name.trim()||(server?form.model.id:filename(form.model.file))).slice(0,120)};
    onSave({...form,model});
  };
  return <form className="setup-form" onSubmit={save}>
    <div className="panel-heading"><div><span className="eyebrow">YOUR MODELS</span><h2>{settings?'Choose your model':'Connect a model. Start a conversation.'}</h2></div></div>
    <p className="section-intro">Choose where your model lives. Black Team fills in the connection details. Use a downloaded model to keep inference on this computer.</p>
    {running&&<div className="connection-card"><div><strong>{status.config.model.name}</strong><p>{status.runtime.busy?'Finish or stop the current response before changing models.':'Connected. Disconnect here to choose another model.'}</p></div><button type="button" className="secondary" disabled={busy||status.runtime.busy} onClick={()=>onAction('runtime-stop',{},'Ready to choose another model.')}>Change model</button></div>}
    <fieldset disabled={busy||checking||running}>
      <div className="provider-grid full" role="group" aria-label="Where is your model?">{providers.map(([id,name,description])=><button type="button" key={id} aria-pressed={provider===id} className={`provider-card${provider===id?' selected':''}`} onClick={()=>chooseProvider(id)}><strong>{name}</strong><span>{description}</span></button>)}</div>
      {server?<>
        {provider==='custom'&&<label className="form-field full">Local server address<input value={form.model.endpoint} placeholder="http://127.0.0.1:1234/v1" onChange={e=>{setModels([]);setMessage('');setForm(previous=>({...previous,model:{...previous.model,endpoint:e.target.value,id:'',apiKey:''}}));}}/></label>}
        <div className="button-row full"><button type="button" className="secondary" onClick={()=>discover()}>{checking?'Finding models…':'Find models'}</button><small>{provider==='ollama'?'Start Ollama first.':provider==='lmstudio'?'Turn on the local server in LM Studio first.':'Start your server and enable its API first.'}</small></div>
        {checking&&<p className="full" role="status">Checking your local server…</p>}
        {message&&<p className="full" role="status">{message}</p>}
        {(models.length>0||form.model.id)&&<label className="form-field full">Model<select value={form.model.id} onChange={e=>setForm(previous=>({...previous,model:{...previous.model,id:e.target.value,name:modelLabel(e.target.value)}}))}>{[...new Set([form.model.id,...models].filter(Boolean))].map(id=><option key={id} value={id}>{modelLabel(id)}</option>)}</select></label>}
      </>:<>
        <div className="file-picker full"><div><strong>Model file</strong><span className="file-path">{form.model.file?filename(form.model.file):'Choose a GGUF already on your computer'}</span></div><button type="button" className="secondary" onClick={()=>pick('model')}>Choose model</button></div>
        <div className="file-picker full"><div><strong>{form.model.runtime?'llama.cpp ready':'Choose llama.cpp once'}</strong><span className="file-path">{form.model.runtime||'Select the llama-server executable from your installation'}</span></div><button type="button" className="secondary" onClick={()=>pick('runtime')}>{form.model.runtime?'Change':'Choose runtime'}</button></div>
      </>}
      <details className="full advanced-settings"><summary>Advanced connection and performance</summary><div className="form-grid">
        <label className="form-field full">Display name (optional)<input value={form.model.name} maxLength={120} onChange={e=>update('name',e.target.value)} placeholder="Uses the model name automatically"/></label>
        {server&&<>
          {provider!=='custom'&&<label className="form-field full">Server address<input value={form.model.endpoint} onChange={e=>{setProvider('custom');setModels([]);setMessage('');setForm(previous=>({...previous,model:{...previous.model,endpoint:e.target.value,id:'',apiKey:''}}));}}/></label>}
          <label className="form-field full">Server API key (only if required)<input type="password" autoComplete="off" value={form.model.apiKey??''} placeholder={status.serverKeyConfigured&&form.model.apiKey===undefined?'Saved key — leave unchanged to keep':'Most local servers need no key'} onChange={e=>update('apiKey',e.target.value)}/></label>
          {status.serverKeyConfigured&&<button type="button" className="text-button full" onClick={()=>update('apiKey','')}>Clear saved key on save</button>}
          <label className="form-field full">Model ID (manual override)<input value={form.model.id} onChange={e=>update('id',e.target.value)}/></label>
        </>}
        <div className="file-picker full"><div><strong>Workspace</strong><span className="file-path">{form.workspace}</span></div><button type="button" className="secondary" onClick={()=>pick('workspace')}>Change folder</button></div>
        <label className="form-field">Context window<input type="number" min="512" max="131072" value={form.model.context} onChange={e=>update('context',Number(e.target.value))}/><small>{server?'Use no more than the context loaded by your server.':'Larger values use more memory.'}</small></label>
        {!server&&<><label className="form-field">CPU threads<input type="number" min="1" max="1024" value={form.model.threads} onChange={e=>update('threads',Number(e.target.value))}/></label><label className="form-field">GPU layers<input type="number" min="0" max="999" value={form.model.gpuLayers} onChange={e=>update('gpuLayers',Number(e.target.value))}/><small>0 uses CPU. GPU layers require a compatible runtime.</small></label></>}
      </div></details>
      <div className="form-actions full"><button className="primary" disabled={server?!form.model.id.trim()||!form.model.endpoint:!form.model.file||!form.model.runtime}>{busy?'Saving…':'Save and open chat'}</button><small>Your first message connects the model automatically.</small></div>
    </fieldset>
    {server&&['ollama','lmstudio'].includes(provider)&&<button type="button" className="text-button" disabled={busy||checking} onClick={()=>onAction('setup-help',{topic:provider})}>Get {provider==='ollama'?'Ollama':'LM Studio'}</button>}
    {error&&<p className="inline-note error-text" role="alert">{error} If your server uses a key, add it under Advanced connection and performance, then choose Find models again.</p>}
  </form>;
}
