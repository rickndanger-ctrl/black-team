import React, {useEffect, useRef, useState} from 'react';
import Markdown from './Markdown.jsx';
import {api, post} from './http.mjs';
import MicButton from './Dictate.jsx';

// The Room page: a team of saved models, cloud models and subscription agents working on one project.
// The engine decides who may take part, what leaves this computer and what each digest covers; this page shows its answers.
const FINISHED = ['done', 'stopped', 'failed'];
const PHASE = {planning: 'Planning', working: 'Working', reviewing: 'Reviewing', reporting: 'Writing the report'};
const STATE = {todo: 'To do', doing: 'Doing', review: 'Review', done: 'Done'};
const JOB = {queued: 'Waiting', running: 'Working', done: 'Done', failed: 'Failed', stopped: 'Stopped'};
const COLUMNS = ['todo', 'doing', 'review', 'done'];
const PERMISSIONS = [['ask', 'Ask'], ['edit', 'Edit'], ['auto', 'Auto']];
const WORK = [['code', 'Code'], ['chat', 'Chat']];
const when = value => value ? new Date(value).toLocaleString(undefined, {month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'}) : '';

function Banner({kind = 'error', children, onClose}) {
  return <div className={`notice${kind === 'error' ? ' error' : ''}`} role={kind === 'error' ? 'alert' : 'status'}><p>{children}</p>{onClose && <button aria-label="Dismiss message" onClick={onClose}>×</button>}</div>;
}

export default function Room({status, project, onOpenChat}) {
  const projects = status.projects || [];
  const firstProject = id => projects.some(item => item.id === id) ? id : projects[0]?.id || null;
  const [projectId, setProjectId] = useState(() => firstProject(project));
  const [room, setRoom] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [roster, setRoster] = useState([]);
  const live = useRef(true);
  const shown = useRef(projectId);
  useEffect(() => {live.current = true; return () => {live.current = false;};}, []);

  // Each writing box gets a microphone when this computer has a dictation tool.
  const mic = (field, value, disabled) => status.dictation && <MicButton field={field} value={value} disabled={disabled} onError={setError}/>;

  // A quiet read is a background refresh: it leaves the error on the page alone, whether it works or not.
  const read = async (id, quiet = false) => {
    try {
      const next = await api(`/api/room?project=${encodeURIComponent(id)}`);
      if (live.current && shown.current === id) {setRoom(next); if (!quiet) setError('');}
    } catch (cause) {
      if (live.current && shown.current === id && !quiet) setError(cause.message);
    }
  };
  // The saved agents belong to this computer, not to a project: read on load and after each roster call.
  const readRoster = async () => {
    try {
      const next = await api('/api/room/roster');
      if (live.current) setRoster(next.agents || []);
    } catch (cause) {
      if (live.current) setError(cause.message);
    }
  };
  useEffect(() => {readRoster();}, []);
  // A different project starts from its own room; nothing from the last one is kept.
  useEffect(() => {
    shown.current = projectId;
    setRoom(null); setError('');
    if (projectId) read(projectId);
  }, [projectId]);
  // The project list can change under the page (a project removed): fall back to the first one.
  useEffect(() => {
    if (projectId && !projects.some(item => item.id === projectId)) setProjectId(projects[0]?.id || null);
  }, [projects, projectId]);

  // While a team run is going or a task is in progress, the room is read every 1.5 s, the way the conversation view polls.
  const team = room?.team;
  const running = Boolean(team && !FINISHED.includes(team.phase)) || Boolean(room?.tasks?.some(task => task.status === 'doing'));
  useEffect(() => {
    if (!projectId || !running) return undefined;
    const timer = window.setInterval(() => read(projectId), 1500);
    return () => window.clearInterval(timer);
  }, [projectId, running]);

  // With nothing running, the room is still read every 10 s and when the window comes back into view, so a change made
  // somewhere else (the black-team command, the phone) shows without leaving the page.
  useEffect(() => {
    if (!projectId || running) return undefined;
    const refresh = () => {if (document.visibilityState === 'visible') read(projectId, true);};
    const timer = window.setInterval(refresh, 10000);
    window.addEventListener('focus', refresh);
    document.addEventListener('visibilitychange', refresh);
    return () => {window.clearInterval(timer); window.removeEventListener('focus', refresh); document.removeEventListener('visibilitychange', refresh);};
  }, [projectId, running]);

  // One call to the engine. Its error shows on the page; the answer is returned to the card that asked.
  const request = async (route, body) => {
    const id = projectId;
    setBusy(true); setError('');
    try {
      return await post(`/api/room/${route}`, {project: id, ...body});
    } catch (cause) {
      if (live.current) setError(cause.message);
      return null;
    } finally {
      if (live.current) setBusy(false);
    }
  };
  // A change is followed by a fresh read of the room, so every card shows the same state.
  const change = async (route, body) => {
    const id = projectId;
    const answer = await request(route, body);
    if (answer && live.current && shown.current === id) await read(id);
    return answer;
  };

  // A roster call returns the new list of saved agents; a call that changes the room is followed by a fresh read of it.
  const rosterCall = async (route, body, inRoom = false) => {
    const answer = await (inRoom ? change : request)(route, body);
    if (answer?.agents) setRoster(answer.agents); else if (answer) await readRoster();
    return answer;
  };

  if (!projects.length) return <section className="local-model-panel">
    <p>Start a project in the sidebar first; a room belongs to a project.</p>
    <div className="button-row"><button type="button" className="link-button" onClick={onOpenChat}>Open Chat / Code, then press + beside Projects</button></div>
  </section>;

  return <>
    <div className="room-project"><span>Project</span><select className="agent-picker" aria-label="Project" value={projectId || ''} onChange={event => setProjectId(event.target.value)}>{projects.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select></div>
    {error && <Banner onClose={() => setError('')}>{error}</Banner>}
    {!room ? <p className="memory-empty">Opening the room…</p> : <>
      <Members key={`members-${projectId}`} room={room} status={status} busy={busy} change={change} mic={mic} roster={roster} rosterCall={rosterCall}/>
      <TeamRun key={`team-${projectId}`} room={room} busy={busy} running={running} request={request} change={change} mic={mic}/>
      <Tasks key={`tasks-${projectId}`} room={room} busy={busy} running={running} change={change} mic={mic}/>
      <HandOff key={`handoff-${projectId}`} room={room} busy={busy} running={running} request={request} change={change}/>
      <RoomLog room={room}/>
    </>}
  </>;
}

// The saved models and installed agents that can be picked, shared by the add row and the saved-agent form.
function memberOptions(status) {
  const agents = (status.agents || []).filter(agent => agent.installed);
  const models = status.models || [];
  return [
    ...agents.map(agent => ({value: `agent:${agent.engine}`, label: agent.name, agent})),
    ...models.map(model => ({value: `model:${model.key}`, label: model.kind === 'cloud' ? `${model.name} · Cloud` : model.name, model})),
  ];
}

// A picker row: choose a model or agent, give it a role and a permission or kind of work, then press the button.
// onSubmit gets the body the engine expects and returns a truthy answer when it worked.
function MemberPicker({status, busy, mic, label, pickLabel, button, onSubmit}) {
  const roleBox = useRef(null);
  const options = memberOptions(status);
  const [pick, setPick] = useState('');
  const [role, setRole] = useState('');
  const [permission, setPermission] = useState('edit');
  const [work, setWork] = useState('code');
  const chosen = options.find(option => option.value === pick) || options[0];
  const submit = async () => {
    if (!chosen) return;
    const body = chosen.agent
      ? {name: chosen.agent.name, role: role.trim(), agent: chosen.agent.engine, permission}
      : {name: chosen.model.name, role: role.trim(), modelKey: chosen.model.key, work};
    if (await onSubmit(body)) setRole('');
  };
  return <div className="room-add">
    <p className="room-sub">{label}</p>
    <div className="button-row">
      <select className="agent-picker" aria-label={pickLabel} value={chosen?.value || ''} disabled={busy} onChange={event => setPick(event.target.value)}>{options.map(option => <option key={option.value} value={option.value}>{option.label}</option>)}</select>
      <span className="room-field"><input ref={roleBox} className="room-input" value={role} maxLength={80} placeholder="Role, for example builder or reviewer" aria-label="Role" disabled={busy} onChange={event => setRole(event.target.value)}/>{mic(roleBox, role, busy)}</span>
      {chosen?.agent
        ? <select className="agent-picker" aria-label="Member permission" value={permission} disabled={busy} onChange={event => setPermission(event.target.value)}>{PERMISSIONS.map(([id, text]) => <option key={id} value={id}>{text}</option>)}</select>
        : <select className="agent-picker" aria-label="Member work" value={work} disabled={busy} onChange={event => setWork(event.target.value)}>{WORK.map(([id, text]) => <option key={id} value={id}>{text}</option>)}</select>}
      <button type="button" className="primary" disabled={busy || !chosen} onClick={submit}>{button}</button>
    </div>
  </div>;
}

// Who is on the team, the row that adds a member, and the saved agents kept on this computer for any room.
function Members({room, status, busy, change, mic, roster, rosterCall}) {
  const hasOptions = memberOptions(status).length > 0;
  const [creating, setCreating] = useState(false);
  return <section className="local-model-panel room-card" aria-label="Who is on this team">
    <span className="eyebrow">TEAM</span>
    <h2>Who is on this team</h2>
    {room.members.length
      ? <ul className="room-list">{room.members.map(member => <li key={member.id}>
          <div>
            <strong>{member.name}{member.role && <em className="room-role">{member.role}</em>}</strong>
            {!member.usable && <p className="message-note">{member.reason}</p>}
          </div>
          <div className="button-row">
            <span className={`privacy-tag${member.kind === 'cloud' ? ' leaves' : ''}`}>{member.kind === 'cloud' ? `Cloud · ${member.provider}` : 'Local'}</span>
            <button type="button" className="link-button" disabled={busy} onClick={() => rosterCall('roster/save', {memberId: member.id})}>Save to roster</button>
            <button type="button" className="link-button" disabled={busy} onClick={() => change('member/remove', {memberId: member.id})}>Remove</button>
          </div>
        </li>)}</ul>
      : <p className="room-empty">No members yet. Add one below.</p>}
    {hasOptions
      ? <MemberPicker status={status} busy={busy} mic={mic} label="Add a member" pickLabel="New member" button="Add" onSubmit={body => change('member/add', body)}/>
      : <p className="room-empty">Save a model in Settings, or install Claude Code or Codex, to add a member.</p>}
    <p className="room-sub">Saved agents</p>
    <p className="room-empty">Agents saved on this computer, ready to add to any room.</p>
    {roster.length
      ? <ul className="room-list">{roster.map(item => <li key={item.entry.id}>
          <div>
            <strong>{item.entry.name}{item.entry.role && <em className="room-role">{item.entry.role}</em>}</strong>
            {!item.usable && item.reason && <p className="message-note">{item.reason}</p>}
          </div>
          <div className="button-row">
            <span className={`privacy-tag${item.kind === 'cloud' ? ' leaves' : ''}`}>{item.kind === 'cloud' ? `Cloud · ${item.provider}` : 'Local'}</span>
            <button type="button" className="secondary" disabled={busy || !item.usable} onClick={() => rosterCall('roster/add', {rosterId: item.entry.id}, true)}>Add to this room</button>
            <button type="button" className="link-button" disabled={busy} onClick={() => rosterCall('roster/remove', {rosterId: item.entry.id})}>Remove</button>
          </div>
        </li>)}</ul>
      : <p className="room-empty">No saved agents yet. Use Save to roster on a member, or create one below.</p>}
    {creating
      ? <>
          {hasOptions
            ? <MemberPicker status={status} busy={busy} mic={mic} label="Create a saved agent" pickLabel="Saved agent" button="Save agent" onSubmit={body => rosterCall('roster/create', body)}/>
            : <p className="room-empty">Save a model in Settings, or install Claude Code or Codex, to create a saved agent.</p>}
          <div className="button-row"><button type="button" className="link-button" onClick={() => setCreating(false)}>Done</button></div>
        </>
      : <div className="room-add-start"><button type="button" className="secondary" onClick={() => setCreating(true)}>Create a saved agent</button></div>}
  </section>;
}

// The team run: the goal, the lead and reviewer, the agreement to confirm, the team's conversation and the report.
function TeamRun({room, busy, running, request, change, mic}) {
  const goalBox = useRef(null);
  const members = room.members;
  const [goal, setGoal] = useState('');
  const [lead, setLead] = useState('');
  const [reviewer, setReviewer] = useState('');
  const [agreement, setAgreement] = useState(null);
  const defaultLead = (members.find(member => member.agent === 'claude-code' && member.canDrive) || members.find(member => member.canDrive) || members.find(member => member.agent === 'claude-code') || members[0] || {}).id || '';
  const leadId = members.some(member => member.id === lead) ? lead : defaultLead;
  const reviewerId = members.some(member => member.id === reviewer) ? reviewer : '';
  const team = room.team;
  const leader = members.find(member => member.id === leadId);
  // A paid member that can drive, with others in the room, drives: it hands pieces of work to the rest and checks them.
  const drives = Boolean(leader?.canDrive && members.length > 1);
  const others = members.filter(member => member.id !== leadId);
  const canRun = !running && !busy && goal.trim() !== '' && leadId !== '';
  const look = async () => {
    const next = await request('team/preview', {goal: goal.trim(), leadId, ...(reviewerId && !drives ? {reviewerId} : {})});
    if (next) setAgreement(next);
  };
  // The run is started with the preview's own fields, so what was agreed is what runs.
  const start = async () => {
    const preview = agreement;
    const started = await change('team/run', {goal: preview.goal, leadId: preview.leadId, ...(preview.reviewerId && preview.mode !== 'driven' ? {reviewerId: preview.reviewerId} : {}), digest: preview.digest});
    if (started) setAgreement(null);
  };
  const cloud = agreement?.members?.filter(member => member.kind === 'cloud') || [];
  return <section className="local-model-panel room-card" aria-label="Team run">
    <span className="eyebrow">TEAM RUN</span>
    <h2>Give the team a goal</h2>
    <div className="room-goal"><textarea ref={goalBox} aria-label="Goal" value={goal} maxLength={2000} placeholder="What should the team do?" disabled={running} onChange={event => {setGoal(event.target.value); setAgreement(null);}}/>{mic(goalBox, goal, running)}</div>
    <div className="button-row room-run-row">
      <label><span>{drives ? 'Driver' : 'Lead'}</span><select className="agent-picker" aria-label={drives ? 'Driver' : 'Lead'} value={leadId} disabled={running || busy || !members.length} onChange={event => {setLead(event.target.value); setAgreement(null);}}>{members.map(member => <option key={member.id} value={member.id}>{member.name}</option>)}</select></label>
      {!drives && <label><span>Reviewer</span><select className="agent-picker" aria-label="Reviewer" value={reviewerId} disabled={running || busy || !members.length} onChange={event => setReviewer(event.target.value)}><option value="">No reviewer</option>{members.map(member => <option key={member.id} value={member.id}>{member.name}</option>)}</select></label>}
      <button type="button" className="primary" disabled={!canRun} onClick={look}>Run team</button>
    </div>
    {drives && <p className="room-empty">Driver: {leader.name}. Its team: {others.map(member => `${member.name} (${member.kind === 'cloud' ? 'paid' : 'local'})`).join(', ')}. The driver works on the goal, hands real pieces of work to its team, waits for the results and checks them.</p>}
    {!members.length && <p className="room-empty">Add members to the room before starting a team run.</p>}
    {running && <div className="room-progress"><span className="spinner" aria-hidden="true"/><strong>{PHASE[team.phase] || 'Working'}</strong><button type="button" className="secondary" title="Stops the driver and every hand-off running beneath it" aria-label="Stop the driver and everything beneath it" onClick={() => change('team/stop', {})}>Stop</button></div>}
    {agreement && !running && <section className="privacy-notice room-agreement" aria-label="Agreement">
      <span className="eyebrow">AGREEMENT</span>
      <p>{agreement.agreement}</p>
      {limitsLine(agreement.caps)}
      {cloud.length > 0 && <p>Cloud members: {cloud.map(member => `${member.name} (${member.provider})`).join(', ')}.</p>}
      <div className="button-row">
        <button type="button" className="primary" disabled={busy} onClick={start}>Start this run</button>
        <button type="button" className="secondary" disabled={busy} onClick={() => setAgreement(null)}>Cancel</button>
      </div>
    </section>}
    {team?.mode === 'driven' && <HandOffs delegations={team.delegations || []}/>}
    {team?.ledger && <Ledger ledger={team.ledger}/>}
    {team && <div className="room-conversation">
      <span className="eyebrow">WHAT THE TEAM IS DOING</span>
      {(team.log || []).map((entry, index) => <div className="room-line" key={index}>
        <div><strong>{entry.memberName ? entry.memberName.toUpperCase() : 'TEAM'}</strong><span className="room-kind">{entry.kind}</span></div>
        <Markdown text={entry.text}/>
      </div>)}
    </div>}
    {team?.phase === 'done' && <div className="room-report"><span className="eyebrow">REPORT</span><Markdown text={team.report}/>{team.ledger?.summary && <p className="message-note">{team.ledger.summary}</p>}</div>}
    {team?.phase === 'stopped' && team.message && <Banner kind="notice">{team.message}</Banner>}
    {team?.phase === 'failed' && team.message && <Banner>{team.message}</Banner>}
  </section>;
}

// The limits of a driven run, as small text under the agreement.
function limitsLine(caps) {
  if (!caps) return null;
  return <p className="message-note">Limits: up to {caps.delegations} hand-offs, {caps.minutes} minutes, {Number(caps.paidTokens).toLocaleString()} tokens on paid services.</p>;
}

// The jobs the driver has handed to its team, live: who has each one, how it is going and what came back.
function HandOffs({delegations}) {
  return <div className="room-conversation">
    <span className="eyebrow">HAND-OFFS</span>
    {!delegations.length && <p className="room-empty">The driver has not handed anything over yet.</p>}
    {delegations.map(job => <div className="room-line" key={job.id}>
      <div>
        <strong>{(job.memberName || 'Member').toUpperCase()}</strong>
        <span className="room-kind">{JOB[job.status] || job.status}</span>
        {job.status !== 'queued' && job.seconds > 0 && <span className="room-kind">{Math.round(job.seconds)} s</span>}
        {job.changed > 0 && <span className="room-kind">{job.changed} files changed</span>}
        {!job.write && <span className="room-kind">read-only</span>}
      </div>
      <p>{job.title}</p>
      {job.result && <details><summary>Result</summary><Markdown text={job.result}/></details>}
      {job.error && <p className="message-note">{job.error}</p>}
    </div>)}
  </div>;
}

// What the run cost: the summary sentence first, then who used what.
function Ledger({ledger}) {
  const number = (line, value) => line.measured ? Number(value || 0).toLocaleString() : 'not measured';
  return <div className="room-report">
    <span className="eyebrow">WHAT IT USED</span>
    {ledger.summary && <p><strong>{ledger.summary}</strong></p>}
    {(ledger.lines || []).length > 0 && <table className="room-ledger">
      <thead><tr><th>Member</th><th>Paid or Local</th><th>Read</th><th>Written</th><th>Time</th></tr></thead>
      <tbody>{ledger.lines.map((line, index) => <tr key={index}>
        <td>{line.name}{line.role && <em className="room-role">{line.role}</em>}</td>
        <td>{line.paid ? 'Paid' : 'Local'}</td>
        <td>{number(line, line.prompt)}</td>
        <td>{number(line, line.completion)}</td>
        <td>{Math.round(line.seconds || 0)} s</td>
      </tr>)}</tbody>
    </table>}
  </div>;
}

// The team's to-do list: four columns. Adding a task by hand is the optional path.
function Tasks({room, busy, running, change, mic}) {
  const titleBox = useRef(null);
  const [adding, setAdding] = useState(false);
  const [title, setTitle] = useState('');
  const [assignee, setAssignee] = useState('');
  const tasks = room.tasks || [];
  const add = async () => {
    const trimmed = title.trim();
    if (!trimmed) return;
    if (await change('task/add', {title: trimmed, ...(assignee ? {assignee} : {})})) {setTitle(''); setAssignee(''); setAdding(false);}
  };
  return <section className="local-model-panel room-card" aria-label="The team's to-do list">
    <span className="eyebrow">TASKS</span>
    <h2>The team&rsquo;s to-do list</h2>
    <p className="section-intro">In a team run the lead writes the tasks here and each one moves from To do to Done as members finish. You do not need to add anything. Click a task to see what was done.</p>
    {!tasks.length && <p className="room-empty">No tasks yet. Give the team a goal above and press Run team.</p>}
    <div className="room-columns">{COLUMNS.map(column => {
      const items = tasks.filter(task => task.status === column);
      return <div className="room-column" key={column}>
        <div className="room-col-head"><strong>{STATE[column]}</strong><small>{items.length}</small></div>
        {items.map(task => <TaskCard key={task.id} task={task} room={room} busy={busy} running={running} change={change} mic={mic}/>)}
      </div>;
    })}</div>
    {adding
      ? <div className="room-add">
          <p className="room-sub">Optional: give one member a single job without a team run. Say what should be done, choose who does it, press Add, then press Start on the task.</p>
          <div className="button-row">
            <span className="room-field"><input ref={titleBox} className="room-input" value={title} maxLength={200} placeholder="What should be done, in a few words" aria-label="Task title" disabled={busy} onChange={event => setTitle(event.target.value)}/>{mic(titleBox, title, busy)}</span>
            <select className="agent-picker" aria-label="Assignee" value={assignee} disabled={busy} onChange={event => setAssignee(event.target.value)}><option value="">Nobody yet</option>{room.members.map(member => <option key={member.id} value={member.id}>{member.name}</option>)}</select>
            <button type="button" className="primary" disabled={busy || running || !title.trim()} onClick={add}>Add</button>
            <button type="button" className="link-button" onClick={() => {setAdding(false); setTitle(''); setAssignee('');}}>Cancel</button>
          </div>
        </div>
      : <div className="room-add-start"><button type="button" className="secondary" disabled={running} onClick={() => setAdding(true)}>Add a task yourself</button></div>}
  </section>;
}

// One task: a card that opens in place to its detail, result, note and the actions for its state.
function TaskCard({task, room, busy, running, change, mic}) {
  const noteBox = useRef(null);
  const [open, setOpen] = useState(false);
  const [sendingBack, setSendingBack] = useState(false);
  const [note, setNote] = useState('');
  const locked = busy || running;
  const who = task.assignee ? (room.members.find(member => member.id === task.assignee)?.name || 'Unknown member') : 'Unassigned';
  const sendBack = async () => {
    if (await change('task/sendback', {taskId: task.id, note})) {setSendingBack(false); setNote('');}
  };
  return <div className="room-task">
    <button type="button" className="room-task-head" aria-expanded={open} onClick={() => setOpen(!open)}>
      <strong>{task.title}</strong>
      <span>{who}</span>
      <em className={`room-state ${task.status}${task.failed ? ' failed' : ''}`}>{STATE[task.status] || task.status}</em>
    </button>
    {open && <div className="room-task-body">
      {task.detail && <p>{task.detail}</p>}
      {task.changed ? <small>{task.changed} files changed</small> : null}
      {task.result && <Markdown text={task.result}/>}
      {task.note && <p>Note: {task.note}</p>}
      {(task.status === 'todo' && task.assignee) || task.status === 'review'
        ? <div className="button-row">
            {task.status === 'todo' && <button type="button" className="primary" disabled={locked} onClick={() => change('task/start', {taskId: task.id})}>Start</button>}
            {task.status === 'review' && <>
              <button type="button" className="primary" disabled={locked} onClick={() => change('task/accept', {taskId: task.id})}>Accept</button>
              {!sendingBack && <button type="button" className="secondary" disabled={locked} onClick={() => setSendingBack(true)}>Send back</button>}
            </>}
          </div>
        : null}
      {task.status === 'review' && sendingBack && <div className="room-add">
        <div className="button-row">
          <span className="room-field"><input ref={noteBox} className="room-input" value={note} maxLength={1000} placeholder="Note for the member" aria-label="Note for the member" disabled={locked} onChange={event => setNote(event.target.value)}/>{mic(noteBox, note, locked)}</span>
          <button type="button" className="primary" disabled={locked} onClick={sendBack}>Send back</button>
          <button type="button" className="link-button" disabled={locked} onClick={() => {setSendingBack(false); setNote('');}}>Cancel</button>
        </div>
      </div>}
    </div>}
  </div>;
}

// Hand a task to another member by hand. The exact text is shown first; nothing is sent until "Hand over".
function HandOff({room, busy, running, request, change}) {
  const tasks = room.tasks || [];
  const [taskId, setTaskId] = useState('');
  const [to, setTo] = useState('');
  const [includeResult, setIncludeResult] = useState(true);
  const [preview, setPreview] = useState(null);
  const task = tasks.find(item => item.id === taskId);
  const receivers = room.members.filter(member => member.id !== task?.assignee);
  const receiver = receivers.some(member => member.id === to) ? to : '';
  const look = async () => {
    const next = await request('handoff/preview', {taskId, to: receiver, includeResult});
    if (next) setPreview(next);
  };
  // The preview's own fields are sent back, with its digest, so what was shown is what goes.
  const handOver = async () => {
    const shown = preview;
    if (await change('handoff', {taskId: shown.taskId, to: shown.receiverId, title: shown.title, detail: shown.detail, includeResult: shown.includesResult, digest: shown.digest})) {
      setPreview(null); setTaskId(''); setTo('');
    }
  };
  return <section className="local-model-panel room-card" aria-label="Hand a task to a member">
    <span className="eyebrow">HAND-OFF</span>
    <h2>Hand a task to a member</h2>
    <p className="section-intro">Pick a task and a member. You see the exact text first, and nothing is sent until you press Hand over. The receiver gets a new To do task; nothing runs until someone presses Start on it.</p>
    {!tasks.length
      ? <p className="room-empty">No tasks to hand over yet.</p>
      : <>
          <div className="button-row">
            <select className="agent-picker" aria-label="Task" value={taskId} disabled={busy} onChange={event => {setTaskId(event.target.value); setTo(''); setPreview(null);}}><option value="">Choose a task</option>{tasks.map(item => <option key={item.id} value={item.id}>{item.title}</option>)}</select>
            <select className="agent-picker" aria-label="Hand to" value={receiver} disabled={busy || !task} onChange={event => {setTo(event.target.value); setPreview(null);}}><option value="">Choose a member</option>{receivers.map(member => <option key={member.id} value={member.id}>{member.name}</option>)}</select>
            <label className="room-check"><input type="checkbox" checked={includeResult} disabled={busy} onChange={event => {setIncludeResult(event.target.checked); setPreview(null);}}/>Include what was done</label>
            <button type="button" className="secondary" disabled={busy || running || !taskId || !receiver} onClick={look}>Preview hand-off</button>
          </div>
          {preview && <div className="room-handoff">
            <pre aria-label="Exact text to hand over">{preview.text}</pre>
            {preview.leavesThisMac && <p className="message-note">This leaves this computer and goes to {preview.provider}.</p>}
            <div className="button-row">
              <button type="button" className="primary" disabled={busy || running} onClick={handOver}>Hand over</button>
              <button type="button" className="secondary" disabled={busy} onClick={() => setPreview(null)}>Cancel</button>
            </div>
          </div>}
        </>}
  </section>;
}

// The room's log, newest first.
function RoomLog({room}) {
  const notes = room.notes || [];
  return <section className="local-model-panel room-card" aria-label="Room log">
    <span className="eyebrow">LOG</span>
    <h2>The room&rsquo;s log</h2>
    {notes.length
      ? <ul className="room-list room-log">{notes.map((note, index) => <li key={index}><time>{when(note.at)}</time><span>{note.text}</span></li>)}</ul>
      : <p className="room-empty">Nothing has happened in this room yet.</p>}
  </section>;
}
