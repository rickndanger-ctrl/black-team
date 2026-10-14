import React, {useEffect, useRef, useState} from 'react';
import {api, post} from './http.mjs';
import {STAGES, STAGE_TITLE, agentChoice, ceilingText, gateChoices, moneyText, roleStatusText, splitLines} from './organizationView.mjs';

// The Organization page: a team of agents that works on a project like a small company. The engine decides who may take part, what leaves
// this computer and what a ceiling means; this page shows its answers and sends what the person types. Nothing here uses a browser prompt.
const ACCESS = [['read', 'Read only'], ['ask', 'Ask me first'], ['edit', 'Edit files in the project'], ['auto', 'Automatic']];
const KINDS = [['engineer', 'Engineer'], ['reviewer', 'Reviewer'], ['designer', 'Designer'], ['qa', 'QA'], ['product', 'Product manager'], ['architect', 'Architect'], ['docs', 'Docs writer'], ['release', 'Release manager'], ['custom', 'Other role']];

function Banner({kind = 'error', children, onClose}) {
  return <div className={`notice${kind === 'error' ? ' error' : ''}`} role={kind === 'error' ? 'alert' : 'status'}><p>{children}</p>{onClose && <button aria-label="Dismiss message" onClick={onClose}>×</button>}</div>;
}

export default function Organization({status, project, onOpenTickets}) {
  const projects = status.projects || [];
  const firstProject = id => projects.some(item => item.id === id) ? id : projects[0]?.id || null;
  const [projectId, setProjectId] = useState(() => firstProject(project));
  const [state, setState] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
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
    shown.current = projectId; setState(null); setError('');
    if (projectId) read(projectId);
  }, [projectId]);
  useEffect(() => {
    if (projectId && !projects.some(item => item.id === projectId)) setProjectId(projects[0]?.id || null);
  }, [projects, projectId]);

  // Read often while a role is working, and now and then when nothing is, so a change made on the phone or the command shows.
  const working = Boolean(state?.roles?.some(role => role.status === 'working'));
  useEffect(() => {
    if (!projectId) return undefined;
    const timer = window.setInterval(() => {if (document.visibilityState === 'visible') read(projectId, true);}, working ? 1500 : 8000);
    return () => window.clearInterval(timer);
  }, [projectId, working]);

  // One call to the engine; it answers with the whole organization, which replaces what is shown.
  const request = async (route, body) => {
    const id = projectId;
    setBusy(true); setError('');
    try {
      const answer = await post(`/api/org/${route}`, {project: id, ...body});
      if (live.current && shown.current === id && answer && answer.projectId) setState(answer);
      return answer;
    } catch (cause) {
      if (live.current) setError(cause.message);
      return null;
    } finally {if (live.current) setBusy(false);}
  };

  if (!projects.length) return <section className="local-model-panel"><p>Start a project in the sidebar first; an organization belongs to a project.</p></section>;
  const org = state?.organization;
  return <>
    <div className="room-project"><span>Project</span><select className="agent-picker" aria-label="Project" value={projectId || ''} onChange={event => setProjectId(event.target.value)}>{projects.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select></div>
    {error && <Banner onClose={() => setError('')}>{error}</Banner>}
    {!state ? <p className="memory-empty">Opening the organization…</p>
      : !org ? <Create state={state} busy={busy} request={request}/>
      : <>
        <Overview key={`o-${projectId}`} state={state} busy={busy} request={request} onOpenTickets={onOpenTickets}/>
        <Chart key={`c-${projectId}`} state={state} busy={busy} request={request}/>
        <Settings key={`s-${projectId}`} state={state} busy={busy} request={request}/>
        <Ledger state={state}/>
      </>}
  </>;
}

// No organization yet: choose a template and what the roles run on.
function Create({state, busy, request}) {
  const [template, setTemplate] = useState('software');
  const local = state.choices.filter(item => item.kind === 'model' && !item.cloud);
  const leads = state.choices;
  const [roles, setRoles] = useState('');
  const [lead, setLead] = useState('');
  const pickedLocal = roles || local[0]?.key || '';
  const pickedLead = lead || 'same';
  const make = () => {
    const body = {template, ...(pickedLocal ? {local: pickedLocal} : {})};
    if (pickedLead !== 'same') {
      const choice = leads.find(item => `${item.kind}:${item.key}` === pickedLead);
      if (choice?.kind === 'agent') body.leadAgent = choice.key; else if (choice) body.leadModel = choice.key;
    }
    return request('create', body);
  };
  return <section className="local-model-panel room-card" aria-label="Make an organization">
    <span className="eyebrow">ORGANIZATION</span>
    <h2>Set up a company of agents for {state.projectName}</h2>
    <p className="section-intro">An organization is a team of agents that works on this project like a small company: it takes tickets, writes a spec, designs, plans, builds, reviews, tests and prepares the change for you. You approve what matters and merge nothing you did not choose to. Local models on a computer without a graphics card are slow, so a full ticket can take hours. Keep tickets small.</p>
    <ul className="room-list">{(state.templates || []).map(item => <li key={item.id}>
      <div><label className="org-template"><input type="radio" name="template" checked={template === item.id} disabled={busy} onChange={() => setTemplate(item.id)}/> <strong>{item.name}</strong></label><p className="message-note">{item.summary}</p></div>
    </li>)}</ul>
    {!local.length && <p className="room-empty">Save a model in Settings first. Every role needs a model or an agent.</p>}
    <div className="room-add">
      <p className="room-sub">Who does the work</p>
      <div className="button-row">
        <label className="org-pick">Most roles<select className="agent-picker" aria-label="Most roles run on" value={pickedLocal} disabled={busy} onChange={event => setRoles(event.target.value)}>{local.map(item => <option key={item.key} value={item.key}>{item.name}</option>)}</select></label>
        <label className="org-pick">The lead<select className="agent-picker" aria-label="The lead runs on" value={pickedLead} disabled={busy} onChange={event => setLead(event.target.value)}><option value="same">The same model</option>{leads.map(item => <option key={`${item.kind}:${item.key}`} value={`${item.kind}:${item.key}`}>{item.name}{item.cloud ? ' · paid' : ''}</option>)}</select></label>
        <button type="button" className="primary" disabled={busy || !pickedLocal} onClick={make}>Make the organization</button>
      </div>
      <p className="room-empty">A paid lead (a cloud model or Claude Code or Codex) plans and decides while local models do the bulk. Nothing is sent anywhere until you read what would leave this computer and confirm.</p>
    </div>
  </section>;
}

// The state of the organization, what starting it sends, and the buttons that start, pause and resume it.
function Overview({state, busy, request, onOpenTickets}) {
  const org = state.organization;
  const [agreement, setAgreement] = useState(null);
  const [removing, setRemoving] = useState(false);
  const open = state.tickets.filter(ticket => !['done', 'cancelled'].includes(ticket.state));
  const waiting = state.tickets.filter(ticket => ticket.state === 'gate').length;
  const stateText = !org.running ? 'Not started' : org.paused ? 'Paused' : 'Running';
  const review = async () => {
    try {setAgreement(await api(`/api/org/agreement?project=${encodeURIComponent(state.projectId)}`));}
    catch (cause) {setAgreement({text: cause.message, problems: [], services: [], digest: ''});}
  };
  const start = async () => {if (await request('start', {digest: agreement.digest})) setAgreement(null);};
  return <section className="local-model-panel room-card" aria-label="Organization">
    <span className="eyebrow">ORGANIZATION</span>
    <h2>{org.name}</h2>
    <p className="section-intro"><span className={`room-state ${org.running && !org.paused ? 'doing' : org.paused ? 'review' : ''}`}>{stateText.toUpperCase()}</span>{' '}
      {org.paused && org.pausedReason ? org.pausedReason : !org.running ? (org.pausedReason || 'It does nothing until you read what it sends and start it.') : 'It picks up the next ticket whenever this computer is idle.'}
      {' '}{open.length} open {open.length === 1 ? 'ticket' : 'tickets'}{waiting ? `, ${waiting} waiting for you` : ''}. Without the background service it works only while this window is open.</p>
    <div className="button-row">
      {!org.running && <button type="button" className="primary" disabled={busy} onClick={review}>Read what it sends, then start</button>}
      {org.running && !org.paused && <button type="button" className="secondary" disabled={busy} onClick={() => request('pause', {})}>Pause</button>}
      {org.running && org.paused && <button type="button" className="primary" disabled={busy} onClick={() => request('resume', {})}>Resume</button>}
      {org.running && !org.paused && <button type="button" className="secondary" disabled={busy || state.busy} onClick={() => request('step', {})}>Work on the next ticket now</button>}
      <button type="button" className="link-button" onClick={onOpenTickets}>Open the tickets</button>
      <button type="button" className="link-button" disabled={busy || org.running} onClick={() => setRemoving(true)}>Remove</button>
    </div>
    {removing && <div className="room-agreement" role="group" aria-label="Remove the organization">
      <p>Remove {org.name}? Its tickets, notes and usage are deleted. Branches it made stay in your repository.</p>
      <div className="button-row"><button type="button" className="primary" disabled={busy} onClick={async () => {if (await request('remove', {})) setRemoving(false);}}>Remove it</button><button type="button" className="secondary" onClick={() => setRemoving(false)}>Keep it</button></div>
    </div>}
    {agreement && <div className="room-agreement" role="group" aria-label="What this organization sends">
      <p className="room-sub">What starting it sends</p>
      <p>{agreement.text}</p>
      {agreement.services?.length > 0 && <p className="message-note">Services: {agreement.services.join(', ')}.</p>}
      {agreement.problems?.length > 0 && <ul className="room-list">{agreement.problems.map(problem => <li key={problem}><div><p className="message-note">{problem}</p></div></li>)}</ul>}
      <div className="button-row"><button type="button" className="primary" disabled={busy || agreement.problems?.length > 0 || !agreement.digest} onClick={start}>I have read this: start</button><button type="button" className="secondary" onClick={() => setAgreement(null)}>Cancel</button></div>
    </div>}
  </section>;
}

// The org chart: each role with where it runs, what it is doing and what it has used today. A role opens to be edited.
function Chart({state, busy, request}) {
  const [editing, setEditing] = useState('');
  const [adding, setAdding] = useState('engineer');
  return <section className="local-model-panel room-card" aria-label="Roles">
    <span className="eyebrow">ROLES</span>
    <h2>Who does what</h2>
    <p className="section-intro">Each role has a charter (what it is responsible for), a model or agent, and how much it may do on its own. Change any of it.</p>
    <ul className="room-list org-chart">{state.roles.map(view => <li key={view.role.id}>
      <div>
        <strong>{view.role.name}<em className="room-role">{view.role.kind}</em></strong>
        <p className="message-note">{agentChoice(view, state.choices)} · {ACCESS.find(([id]) => id === view.role.access)?.[1]} · <span className={`room-state ${view.status === 'working' ? 'doing' : view.status === 'waiting' ? 'review' : ''}`}>{roleStatusText(view)}</span></p>
        {!view.usable && view.reason && <p className="message-note">{view.reason}</p>}
        {(view.spentToday.paidTokens > 0 || view.spentToday.localTokens > 0) && <p className="message-note">Today: {view.spentToday.localTokens.toLocaleString()} local tokens{view.spentToday.paidTokens > 0 ? `, ${view.spentToday.paidTokens.toLocaleString()} paid${view.spentToday.money ? ` (about ${moneyText(view.spentToday.money)})` : ''}` : ''}</p>}
      </div>
      <div className="button-row">
        <span className={`privacy-tag${view.kind === 'cloud' ? ' leaves' : ''}`}>{view.kind === 'cloud' ? `Paid · ${view.provider}` : view.kind === 'none' ? 'Not set up' : 'Local'}</span>
        <button type="button" className="link-button" aria-expanded={editing === view.role.id} onClick={() => setEditing(editing === view.role.id ? '' : view.role.id)}>{editing === view.role.id ? 'Close' : 'Edit'}</button>
      </div>
      {editing === view.role.id && <RoleEditor view={view} state={state} busy={busy} request={request} onDone={() => setEditing('')}/>}
    </li>)}</ul>
    <div className="room-add">
      <p className="room-sub">Add a role</p>
      <div className="button-row">
        <select className="agent-picker" aria-label="Kind of role" value={adding} disabled={busy} onChange={event => setAdding(event.target.value)}>{KINDS.map(([id, label]) => <option key={id} value={id}>{label}</option>)}</select>
        <button type="button" className="secondary" disabled={busy} onClick={() => request('role/add', {kind: adding})}>Add</button>
      </div>
    </div>
  </section>;
}

function RoleEditor({view, state, busy, request, onDone}) {
  const role = view.role;
  const [draft, setDraft] = useState({
    name: role.name, charter: role.charter, skills: (role.skills || []).join('\n'), pick: role.agent ? `agent:${role.agent}` : role.modelKey ? `model:${role.modelKey}` : '',
    work: role.work || 'code', access: role.access, priceIn: role.price?.inPerMillion ?? '', priceOut: role.price?.outPerMillion ?? '',
    tokens: role.budget?.paidTokensPerDay ?? '', money: role.budget?.moneyPerDay ?? '',
  });
  const set = (key, value) => setDraft(previous => ({...previous, [key]: value}));
  const isAgent = draft.pick.startsWith('agent:');
  const number = value => value === '' || value === null || Number.isNaN(Number(value)) ? undefined : Number(value);
  const save = async () => {
    const next = {...role, name: draft.name.trim() || role.name, charter: draft.charter, skills: splitLines(draft.skills), access: draft.access};
    delete next.modelKey; delete next.agent; delete next.work;
    if (draft.pick.startsWith('agent:')) next.agent = draft.pick.slice(6);
    else if (draft.pick.startsWith('model:')) {next.modelKey = draft.pick.slice(6); next.work = draft.work;}
    const pin = number(draft.priceIn), pout = number(draft.priceOut);
    if (pin !== undefined && pout !== undefined) next.price = {inPerMillion: pin, outPerMillion: pout}; else delete next.price;
    const tokens = number(draft.tokens), money = number(draft.money);
    if (tokens !== undefined || money !== undefined) next.budget = {...(tokens !== undefined ? {paidTokensPerDay: tokens} : {}), ...(money !== undefined ? {moneyPerDay: money} : {})}; else delete next.budget;
    if (await request('role/save', {role: next})) onDone();
  };
  return <div className="org-editor" role="group" aria-label={`Edit ${role.name}`}>
    <label>Name<input className="room-input" value={draft.name} maxLength={60} disabled={busy} onChange={event => set('name', event.target.value)}/></label>
    <label>Charter<textarea className="org-text" value={draft.charter} maxLength={2000} rows={5} disabled={busy} onChange={event => set('charter', event.target.value)}/></label>
    <label>Guidance notes, one per line<textarea className="org-text" value={draft.skills} rows={3} disabled={busy} onChange={event => set('skills', event.target.value)}/></label>
    <div className="button-row">
      <label className="org-pick">Runs on<select className="agent-picker" value={draft.pick} disabled={busy} onChange={event => set('pick', event.target.value)}><option value="">Choose…</option>{state.choices.map(item => <option key={`${item.kind}:${item.key}`} value={`${item.kind}:${item.key}`}>{item.name}{item.cloud ? ' · paid' : ''}</option>)}</select></label>
      {!isAgent && <label className="org-pick">Work<select className="agent-picker" value={draft.work} disabled={busy} onChange={event => set('work', event.target.value)}><option value="code">Code: reads and changes files</option><option value="chat">Chat: answers in text</option></select></label>}
      <label className="org-pick">May do<select className="agent-picker" value={draft.access} disabled={busy} onChange={event => set('access', event.target.value)}>{ACCESS.map(([id, label]) => <option key={id} value={id}>{label}</option>)}</select></label>
    </div>
    <p className="room-sub">Prices and daily ceilings for paid work (your own numbers; empty means none)</p>
    <div className="button-row">
      <label className="org-pick">Price per million tokens read<input className="room-input" inputMode="decimal" value={draft.priceIn} disabled={busy} onChange={event => set('priceIn', event.target.value)}/></label>
      <label className="org-pick">Price per million tokens written<input className="room-input" inputMode="decimal" value={draft.priceOut} disabled={busy} onChange={event => set('priceOut', event.target.value)}/></label>
      <label className="org-pick">Paid tokens a day<input className="room-input" inputMode="numeric" value={draft.tokens} disabled={busy} onChange={event => set('tokens', event.target.value)}/></label>
      <label className="org-pick">Money a day<input className="room-input" inputMode="decimal" value={draft.money} disabled={busy} onChange={event => set('money', event.target.value)}/></label>
    </div>
    <div className="button-row">
      <button type="button" className="primary" disabled={busy} onClick={save}>Save</button>
      <button type="button" className="secondary" disabled={busy} onClick={onDone}>Cancel</button>
      <button type="button" className="link-button" disabled={busy || !role.modelKey && !role.agent} onClick={() => request('role/roster', {roleId: role.id})}>Save to roster</button>
      <button type="button" className="link-button" disabled={busy || role.kind === 'lead'} onClick={() => request('role/remove', {roleId: role.id}).then(onDone)}>Remove role</button>
    </div>
  </div>;
}

// Which stages wait for the owner, the organization's ceilings, the stand-up time, and tickets that appear on a schedule.
function Settings({state, busy, request}) {
  const org = state.organization;
  const [tokens, setTokens] = useState(org.budget?.paidTokensPerDay ?? '');
  const [money, setMoney] = useState(org.budget?.moneyPerDay ?? '');
  const [standup, setStandup] = useState(org.standupAt || '');
  const [title, setTitle] = useState('');
  const [when, setWhen] = useState('weekdays at 9:00');
  const [report, setReport] = useState('');
  const toggle = stage => request('update', {gates: gateChoices(org.gates, stage)});
  const number = value => value === '' || Number.isNaN(Number(value)) ? undefined : Number(value);
  const saveCeilings = () => request('update', {budget: {...(number(tokens) !== undefined ? {paidTokensPerDay: number(tokens)} : {}), ...(number(money) !== undefined ? {moneyPerDay: number(money)} : {})}});
  return <section className="local-model-panel room-card" aria-label="Approvals, ceilings and routines">
    <span className="eyebrow">YOU DECIDE</span>
    <h2>Approvals, ceilings and routines</h2>
    <p className="room-sub">Wait for my approval after</p>
    <div className="button-row org-gates">{STAGES.map(stage => <label key={stage}><input type="checkbox" checked={org.gates.includes(stage)} disabled={busy} onChange={() => toggle(stage)}/> {STAGE_TITLE[stage]}</label>)}</div>
    <p className="room-empty">A gate shows in the Inbox with the work to read. Approve it, or send it back with a note.</p>
    <p className="room-sub">Daily ceilings on paid work for the whole organization ({ceilingText(org.budget)})</p>
    <div className="button-row">
      <label className="org-pick">Paid tokens a day<input className="room-input" inputMode="numeric" value={tokens} disabled={busy} onChange={event => setTokens(event.target.value)}/></label>
      <label className="org-pick">Money a day<input className="room-input" inputMode="decimal" value={money} disabled={busy} onChange={event => setMoney(event.target.value)}/></label>
      <button type="button" className="secondary" disabled={busy} onClick={saveCeilings}>Save ceilings</button>
    </div>
    <p className="room-empty">Reaching a ceiling pauses the organization and leaves a note in the Inbox. Local work is measured, never limited. Money uses the prices you enter on each role.</p>
    <p className="room-sub">Daily stand-up report</p>
    <div className="button-row">
      <input className="room-input" aria-label="When the stand-up is made" value={standup} placeholder="daily at 9:00, or empty for never" disabled={busy} onChange={event => setStandup(event.target.value)}/>
      <button type="button" className="secondary" disabled={busy} onClick={() => request('update', {standupAt: standup})}>Save</button>
      <button type="button" className="secondary" disabled={busy} onClick={async () => {const answer = await request('standup', {}); if (answer?.text) setReport(answer.text);}}>Make one now</button>
    </div>
    {report && <pre className="org-report">{report}</pre>}
    <p className="room-sub">Routines: tickets that appear on a schedule</p>
    {org.routines?.length ? <ul className="room-list">{org.routines.map(item => <li key={item.id}><div><strong>{item.title}</strong><em className="room-role">{item.whenText}</em></div><div className="button-row"><button type="button" className="link-button" disabled={busy} onClick={() => request('routine/remove', {routineId: item.id})}>Remove</button></div></li>)}</ul> : <p className="room-empty">No routines.</p>}
    <div className="button-row">
      <input className="room-input" aria-label="Routine ticket title" value={title} maxLength={120} placeholder="Ticket to make, for example Check for outdated packages" disabled={busy} onChange={event => setTitle(event.target.value)}/>
      <input className="room-input" aria-label="When" value={when} disabled={busy} onChange={event => setWhen(event.target.value)}/>
      <button type="button" className="secondary" disabled={busy || !title.trim()} onClick={async () => {if (await request('routine/add', {title: title.trim(), when})) setTitle('');}}>Add routine</button>
    </div>
  </section>;
}

// Who did what today, paid and local apart.
function Ledger({state}) {
  const ledger = state.ledger;
  return <section className="local-model-panel room-card" aria-label="Ledger">
    <span className="eyebrow">LEDGER</span>
    <h2>Today</h2>
    <p className="section-intro">{ledger.summary}</p>
    {ledger.lines.length > 0 && <ul className="room-list">{ledger.lines.map(line => <li key={line.roleName}><div><strong>{line.roleName}</strong><em className="room-role">{line.runs} {line.runs === 1 ? 'run' : 'runs'}</em></div>
      <div className="button-row"><span className={`privacy-tag${line.paid ? ' leaves' : ''}`}>{line.paid ? 'Paid' : 'Local'}</span><small>{(line.prompt + line.completion).toLocaleString()} tokens{line.money ? ` · about ${moneyText(line.money)}` : ''}</small></div></li>)}</ul>}
  </section>;
}
