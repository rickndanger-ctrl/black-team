import React, {useState} from 'react';
import {native} from './desktop.mjs';
import Icon from './Icons.jsx';
import AgentAvatar from './AgentAvatar.jsx';

export const SERVICES = [
  ['openrouter', 'OpenRouter', 'https://openrouter.ai/api/v1'],
  ['openai', 'OpenAI', 'https://api.openai.com/v1'],
  ['anthropic', 'Anthropic', 'https://api.anthropic.com/v1'],
  ['google', 'Google', 'https://generativelanguage.googleapis.com/v1beta/openai'],
  ['other', 'Another service', ''],
];
const serviceFor = endpoint => SERVICES.find(service => service[2] === endpoint)?.[0] || 'other';

// The cloud form in model setup. The key is only in this form's state, until it is saved.
export default function CloudModel({status, busy, onSaved}) {
  const saved = status.config?.model?.kind === 'cloud' ? status.config.model : null;
  const [service, setService] = useState(() => serviceFor(saved?.endpoint || SERVICES[0][2]));
  const [endpoint, setEndpoint] = useState(() => saved?.endpoint || SERVICES[0][2]);
  const [apiKey, setApiKey] = useState('');
  const [models, setModels] = useState([]);
  const [modelId, setModelId] = useState(() => saved?.id || '');
  const [name, setName] = useState(() => saved?.name && saved.name !== saved.id ? saved.name : '');
  const [context, setContext] = useState(() => saved?.context || 128000);
  const [freeOnly, setFreeOnly] = useState(false);
  const [working, setWorking] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const [message, setMessage] = useState('');
  const host = (() => {try {return new URL(endpoint).host;} catch {return '';}})();
  const keySaved = status.models?.some(model => model.kind === 'cloud' && model.keyConfigured && model.provider === host);
  const freeCount = models.filter(model => model.freeAgent).length;
  const shown = freeOnly ? models.filter(model => model.freeAgent) : models;
  // Changing the address clears what was found for the old one, including the key field.
  const clear = () => {setApiKey(''); setModels([]); setModelId(''); setName(''); setFreeOnly(false); setError(''); setMessage('');};
  const chooseService = id => {const found = SERVICES.find(item => item[0] === id); setService(id); setEndpoint(found[2]); clear();};
  const changeEndpoint = value => {setService(serviceFor(value)); setEndpoint(value); clear();};
  const find = async () => {
    setError(''); setMessage(''); setModels([]); setWorking(true);
    try {
      const result = await native('cloud-discover', {endpoint, ...(apiKey.trim() ? {apiKey: apiKey.trim()} : {})});
      setModels(result.models);
      setMessage(`${result.models.length} ${result.models.length === 1 ? 'model' : 'models'} from ${result.host}. Choose one below.`);
    } catch (cause) {setError(cause.message);}
    finally {setWorking(false);}
  };
  const pick = id => {
    setModelId(id); setName('');
    const found = models.find(model => model.id === id);
    if (found) setContext(found.context ? Math.min(found.context, 2000000) : 128000);
  };
  const save = async () => {
    setError(''); setMessage(''); setSaving(true);
    try {
      const result = await native('cloud-save', {endpoint, id: modelId.trim(), context, ...(name.trim() ? {name: name.trim()} : {}), ...(apiKey.trim() ? {apiKey: apiKey.trim()} : {})});
      setApiKey(''); setModels([]); setFreeOnly(false);
      setMessage(result.warning || 'Cloud model saved. Send a message to begin.');
      onSaved?.();
    } catch (cause) {setError(cause.message);}
    finally {setSaving(false);}
  };
  return <fieldset className="cloud-model full" disabled={busy || saving}>
    <p className="section-intro">Use a service with your own API key. What you send leaves this computer.</p>
    <div className="inline-note">Conversations with a cloud model leave this computer: Black Team sends your messages, and in Code the contents of files the agent reads and the output of commands it runs, to the service you name. Memory is not used. Your key stays on this computer and goes only to this service’s address.</div>
    <div className="form-grid">
      <label className="form-field">Service<select value={service} onChange={event => chooseService(event.target.value)}>{SERVICES.map(([id, label]) => <option key={id} value={id}>{label}</option>)}</select></label>
      <label className="form-field full">Service address<input value={endpoint} placeholder="https://" onChange={event => changeEndpoint(event.target.value)}/><small>https only. The key is sent here and nowhere else.</small></label>
      <label className="form-field full">API key<input type="password" autoComplete="off" value={apiKey} placeholder={keySaved && !apiKey ? 'Saved key — leave unchanged to keep' : 'Paste your key. It is not shown again.'} onChange={event => setApiKey(event.target.value)}/></label>
      <div className="button-row full"><button type="button" className="secondary" disabled={working || !endpoint.trim()} onClick={find}>{working ? 'Finding models…' : 'Find models'}</button><small>Asks the service for the models your key can use. You can also type a model id.</small></div>
      {working && <p className="full" role="status">Asking the service…</p>}
      {message && !working && <p className="full" role="status">{message}</p>}
      {freeCount > 0 && <label className="checkbox-field full"><input type="checkbox" checked={freeOnly} onChange={event => setFreeOnly(event.target.checked)}/><span>Free models that can use tools ({freeCount})</span></label>}
      {freeOnly && <p className="inline-note full">Free models have daily limits, and the service may use what you send to train its models. Do not send anything private through one.</p>}
      {models.length > 0 && <label className="form-field full">Models from the service<select value={shown.some(model => model.id === modelId) ? modelId : ''} onChange={event => pick(event.target.value)}><option value="">Choose a model</option>{shown.map(model => <option key={model.id} value={model.id}>{model.id}{model.free ? ' · free' : ''}</option>)}</select></label>}
      <label className="form-field">Model id<input value={modelId} placeholder="For example gpt-5.1 or anthropic/claude-sonnet" onChange={event => setModelId(event.target.value)}/></label>
      <label className="form-field">Display name<input value={name} maxLength={120} placeholder="Uses the model id automatically" onChange={event => setName(event.target.value)}/></label>
      <label className="form-field">Context window<input type="number" min="512" max="2000000" value={context} onChange={event => setContext(Number(event.target.value))}/><small>The most the model can read at once. Code works within 60% of it.</small></label>
      <div className="form-actions full"><button type="button" className="primary" disabled={saving || !modelId.trim() || !endpoint.trim()} onClick={save}>{saving ? 'Saving…' : 'Save cloud model'}</button><small>The key is stored on this computer and never shown again.</small></div>
    </div>
    {error && <p role="alert" className="inline-note error-text">{error}</p>}
  </fieldset>;
}

// The home page card for a cloud model in use: no process, so no start or stop.
export function CloudPanel({status, busy, onChat, onSettings}) {
  const model = status.config?.model || {};
  return <section className="local-model-panel">
    <div className="model-identity"><AgentAvatar large active={status.runtime?.busy}/><div><span className="eyebrow">YOUR CLOUD MODEL</span><h2>{model.name || 'Cloud model'}<em className="cloud-tag">Cloud · {model.provider}</em></h2><p>Ready. Conversations with this model leave this computer, and the service you chose receives what they contain.</p></div></div>
    <div className="model-facts"><div><span>Model</span><strong>{model.id}</strong></div><div><span>Service</span><strong>{model.provider}</strong></div><div><span>Context window</span><strong>{Number(model.context || status.config?.model?.context || 0).toLocaleString()} tokens</strong></div></div>
    <div className="button-row"><button className="primary" disabled={busy} onClick={() => onChat('chat')}><Icon name="chat" size={16}/>Open chat</button><button className="link-button" onClick={() => onSettings('model')}>Change model <Icon name="arrow" size={15}/></button></div>
  </section>;
}
