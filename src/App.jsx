import React, {useCallback, useEffect, useRef, useState} from 'react';
import Integrations from './Integrations.jsx';
import Brand from './Brand.jsx';
import AgentAvatar from './AgentAvatar.jsx';
import Icon from './Icons.jsx';
import {responseActivity} from './responseActivity.mjs';

const desktop = Boolean(window.blackTeam?.request);
const defaultModel = {source: 'gguf', endpoint: 'http://127.0.0.1:11434/v1', id: '', name: '', file: '', runtime: '', context: 4096, gpuLayers: 0, threads: 4};
const byteSize = value => Number.isFinite(value) ? `${(value / 1024 ** 3).toFixed(1)} GB` : 'Unavailable';
const basename = path => path?.split(/[\\/]/).filter(Boolean).at(-1) || 'Not selected';
const date = value => value ? new Date(value).toLocaleDateString(undefined, {month: 'short', day: 'numeric'}) : '';

async function api(path, options = {}) {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 20000);
  let response;
  try {
    response = await fetch(path, {credentials: 'same-origin', cache: 'no-store', ...options, signal: controller.signal, headers: {'Content-Type': 'application/json', ...options.headers}});
  } finally {window.clearTimeout(timeout);}
  if (!response.ok) {
    const error = new Error(response.status === 403 || response.status === 401 ? 'Connect to Tailscale and open the Companion pairing link from your Black Team desktop app.' : 'That request could not be completed. Check your computer’s connection and try again.');
    if (![401,403].includes(response.status)) {try {const value=await response.json();if(typeof value.error==='string')error.message=value.error;}catch{}}
    error.status = response.status;
    throw error;
  }
  return response.json();
}
const post = (path, value) => api(path, {method: 'POST', body: JSON.stringify(value)});
const native = async (action, data = {}) => {
  try {return await window.blackTeam.request(action, data);}
  catch (cause) {
    const message=String(cause?.message || 'The desktop action could not finish.').replace(/^Error invoking remote method '[^']+':\s*(?:Error:\s*)?/, '');
    throw new Error(message);
  }
};

// One initialization promise survives React's development effect replay. The
// pairing secret is consumed from the URL and never written to browser storage.
let companionInitialization;
function initializeCompanion() {
  if (desktop) return Promise.resolve();
  if (!companionInitialization) companionInitialization = (async () => {
    const fragment = new URLSearchParams(window.location.hash.slice(1));
    if (!fragment.has('pair')) return;
    const key = fragment.get('pair');
    window.history.replaceState(null, '', window.location.pathname + window.location.search);
    try {
      if (!/^[a-f0-9]{64}$/i.test(key || '')) throw new Error('Invalid pairing link.');
      await post('/api/pair', {key});
    } catch {
      const error = new Error('Companion pairing could not finish. Connect to Tailscale, then reopen the pairing link from your Black Team desktop app.');
      error.status = 401;
      throw error;
    }
  })();
  return companionInitialization;
}

function StatusPill({status, connection}) {
  const ready = connection === 'online' && status?.runtime?.ready;
  const label = connection !== 'online' ? (connection === 'connecting' ? 'Connecting' : 'Connection lost') : status?.runtime?.state === 'starting' ? (status?.config?.model?.source === 'server' ? 'Connecting model' : 'Starting model') : status?.runtime?.busy ? 'Model responding' : ready ? 'Model ready' : 'Model stopped';
  return <span className={`online status-pill${ready ? ' is-ready' : ''}`} role="status"><i className={ready ? 'live-dot' : 'idle-dot'}/>{label}</span>;
}

function SetupForm({status, onSave, busy, settings = false}) {
  const [form, setForm] = useState(() => ({model: {...defaultModel, threads: Math.max(1, Math.min(8, status?.hardware?.cores || 4)), ...status?.config?.model}, workspace: status?.config?.workspace || ''}));
  const [pickerError, setPickerError] = useState('');
  const [models, setModels] = useState([]);
  const [discovering, setDiscovering] = useState(false);
  const server = form.model.source === 'server';
  const discover = async () => {
    setPickerError(''); setDiscovering(true); setModels([]);
    try {
      const result = await native('server-discover', {endpoint: form.model.endpoint, ...(form.model.apiKey === undefined ? {} : {apiKey: form.model.apiKey})});
      setModels(result.models);
      setForm(previous => ({...previous, model: {...previous.model, id: result.models.includes(previous.model.id) ? previous.model.id : result.models[0]}}));
    } catch (error) { setPickerError(error.message || 'Model discovery failed.'); }
    finally { setDiscovering(false); }
  };
  const update = (field, value) => setForm(previous => ({...previous, model: {...previous.model, [field]: value}}));
  const pick = async kind => {
    setPickerError('');
    try {
      const path = await window.blackTeam.pick(kind);
      if (!path) return;
      if (kind === 'workspace') setForm(previous => ({...previous, workspace: path}));
      else setForm(previous => ({...previous, model: {...previous.model, [kind === 'model' ? 'file' : 'runtime']: path, ...(kind === 'model' && !previous.model.name ? {name: basename(path).replace(/\.gguf$/i, '')} : {})}}));
    } catch { setPickerError('The file chooser could not open. Try again from the desktop app.'); }
  };
  const running = ['starting', 'running'].includes(status.runtime?.state) || status.runtime?.ready;
  return <form className="setup-form" onSubmit={event => {event.preventDefault(); onSave(form);}}>
    <div className="panel-heading"><div><span className="eyebrow">{settings ? 'MODEL CONFIGURATION' : 'FIRST RUN / 01'}</span><h2>{settings ? 'Your local model' : 'Make this computer your AI workspace'}</h2></div><Icon name="chip" size={25}/></div>
    <p className="section-intro">Use a model you already have. Load a GGUF file or connect to Ollama, LM Studio, or another compatible server on this computer.</p>
    <fieldset disabled={busy || running || discovering}>
      <label className="form-field full">Model connection<select value={form.model.source} onChange={event => update('source', event.target.value)}><option value="gguf">GGUF file — Black Team starts llama.cpp</option><option value="server">Existing local server — Ollama, LM Studio, compatible API</option></select></label>
      <label className="form-field full">Model display name<input value={form.model.name} maxLength={100} required placeholder="Name your model" onChange={event => update('name', event.target.value)}/></label>
      {server ? <>
        <div className="button-row full"><button type="button" className="secondary" onClick={() => {update('endpoint', 'http://127.0.0.1:11434/v1'); update('apiKey', ''); update('id', ''); setModels([]);}}>Ollama address</button><button type="button" className="secondary" onClick={() => {update('endpoint', 'http://127.0.0.1:1234/v1'); update('apiKey', ''); update('id', ''); setModels([]);}}>LM Studio address</button></div>
        <label className="form-field full">Local server URL<input required value={form.model.endpoint} onChange={event => {update('endpoint', event.target.value); update('apiKey', ''); update('id', ''); setModels([]);}} placeholder="http://127.0.0.1:11434/v1"/><small>Start the server and enable its API first. Use a locally downloaded model; a server configured to forward to the cloud can send your prompts off this computer.</small></label>
        <label className="form-field full">Local server API key (optional)<input type="password" autoComplete="off" value={form.model.apiKey ?? ''} placeholder={status.serverKeyConfigured && form.model.apiKey === undefined ? 'Saved key — leave blank to keep' : 'Only if your local server requires it'} onChange={event => update('apiKey', event.target.value)}/><small>Stored privately on this computer and never shown in status responses.</small></label>
        {status.serverKeyConfigured && <button type="button" className="text-button" onClick={() => update('apiKey', '')}>Clear saved server key on save</button>}
        <div className="button-row full"><button type="button" className="secondary" onClick={discover}>{discovering ? 'Checking…' : 'Test connection & find models'}</button>{models.length > 0 && <span role="status">{models.length} models found</span>}</div>
        <label className="form-field full">Model ID<input list="local-models" required value={form.model.id} maxLength={256} onChange={event => update('id', event.target.value)} placeholder="Choose a discovered model or enter its exact ID"/><datalist id="local-models">{models.map(id => <option key={id} value={id}/>)}</datalist><small>Use a text chat model. The server controls supported model formats and hardware.</small></label>
      </> : <>
        <div className="file-picker full"><div><strong>Model file <span>.gguf</span></strong><span className="file-path" title={form.model.file}>{form.model.file || 'Choose a model already saved on your computer'}</span></div><button type="button" className="secondary" onClick={() => pick('model')}><Icon name="folder" size={16}/>Choose model</button></div>
        <div className="file-picker full"><div><strong>llama.cpp runtime</strong><span className="file-path" title={form.model.runtime}>{form.model.runtime || 'Choose the llama-server executable'}</span></div><button type="button" className="secondary" onClick={() => pick('runtime')}><Icon name="folder" size={16}/>Choose runtime</button></div>
      </>}
      <div className="file-picker full"><div><strong>Workspace folder</strong><span className="file-path" title={form.workspace}>{form.workspace || 'Choose a folder for your workspace'}</span></div><button type="button" className="secondary" onClick={() => pick('workspace')}><Icon name="folder" size={16}/>Choose folder</button></div>
      <details className="full advanced-settings"><summary>Performance settings</summary><div className="form-grid">
        <label className="form-field">Context window<input type="number" min="512" max="131072" step="1" required value={form.model.context} onChange={event => update('context', Number(event.target.value))}/><small>{server ? 'Set this no higher than the context loaded by your server. Black Team estimates input size for compatible APIs.' : 'Tokens available to the conversation. Larger values use more memory.'}</small></label>
        {!server && <><label className="form-field">CPU threads<input type="number" min="1" max="1024" step="1" required value={form.model.threads} onChange={event => update('threads', Number(event.target.value))}/><small>{status.hardware?.cores || 'Your'} logical CPU cores detected.</small></label>
        <label className="form-field">GPU layers<input type="number" min="0" max="999" step="1" required value={form.model.gpuLayers} onChange={event => update('gpuLayers', Number(event.target.value))}/><small>0 uses the CPU. Set a higher value only with a runtime built for your GPU.</small></label></>}
      </div></details>
      <div className="form-actions full"><button className="primary" disabled={(server ? !form.model.id.trim() || !form.model.endpoint : !form.model.file || !form.model.runtime) || !form.workspace || !form.model.name.trim()}><Icon name="check" size={16}/>{busy ? 'Saving…' : settings ? 'Save configuration' : 'Save local setup'}</button><span className="muted">Your configuration stays on this computer.</span></div>
    </fieldset>
    {running && <p className="inline-note">Stop the model before changing its configuration.</p>}
    {pickerError && <p className="inline-note error-text" role="alert">{pickerError}</p>}
  </form>;
}

function Workspace({status, busy, onAction, onChat, onSettings, onSave}) {
  const hardware = status.hardware || {};
  const running = status.runtime?.ready || status.runtime?.state === 'starting';
  return <>
    <section className="telemetry hardware-grid" aria-label="This computer">
      <div><Icon name="chip"/><div><span>CPU UTILIZATION</span><strong>{status.performance?.cpu ?? '—'}% <small>· {hardware.cores || '—'} cores · load {status.performance?.load?.toFixed(1) || '0.0'}</small></strong></div></div>
      <div><Icon name="activity"/><div><span>MEMORY AVAILABLE</span><strong>{byteSize(hardware.memory?.free)} <small>/ {byteSize(hardware.memory?.total)}</small></strong></div></div>
      <div><Icon name="folder"/><div><span>DISK AVAILABLE</span><strong>{byteSize(hardware.disk?.free)}</strong></div></div>
    </section>
    {!status.setupComplete ? <SetupForm status={status} busy={busy} onSave={onSave}/> : <section className="local-model-panel">
      <div className="model-identity"><AgentAvatar large active={status.runtime?.busy}/><div><span className="eyebrow">YOUR LOCAL MODEL</span><h2>{status.config?.model?.name || 'Local model'}</h2><p>{status.runtime?.ready ? 'Ready on this computer. Open a conversation to begin.' : status.runtime?.state === 'starting' ? (status.config?.model?.source === 'server' ? 'Connecting to your local server. The server manages model loading.' : 'Loading the model into memory. This can take a moment.') : 'Start your model when you need it. Your conversations stay here.'}</p></div></div>
      <div className="model-facts"><div><span>Model</span><strong>{status.config?.model?.source === 'server' ? status.config.model.id : basename(status.config?.model?.file)}</strong></div><div><span>Processing</span><strong>{status.config?.model?.source === 'server' ? 'Local server' : status.config?.model?.gpuLayers ? `${status.config.model.gpuLayers} GPU layers` : 'CPU'}</strong></div><div><span>Context window</span><strong>{Number(status.config?.model?.context || 4096).toLocaleString()} tokens</strong></div></div>
      <div className="button-row">{running ? <button className="secondary" disabled={busy || status.runtime?.busy} onClick={() => onAction('runtime-stop', {}, 'Model stopped.')}><Icon name="power" size={16}/>{status.config?.model?.source === 'server' ? 'Disconnect model' : 'Stop model'}</button> : <button className="primary" disabled={busy} onClick={() => onAction('runtime-start', {}, status.config?.model?.source === 'server' ? 'Connecting to your local server.' : 'Starting your local model.')}><Icon name="power" size={16}/>{status.config?.model?.source === 'server' ? 'Connect model' : 'Start model'}</button>}<button className={running ? 'primary' : 'secondary'} disabled={!status.runtime?.ready || busy} onClick={onChat}><Icon name="chat" size={16}/>Open chat</button><button className="text-button" onClick={onSettings}>Model settings <Icon name="arrow" size={15}/></button></div>
      {status.runtime?.busy && <p className="inline-note">A response is running. Open Conversations to stop the response before stopping the model.</p>}
    </section>}
    {hardware.warnings?.length > 0 && <section className="inline-note"><strong>Hardware notes</strong><ul>{hardware.warnings.map((warning, index) => <li key={index}>{warning}</li>)}</ul></section>}
    {status.runtime?.error && <div className="notice error" role="alert"><div><strong>{status.config?.model?.source === 'server' ? 'The local server could not connect.' : 'The model could not start.'}</strong><p>{typeof status.runtime.error === 'string' ? status.runtime.error : 'Check that the model and runtime match this computer, then review your memory and performance settings.'}</p></div></div>}
    <section className="local-model-panel"><span className="eyebrow">HARNESS LAUNCHER</span><h2>Choose how you work</h2><p>Black Team Chat and Agent work are built in. Launch other installed harnesses with your selected local model and workspace.</p><div className="button-row">{(status.integrations?.harnesses||[]).map(h=><button key={h.id} className="secondary" disabled={busy||status.runtime?.busy||!status.setupComplete} onClick={()=>onAction('harness-launch',{id:h.id},`${h.name} launched.`)}>{h.name}</button>)}<button className="text-button" onClick={onSettings}>Configure harnesses</button></div><small>Keep Black Team open while an external harness uses an app-owned GGUF runtime. Stop its tasks before stopping or changing the model.</small></section>
    <div className="principle-grid"><section><span className="step-number">01 / YOUR COMPUTER</span><h3>Local by default</h3><p>Conversation history lives on your machine. No Black Team account needed. Use a local model in your server to keep inference here.</p></section><section><span className="step-number">02 / YOUR CHOICE</span><h3>Bring your model</h3><p>Load a GGUF model or connect your existing local model server.</p></section><section><span className="step-number">03 / OPTIONAL COMPANION</span><h3>Continue from your phone</h3><p>Set up private network access when you need it. Your computer remains the host.</p></section></div>
  </>;
}

function PhoneSettings({status, busy, onAction}) {
  const [phone, setPhone] = useState(() => ({enabled: false, hostname: '', owner: '', ...status.config?.phone}));
  const [detection, setDetection] = useState(null);
  const [command, setCommand] = useState('');
  const [copied, setCopied] = useState(false);
  const [copyError, setCopyError] = useState(false);
  const update = (field, value) => setPhone(previous => ({...previous, [field]: value}));
  const detect = async () => {
    const result = await onAction('phone-detect');
    if (!result) return;
    setDetection(result);
    setPhone(previous => ({...previous, hostname: result.hostname || previous.hostname, owner: result.owner || previous.owner}));
  };
  const commands = command || status.phone?.command || (typeof status.phone?.commands === 'string' ? status.phone.commands : Array.isArray(status.phone?.commands) ? status.phone.commands.join('\n') : Object.values(status.phone?.commands || {}).filter(value => typeof value === 'string').join('\n'));
  const saved = status.config?.phone;
  const dirty = ['enabled', 'hostname', 'owner'].some(key => phone[key] !== (saved?.[key] ?? (key === 'enabled' ? false : '')));
  const copy = async () => {
    try { await navigator.clipboard.writeText(status.phone.url); setCopied(true); setCopyError(false); window.setTimeout(() => setCopied(false), 2500); }
    catch { setCopyError(true); }
  };
  return <section className="setup-form phone-setup">
    <div className="panel-heading"><div><span className="eyebrow">OPTIONAL / PRIVATE ACCESS</span><h2>Your computer. Your Companion.</h2></div><AgentAvatar/></div>
    <p className="section-intro">Use Black Team Companion in Safari on your iPhone or Chrome on your Android phone, then add it to your Home Screen. Models and agent tools run on this computer, which must be awake and connected. A paired phone can use the Agent tools you enable in Settings.</p>
    <ol className="setup-steps"><li>Install Tailscale on this computer and your phone, then sign in to your private network.</li><li>Detect the computer’s private address and save the account allowed to use Companion.</li><li>Enable private access here, open the pairing link on your phone, and add it to your Home Screen using Safari’s Share menu or Chrome’s menu.</li></ol>
    <div className="button-row"><button className="secondary" disabled={busy} onClick={detect}><Icon name="refresh" size={16}/>Detect Tailscale</button>{detection && <p className="detection-state" role="status">{!detection.installed ? 'Tailscale is not installed on this computer.' : !detection.online ? 'Tailscale is installed. Sign in and connect before continuing.' : 'Private network detected. Review the details below.'}</p>}</div>
    <form onSubmit={event => {event.preventDefault(); setCommand(''); onAction('phone-save', phone, 'Companion settings saved. Enable private access to connect your phone.');}}>
      <fieldset disabled={busy}>
        <label className="checkbox-field full"><input type="checkbox" checked={phone.enabled} onChange={event => update('enabled', event.target.checked)}/><span>Allow Companion on my private network<small>Optional. Desktop chat works without this.</small></span></label>
        <label className="form-field full">This computer’s Tailscale hostname<input type="text" required={phone.enabled} placeholder="your-computer.your-network.ts.net" autoCapitalize="none" autoCorrect="off" value={phone.hostname} onChange={event => update('hostname', event.target.value.trim())}/></label>
        <label className="form-field full">Allowed Tailscale account<input type="text" required={phone.enabled} placeholder="Your Tailscale account login" autoCapitalize="none" autoCorrect="off" value={phone.owner} onChange={event => update('owner', event.target.value.trim())}/><small>Use the same account on your phone. Other accounts are not automatically allowed.</small></label>
        <div className="form-actions full"><button className="secondary">Save Companion settings</button></div>
      </fieldset>
    </form>
    {status.phone?.enabled && <div className="phone-connect"><span className={`connection-label${status.phone.connected ? ' ready' : ''}`}><i className={status.phone.connected ? 'live-dot' : 'idle-dot'}/>{status.phone.connected ? 'Private access configured' : 'Private access needs setup'}</span><div className="button-row"><button className="primary" disabled={busy || dirty || status.phone.connected} onClick={() => onAction('phone-connect', {}, 'Private access checked. Open the Companion address on your phone.')}><Icon name="globe" size={16}/>Enable private phone access</button>{status.phone.connected && <button className="secondary" disabled={busy} onClick={() => onAction('phone-disconnect', {}, 'Private phone access stopped. Desktop chat is still available.')}>Disconnect phone access</button>}</div>{dirty && <p className="inline-note">Save your changes before enabling private access.</p>}{status.phone.connected && status.phone.url && <div className="companion-address"><label htmlFor="private-url">Your private Companion pairing link</label><p className="pairing-help">Open this link on your own devices. It grants access to your Companion.</p><div><input id="private-url" readOnly value={status.phone.url} onFocus={event => event.target.select()}/><button className="secondary" onClick={copy}>{copied ? 'Copied' : 'Copy pairing link'}</button></div>{copyError && <small>Select the pairing link above and copy it manually.</small>}</div>}<details><summary>Manual connection command</summary><p className="muted">If your system asks for permission, run this command in your terminal, then enable private access again to verify it.</p>{commands ? <pre>{commands}</pre> : <button className="secondary" disabled={busy || dirty} onClick={async () => {const result = await onAction('phone-command'); if (result?.command) setCommand(result.command);}}>Show command</button>}</details></div>}
    <p className="inline-note">Companion uses your Tailscale network. It does not publish your model or conversations to a public website. Review your network’s device access rules before pairing.</p>
  </section>;
}

function ContextReport({report}) {
  if (!report || !Number.isSafeInteger(report.measuredInputTokens) || !Number.isSafeInteger(report.context) || report.context <= 0) return null;
  const omitted = Number.isSafeInteger(report.omittedMessages) ? report.omittedMessages : 0;
  const used = Math.max(0, Math.min(100, report.measuredInputTokens / report.context * 100));
  const reserve = Number.isSafeInteger(report.maxTokens) ? Math.max(0, Math.min(100-used, report.maxTokens / report.context * 100)) : 0;
  return <details className="context-inspector"><summary><span>Context control</span><span>{Math.round(used)}% used{omitted > 0 ? ' · Adjusted' : ' · Within budget'}</span></summary><div className="context-inspector-body"><div className="context-meter" role="meter" aria-label="Input context used" aria-valuemin={0} aria-valuemax={report.context} aria-valuenow={Math.min(report.context,report.measuredInputTokens)} aria-valuetext={`${report.measuredInputTokens.toLocaleString()} input tokens of ${report.context.toLocaleString()}`}><span style={{width:`${used}%`}}/><i style={{width:`${reserve}%`}}/></div><dl><div><dt>{report.method === 'estimated-bytes' ? 'Estimated conversation input' : 'Conversation input'}</dt><dd>{report.measuredInputTokens.toLocaleString()} tokens</dd></div><div><dt>Reserved for reply</dt><dd>{Number.isSafeInteger(report.maxTokens) ? report.maxTokens.toLocaleString() : '—'} tokens</dd></div><div><dt>Model context</dt><dd>{report.context.toLocaleString()} tokens</dd></div></dl><p>{omitted > 0 ? `${omitted} older ${omitted === 1 ? 'message was' : 'messages were'} left out of this reply’s context. The full conversation stays saved on your computer.` : 'This reply includes all eligible completed turns. Your current message and system instructions are preserved.'}</p><small>{report.method === 'estimated-bytes' ? 'Estimated locally, not a tokenizer measurement. Match context settings to your server; its template and truncation behavior can differ.' : 'Measured locally · No hosted context service'}</small></div></details>;
}

function Chat({status, thread, threadId, connection, onSend, onCancel, onApproval, sending, pendingRequest}) {
  const [message, setMessage] = useState('');
  const [mode, setMode] = useState('balanced');
  const [selectedKind,setKind]=useState('chat');
  const kind=thread?.kind||pendingRequest?.kind||selectedKind;
  const endRef = useRef(null);
  const activity = responseActivity({thread, threadId, job: status.job, connection});
  const activeJob = status.job?.state === 'running';
  const available = connection === 'online' && !sending && (Boolean(pendingRequest) || (status.setupComplete && !activeJob && (kind!=='agent'||status.agentEnabled)));
  const modelName = status.config?.model?.name || status.runtime?.name || 'Black Team';
  useEffect(() => {endRef.current?.scrollIntoView({behavior: 'instant', block: 'nearest'});}, [thread?.messages?.length, thread?.messages?.at(-1)?.content]);
  const submit = async event => {
    event.preventDefault();
    if ((!message.trim() && !pendingRequest) || !available) return;
    const content = pendingRequest?.message || message.trim();
    if (await onSend(content, mode, kind)) setMessage('');
  };
  return <div className="chat-layout">
    <div className="chat-controls"><label htmlFor="work-kind" className="eyebrow">HARNESS</label><select id="work-kind" value={kind} disabled={Boolean(threadId)||sending||activeJob||Boolean(pendingRequest)} onChange={event=>setKind(event.target.value)}><option value="chat">Black Team Chat</option><option value="agent" disabled={!status.agentEnabled}>Black Team Agent · Hermes tools</option></select><label htmlFor="response-mode" className="eyebrow">RESPONSE LENGTH</label><select id="response-mode" value={mode} onChange={event => setMode(event.target.value)} disabled={kind==='agent' || sending || activeJob || Boolean(pendingRequest)}><option value="fast">Short</option><option value="balanced">Standard</option><option value="deep">Long</option><option value="extended">Extended</option></select><small>{modelName} · Runs on {desktop ? 'this' : 'your'} computer</small><p className="mode-help">{kind==='agent'?'Agent work uses Hermes tools, a 48-step budget and local context compaction.':'Sets the reply length limit. Speed and reasoning depend on your model.'}</p></div>
    {!status.setupComplete ? <div className="notice"><p>Complete model setup in the Black Team desktop app to begin.</p></div> : !status.runtime?.ready && <div className="notice"><p>{status.runtime?.state === 'starting' ? (status.config?.model?.source === 'server' ? 'Connecting to your local server. Chat will be ready when the connection finishes.' : 'Your model is starting. The chat will be ready when it finishes loading.') : 'Send a message to start or connect your configured local model.'}</p></div>}
    <div className="conversation" role="log" aria-label="Conversation" aria-live="off">
      {!thread?.messages?.length ? <div className="chat-empty"><AgentAvatar large active={Boolean(activity?.glowing)}/><span className="eyebrow">BLACK TEAM {desktop ? 'LOCAL' : 'COMPANION'}</span><h2>A space to think freely.</h2><p>Start a conversation with your local model.<br/>History is saved on your computer.</p></div> : thread.messages.map((item, index) => <article className={`message ${item.role === 'user' ? 'user' : 'assistant'}`} key={item.id || index}><div className="message-heading">{item.role !== 'user' && <AgentAvatar active={Boolean(activity?.glowing && (!activity.messageId ? index === thread.messages.length - 1 : activity.messageId === item.id))}/>}<span>{item.role === 'user' ? 'YOU' : modelName}</span>{activity?.messageId === item.id && <small className="response-label">{activity.label}</small>}</div>{item.thinking && <details className="thinking-content"><summary>Reasoning</summary><div>{item.thinking}</div></details>}<div className="message-body">{item.content || (item.state === 'writing' ? '…' : '')}</div>{item.role === 'assistant' && <ContextReport report={item.context}/>} {item.events?.length>0&&<details className="context-inspector"><summary>Agent tool activity ({item.events.length})</summary>{item.events.map((e,i)=><div key={i}><strong>{e.name}</strong><pre>{e.output}</pre></div>)}</details>}{item.artifacts?.map(a=><p key={a.id}><a href={`/api/file/${a.id}`} download={a.name}>{a.name} · Download</a></p>)} {item.state === 'interrupted' && <p className="message-note">Response stopped. Any text already received is saved here.</p>}{item.role === 'assistant' && item.finishReason === 'length' && <p className="message-note">This reply reached its length limit. Ask the model to continue, or choose a longer reply length for your next message.</p>}{item.state === 'error' && <p className="message-note">{typeof item.error === 'string' ? item.error : 'The response was interrupted. Try again when your model is ready.'}</p>}</article>)}
      {activity && !activity.messageId && <div className="response-status" role="status"><AgentAvatar active={activity.glowing}/><span>{activity.label}…</span></div>}
      <div ref={endRef}/>
    </div>
    {activity && !thread?.messages?.at(-1)?.context && <ContextReport report={status.job?.context}/>}
    {status.job?.approval&&<section className="notice approval-card" role="status"><div><strong>Agent approval required</strong><p>{status.job.approval.description}</p><pre>{status.job.approval.command}</pre><div className="button-row"><button className="primary" disabled={sending} onClick={()=>onApproval('once')}>Approve once</button><button className="secondary" disabled={sending} onClick={()=>onApproval('deny')}>Deny</button></div></div></section>}
    {!desktop&&<small className="composer-note">Computer CPU {status.performance?.cpu ?? '—'}% · RAM available {byteSize(status.performance?.memory?.free)}</small>}
    {pendingRequest && !sending && <p className="inline-note retry-note" role="status">Your last message may already be saved. Retry to reconnect to that same response without sending it twice.</p>}
    <form className="composer" onSubmit={submit}><textarea aria-label="Message your local model" rows={3} value={pendingRequest?.message || message} onChange={event => setMessage(event.target.value)} placeholder={connection !== 'online' ? 'Reconnecting to your computer…' : 'Message your local model…'} disabled={connection !== 'online' || !status.setupComplete || Boolean(pendingRequest)} onKeyDown={event => {if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing && window.innerWidth > 760) {event.preventDefault(); if (available && message.trim()) submit(event);}}}/>{activeJob && !pendingRequest ? <button type="button" className="secondary" onClick={onCancel} disabled={sending || connection !== 'online'}>Stop response</button> : <button className="primary" aria-label={pendingRequest ? 'Retry last message' : 'Send message'} disabled={!available || (!message.trim() && !pendingRequest)}><Icon name="send" size={17}/><span>{sending ? 'Sending…' : pendingRequest ? 'Retry message' : 'Send'}</span></button>}</form>
    <small className="composer-note">{activeJob && status.job?.threadId !== threadId ? 'A response is running in another conversation.' : 'LOCAL INFERENCE · HISTORY SAVED ON YOUR COMPUTER'}</small>
  </div>;
}

export default function App() {
  const [status, setStatus] = useState(null);
  const [connection, setConnection] = useState('connecting');
  const [pairingRequired, setPairingRequired] = useState(false);
  const [page, setPage] = useState(desktop ? 'workspace' : 'conversations');
  const [threadId, setThreadId] = useState(null);
  const [thread, setThread] = useState(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [busy, setBusy] = useState(false);
  const [sending, setSending] = useState(false);
  const [pendingRequest, setPendingRequest] = useState(null);
  const [mobileNav, setMobileNav] = useState(false);
  const selectedThread = useRef(null);
  const pollInFlight = useRef(false);
  const mounted = useRef(true);
  const networkUnavailable = useRef(!desktop && navigator.onLine === false);
  const refresh = useCallback(async () => {
    if (networkUnavailable.current) {setConnection('offline'); return;}
    if (pollInFlight.current) return;
    pollInFlight.current = true;
    try {
      await initializeCompanion();
      const next = desktop ? await native('status') : await api('/api/status');
      if (!mounted.current || networkUnavailable.current) return;
      setStatus(next); setConnection('online'); setPairingRequired(false);
      if (selectedThread.current) {
        const id = selectedThread.current;
        const nextThread = await api(`/api/thread/${encodeURIComponent(id)}`);
        if (mounted.current && !networkUnavailable.current && selectedThread.current === id) setThread(nextThread);
      }
    } catch (cause) {
      if (mounted.current) {setConnection('offline'); setPairingRequired(!desktop && [401, 403].includes(cause.status)); if (cause.status === 403 || cause.status === 401) setError(cause.message);}
    } finally {pollInFlight.current = false;}
  }, []);
  useEffect(() => {
    mounted.current = true;
    const onOffline = () => {
      // Desktop inference remains available without an Internet connection.
      if (desktop) {refresh(); return;}
      networkUnavailable.current = true;
      setConnection('offline');
    };
    const onOnline = () => {
      networkUnavailable.current = false;
      if (!desktop) setConnection('connecting');
      refresh();
    };
    window.addEventListener('offline', onOffline);
    window.addEventListener('online', onOnline);
    refresh();
    const timer = window.setInterval(refresh, 1500);
    return () => {
      mounted.current = false;
      window.clearInterval(timer);
      window.removeEventListener('offline', onOffline);
      window.removeEventListener('online', onOnline);
    };
  }, [refresh]);
  const action = async (name, data, success) => {
    if (!desktop || busy) return null;
    setBusy(true); setError(''); setNotice('');
    try {const result = await native(name, data); if (success) setNotice(success); await refresh(); return result;}
    catch (cause) {setError(cause.message || (name.startsWith('phone-') ? 'Companion setup could not finish. Check that Tailscale is installed and connected. The manual connection command is available below.' : name === 'setup-save' ? 'Setup could not be saved. Choose a valid local model connection and a writable workspace. Check the performance values and try again.' : 'The action could not finish. Check your model settings and available memory, then try again.')); return null;}
    finally {setBusy(false);}
  };
  const openThread = async id => {
    selectedThread.current = id; setThreadId(id); setThread(null); setPage('conversations'); setMobileNav(false); setError('');
    if (id) try {const result = await api(`/api/thread/${encodeURIComponent(id)}`); if (selectedThread.current === id) setThread(result);} catch {setError('This conversation could not be loaded. Check the connection and try again.');}
  };
  const send = async (message, mode, kind) => {
    if (sending) return false;
    setSending(true); setError('');
    try {
      const payload = pendingRequest || {threadId: selectedThread.current, message, mode, kind, requestId: crypto.randomUUID()};
      setPendingRequest(payload);
      const result = await post('/api/chat', payload);
      setPendingRequest(null);
      const id = result.threadId || result.thread?.id;
      if (id) {selectedThread.current = id; setThreadId(id);}
      await refresh(); return true;
    } catch (cause) {if (cause.status && cause.status < 500) setPendingRequest(null); setError(cause.status ? cause.message : 'The connection dropped while sending. Retry your message to recover the same response.'); return false;}
    finally {setSending(false);}
  };
  const cancel = async () => {setSending(true); setError(''); try {await post('/api/cancel', {}); await refresh();} catch (cause) {setError(cause.message);} finally {setSending(false);}};
  const approval=async choice=>{setSending(true);setError('');try{await post('/api/approval',{id:status.job.approval.id,digest:status.job.approval.digest,choice});await refresh();}catch(cause){setError(cause.message);}finally{setSending(false);}};
  const navigate = next => {setPage(next); setMobileNav(false); setError(''); setNotice('');};
  if (!status) return <div className="cabinet boot setup-boot"><div className="boot-brand"><Brand caption={desktop ? 'PRIVATE AI. TOTAL CONTROL.' : 'PRIVATE COMPANION'}/></div>{connection === 'connecting' ? <><span className="spinner"/><h1>Opening your workspace</h1><p>Connecting to Black Team on your computer.</p></> : <><h1>{pairingRequired ? 'Pair this phone with Black Team.' : 'Your computer is out of reach.'}</h1><p>{error || (desktop ? 'Black Team could not connect to its local service. Reopen the app or try again.' : 'Keep your computer awake, connect your phone to Tailscale, and open the private Companion address from the desktop app.')}</p><button className="primary" onClick={() => {setConnection('connecting'); refresh();}}>Try again</button></>}</div>;
  const titles = {workspace: ['YOUR LOCAL AI', 'Your local AI command center.', 'Models, harnesses, tools and performance. On your computer.'], conversations: [desktop ? 'LOCAL CONVERSATIONS' : 'BLACK TEAM COMPANION', thread?.title || 'Your private conversation.', 'A direct connection to the model on your computer.'], phone: ['BLACK TEAM COMPANION', 'Take the conversation with you.', 'Private access to your local models and agent work.'], settings: ['LOCAL CONFIGURATION', 'Built around your machine.', 'You choose the model, workspace, and processing settings.']};
  const [eyebrow, title, description] = titles[page] || titles.conversations;
  return <div className={`cabinet cabinet-companion black-team-app${desktop ? ' desktop-app' : ' phone-app'}`}>
    <div className="mobile-topbar"><span className="mobile-wordmark"><AgentAvatar/>BLACK TEAM{!desktop && <small>COMPANION</small>}</span><button className="secondary" aria-expanded={mobileNav} aria-controls="app-navigation" onClick={() => setMobileNav(previous => !previous)}>{mobileNav ? 'Close' : 'Menu'}</button></div>
    <aside className={`sidebar companion-nav app-sidebar${mobileNav ? ' mobile-open' : ''}`} id="app-navigation"><Brand caption={desktop ? 'PRIVATE AI. TOTAL CONTROL.' : 'PRIVATE COMPANION'}/><div className="nav-label">{desktop ? 'CONTROL ROOM' : 'YOUR COMPANION'}</div><nav aria-label="Main navigation">{(desktop ? [['workspace', 'grid', 'Workspace'], ['conversations', 'chat', 'Conversations'], ['phone', 'globe', 'Phone Companion'], ['settings', 'chip', 'Settings']] : [['conversations', 'chat', 'Conversations']]).map(([id, icon, label]) => <button key={id} className={`nav${page === id ? ' selected' : ''}`} onClick={() => navigate(id)} aria-current={page === id ? 'page' : undefined}><Icon name={icon} size={17}/>{label}</button>)}</nav><div className="thread-heading"><span className="nav-label">SAVED CONVERSATIONS</span><button className="text-button" onClick={() => openThread(null)} aria-label="New conversation">+</button></div><div className="thread-list">{(status.threads || []).length ? status.threads.map(item => <button key={item.id} className={threadId === item.id && page === 'conversations' ? 'selected' : ''} onClick={() => openThread(item.id)}>{item.title || 'Untitled conversation'}<small>{date(item.updated)}</small></button>) : <p className="empty-history">Your conversations will appear here.</p>}</div><div className="sidebar-bottom"><span><i className={connection === 'online' ? 'live-dot' : 'idle-dot'}/>{desktop ? 'ON THIS COMPUTER' : 'PRIVATE CONNECTION'}</span><p>{desktop ? 'Your model. Your conversations.' : 'Powered by your computer.'}</p><small>BLACK TEAM {status.version || ''}</small></div></aside>
    <main className={`companion-main app-main${page === 'conversations' ? ' chat-page' : ''}`}><header><div><span className="eyebrow">{eyebrow}</span><h1>{title}</h1><p className="muted">{description}</p></div><StatusPill status={status} connection={connection}/></header>
      {connection === 'offline' && <div className="notice error" role="status"><p>{desktop ? 'The local service is unavailable. Reconnecting automatically…' : 'Connection lost. Keep your computer awake and check that both devices are connected to Tailscale. Reconnecting…'}</p></div>}
      {error && <div className="notice error" role="alert"><p>{error}</p><button aria-label="Dismiss error" onClick={() => setError('')}>×</button></div>}
      {notice && <div className="notice" role="status"><p>{notice}</p><button aria-label="Dismiss message" onClick={() => setNotice('')}>×</button></div>}
      {desktop && page === 'workspace' && <Workspace status={status} busy={busy} onAction={action} onChat={() => navigate('conversations')} onSettings={() => navigate('settings')} onSave={value => action('setup-save', value, 'Local setup saved. Start your model to begin.')}/>}
      {page === 'conversations' && <Chat status={status} thread={thread} threadId={threadId} connection={connection} onSend={send} onCancel={cancel} onApproval={approval} sending={sending} pendingRequest={pendingRequest}/>}
      {desktop && page === 'phone' && <PhoneSettings status={status} busy={busy} onAction={action}/>}
      {desktop && page === 'settings' && <><SetupForm status={status} settings busy={busy} onSave={value => action('setup-save', value, 'Configuration saved.')}/><Integrations status={status} busy={busy} onAction={action}/><section className="inline-note"><strong>JEV context helper: not enabled</strong><p>Chat uses local context management and needs no JEV key. Optional synthetic research can use your own key; see docs/JEV.md. Saving a key for research does not enable hosted chat.</p></section><section className="settings-data"><div><h2>Local application data</h2><p>Configuration and conversation history are stored on this computer.</p></div><button className="secondary" onClick={() => action('open-data')} disabled={busy}><Icon name="folder" size={16}/>Open data folder</button></section><section className="inline-note"><strong>Updates are your choice.</strong><p>This edition does not automatically download models or application updates. Install a newer Black Team package when you choose.</p></section></>}
      {page !== 'conversations' && <footer>PRIVATE AI. TOTAL CONTROL.<span>{status.hardware?.platform === 'linux' ? 'Linux' : status.hardware?.platform} · {status.hardware?.arch}</span></footer>}
    </main>
  </div>;
}
