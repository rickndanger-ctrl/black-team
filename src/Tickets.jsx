import React, {useEffect, useRef, useState} from 'react';
import Markdown from './Markdown.jsx';
import {api, post} from './http.mjs';
import {TICKET_STATE, STAGE_TITLE, artifactKind, boardColumns, latestArtifacts, needsOwner, sendBackText, waitingText} from './organizationView.mjs';

// The Tickets page: work moving through the organization's stages, with each ticket's artifacts, history and send-backs, and the gates that
// wait for you. The engine decides the stage, the gate and what leaves this computer; this page shows it and sends what you type.
const when = value => value ? new Date(value).toLocaleString(undefined, {month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'}) : '';

function Banner({kind = 'error', children, onClose}) {
  return <div className={`notice${kind === 'error' ? ' error' : ''}`} role={kind === 'error' ? 'alert' : 'status'}><p>{children}</p>{onClose && <button aria-label="Dismiss message" onClick={onClose}>×</button>}</div>;
}

export default function Tickets({status, project, onOpenOrganization}) {
  const projects = status.projects || [];
  const firstProject = id => projects.some(item => item.id === id) ? id : projects[0]?.id || null;
  const [projectId, setProjectId] = useState(() => firstProject(project));
  const [state, setState] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [openId, setOpenId] = useState('');
  const live = useRef(true);
  const shown = useRef(projectId);
  useEffect(() => {live.current = true; return () => {live.current = false;};}, []);

  const read = async (id, quiet = false) => {
    try {
      const next = await api(`/api/org?project=${encodeURIComponent(id)}`);
      if (live.current && shown.current === id) {setState(next); if (!quiet) setError('');}
    } catch (cause) {if (live.current && shown.current === id && !quiet) setError(cause.message);}
  };
  useEffect(() => {
    shown.current = projectId; setState(null); setError(''); setOpenId('');
    if (projectId) read(projectId);
  }, [projectId]);
  useEffect(() => {
    if (projectId && !projects.some(item => item.id === projectId)) setProjectId(projects[0]?.id || null);
  }, [projects, projectId]);
  const running = Boolean(state?.tickets?.some(ticket => ticket.state === 'running'));
  useEffect(() => {
    if (!projectId) return undefined;
    const timer = window.setInterval(() => {if (document.visibilityState === 'visible') read(projectId, true);}, running ? 1500 : 6000);
    return () => window.clearInterval(timer);
  }, [projectId, running]);

  const request = async (route, body) => {
    const id = projectId;
    setBusy(true); setError('');
    try {
      const answer = await post(`/api/org/${route}`, {project: id, ...body});
      if (live.current && shown.current === id && answer?.projectId) setState(answer);
      return answer;
    } catch (cause) {
      if (live.current) setError(cause.message);
      return null;
    } finally {if (live.current) setBusy(false);}
  };

  if (!projects.length) return <section className="local-model-panel"><p>Start a project in the sidebar first; tickets belong to a project.</p></section>;
  const org = state?.organization;
  return <>
    <div className="room-project"><span>Project</span><select className="agent-picker" aria-label="Project" value={projectId || ''} onChange={event => setProjectId(event.target.value)}>{projects.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select></div>
    {error && <Banner onClose={() => setError('')}>{error}</Banner>}
    {!state ? <p className="memory-empty">Opening the tickets…</p>
      : !org ? <section className="local-model-panel room-card"><p>This project has no organization yet.</p><div className="button-row"><button type="button" className="primary" onClick={onOpenOrganization}>Set one up</button></div></section>
      : <>
        <NewTicket busy={busy} request={request} org={org}/>
        <Board state={state} openId={openId} onOpen={setOpenId}/>
        {openId && state.tickets.some(ticket => ticket.id === openId) && <Detail key={openId} projectId={projectId} ticket={state.tickets.find(ticket => ticket.id === openId)} busy={busy} request={request} onClose={() => setOpenId('')}/>}
      </>}
  </>;
}

function NewTicket({busy, request, org}) {
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [ui, setUi] = useState('auto');
  const add = async () => {
    const answer = await request('ticket/add', {title: title.trim(), body, ...(ui === 'auto' ? {} : {ui: ui === 'yes'})});
    if (answer) {setTitle(''); setBody(''); setUi('auto');}
  };
  return <section className="local-model-panel room-card" aria-label="Add a ticket">
    <span className="eyebrow">TICKETS</span>
    <h2>Give {org.name} some work</h2>
    <p className="section-intro">One ticket is one change: a few sentences on what you want. Small tickets finish sooner, and local models are slow. The lead splits a large one into smaller ones.</p>
    <div className="org-ticket-form">
      <input className="room-input" aria-label="Ticket title" value={title} maxLength={120} placeholder="What should be done, in a few words" disabled={busy} onChange={event => setTitle(event.target.value)}/>
      <textarea className="org-text" aria-label="Ticket details" value={body} maxLength={4000} rows={3} placeholder="Details, if they help: what you see now, what you want to see" disabled={busy} onChange={event => setBody(event.target.value)}/>
      <div className="button-row">
        <label className="org-pick">Changes how it looks?<select className="agent-picker" aria-label="Does it touch the user interface" value={ui} disabled={busy} onChange={event => setUi(event.target.value)}><option value="auto">Let the lead decide</option><option value="yes">Yes, design it first</option><option value="no">No</option></select></label>
        <button type="button" className="primary" disabled={busy || !title.trim()} onClick={add}>Add the ticket</button>
      </div>
    </div>
  </section>;
}

// One column per stage; a ticket that waits for you is marked.
function Board({state, openId, onOpen}) {
  const columns = boardColumns(state.tickets);
  if (!state.tickets.length) return <section className="local-model-panel room-card"><p className="room-empty">No tickets yet.</p></section>;
  return <section className="local-model-panel room-card" aria-label="Ticket board">
    <span className="eyebrow">BOARD</span>
    <h2>Where the work is</h2>
    <div className="org-board">{columns.map(column => <div className="room-column" key={column.id}>
      <div className="room-col-head"><strong>{column.title}</strong><small>{column.tickets.length}</small></div>
      {column.tickets.map(ticket => <button key={ticket.id} type="button" className={`org-ticket${openId === ticket.id ? ' open' : ''}${needsOwner(ticket) ? ' attention' : ''}`} aria-expanded={openId === ticket.id} onClick={() => onOpen(openId === ticket.id ? '' : ticket.id)}>
        <strong>{ticket.label} {ticket.title}</strong>
        <em className={`room-state ${ticket.state === 'running' ? 'doing' : ticket.state === 'gate' ? 'review' : ticket.state === 'done' ? 'done' : ticket.state === 'blocked' ? 'failed' : ''}`}>{TICKET_STATE[ticket.state] || ticket.state}</em>
      </button>)}
    </div>)}</div>
  </section>;
}

// A ticket opened: what it is waiting for, its artifacts, its history.
function Detail({projectId, ticket, busy, request, onClose}) {
  const [detail, setDetail] = useState(null);
  const [error, setError] = useState('');
  const [artifact, setArtifact] = useState('');
  const [note, setNote] = useState('');
  const [answer, setAnswer] = useState('');
  const [sending, setSending] = useState(false);
  const stamp = `${ticket.updated}:${ticket.artifacts.length}:${ticket.state}`;
  useEffect(() => {
    let live = true;
    api(`/api/org/ticket?project=${encodeURIComponent(projectId)}&id=${encodeURIComponent(ticket.id)}`)
      .then(next => {if (live) {setDetail(next); setError('');}}).catch(cause => {if (live) setError(cause.message);});
    return () => {live = false;};
  }, [projectId, ticket.id, stamp]);
  const full = detail?.ticket || ticket;
  const shown = latestArtifacts(full.artifacts);
  const current = artifact && shown.some(item => item.name === artifact) ? artifact : (full.gate?.artifact || shown[shown.length - 1]?.name || '');
  const text = detail?.artifacts?.[current];
  const act = async (route, body) => {if (await request(route, {id: ticket.id, ...body})) {setNote(''); setAnswer(''); setSending(false);}};
  const waiting = waitingText(ticket);
  return <section className="local-model-panel room-card" aria-label={`Ticket ${ticket.label}`}>
    <span className="eyebrow">{ticket.label} · {STAGE_TITLE[ticket.stage] || ticket.stage}</span>
    <h2>{ticket.title}</h2>
    {full.body && <p className="section-intro">{full.body}</p>}
    {error && <Banner onClose={() => setError('')}>{error}</Banner>}
    {waiting && <div className="room-agreement" role="group" aria-label="Waiting for you">
      <p className="room-sub">{ticket.state === 'blocked' ? 'This ticket is stuck' : 'Waiting for you'}</p>
      <p>{waiting}</p>
      {ticket.state === 'gate' && ticket.gate.kind === 'question' && <div className="org-ticket-form">
        <textarea className="org-text" aria-label="Your answer" rows={3} maxLength={1000} value={answer} disabled={busy} onChange={event => setAnswer(event.target.value)}/>
        <div className="button-row"><button type="button" className="primary" disabled={busy || !answer.trim()} onClick={() => act('ticket/answer', {answer})}>Send my answer</button></div>
      </div>}
      {ticket.state === 'gate' && ticket.gate.kind !== 'question' && <>
        {sending && <textarea className="org-text" aria-label="What to change" rows={3} maxLength={1000} value={note} placeholder="What should change?" disabled={busy} onChange={event => setNote(event.target.value)}/>}
        <div className="button-row">
          {!sending && <button type="button" className="primary" disabled={busy} onClick={() => act('ticket/approve', {})}>Approve</button>}
          {!sending && <button type="button" className="secondary" disabled={busy} onClick={() => setSending(true)}>Send back with a note</button>}
          {sending && <button type="button" className="primary" disabled={busy || !note.trim()} onClick={() => act('ticket/sendback', {note})}>Send it back</button>}
          {sending && <button type="button" className="secondary" onClick={() => setSending(false)}>Cancel</button>}
        </div>
      </>}
      {ticket.state === 'blocked' && <div className="button-row"><button type="button" className="primary" disabled={busy} onClick={() => act('ticket/retry', {})}>Try again</button></div>}
    </div>}
    {full.branch && <p className="message-note">Branch <code>{full.branch}</code>, started from {full.baseBranch || 'your branch'} ({String(full.base || '').slice(0, 8)}). Your own branch and folder are untouched. {ticket.state === 'done' ? <>Merging is your decision: <code>git merge {full.branch}</code></> : 'Merging it is always your decision.'}</p>}
    {sendBackText(full.sendBacks) && <p className="message-note">{sendBackText(full.sendBacks)}.</p>}
    {shown.length > 0 && <>
      <p className="room-sub">What each stage made</p>
      <div className="button-row org-artifacts" role="tablist" aria-label="Artifacts">{shown.map(item => <button key={item.name} type="button" role="tab" aria-selected={current === item.name} className={current === item.name ? 'primary' : 'secondary'} onClick={() => setArtifact(item.name)} title={`${item.title}${item.role ? ` · ${item.role}` : ''}`}>{item.title}</button>)}</div>
      {text == null ? <p className="room-empty">Opening…</p> : text === '' ? <p className="room-empty">Empty.</p> : artifactKind(current) === 'markdown' ? <div className="org-artifact"><Markdown text={text}/></div> : <pre className="org-report">{text}</pre>}
    </>}
    <p className="room-sub">History</p>
    <ul className="room-list org-history">{[...full.history].reverse().map((item, index) => <li key={index}><div><p className="message-note">{when(item.at)}{item.role ? ` · ${item.role}` : ''} — {item.text}</p></div></li>)}</ul>
    <div className="button-row">
      {['ready', 'gate', 'blocked'].includes(ticket.state) && <button type="button" className="link-button" disabled={busy} onClick={() => act('ticket/cancel', {})}>Cancel this ticket</button>}
      {ticket.state === 'done' && <button type="button" className="link-button" disabled={busy} onClick={() => setSending(true)}>Send it back to Build</button>}
      <button type="button" className="link-button" onClick={onClose}>Close</button>
    </div>
    {ticket.state === 'done' && sending && <div className="org-ticket-form">
      <textarea className="org-text" aria-label="What to change" rows={3} maxLength={1000} value={note} placeholder="What should change?" disabled={busy} onChange={event => setNote(event.target.value)}/>
      <div className="button-row"><button type="button" className="primary" disabled={busy || !note.trim()} onClick={() => act('ticket/sendback', {note})}>Send it back</button></div>
    </div>}
  </section>;
}

// The phone's view: the tickets list, read only, and a yes for a gate that may be answered from a phone. The computer does the work.
export function PhoneTickets({status, project, call}) {
  const projects = status.projects || [];
  const [projectId, setProjectId] = useState(() => projects.some(item => item.id === project) ? project : projects[0]?.id || '');
  const [tickets, setTickets] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState('');
  const load = () => call(`org/tickets?project=${encodeURIComponent(projectId)}`).then(next => {setTickets(next.tickets); setError('');}).catch(cause => setError(cause.message));
  useEffect(() => {
    if (!projectId) return undefined;
    load();
    const timer = window.setInterval(load, 8000);
    return () => window.clearInterval(timer);
  }, [projectId]);
  const approve = async ticket => {
    setBusy(ticket.id);
    try {await call('org/ticket/approve', {project: projectId, id: ticket.id}); await load();} catch (cause) {setError(cause.message);} finally {setBusy('');}
  };
  if (!projects.length) return <section className="local-model-panel"><p>No projects yet.</p></section>;
  return <>
    <div className="room-project"><span>Project</span><select className="agent-picker" aria-label="Project" value={projectId} onChange={event => setProjectId(event.target.value)}>{projects.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select></div>
    {error && <Banner onClose={() => setError('')}>{error}</Banner>}
    <section className="local-model-panel room-card" aria-label="Tickets">
      <span className="eyebrow">TICKETS</span>
      <h2>What the organization is working on</h2>
      {!tickets ? <p className="room-empty">Loading…</p> : !tickets.length ? <p className="room-empty">No tickets. Add them on your computer.</p>
        : <ul className="room-list">{tickets.map(ticket => <li key={ticket.id}>
          <div><strong>{ticket.label} {ticket.title}</strong><em className="room-role">{STAGE_TITLE[ticket.stage]} · {TICKET_STATE[ticket.state] || ticket.state}</em>{ticket.gate && <p className="message-note">{ticket.gate.question}</p>}{ticket.state === 'blocked' && <p className="message-note">{ticket.note}</p>}</div>
          {ticket.state === 'gate' && ticket.gate.kind !== 'question' && (ticket.gate.desktopOnly
            ? <div className="button-row"><small>Answer on your computer</small></div>
            : <div className="button-row"><button type="button" className="primary" disabled={busy === ticket.id} onClick={() => approve(ticket)}>Approve</button></div>)}
        </li>)}</ul>}
    </section>
  </>;
}
