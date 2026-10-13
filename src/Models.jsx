import React from 'react';

// The model in use, as a menu when more than one is set up. Switching is a desktop action.
export function ModelSwitch({models = [], name, disabled, onSwitch}) {
  const active = models.find(model => model.active);
  if (!onSwitch || models.length < 2) return <small>{name}</small>;
  return <select className="model-switch" aria-label="Model in use" title="Switch model" value={active?.key || ''} disabled={disabled} onChange={event => onSwitch(event.target.value)}>
    {!active && <option value="" disabled>{name}</option>}
    {models.map(model => <option key={model.key} value={model.key}>{model.kind === 'cloud' ? `${model.name} · Cloud` : model.name}</option>)}
  </select>;
}

export function ModelList({models = [], busy, working, onSwitch, onForget}) {
  if (!models.length) return null;
  return <section className="model-list" aria-label="Your models">
    <div className="panel-heading"><div><span className="eyebrow">YOUR MODELS</span><h2>Switch between your models</h2></div></div>
    <p className="section-intro">Every model you set up is kept here. Choosing one stops the model in use; your next message starts the new one.</p>
    <ul>{models.map(model => <li key={model.key} className={model.active ? 'active' : ''}>
      {model.kind === 'cloud'
        ? <div><strong>{model.name}<em className="cloud-tag">Cloud</em></strong><span>Cloud · {model.provider} · {model.keyConfigured ? 'Key saved on this computer' : 'No key saved'} · {Number(model.context).toLocaleString()} tokens</span></div>
        : <div><strong>{model.name}</strong><span>Local · {model.source === 'server' ? 'Local server' : 'Model file'} · {model.where} · {Number(model.context).toLocaleString()} tokens</span></div>}
      {model.active ? <span className="in-use">In use</span> : <div className="button-row"><button type="button" className="secondary" disabled={busy || working} onClick={() => onSwitch(model.key)}>Use</button><button type="button" className="text-button" disabled={busy || working} onClick={() => onForget(model.key)} aria-label={`Remove ${model.name} from your list`}>Remove</button></div>}
    </li>)}</ul>
    {working && <p className="inline-note">Finish or stop the current response before switching models.</p>}
  </section>;
}
