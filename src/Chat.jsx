import React, {useEffect, useRef, useState} from 'react';
import Icon from './Icons.jsx';
import MicButton from './Dictate.jsx';
import AgentAvatar from './AgentAvatar.jsx';
import Markdown from './Markdown.jsx';
import {Changes, SpeedMeter, WorkLog} from './Panels.jsx';
import {ModelSwitch} from './Models.jsx';
import {responseActivity} from './responseActivity.mjs';
import {api, call, post} from './http.mjs';
import {AGENT_NAMES, CloudNotice, CloudUsage, PrivacyCard, PrivacyTag, ProjectCloud} from './Privacy.jsx';
import {AgentPicker, AgentRunActions, PermissionPicker, VersionLine} from './Agents.jsx';
import StopCard from './StopCard.jsx';
import {MAX_PICTURES, MessageImages, PictureButton, PictureChips, VisionDownload} from './Pictures.jsx';

const desktop = Boolean(window.blackTeam?.request);
const byteSize = value => Number.isFinite(value) ? `${(value / 1024 ** 3).toFixed(1)} GB` : 'Unavailable';
const AGENTS = Object.keys(AGENT_NAMES);
// The outcomes that mean "this conversation would leave this computer" (the phone's answer is phoneNeedsMac).
const LEAVES = ['startsCloud', 'phoneNeedsMac'];

export function ContextReport({report}) {
  if (!report || !Number.isSafeInteger(report.measuredInputTokens) || !Number.isSafeInteger(report.context) || report.context <= 0) return null;
  const omitted = Number.isSafeInteger(report.omittedMessages) ? report.omittedMessages : 0;
  const used = Math.max(0, Math.min(100, report.measuredInputTokens / report.context * 100));
  const reserve = Number.isSafeInteger(report.maxTokens) ? Math.max(0, Math.min(100-used, report.maxTokens / report.context * 100)) : 0;
  return <details className="context-inspector"><summary><span>Context control</span><span>{Math.round(used)}% used{omitted > 0 ? ' · Adjusted' : ' · Within budget'}</span></summary><div className="context-inspector-body"><div className="context-meter" role="meter" aria-label="Input context used" aria-valuemin={0} aria-valuemax={report.context} aria-valuenow={Math.min(report.context,report.measuredInputTokens)} aria-valuetext={`${report.measuredInputTokens.toLocaleString()} input tokens of ${report.context.toLocaleString()}`}><span style={{width:`${used}%`}}/><i style={{width:`${reserve}%`}}/></div><dl><div><dt>{report.method === 'estimated-bytes' ? 'Estimated conversation input' : 'Conversation input'}</dt><dd>{report.measuredInputTokens.toLocaleString()} tokens</dd></div><div><dt>Reserved for reply</dt><dd>{Number.isSafeInteger(report.maxTokens) ? report.maxTokens.toLocaleString() : '—'} tokens</dd></div><div><dt>Model context</dt><dd>{report.context.toLocaleString()} tokens</dd></div></dl><p>{omitted > 0 ? `${omitted} older ${omitted === 1 ? 'message was' : 'messages were'} left out of this reply’s context. The full conversation stays saved on your computer.` : 'This reply includes all eligible completed turns. Your current message and system instructions are preserved.'}</p><small>{report.method === 'estimated-bytes' ? 'Estimated locally, not a tokenizer measurement. Match context settings to your server; its template and truncation behavior can differ.' : 'Measured locally · No hosted context service'}</small></div></details>;
}

export function Chat({status, thread, threadId, connection, onSend, onCancel, onApproval, sending, pendingRequest, initialKind, onSetup, onOpenThread, drafts, project, onLeaveProject, onNotice, onError, onSwitchModel, stopping, onApproveStop, onCancelStop}) {
  const draftKey=threadId||'new';
  const draft = () => drafts.current[draftKey] || {};
  const [message, setMessage] = useState(()=>draft().message||'');
  const saveDraft=patch=>{drafts.current[draftKey]={...drafts.current[draftKey],...patch};};
  const editMessage=value=>{saveDraft({message:value});setMessage(value);};
  const [mode, setMode] = useState(()=>draft().mode||'balanced');
  const kind=thread?.kind||pendingRequest?.kind||draft().kind||initialKind||'chat';
  // A conversation that belongs to an agent keeps it; a new Code conversation takes the agent chosen above the composer.
  const boundAgent = AGENTS.includes(thread?.engine) ? thread.engine : (pendingRequest?.agent || '');
  const [agentChoice, setAgentChoice] = useState(()=>draft().agent||'');
  const agentEngine = boundAgent || (kind==='agent' && !threadId ? agentChoice : '');
  const [permission, setPermission] = useState(()=>draft().permission||'edit');
  useEffect(()=>{if(thread?.agentPermission)setPermission(thread.agentPermission);},[thread?.agentPermission]);
  const shownPermission = pendingRequest?.permission || permission;
  const [images, setImages] = useState([]);
  const [preparing, setPreparing] = useState(false);
  const [check, setCheck] = useState(null);
  const [card, setCard] = useState(null);
  // A message that waits for the person's yes to stop another model; the words stay in the box meanwhile.
  const [stopWait, setStopWait] = useState(null);
  const endRef = useRef(null), box = useRef(null);
  const keep=async item=>{try{const result=await call('memory/remember',{title:item.content.replace(/[#*_`>\[\]]/g,'').replace(/\s+/g,' ').trim().slice(0,48)||'Saved reply',text:item.content.slice(0,4000),project:project?.id||null});onNotice(`Saved to memory as ${result.id}. Open Memory to rename or edit it.`);}catch(cause){onError(cause.message);}};
  const undo=async id=>{try{const result=await call('undo',{id});onNotice(result.removed?`Removed ${result.path}, which this edit had created.`:`Put ${result.path} back as it was.`);return true;}catch(cause){onError(cause.message);return false;}};
  const activity = responseActivity({thread, threadId, job: status.job, connection});
  const activeJob = status.job?.state === 'running';
  const busy = sending || activeJob || Boolean(pendingRequest);
  const available = connection === 'online' && !sending && (Boolean(pendingRequest) || (status.setupComplete && !activeJob));
  const modelName = status.config?.model?.name || status.runtime?.name || 'Black Team';
  const replyName = boundAgent ? AGENT_NAMES[boundAgent] : modelName;
  const meter = (status.job?.threadId===threadId&&threadId&&status.job.meter) || thread?.messages?.findLast?.(item=>item.meter)?.meter;
  // Pictures are for Chat with a vision-capable model on this computer; never for an agent.
  const canPicture = desktop && kind !== 'agent' && Boolean(status.vision?.canSee);
  const privacyQuery = () => {
    const query = new URLSearchParams();
    if (threadId) query.set('threadId', threadId); else if (project?.id) query.set('project', project.id);
    query.set('kind', kind === 'agent' ? 'agent' : 'chat');
    if (agentEngine) query.set('agent', agentEngine);
    return query.toString();
  };
  const privacyKey = [threadId || '', project?.id || '', kind, agentEngine, thread?.privacy, status.cloud?.selected, status.cloud?.provider].join('|');
  // "What would happen if I sent now?" The engine decides again on send; this only draws the tag and the notice.
  useEffect(() => {
    let active = true;
    api(`/api/privacy?${privacyQuery()}`).then(value => {if (active) setCheck(value);}).catch(() => {if (active) setCheck(null);});
    return () => {active = false;};
  }, [privacyKey]);
  const askPrivacy = () => api(`/api/privacy?${privacyQuery()}`).catch(() => null);
  useEffect(() => {endRef.current?.scrollIntoView({behavior: 'instant', block: 'nearest'});}, [thread?.messages?.length, thread?.messages?.at(-1)?.content]);
  const leaves = thread ? thread.privacy === 'cloud' : (check ? LEAVES.includes(check.outcome) : Boolean(status.cloud?.selected));
  const leaveProvider = thread ? thread.provider : (check?.provider || status.cloud?.provider || '');
  const pictureIds = images.map(item => item.id);
  // Sends the words, with the agent, permission or pictures chosen for this message.
  const deliver = async (content, extra, fresh) => {
    const result = await onSend(content, mode, kind, {...extra, ...(fresh ? {fresh: true} : {})});
    if (result === true) {editMessage(''); setImages([]); setCard(null); return;}
    if (result?.status === 400) {
      // A privacy refusal becomes the card; any other refusal is shown as the engine words it.
      const found = desktop ? await askPrivacy() : null;
      if (found?.refused) setCard({check: found, content, extra, view: 'choice', threadId}); else onError(result.message);
    }
  };
  const submit = async event => {
    event.preventDefault();
    if ((!message.trim() && !images.length && !pendingRequest) || !available) return;
    const content = pendingRequest?.message || message.trim() || 'Describe these images.';
    const extra = agentEngine ? {agent: agentEngine, permission: shownPermission} : (pictureIds.length ? {images: pictureIds} : {});
    if (desktop && !pendingRequest) {
      const found = await askPrivacy();
      if (found?.refused) {setCard({check: found, content, extra, view: 'choice', threadId}); return;}
    }
    if (desktop && !pendingRequest && !agentEngine) {
      // Would the model fit beside the one that is running? If not, ask first; the message is kept and nothing is sent.
      const start = await api('/api/runtime/approval').catch(() => null);
      if (start?.approval) {setStopWait({approval: start.approval, content, extra}); return;}
    }
    await deliver(content, extra, false);
  };
  const askedStop = stopWait?.approval || (desktop && !agentEngine ? status.runtime?.approval : null);
  const approveStop = async () => {
    const waiting = stopWait;
    if (!await onApproveStop(askedStop)) return;
    setStopWait(null);
    if (waiting) await deliver(waiting.content, waiting.extra, false);
  };
  const cancelStop = async () => {setStopWait(null); await onCancelStop();};
  const cardAction = {
    startNew: () => deliver(card.content, card.extra, true),
    switchBack: async () => {const key = card.check.localModelKey; setCard(null); const result = await onSwitchModel?.(key); if (result) await deliver(card.content, card.extra, false);},
    convert: () => setCard({...card, view: 'confirm'}),
    confirm: async () => {
      try {await post('/api/privacy/convert', {threadId: card.threadId, provider: card.check.provider});}
      catch (cause) {onError(cause.message); return;}
      const {content, extra} = card; setCard(null);
      await deliver(content, extra, false);
    },
    close: () => setCard(null),
  };
  // The preview is a data: address, because the window's Content Security Policy allows no blob: pictures.
  const preview = file => new Promise(resolve => {const reader = new FileReader(); reader.onload = () => resolve(reader.result); reader.onerror = () => resolve(''); reader.readAsDataURL(file);});
  const addPictures = async files => {
    if (images.length + files.length > MAX_PICTURES) {onError('Choose up to 4 images.'); return;}
    setPreparing(true);
    for (const file of files) {
      try {
        const info = await api(`/api/image?name=${encodeURIComponent(file.name)}`, {method: 'POST', body: file, headers: {'Content-Type': file.type || 'application/octet-stream'}});
        const url = await preview(file);
        setImages(previous => [...previous, {...info, url}]);
      } catch (cause) {onError(cause.message);}
    }
    setPreparing(false);
  };
  const removePicture = item => {
    setImages(previous => previous.filter(entry => entry.id !== item.id));
    post('/api/image/discard', {ids: [item.id]}).catch(() => {});
  };
  const paste = event => {
    if (!canPicture) return;
    const files = [...(event.clipboardData?.files || [])].filter(file => file.type.startsWith('image/'));
    if (files.length) {event.preventDefault(); addPictures(files);}
  };
  return <div className="chat-layout">
    <div className="chat-controls">
      <label htmlFor="response-mode" className="eyebrow">THINKING</label><select id="response-mode" title="How much the model thinks before answering. Fast turns thinking off; each level after it thinks longer and may reply at more length." value={mode} onChange={event => {saveDraft({mode:event.target.value});setMode(event.target.value);}} disabled={busy}><option value="fast">Fast</option><option value="balanced">Balanced</option><option value="deep">Deep</option><option value="extended">Extended</option></select>
      {project&&<span className="project-chip"><Icon name="folder" size={13}/>{project.name}{!threadId&&<button type="button" aria-label="Leave project" title="Leave project" onClick={onLeaveProject}>×</button>}</span>}
      {desktop && (!threadId || boundAgent) && kind === 'agent' && <AgentPicker agents={status.agents} value={agentEngine} disabled={busy || Boolean(boundAgent)} onChange={value => {setAgentChoice(value); saveDraft({agent: value});}}/>}
      {agentEngine && desktop && <PermissionPicker engine={agentEngine} value={shownPermission} disabled={busy} onChange={value => {setPermission(value); saveDraft({permission: value});}}/>}
      <PrivacyTag leaves={leaves} provider={leaveProvider}/>
      <CloudUsage thread={thread}/>
      <SpeedMeter meter={meter}/>
      <ModelSwitch models={status.models} name={modelName} disabled={busy} onSwitch={onSwitchModel}/>
      {agentEngine && desktop && <VersionLine engine={agentEngine}/>}
    </div>
    {desktop && project && <ProjectCloud project={project} busy={busy} onNotice={onNotice} onError={onError}/>}
    {!status.setupComplete ? <div className="notice"><p>{desktop?'Connect a model to start.':'Connect a model in Black Team on your computer first.'}</p>{desktop&&<button className="secondary" onClick={()=>onSetup('model')}>Connect a model</button>}</div> : !status.runtime?.ready && !agentEngine && <div className="notice"><p>{status.runtime?.state === 'starting' ? (status.config?.model?.source === 'server' ? 'Connecting to your local server. It will be ready when the connection finishes.' : 'Your model is starting. It will be ready when it finishes loading.') : 'Send a message to start or connect your configured local model.'}</p></div>}
    <div className="conversation" role="log" aria-label="Conversation" aria-live="off">
      {!thread?.messages?.length ? <div className="chat-empty"><AgentAvatar large active={Boolean(activity?.glowing)}/><h2>{kind==='agent'?'Ready to work.':'A space to think freely.'}</h2><p>{kind==='agent'?<>Describe a task. {agentEngine ? AGENT_NAMES[agentEngine] : 'Code'} reads and edits files in {project?project.name:'your workspace'}, runs commands and shows every change.</>:'Start a conversation with your local model.'}<br/>History is saved on your computer.</p></div> : thread.messages.map((item, index) => <article className={`message ${item.role === 'user' ? 'user' : 'assistant'}`} key={item.id || index}><div className="message-heading">{item.role !== 'user' && <AgentAvatar active={Boolean(activity?.glowing && (!activity.messageId ? index === thread.messages.length - 1 : activity.messageId === item.id))}/>}<span>{item.role === 'user' ? 'YOU' : item.model || replyName}</span>{activity?.messageId === item.id && <small className="response-label">{activity.label}</small>}</div>{item.role === 'user' && <MessageImages images={item.images} threadId={thread.id}/>}{item.thinking && <details className="thinking-content"><summary>Reasoning</summary><div>{item.thinking}</div></details>}{item.role !== 'user' && item.content ? <Markdown text={item.content}/> : <div className="message-body">{item.content || (item.state === 'writing' ? '…' : '')}</div>}{item.recalled?.length>0&&<p className="memory-used" title={item.recalled.map(found=>`${found.title}: ${found.text}`).join('\n')}>Memory used: {[...new Set(item.recalled.map(found=>found.title))].join(', ')}</p>}{item.role === 'assistant' && <ContextReport report={item.context}/>}<Changes events={item.events} onUndo={undo} busy={sending||activeJob}/><WorkLog events={item.events}/>{item.artifacts?.map(a=><p key={a.id}><a href={`/api/file/${a.id}`} download={a.name}>{a.name} · Download</a></p>)}{item.role==='assistant'&&item.run&&desktop&&<AgentRunActions item={item} threadId={thread.id} busy={sending||activeJob} onError={onError}/>}{item.role==='assistant'&&status.memory&&item.content&&item.state==='done'&&<button type="button" className="remember" onClick={()=>keep(item)} title="Save this reply to the Black Team vault">Remember this</button>}{item.note && <p className="message-note">{item.note}</p>}{item.state === 'interrupted' && <p className="message-note">Response stopped. Any text already received is saved here.</p>}{item.role === 'assistant' && item.finishReason === 'length' && <p className="message-note">This reply reached its length limit. Ask the model to continue, or choose a longer reply length for your next message.</p>}{item.state === 'error' && <p className="message-note">{typeof item.error === 'string' ? item.error : 'The response was interrupted. Try again when your model is ready.'}</p>}</article>)}
      {activity && !activity.messageId && <div className="response-status" role="status"><AgentAvatar active={activity.glowing}/><span>{activity.label}…</span></div>}
      <div ref={endRef}/>
    </div>
    {activity && !thread?.messages?.at(-1)?.context && <ContextReport report={status.job?.context}/>}
    {desktop && check?.outcome === 'startsCloud' && !threadId && <CloudNotice check={check}/>}
    {askedStop && <StopCard approval={askedStop} busy={stopping} sends={Boolean(stopWait)} onApprove={approveStop} onCancel={cancelStop}/>}
    {card && <PrivacyCard card={card} busy={sending} canConvert={Boolean(card.threadId)} onStartNew={cardAction.startNew} onSwitch={cardAction.switchBack} onConvert={cardAction.convert} onConfirm={cardAction.confirm} onClose={cardAction.close}/>}
    {status.job?.approval&&status.job.threadId===threadId&&<section className="notice approval-card" role="status"><div><strong>Your decision</strong><p>{status.job.approval.description}</p><pre>{status.job.approval.command}</pre><div className="button-row"><button className="primary" disabled={sending} onClick={()=>onApproval('once')}>Approve once</button><button className="secondary" disabled={sending} onClick={()=>onApproval('deny')}>Deny</button></div></div></section>}
    {status.job?.approval&&status.job.threadId!==threadId&&<div className="notice"><p>Code is waiting for your approval in another conversation.</p><button className="secondary" disabled={sending||Boolean(pendingRequest)} onClick={()=>onOpenThread(status.job.threadId)}>Open that task</button></div>}
    {!desktop&&<small className="composer-note">Computer CPU {status.performance?.cpu ?? '—'}% · RAM available {byteSize(status.performance?.memory?.free)}</small>}
    {pendingRequest && !sending && <p className="inline-note retry-note" role="status">Your last message may already be saved. Retry to reconnect to that same response without sending it twice.</p>}
    {canPicture && (images.length > 0) && <PictureChips items={images} onRemove={removePicture}/>}
    {desktop && kind !== 'agent' && <VisionDownload status={status} onError={onError}/>}
    <form className="composer" onSubmit={submit}>{status.dictation&&<MicButton field={box} value={message} disabled={sending||connection!=='online'||!status.setupComplete||Boolean(pendingRequest)} onError={onError}/>}{canPicture && <PictureButton busy={preparing} disabled={sending || Boolean(pendingRequest) || images.length >= MAX_PICTURES} onFiles={addPictures}/>}<textarea ref={box} aria-label={kind==='agent'?'Describe a task for Code':'Message your local model'} rows={3} value={pendingRequest?.message || message} onChange={event => editMessage(event.target.value)} onPaste={paste} placeholder={connection !== 'online' ? 'Reconnecting to your computer…' : kind==='agent' ? 'Describe what you want built, checked or changed…' : 'Message your local model…'} disabled={sending || connection !== 'online' || !status.setupComplete || Boolean(pendingRequest)} onKeyDown={event => {if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing && window.innerWidth > 760) {event.preventDefault(); if (available && message.trim()) submit(event);}}}/>{activeJob && !pendingRequest ? <button type="button" className="secondary" onClick={onCancel} disabled={sending || connection !== 'online'}>{status.job?.kind==='memory'?'Stop upkeep':'Stop'}</button> : <button className="primary" aria-label={pendingRequest ? 'Retry last message' : kind==='agent' ? 'Run task' : 'Send message'} disabled={!available || (!message.trim() && !images.length && !pendingRequest)}><Icon name="send" size={17}/><span>{sending ? 'Sending…' : pendingRequest ? 'Retry message' : kind==='agent' ? 'Run' : 'Send'}</span></button>}</form>
    <small className="composer-note">{activeJob && status.job?.threadId !== threadId ? (status.job?.kind==='memory' ? 'Black Team is tidying memory with your model.' : 'A response is running in another conversation.') : 'LOCAL INFERENCE · HISTORY SAVED ON YOUR COMPUTER'}</small>
  </div>;
}
