import React, {useCallback, useEffect, useRef, useState} from 'react';
import Integrations from './Integrations.jsx';
import SetupForm from './ModelSetup.jsx';
import PhoneSettings from './PhoneSettings.jsx';
import {native} from './desktop.mjs';
import {createCompanionInitializer} from './companionConnection.mjs';
import Brand from './Brand.jsx';
import AgentAvatar from './AgentAvatar.jsx';
import Icon from './Icons.jsx';
import ThemePicker from './Theme.jsx';
import {responseActivity} from './responseActivity.mjs';

const desktop = Boolean(window.blackTeam?.request);
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
const initializeCompanion=createCompanionInitializer({desktop,location:window.location,replaceURL:url=>window.history.replaceState(null,'',url),post});

function StatusPill({status, connection}) {
  const ready = connection === 'online' && status?.runtime?.ready;
  const label = connection !== 'online' ? (connection === 'connecting' ? 'Connecting' : 'Connection lost') : status?.runtime?.state === 'starting' ? (status?.config?.model?.source === 'server' ? 'Connecting model' : 'Starting model') : status?.runtime?.busy ? 'Model responding' : ready ? 'Model ready' : 'Model stopped';
  return <span className={`online status-pill${ready ? ' is-ready' : ''}`} role="status"><i className={ready ? 'live-dot' : 'idle-dot'}/>{label}</span>;
}

function Workspace({status, busy, onAction, onChat, onSettings, onPhone, onSave}) {
  const hardware = status.hardware || {};
  const running = status.runtime?.ready || status.runtime?.state === 'starting';
  return <>
    <section className="telemetry hardware-grid" aria-label="This computer">
      <div><Icon name="chip"/><div><span>CPU UTILIZATION</span><strong>{status.performance?.cpu ?? '—'}% <small>· {hardware.cores || '—'} cores · load {status.performance?.load?.toFixed(1) || '0.0'}</small></strong></div></div>
      <div><Icon name="activity"/><div><span>MEMORY AVAILABLE</span><strong>{byteSize(hardware.memory?.free)} <small>/ {byteSize(hardware.memory?.total)}</small></strong></div></div>
      <div><Icon name="folder"/><div><span>DISK AVAILABLE</span><strong>{byteSize(hardware.disk?.free)}</strong></div></div>
    </section>
    {!status.setupComplete ? <SetupForm status={status} busy={busy} onSave={onSave} onAction={onAction}/> : <section className="local-model-panel">
      <div className="model-identity"><AgentAvatar large active={status.runtime?.busy}/><div><span className="eyebrow">YOUR LOCAL MODEL</span><h2>{status.config?.model?.name || 'Local model'}</h2><p>{status.runtime?.ready ? 'Ready on this computer. Open a conversation to begin.' : status.runtime?.state === 'starting' ? (status.config?.model?.source === 'server' ? 'Connecting to your local server. The server manages model loading.' : 'Loading the model into memory. This can take a moment.') : 'Start your model when you need it. Your conversations stay here.'}</p></div></div>
      <div className="model-facts"><div><span>Model</span><strong>{status.config?.model?.source === 'server' ? status.config.model.id : basename(status.config?.model?.file)}</strong></div><div><span>Processing</span><strong>{status.config?.model?.source === 'server' ? 'Local server' : status.config?.model?.gpuLayers ? `${status.config.model.gpuLayers} GPU layers` : 'CPU'}</strong></div><div><span>Context window</span><strong>{Number(status.config?.model?.context || 4096).toLocaleString()} tokens</strong></div></div>
      <div className="button-row">{running ? <button className="secondary" disabled={busy || status.runtime?.busy} onClick={() => onAction('runtime-stop', {}, 'Model stopped.')}><Icon name="power" size={16}/>{status.config?.model?.source === 'server' ? 'Disconnect model' : 'Stop model'}</button> : <button className="primary" disabled={busy} onClick={() => onAction('runtime-start', {}, status.config?.model?.source === 'server' ? 'Connecting to your local server.' : 'Starting your local model.')}><Icon name="power" size={16}/>{status.config?.model?.source === 'server' ? 'Connect model' : 'Start model'}</button>}<button className={running ? 'primary' : 'secondary'} disabled={busy} onClick={()=>onChat("chat")}><Icon name="chat" size={16}/>Open chat</button><button className="text-button" onClick={()=>onSettings("model")}>Change model <Icon name="arrow" size={15}/></button></div>
      {status.runtime?.busy && <p className="inline-note">A response is running. Open Conversations to stop the response before stopping the model.</p>}
    </section>}
    {hardware.warnings?.length > 0 && <section className="inline-note"><strong>Hardware notes</strong><ul>{hardware.warnings.map((warning, index) => <li key={index}>{warning}</li>)}</ul></section>}
    {status.runtime?.error && <div className="notice error" role="alert"><div><strong>{status.config?.model?.source === 'server' ? 'The local server could not connect.' : 'The model could not start.'}</strong><p>{typeof status.runtime.error === 'string' ? status.runtime.error : 'Check that the model and runtime match this computer, then review your memory and performance settings.'}</p></div></div>}
    <section className="local-model-panel"><span className="eyebrow">AGENTS & APPS</span><h2>Choose how you work</h2><p>Black Team Chat and Agent work are built in. Launch other installed harnesses with your selected local model and workspace.</p><div className="button-row">{status.agentEnabled&&<button className="primary" disabled={busy||!status.setupComplete} onClick={()=>onChat("agent")}>Start agent work</button>}{(status.integrations?.harnesses||[]).map(h=><button key={h.id} className="secondary" disabled={busy||status.runtime?.busy||!status.setupComplete} onClick={()=>onAction('harness-launch',{id:h.id},`${h.name} launched.`)}>{h.name}</button>)}<button className="text-button" onClick={()=>onSettings("agents")}>Connect an agent or app</button></div><small>Keep Black Team open while an external harness uses an app-owned GGUF runtime. Stop its tasks before stopping or changing the model.</small></section>
    <div className="principle-grid"><section><span className="step-number">01 / YOUR COMPUTER</span><h3>Local by default</h3><p>Conversation history lives on your machine. No Black Team account needed. Use a local model in your server to keep inference here.</p></section><section><span className="step-number">02 / YOUR CHOICE</span><h3>Bring your model</h3><p>Load a GGUF model or connect your existing local model server.</p></section><section><span className="step-number">03 / OPTIONAL COMPANION</span><h3>Continue from your phone</h3><p>Connect privately and keep working with the same model.</p><button className="text-button" onClick={onPhone}>Connect your phone →</button></section></div>
  </>;
}

function ContextReport({report}) {
  if (!report || !Number.isSafeInteger(report.measuredInputTokens) || !Number.isSafeInteger(report.context) || report.context <= 0) return null;
  const omitted = Number.isSafeInteger(report.omittedMessages) ? report.omittedMessages : 0;
  const used = Math.max(0, Math.min(100, report.measuredInputTokens / report.context * 100));
  const reserve = Number.isSafeInteger(report.maxTokens) ? Math.max(0, Math.min(100-used, report.maxTokens / report.context * 100)) : 0;
  return <details className="context-inspector"><summary><span>Context control</span><span>{Math.round(used)}% used{omitted > 0 ? ' · Adjusted' : ' · Within budget'}</span></summary><div className="context-inspector-body"><div className="context-meter" role="meter" aria-label="Input context used" aria-valuemin={0} aria-valuemax={report.context} aria-valuenow={Math.min(report.context,report.measuredInputTokens)} aria-valuetext={`${report.measuredInputTokens.toLocaleString()} input tokens of ${report.context.toLocaleString()}`}><span style={{width:`${used}%`}}/><i style={{width:`${reserve}%`}}/></div><dl><div><dt>{report.method === 'estimated-bytes' ? 'Estimated conversation input' : 'Conversation input'}</dt><dd>{report.measuredInputTokens.toLocaleString()} tokens</dd></div><div><dt>Reserved for reply</dt><dd>{Number.isSafeInteger(report.maxTokens) ? report.maxTokens.toLocaleString() : '—'} tokens</dd></div><div><dt>Model context</dt><dd>{report.context.toLocaleString()} tokens</dd></div></dl><p>{omitted > 0 ? `${omitted} older ${omitted === 1 ? 'message was' : 'messages were'} left out of this reply’s context. The full conversation stays saved on your computer.` : 'This reply includes all eligible completed turns. Your current message and system instructions are preserved.'}</p><small>{report.method === 'estimated-bytes' ? 'Estimated locally, not a tokenizer measurement. Match context settings to your server; its template and truncation behavior can differ.' : 'Measured locally · No hosted context service'}</small></div></details>;
}

function Chat({status, thread, threadId, connection, onSend, onCancel, onApproval, sending, pendingRequest, initialKind, onSetup, onOpenThread, drafts}) {
  const draftKey=threadId||'new';
  const [message, setMessage] = useState(()=>drafts.current[draftKey]?.message||'');
  const saveDraft=patch=>{drafts.current[draftKey]={...drafts.current[draftKey],...patch};};
  const editMessage=value=>{saveDraft({message:value});setMessage(value);};
  const [mode, setMode] = useState(()=>drafts.current[draftKey]?.mode||'balanced');
  const [selectedKind,setKind]=useState(()=>drafts.current[draftKey]?.kind||initialKind||'chat');
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
    if (await onSend(content, mode, kind)) editMessage('');
  };
  return <div className="chat-layout">
    <div className="chat-controls"><label htmlFor="work-kind" className="eyebrow">WORK MODE</label><select id="work-kind" value={kind} disabled={Boolean(threadId)||sending||activeJob||Boolean(pendingRequest)} onChange={event=>{saveDraft({kind:event.target.value});setKind(event.target.value);}}><option value="chat">Chat · ask and think</option><option value="agent" disabled={!status.agentEnabled}>Agent · work with tools</option></select><label htmlFor="response-mode" className="eyebrow">RESPONSE LENGTH</label><select id="response-mode" value={mode} onChange={event => {saveDraft({mode:event.target.value});setMode(event.target.value);}} disabled={kind==='agent' || sending || activeJob || Boolean(pendingRequest)}><option value="fast">Short</option><option value="balanced">Standard</option><option value="deep">Long</option><option value="extended">Extended</option></select><small>{modelName} · Runs on {desktop ? 'this' : 'your'} computer</small><p className="mode-help">{kind==='agent'?'Your local model can use Hermes tools. Activity and approvals appear here.':'Ask a question or talk through an idea with your local model.'}</p></div>
    {desktop&&!status.agentEnabled&&<p className="inline-note">Want your model to work with files and tools? <button className="text-button" onClick={()=>onSetup('agents')}>Connect an agent</button></p>}
    {!status.setupComplete ? <div className="notice"><p>{desktop?'Connect a model to start chatting.':'Connect a model in Black Team on your computer first.'}</p>{desktop&&<button className="secondary" onClick={()=>onSetup('model')}>Connect a model</button>}</div> : !status.runtime?.ready && <div className="notice"><p>{status.runtime?.state === 'starting' ? (status.config?.model?.source === 'server' ? 'Connecting to your local server. Chat will be ready when the connection finishes.' : 'Your model is starting. The chat will be ready when it finishes loading.') : 'Send a message to start or connect your configured local model.'}</p></div>}
    <div className="conversation" role="log" aria-label="Conversation" aria-live="off">
      {!thread?.messages?.length ? <div className="chat-empty"><AgentAvatar large active={Boolean(activity?.glowing)}/><span className="eyebrow">BLACK TEAM {desktop ? 'LOCAL' : 'COMPANION'}</span><h2>A space to think freely.</h2><p>Start a conversation with your local model.<br/>History is saved on your computer.</p></div> : thread.messages.map((item, index) => <article className={`message ${item.role === 'user' ? 'user' : 'assistant'}`} key={item.id || index}><div className="message-heading">{item.role !== 'user' && <AgentAvatar active={Boolean(activity?.glowing && (!activity.messageId ? index === thread.messages.length - 1 : activity.messageId === item.id))}/>}<span>{item.role === 'user' ? 'YOU' : modelName}</span>{activity?.messageId === item.id && <small className="response-label">{activity.label}</small>}</div>{item.thinking && <details className="thinking-content"><summary>Reasoning</summary><div>{item.thinking}</div></details>}<div className="message-body">{item.content || (item.state === 'writing' ? '…' : '')}</div>{item.role === 'assistant' && <ContextReport report={item.context}/>} {item.events?.length>0&&<details className="context-inspector"><summary>Agent tool activity ({item.events.length})</summary>{item.events.map((e,i)=><div key={i}><strong>{e.name}</strong><pre>{e.output}</pre></div>)}</details>}{item.artifacts?.map(a=><p key={a.id}><a href={`/api/file/${a.id}`} download={a.name}>{a.name} · Download</a></p>)} {item.state === 'interrupted' && <p className="message-note">Response stopped. Any text already received is saved here.</p>}{item.role === 'assistant' && item.finishReason === 'length' && <p className="message-note">This reply reached its length limit. Ask the model to continue, or choose a longer reply length for your next message.</p>}{item.state === 'error' && <p className="message-note">{typeof item.error === 'string' ? item.error : 'The response was interrupted. Try again when your model is ready.'}</p>}</article>)}
      {activity && !activity.messageId && <div className="response-status" role="status"><AgentAvatar active={activity.glowing}/><span>{activity.label}…</span></div>}
      <div ref={endRef}/>
    </div>
    {activity && !thread?.messages?.at(-1)?.context && <ContextReport report={status.job?.context}/>}
    {status.job?.approval&&status.job.threadId===threadId&&<section className="notice approval-card" role="status"><div><strong>Agent approval required</strong><p>{status.job.approval.description}</p><pre>{status.job.approval.command}</pre><div className="button-row"><button className="primary" disabled={sending} onClick={()=>onApproval('once')}>Approve once</button><button className="secondary" disabled={sending} onClick={()=>onApproval('deny')}>Deny</button></div></div></section>}
    {status.job?.approval&&status.job.threadId!==threadId&&<div className="notice"><p>An agent is waiting for approval in another conversation.</p><button className="secondary" disabled={sending||Boolean(pendingRequest)} onClick={()=>onOpenThread(status.job.threadId)}>Open agent task</button></div>}
    {!desktop&&<small className="composer-note">Computer CPU {status.performance?.cpu ?? '—'}% · RAM available {byteSize(status.performance?.memory?.free)}</small>}
    {pendingRequest && !sending && <p className="inline-note retry-note" role="status">Your last message may already be saved. Retry to reconnect to that same response without sending it twice.</p>}
    <form className="composer" onSubmit={submit}><textarea aria-label="Message your local model" rows={3} value={pendingRequest?.message || message} onChange={event => editMessage(event.target.value)} placeholder={connection !== 'online' ? 'Reconnecting to your computer…' : 'Message your local model…'} disabled={sending || connection !== 'online' || !status.setupComplete || Boolean(pendingRequest)} onKeyDown={event => {if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing && window.innerWidth > 760) {event.preventDefault(); if (available && message.trim()) submit(event);}}}/>{activeJob && !pendingRequest ? <button type="button" className="secondary" onClick={onCancel} disabled={sending || connection !== 'online'}>Stop response</button> : <button className="primary" aria-label={pendingRequest ? 'Retry last message' : 'Send message'} disabled={!available || (!message.trim() && !pendingRequest)}><Icon name="send" size={17}/><span>{sending ? 'Sending…' : pendingRequest ? 'Retry message' : 'Send'}</span></button>}</form>
    <small className="composer-note">{activeJob && status.job?.threadId !== threadId ? 'A response is running in another conversation.' : 'LOCAL INFERENCE · HISTORY SAVED ON YOUR COMPUTER'}</small>
  </div>;
}

export default function App() {
  const [status, setStatus] = useState(null);
  const drafts=useRef({});
  const [settingsSection,setSettingsSection]=useState('model');
  const [newChatKind,setNewChatKind]=useState('chat');
  const [chatKey,setChatKey]=useState(0);
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
    try {const result = await native(name, data); if (result?.warning || success) setNotice(result?.warning || success); await refresh(); return result;}
    catch (cause) {setError(cause.message || (name.startsWith('phone-') ? 'Companion setup could not finish. Check that Tailscale is installed and connected. The manual connection command is available below.' : name === 'setup-save' ? 'Setup could not be saved. Choose a valid local model connection and a writable workspace. Check the performance values and try again.' : 'The action could not finish. Check your model settings and available memory, then try again.')); return null;}
    finally {setBusy(false);}
  };
  const openThread = async id => {
    if(sending||pendingRequest){setPage('conversations');setMobileNav(false);return;}
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
  const startChat = kind => {if(sending||pendingRequest){setPage('conversations');setMobileNav(false);return;}drafts.current.new={...drafts.current.new,kind:kind||'chat'};setNewChatKind(kind || 'chat');setChatKey(previous=>previous+1);openThread(null);};
  const showSettings = section => {setSettingsSection(section||'model');navigate('settings');};
  const saveModel = async value => {if(await action('setup-save',value,'Model saved. Send a message to begin.'))startChat('chat');};
  const navigate = next => {setPage(next); setMobileNav(false); setError(''); setNotice('');};
  if (!status) return <div className="cabinet boot setup-boot"><div className="boot-brand"><Brand caption={desktop ? 'PRIVATE AI. TOTAL CONTROL.' : 'PRIVATE COMPANION'}/></div>{connection === 'connecting' ? <><span className="spinner"/><h1>Opening your workspace</h1><p>Connecting to Black Team on your computer.</p></> : <><h1>{pairingRequired ? 'Pair this phone with Black Team.' : 'Your computer is out of reach.'}</h1><p>{error || (desktop ? 'Black Team could not connect to its local service. Reopen the app or try again.' : 'Keep your computer awake, connect your phone to Tailscale, and open the private Companion address from the desktop app.')}</p><button className="primary" onClick={() => {setConnection('connecting'); refresh();}}>Try again</button></>}</div>;
  const titles = {workspace: ['YOUR LOCAL AI', 'Your local AI command center.', 'Models, harnesses, tools and performance. On your computer.'], conversations: [desktop ? 'LOCAL CONVERSATIONS' : 'BLACK TEAM COMPANION', thread?.title || 'Your private conversation.', 'A direct connection to the model on your computer.'], phone: ['BLACK TEAM COMPANION', 'Take the conversation with you.', 'Private access to your local models and agent work.'], settings: ['CONNECTIONS', 'Make yourself at home.', 'Connect your models and agents. Keep the details out of your way.']};
  const [eyebrow, title, description] = titles[page] || titles.conversations;
  return <div className={`cabinet cabinet-companion black-team-app${desktop ? ' desktop-app' : ' phone-app'}`}>
    <div className="mobile-topbar"><span className="mobile-wordmark"><AgentAvatar/>BLACK TEAM{!desktop && <small>COMPANION</small>}</span><button className="secondary" aria-expanded={mobileNav} aria-controls="app-navigation" onClick={() => setMobileNav(previous => !previous)}>{mobileNav ? 'Close' : 'Menu'}</button></div>
    <aside className={`sidebar companion-nav app-sidebar${mobileNav ? ' mobile-open' : ''}`} id="app-navigation"><Brand caption={desktop ? 'PRIVATE AI. TOTAL CONTROL.' : 'PRIVATE COMPANION'}/><div className="nav-label">{desktop ? 'CONTROL ROOM' : 'YOUR COMPANION'}</div><nav aria-label="Main navigation">{(desktop ? [['workspace', 'grid', 'Workspace'], ['conversations', 'chat', 'Conversations'], ['phone', 'globe', 'Phone Companion'], ['settings', 'chip', 'Settings']] : [['conversations', 'chat', 'Conversations']]).map(([id, icon, label]) => <button key={id} className={`nav${page === id ? ' selected' : ''}`} onClick={() => navigate(id)} aria-current={page === id ? 'page' : undefined}><Icon name={icon} size={17}/>{label}</button>)}</nav><div className="thread-heading"><span className="nav-label">SAVED CONVERSATIONS</span><button className="text-button" disabled={sending||Boolean(pendingRequest)} onClick={() => startChat("chat")} aria-label="New conversation">+</button></div><div className="thread-list">{(status.threads || []).length ? status.threads.map(item => <button key={item.id} disabled={sending||Boolean(pendingRequest)} className={threadId === item.id && page === 'conversations' ? 'selected' : ''} onClick={() => openThread(item.id)}>{item.title || 'Untitled conversation'}<small>{date(item.updated)}</small></button>) : <p className="empty-history">Your conversations will appear here.</p>}</div><ThemePicker/><div className="sidebar-bottom"><span><i className={connection === 'online' ? 'live-dot' : 'idle-dot'}/>{desktop ? 'ON THIS COMPUTER' : 'PRIVATE CONNECTION'}</span><p>{desktop ? 'Your model. Your conversations.' : 'Powered by your computer.'}</p><small>BLACK TEAM {status.version || ''}</small></div></aside>
    <main className={`companion-main app-main${page === 'conversations' ? ' chat-page' : ''}`}><header><div><span className="eyebrow">{eyebrow}</span><h1>{title}</h1><p className="muted">{description}</p></div><StatusPill status={status} connection={connection}/></header>
      {connection === 'offline' && <div className="notice error" role="status"><p>{desktop ? 'The local service is unavailable. Reconnecting automatically…' : 'Connection lost. Keep your computer awake and check that both devices are connected to Tailscale. Reconnecting…'}</p></div>}
      {error && <div className="notice error" role="alert"><p>{error}</p><button aria-label="Dismiss error" onClick={() => setError('')}>×</button></div>}
      {pendingRequest&&page!=='conversations'&&<div className="notice" role="status"><p>Your last message needs to reconnect before you start another conversation.</p><button className="secondary" onClick={()=>navigate('conversations')}>Recover last message</button></div>}
      {notice && <div className="notice" role="status"><p>{notice}</p><button aria-label="Dismiss message" onClick={() => setNotice('')}>×</button></div>}
      {desktop && page === 'workspace' && <Workspace status={status} busy={busy} onAction={action} onChat={startChat} onSettings={showSettings} onPhone={()=>navigate("phone")} onSave={saveModel}/>}
      {page === 'conversations' && <Chat key={`${threadId||"new"}:${chatKey}`} drafts={drafts} onOpenThread={openThread} initialKind={newChatKind} onSetup={showSettings} status={status} thread={thread} threadId={threadId} connection={connection} onSend={send} onCancel={cancel} onApproval={approval} sending={sending} pendingRequest={pendingRequest}/>}
      {desktop && page === 'phone' && <PhoneSettings status={status} busy={busy} onAction={action}/>}
      {desktop && page === 'settings' && <>
        <nav className="settings-sections" aria-label="Settings sections">{[['model','Models'],['agents','Agents & apps'],['data','App & data']].map(([id,label])=><button key={id} className={settingsSection===id?'selected':''} aria-current={settingsSection===id?'page':undefined} onClick={()=>setSettingsSection(id)}>{label}</button>)}</nav>
        {settingsSection==='model'&&<SetupForm status={status} settings busy={busy} onAction={action} onSave={saveModel}/>}
        {settingsSection==='agents'&&<Integrations status={status} busy={busy} onAction={action} onChat={()=>startChat('agent')}/>}
        {settingsSection==='data'&&<><section className="settings-data"><div><h2>Your data stays here</h2><p>Settings and conversations are saved on this computer.</p></div><button className="secondary" onClick={()=>action('open-data')} disabled={busy}>Open data folder</button></section><details><summary>Optional research: JEV</summary><p className="section-intro">Chat and agent work use local context management and need no JEV key. Optional research setup is described in docs/JEV.md.</p></details><p className="inline-note">Updates are your choice. Black Team does not automatically download models or new app versions.</p></>}
      </>}
      {page !== 'conversations' && <footer>PRIVATE AI. TOTAL CONTROL.<span>{status.hardware?.platform === 'linux' ? 'Linux' : status.hardware?.platform} · {status.hardware?.arch}</span></footer>}
    </main>
  </div>;
}
