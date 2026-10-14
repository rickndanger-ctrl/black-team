import React, {useCallback, useEffect, useRef, useState} from 'react';
import Integrations from './Integrations.jsx';
import SetupForm from './ModelSetup.jsx';
import PhoneSettings from './PhoneSettings.jsx';
import {native} from './desktop.mjs';
import StarterModels from './Starter.jsx';
import {createCompanionInitializer} from './companionConnection.mjs';
import Brand from './Brand.jsx';
import AgentAvatar from './AgentAvatar.jsx';
import Icon from './Icons.jsx';
import ThemePicker from './Theme.jsx';
import MemoryPage from './Memory.jsx';
import {ModelList} from './Models.jsx';
import Harnesses from './Harnesses.jsx';
import FindModels, {FoundPrompt} from './FindModels.jsx';
import {Chat} from './Chat.jsx';
import StopCard from './StopCard.jsx';
import {CloudPanel} from './Cloud.jsx';
import Room from './Room.jsx';
import MicButton from './Dictate.jsx';
import {api, call, post} from './http.mjs';

const desktop = Boolean(window.blackTeam?.request);
const byteSize = value => Number.isFinite(value) ? `${(value / 1024 ** 3).toFixed(1)} GB` : 'Unavailable';
const speed = mhz => mhz ? (mhz >= 1000 ? `${(mhz / 1000).toFixed(1)} GHz` : `${mhz} MHz`) : '';
const basename = path => path?.split(/[\\/]/).filter(Boolean).at(-1) || 'Not selected';
const date = value => value ? new Date(value).toLocaleDateString(undefined, {month: 'short', day: 'numeric'}) : '';

const initializeCompanion=createCompanionInitializer({desktop,location:window.location,replaceURL:url=>window.history.replaceState(null,'',url),post});

function StatusPill({status, connection}) {
  const ready = connection === 'online' && status?.runtime?.ready;
  const label = connection !== 'online' ? (connection === 'connecting' ? 'Connecting' : 'Connection lost') : status?.runtime?.state === 'starting' ? (status?.config?.model?.source === 'server' ? 'Connecting model' : 'Starting model') : status?.runtime?.busy ? 'Model responding' : ready ? 'Model ready' : 'Model stopped';
  return <span className={`online status-pill${ready ? ' is-ready' : ''}`} role="status"><i className={ready ? 'live-dot' : 'idle-dot'}/>{label}</span>;
}

function Workspace({status, busy, onAction, onChat, onSettings, onPhone, onSave}) {
  const hardware = status.hardware || {};
  const running = status.runtime?.ready || status.runtime?.state === 'starting';
  // A new install is walked through two steps: the models found here, then the agents found here.
  const [welcome, setWelcome] = useState(() => status.setupComplete ? null : 'models');
  const [manual, setManual] = useState(false);
  return <>
    <section className="telemetry hardware-grid" aria-label="This computer">
      <div><Icon name="chip"/><div><span>CPU IN USE</span><strong>{status.performance?.cpu ?? '—'}% <small>· load {status.performance?.load?.toFixed(1) || '0.0'} of {hardware.cpu?.threads || hardware.cores || '—'}{Number.isFinite(status.performance?.temperature) && <> · {status.performance.temperature}°C</>}</small></strong><em>{hardware.cpu?.name || 'CPU'} · {hardware.cpu?.cores || '—'} physical {hardware.cpu?.cores === 1 ? 'core' : 'cores'} · {hardware.cpu?.threads || '—'} threads{hardware.cpu?.mhz ? ` · ${speed(hardware.cpu.mhz)} now` : ''}</em></div></div>
      <div><Icon name="activity"/><div><span>MEMORY AVAILABLE</span><strong>{byteSize(status.performance?.memory?.free ?? hardware.memory?.free)} <small>/ {byteSize(hardware.memory?.total)}</small></strong><em>{status.performance?.model ? <>Model holding {byteSize(status.performance.model.resident)}{status.performance.model.swapped > 256 * 1024 ** 2 ? `, ${byteSize(status.performance.model.swapped)} pushed to swap` : ''}</> : status.performance?.memory?.swapUsed > 256 * 1024 ** 2 ? `${byteSize(status.performance.memory.swapUsed)} of swap in use` : 'Free for a model to load'}</em></div></div>
      <div><Icon name="folder"/><div><span>DISK AVAILABLE</span><strong>{byteSize(hardware.disk?.available ?? hardware.disk?.free)} <small>/ {byteSize(hardware.disk?.total)}</small></strong><em>Where Black Team keeps its data</em></div></div>
    </section>
    {welcome === 'agents' && status.setupComplete && <section className="welcome-step"><div><span className="eyebrow">STEP 2 OF 2 · YOUR AGENTS</span><h2>{status.config?.model?.name} is ready.</h2><p>Connect any agents you want from the list just below, then start. You can do this later too.</p></div><div className="button-row"><button className="primary" disabled={busy} onClick={() => {setWelcome(null); onChat('chat');}}>Start chatting</button><button className="secondary" disabled={busy} onClick={() => setWelcome(null)}>Stay here</button></div></section>}
    {welcome === 'agents' && status.setupComplete && <Harnesses status={status} busy={busy} onAction={onAction} onChat={onChat} onSettings={onSettings}/>}
    {!status.setupComplete ? (welcome === 'models' && !manual ? <><p className="welcome-lead"><span className="eyebrow">STEP 1 OF 2 · YOUR MODELS</span></p><FindModels auto busy={busy} onAction={onAction} onAdded={() => setWelcome('agents')} onManual={() => setManual(true)} heading="Here is what is on this computer"/><StarterModels status={status}/></> : <><StarterModels status={status}/><SetupForm status={status} busy={busy} onSave={onSave} onAction={onAction} onCloudSaved={() => onChat('chat')}/></>) : status.config?.model?.kind === 'cloud' ? <CloudPanel status={status} busy={busy} onChat={onChat} onSettings={onSettings}/> : <section className="local-model-panel">
      <div className="model-identity"><AgentAvatar large active={status.runtime?.busy}/><div><span className="eyebrow">YOUR LOCAL MODEL</span><h2>{status.config?.model?.name || 'Local model'}</h2><p>{status.runtime?.ready ? 'Ready on this computer. Open a conversation to begin.' : status.runtime?.state === 'starting' ? (status.config?.model?.source === 'server' ? 'Connecting to your local server. The server manages model loading.' : 'Loading the model into memory. This can take a moment.') : 'Start your model when you need it. Your conversations stay here.'}</p></div></div>
      <div className="model-facts"><div><span>Model</span><strong>{status.config?.model?.source === 'server' ? status.config.model.id : basename(status.config?.model?.file)}</strong></div><div><span>Processing</span><strong>{status.config?.model?.source === 'server' ? 'Local server' : [status.config?.model?.gpuLayers ? `${status.config.model.gpuLayers} GPU layers` : 'CPU', ...(status.runtime?.features?.length ? status.runtime.features : [`${status.config?.model?.threads || '—'} threads`])].join(' · ')}</strong></div><div><span>Context window</span><strong>{Number(status.config?.model?.context || 4096).toLocaleString()} tokens</strong></div></div>
      <div className="button-row">{running ? <button className="secondary" disabled={busy || status.runtime?.busy} onClick={() => onAction('runtime-stop', {}, 'Model stopped.')}><Icon name="power" size={16}/>{status.config?.model?.source === 'server' ? 'Disconnect model' : 'Stop model'}</button> : <button className="primary" disabled={busy} onClick={() => onAction('runtime-start', {}, status.config?.model?.source === 'server' ? 'Connecting to your local server.' : 'Starting your local model.')}><Icon name="power" size={16}/>{status.config?.model?.source === 'server' ? 'Connect model' : 'Start model'}</button>}<button className={running ? 'primary' : 'secondary'} disabled={busy} onClick={()=>onChat("chat")}><Icon name="chat" size={16}/>Open chat</button><button className="text-button" onClick={()=>onSettings("model")}>Change model <Icon name="arrow" size={15}/></button></div>
      {status.runtime?.busy && <p className="inline-note">A response is running. Open Conversations to stop the response before stopping the model.</p>}
    </section>}
    {hardware.warnings?.length > 0 && <section className="inline-note"><strong>Hardware notes</strong><ul>{hardware.warnings.map((warning, index) => <li key={index}>{warning}</li>)}</ul></section>}
    {status.runtime?.error && <div className="notice error" role="alert"><div><strong>{status.config?.model?.source === 'server' ? 'The local server could not connect.' : 'The model could not start.'}</strong><p>{typeof status.runtime.error === 'string' ? status.runtime.error : 'Check that the model and runtime match this computer, then review your memory and performance settings.'}</p></div></div>}
    {status.setupComplete && welcome === null && <FoundPrompt busy={busy} onAction={onAction}/>}
    {welcome !== 'agents' && <Harnesses status={status} busy={busy} onAction={onAction} onChat={onChat} onSettings={onSettings}/>}
    <div className="principle-grid"><section><span className="step-number">01 / YOUR COMPUTER</span><h3>Local by default</h3><p>Conversation history lives on your machine. No Black Team account needed. Use a local model in your server to keep inference here.</p></section><section><span className="step-number">02 / YOUR CHOICE</span><h3>Bring your model</h3><p>Load a GGUF model or connect your existing local model server.</p></section><section><span className="step-number">03 / OPTIONAL COMPANION</span><h3>Continue from your phone</h3><p>Connect privately and keep working with the same model.</p><button className="text-button" onClick={onPhone}>Connect your phone →</button></section></div>
  </>;
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
  const [stopping, setStopping] = useState(false);
  const [sending, setSending] = useState(false);
  const [pendingRequest, setPendingRequest] = useState(null);
  const [mobileNav, setMobileNav] = useState(false);
  const [project, setProject] = useState(null);
  const [naming, setNaming] = useState(null);
  const nameBox = useRef(null);
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
  // Returns true when sent; {status, message} for a refusal the conversation view explains (privacy, permission, pictures); false otherwise.
  const send = async (message, mode, kind, extra = {}) => {
    if (sending) return false;
    const {fresh, ...options} = extra;
    if (fresh && !pendingRequest) {
      // "Start a new cloud conversation" keeps the typed words and starts a new conversation with them.
      drafts.current.new = {...drafts.current.new, message, mode, kind};
      selectedThread.current = null; setThreadId(null); setThread(null);
    }
    setSending(true); setError('');
    try {
      const payload = pendingRequest || {threadId: selectedThread.current, message, mode, kind, requestId: crypto.randomUUID(), ...options, ...(project && !selectedThread.current ? {project} : {})};
      setPendingRequest(payload);
      const result = await post('/api/chat', payload);
      setPendingRequest(null);
      const id = result.threadId || result.thread?.id;
      if (id) {selectedThread.current = id; setThreadId(id);}
      await refresh(); return true;
    } catch (cause) {
      if (cause.status && cause.status < 500) setPendingRequest(null);
      if (cause.status === 400) return {status: 400, message: cause.message};
      setError(cause.status ? cause.message : 'The connection dropped while sending. Retry your message to recover the same response.'); return false;
    }
    finally {setSending(false);}
  };
  const cancel = async () => {setSending(true); setError(''); try {await post('/api/cancel', {}); await refresh();} catch (cause) {setError(cause.message);} finally {setSending(false);}};
  const approval=async choice=>{setSending(true);setError('');try{await post('/api/approval',{id:status.job.approval.id,digest:status.job.approval.digest,choice});await refresh();}catch(cause){setError(cause.message);}finally{setSending(false);}};
  const startChat = kind => {if(sending||pendingRequest){setPage('conversations');setMobileNav(false);return;}drafts.current.new={...drafts.current.new,kind:kind||'chat'};setNewChatKind(kind || 'chat');setChatKey(previous=>previous+1);openThread(null);};
  const projects = status?.projects || [];
  const activeProject = projects.find(item => item.id === project) || null;
  // Opening a conversation follows it into its project; opening a project returns to its latest conversation, or starts one in its folder.
  const openConversation = item => {setProject(item.project || null); openThread(item.id);};
  const openProject = item => {if(sending||pendingRequest){setPage('conversations');setMobileNav(false);return;}const latest=(status.threads||[]).find(entry=>entry.project===item.id);setProject(item.id);if(latest)openThread(latest.id);else startChat('agent');};
  const leaveProject = () => {setProject(null); startChat(newChatKind);};
  const createProject = async event => {
    event.preventDefault();const name=(naming||'').trim();if(!name)return;
    try{const made=await call('project-create',{name});setNaming(null);await refresh();setProject(made.id);startChat('agent');}catch(cause){setError(cause.message);}
  };
  const currentKind = thread?.kind || pendingRequest?.kind || newChatKind;
  const showSettings = section => {setSettingsSection(section||'model');navigate('settings');};
  const switchModel = async key => {
    const result = await action('model-switch', {key});
    if (result?.name) {
      setNotice(`Now using ${result.name}. Your next message starts it.`);
      // If it would not fit beside another model that is running, ask now; the card shows up from the status.
      try {await api('/api/runtime/approval'); await refresh();} catch {}
    }
    return result;
  };
  // The person said yes to stopping the other model: the engine stops that one server and starts the chosen model.
  const approveStop = async approval => {
    setStopping(true); setError('');
    try {await post('/api/runtime/approve', {pid: approval.pid}); setNotice(`Stopped ${approval.otherName}. ${approval.modelName} is starting.`); await refresh(); return true;}
    catch (cause) {setError(cause.message); await refresh(); return false;}
    finally {setStopping(false);}
  };
  const cancelStop = async () => {try {await post('/api/runtime/decline', {});} catch {} await refresh();};
  const threadLine = item => `${item.kind === 'agent' ? 'Code' : 'Chat'} · ${date(item.updated)}${item.privacy === 'cloud' ? ` · Leaves this computer · ${item.provider}` : ''}`;
  const forgetModel = key => action('model-forget', {key}, 'Removed from your list. Nothing was deleted from your computer.');
  const saveModel = async value => {if(await action('setup-save',value,'Model saved. Send a message to begin.'))startChat('chat');};
  const navigate = next => {setPage(next); setMobileNav(false); setError(''); setNotice('');};
  if (!status) return <div className="cabinet boot setup-boot"><div className="boot-brand"><Brand caption={desktop ? 'PRIVATE AI. TOTAL CONTROL.' : 'PRIVATE COMPANION'}/></div>{connection === 'connecting' ? <><span className="spinner"/><h1>Opening your workspace</h1><p>Connecting to Black Team on your computer.</p></> : <><h1>{pairingRequired ? 'Pair this phone with Black Team.' : 'Your computer is out of reach.'}</h1><p>{error || (desktop ? 'Black Team could not connect to its local service. Reopen the app or try again.' : 'Keep your computer awake, connect your phone to Tailscale, and open the private Companion address from the desktop app.')}</p><button className="primary" onClick={() => {setConnection('connecting'); refresh();}}>Try again</button></>}</div>;
  const titles = {room: ['PROJECT ROOM', 'Your team room.', 'Local models, cloud models and agents working on one project, on this computer.'], memory: ['BLACK TEAM VAULT', 'Memory', 'What your local models remember. It never leaves this computer.'], workspace: ['YOUR LOCAL AI', 'Your local AI command center.', 'Models, harnesses, tools and performance. On your computer.'], conversations: [desktop ? 'LOCAL CONVERSATIONS' : 'BLACK TEAM COMPANION', thread?.title || 'Your private conversation.', 'A direct connection to the model on your computer.'], phone: ['BLACK TEAM COMPANION', 'Take the conversation with you.', 'Private access to your local models and agent work.'], settings: ['CONNECTIONS', 'Make yourself at home.', 'Connect your models and agents. Keep the details out of your way.']};
  const [eyebrow, title, description] = titles[page] || titles.conversations;
  return <div className={`cabinet cabinet-companion black-team-app${desktop ? ' desktop-app' : ' phone-app'}`}>
    <div className="mobile-topbar"><span className="mobile-wordmark"><AgentAvatar/>BLACK TEAM{!desktop && <small>COMPANION</small>}</span><button className="secondary" aria-expanded={mobileNav} aria-controls="app-navigation" onClick={() => setMobileNav(previous => !previous)}>{mobileNav ? 'Close' : 'Menu'}</button></div>
    <aside className={`sidebar companion-nav app-sidebar${mobileNav ? ' mobile-open' : ''}`} id="app-navigation"><Brand caption={desktop ? 'PRIVATE AI. TOTAL CONTROL.' : 'PRIVATE COMPANION'}/><div className="nav-label">{desktop ? 'CONTROL ROOM' : 'YOUR COMPANION'}</div><nav aria-label="Main navigation">{(desktop ? [['workspace', 'grid', 'Workspace'], ['conversations', 'chat', 'Chat / Code'], ...(status.access === 'desktop' ? [['room', 'work', 'Room']] : []), ['memory', 'activity', 'Memory'], ['phone', 'globe', 'Phone Companion'], ['settings', 'chip', 'Settings']] : [['conversations', 'chat', 'Chat / Code'], ['memory', 'activity', 'Memory']]).map(([id, icon, label]) => <button key={id} className={`nav${page === id ? ' selected' : ''}`} onClick={() => navigate(id)} aria-current={page === id ? 'page' : undefined}><Icon name={icon} size={17}/>{label}</button>)}</nav><div className="thread-list">
      <div className="side-heading"><small>PROJECTS</small><button type="button" onClick={()=>setNaming(naming===null?'':null)} aria-label="New project" aria-expanded={naming!==null} title="New project">+</button></div>
      {naming!==null&&<form className="side-form" onSubmit={createProject}><input ref={nameBox} autoFocus value={naming} maxLength={60} placeholder="Project name" aria-label="Project name" onChange={event=>setNaming(event.target.value)} onKeyDown={event=>{if(event.key==='Escape')setNaming(null);}}/>{status.dictation&&<MicButton field={nameBox} value={naming} onError={setError}/>}</form>}
      {projects.length?projects.map(item=>{const mine=(status.threads||[]).filter(entry=>entry.project===item.id);const open=project===item.id;return <div key={item.id} className={`project${open?' open':''}`}><button className="project-name" aria-expanded={open} disabled={!item.exists||sending||Boolean(pendingRequest)} onClick={()=>open?leaveProject():openProject(item)}><Icon name="folder" size={14}/><span>{item.name}</span><i>{mine.length||''}</i></button>{open&&(mine.length?mine.map(entry=><button key={entry.id} disabled={sending||Boolean(pendingRequest)} className={`in-project${threadId===entry.id&&page==='conversations'?' selected':''}`} onClick={()=>openConversation(entry)}>{entry.title||'Untitled conversation'}<small>{threadLine(entry)}</small></button>):<p className="side-empty">No conversations yet. Send a message to start.</p>)}</div>;}):naming===null&&<p className="side-empty">Press + to start a project.</p>}
      <div className="side-heading"><small>CONVERSATIONS</small><button type="button" disabled={sending||Boolean(pendingRequest)} onClick={()=>startChat(newChatKind)} aria-label="New conversation" title="New conversation">+</button></div>
      {(status.threads||[]).filter(item=>!item.project||!projects.some(entry=>entry.id===item.project)).length?(status.threads||[]).filter(item=>!item.project||!projects.some(entry=>entry.id===item.project)).map(item=><button key={item.id} disabled={sending||Boolean(pendingRequest)} className={threadId===item.id&&page==='conversations'?'selected':''} onClick={()=>openConversation(item)}>{item.title||'Untitled conversation'}<small>{threadLine(item)}</small></button>):<p className="side-empty">Your conversations will appear here.</p>}
    </div><ThemePicker/><div className="sidebar-bottom"><span><i className={connection === 'online' ? 'live-dot' : 'idle-dot'}/>{desktop ? 'ON THIS COMPUTER' : 'PRIVATE CONNECTION'}</span><p>{desktop ? 'Your model. Your conversations.' : 'Powered by your computer.'}</p><small>BLACK TEAM AGENT {status.version || ''}</small></div></aside>
    <main className={`companion-main app-main${page === 'conversations' ? ' chat-page' : ''}`}><header>{page==='conversations'?<h1 className="page-mark" role="group" aria-label="Mode">{[['chat','chat','Chat'],['agent','terminal','Code']].map(([id,icon,label],index)=><React.Fragment key={id}>{index>0&&<i>/</i>}<button type="button" className={currentKind===id?'lit':''} aria-pressed={currentKind===id} aria-label={`Black Team ${label}`} title={label} disabled={currentKind!==id&&(sending||Boolean(pendingRequest))} onClick={()=>{if(id!==currentKind)startChat(id);}}><Icon name={icon} size={30}/></button></React.Fragment>)}</h1>:<div><span className="eyebrow">{eyebrow}</span><h1>{title}</h1><p className="muted">{description}</p></div>}<StatusPill status={status} connection={connection}/></header>
      {connection === 'offline' && <div className="notice error" role="status"><p>{desktop ? 'The local service is unavailable. Reconnecting automatically…' : 'Connection lost. Keep your computer awake and check that both devices are connected to Tailscale. Reconnecting…'}</p></div>}
      {error && <div className="notice error" role="alert"><p>{error}</p><button aria-label="Dismiss error" onClick={() => setError('')}>×</button></div>}
      {pendingRequest&&page!=='conversations'&&<div className="notice" role="status"><p>Your last message needs to reconnect before you start another conversation.</p><button className="secondary" onClick={()=>navigate('conversations')}>Recover last message</button></div>}
      {notice && <div className="notice" role="status"><p>{notice}</p><button aria-label="Dismiss message" onClick={() => setNotice('')}>×</button></div>}
      {desktop && page !== 'conversations' && status.runtime?.approval && <StopCard approval={status.runtime.approval} busy={stopping} onApprove={() => approveStop(status.runtime.approval)} onCancel={cancelStop}/>}
      {desktop && page === 'workspace' && <Workspace status={status} busy={busy} onAction={action} onChat={startChat} onSettings={showSettings} onPhone={()=>navigate("phone")} onSave={saveModel}/>}
      {page === 'conversations' && <Chat key={`${threadId||"new"}:${chatKey}`} drafts={drafts} onSwitchModel={desktop?switchModel:undefined} onOpenThread={openThread} initialKind={newChatKind} onSetup={showSettings} status={status} thread={thread} threadId={threadId} connection={connection} onSend={send} onCancel={cancel} onApproval={approval} sending={sending} pendingRequest={pendingRequest} project={activeProject} onLeaveProject={leaveProject} onNotice={setNotice} onError={setError} stopping={stopping} onApproveStop={approveStop} onCancelStop={cancelStop}/>}
      {desktop && page === 'room' && status.access === 'desktop' && <Room status={status} project={project} onOpenChat={() => navigate('conversations')}/>}
      {page === 'memory' && <MemoryPage call={call} onError={setError} status={status} onUseProject={openProject}/>}
      {desktop && page === 'phone' && <PhoneSettings status={status} busy={busy} onAction={action}/>}
      {desktop && page === 'settings' && <>
        <nav className="settings-sections" aria-label="Settings sections">{[['model','Models'],['agents','Agents & apps'],['data','App & data']].map(([id,label])=><button key={id} className={settingsSection===id?'selected':''} aria-current={settingsSection===id?'page':undefined} onClick={()=>setSettingsSection(id)}>{label}</button>)}</nav>
        {settingsSection==='model'&&<><ModelList models={status.models} busy={busy} working={Boolean(status.runtime?.busy)} onSwitch={switchModel} onForget={forgetModel}/><FindModels busy={busy} onAction={action}/><StarterModels status={status}/><SetupForm status={status} settings busy={busy} onAction={action} onSave={saveModel} onCloudSaved={() => startChat('chat')}/></>}
        {settingsSection==='agents'&&<Integrations status={status} busy={busy} onAction={action} onChat={()=>startChat('agent')}/>}
        {settingsSection==='data'&&<><section className="settings-data"><div><h2>Your data stays here</h2><p>Settings and conversations are saved on this computer.</p></div><button className="secondary" onClick={()=>action('open-data')} disabled={busy}>Open data folder</button></section><details><summary>Optional research: JEV</summary><p className="section-intro">Chat and agent work use local context management and need no JEV key. Optional research setup is described in docs/JEV.md.</p></details><p className="inline-note">Updates are your choice. Black Team does not automatically download models or new app versions.</p></>}
      </>}
      {page !== 'conversations' && <footer>PRIVATE AI. TOTAL CONTROL.<span>{status.hardware?.platform === 'linux' ? 'Linux' : status.hardware?.platform} · {status.hardware?.arch}</span></footer>}
    </main>
  </div>;
}
