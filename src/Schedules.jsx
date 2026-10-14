import React, {useCallback, useEffect, useState} from 'react';
import {EMPTY_FORM, PERMISSIONS, formFor, needsAttention, resultWords, stateWords, timeText, whenText} from './schedulesView.mjs';

// Messages sent on a schedule. Each run is a normal conversation in its project. The engine does the work (Service/Scheduler.swift) while Black
// Team is kept running in the background; this page lists, adds, edits, pauses, runs and removes. A phone sees the list and can open results.
export default function Schedules({call, onError, onOpenThread, readOnly = false}) {
  const [data, setData] = useState(null);
  const [form, setForm] = useState(null);
  const [busy, setBusy] = useState(false);
  const [removing, setRemoving] = useState('');
  const [notice, setNotice] = useState('');

  const load = useCallback(() => call('schedules').then(setData).catch(cause => onError(cause.message)), [call, onError]);
  useEffect(() => {
    load();
    const timer = window.setInterval(load, 5000);
    return () => window.clearInterval(timer);
  }, [load]);

  const act = async (route, body, done) => {
    setBusy(true); setNotice('');
    try {const next = await call(route, body); if (next && next.schedules) setData(next); if (done) setNotice(done); return true;}
    catch (cause) {onError(cause.message); return false;}
    finally {setBusy(false);}
  };
  const save = async event => {
    event.preventDefault();
    const body = {id: form.id || undefined, name: form.name, project: form.project, kind: form.kind, message: form.message, model: form.model, permission: form.permission, whenText: whenText(form), enabled: true};
    if (await act('schedules/save', body, form.id ? 'Saved.' : 'Added.')) {setForm(null); load();}
  };
  const set = (name, value) => setForm(previous => ({...previous, [name]: value}));

  if (!data) return <section className="local-model-panel room-card" aria-label="Schedules"><p className="room-empty">Loading…</p></section>;
  const schedules = data.schedules || [];
  const code = form?.kind === 'agent';

  return <section className="local-model-panel room-card" aria-label="Schedules">
    <span className="eyebrow">SCHEDULED WORK</span>
    <h2>Messages that send themselves</h2>
    <p className="section-intro">Each run is a normal conversation in its project, so it shows in your history and on your phone. Runs happen while Black Team is kept running in the background, even with this window closed. A run missed while this computer was off happens once when it starts again.</p>
    {!data.running && <div className="notice" role="status"><p>Nothing runs by itself yet. Turn on “Keep Black Team running in the background” in Settings, App &amp; data.</p></div>}
    {notice && <p className="inline-note" role="status">{notice}</p>}
    {schedules.length === 0 && !form && <p className="room-empty">No schedules yet.</p>}
    <ul className="room-list sched-list">{schedules.map(item => <li key={item.id} className={`sched-item ${item.state}`}>
      <div>
        <strong>{item.name}</strong><em className="room-role">{item.kind === 'chat' ? 'Chat' : 'Code'}{item.projectName ? ` · ${item.projectName}` : ''}{item.modelName ? ` · ${item.modelName}` : ''}</em>
        <p className="message-note">{item.whenDescription} · {stateWords(item.state)}{item.state === 'scheduled' && item.nextRun ? ` · next ${timeText(item.nextRun)}` : ''}</p>
        {item.kind === 'agent' && <p className="message-note">{item.permissionTitle}</p>}
        {item.lastRun && <p className={`message-note${needsAttention(item.lastRun.state) ? ' sched-attention' : ''}`}>Last run {timeText(item.lastRun.at)}: {resultWords(item.lastRun.state)}{item.lastRun.note && item.lastRun.state !== 'running' ? `. ${item.lastRun.note}` : ''}{item.lastRun.threadId && onOpenThread && <> <button type="button" className="text-button" onClick={() => onOpenThread(item.lastRun.threadId)}>Open the conversation</button></>}</p>}
      </div>
      {!readOnly && <div className="button-row">
        <button type="button" className="secondary" disabled={busy || ['running', 'waiting', 'queued'].includes(item.state)} onClick={() => act('schedules/run', {id: item.id}, `${item.name} will run as soon as the model is free.`)}>Run now</button>
        <button type="button" className="secondary" disabled={busy} onClick={() => act('schedules/pause', {id: item.id, paused: item.enabled})}>{item.enabled ? 'Pause' : 'Resume'}</button>
        <button type="button" className="secondary" disabled={busy} onClick={() => setForm(formFor(item))}>Edit</button>
        {removing === item.id
          ? <><button type="button" className="primary" disabled={busy} onClick={async () => {await act('schedules/remove', {id: item.id}); setRemoving('');}}>Remove it</button><button type="button" className="text-button" onClick={() => setRemoving('')}>Keep it</button></>
          : <button type="button" className="text-button" disabled={busy} onClick={() => setRemoving(item.id)}>Remove</button>}
      </div>}
    </li>)}</ul>
    {!readOnly && !form && schedules.length < (data.limits?.schedules || 20) && <div className="room-add-start"><button type="button" className="primary" onClick={() => setForm({...EMPTY_FORM, project: data.projects?.[0]?.id || '', date: new Date(Date.now() + 86400000).toISOString().slice(0, 10)})}>Add a schedule</button></div>}
    {!readOnly && form && <form className="room-add sched-form" onSubmit={save} aria-label={form.id ? 'Edit schedule' : 'New schedule'}>
      <span className="room-sub">{form.id ? 'Edit schedule' : 'New schedule'}</span>
      <label className="form-field"><span>Name</span><input className="room-input" value={form.name} maxLength={60} required disabled={busy} onChange={event => set('name', event.target.value)} placeholder="Morning test check"/></label>
      <div className="sched-row">
        <label className="form-field"><span>Project</span><select className="agent-picker" value={form.project} disabled={busy} onChange={event => set('project', event.target.value)}><option value="">General workspace</option>{(data.projects || []).map(project => <option key={project.id} value={project.id}>{project.name}</option>)}</select></label>
        <label className="form-field"><span>Kind</span><select className="agent-picker" value={form.kind} disabled={busy} onChange={event => set('kind', event.target.value)}><option value="agent">Code</option><option value="chat">Chat</option></select></label>
        <label className="form-field"><span>Model</span><select className="agent-picker" value={form.model} disabled={busy} onChange={event => set('model', event.target.value)}><option value="">The model in use</option>{(data.models || []).map(model => <option key={model.key} value={model.key}>{model.name}</option>)}</select></label>
      </div>
      <label className="form-field"><span>Message to send</span><textarea className="room-input" value={form.message} maxLength={16000} required rows={3} disabled={busy} onChange={event => set('message', event.target.value)} placeholder="Run the tests and tell me what changed."/></label>
      <div className="sched-row">
        <label className="form-field"><span>When</span><select className="agent-picker" value={form.every} disabled={busy} onChange={event => set('every', event.target.value)}><option value="every">Every so often</option><option value="daily">Every day</option><option value="weekdays">Weekdays</option><option value="once">Once</option></select></label>
        {form.every === 'every' && <><label className="form-field"><span>How often</span><input className="room-input" type="number" min="1" max="10080" value={form.gap} disabled={busy} onChange={event => set('gap', event.target.value)}/></label>
          <label className="form-field"><span>Unit</span><select className="agent-picker" value={form.unit} disabled={busy} onChange={event => set('unit', event.target.value)}><option value="minutes">minutes</option><option value="hours">hours</option></select></label></>}
        {form.every === 'once' && <label className="form-field"><span>Date</span><input className="room-input" type="date" value={form.date} required disabled={busy} onChange={event => set('date', event.target.value)}/></label>}
        {form.every !== 'every' && <label className="form-field"><span>Time</span><input className="room-input" type="time" value={form.time} required disabled={busy} onChange={event => set('time', event.target.value)}/></label>}
      </div>
      {code && <fieldset className="sched-permission" disabled={busy}><legend className="room-sub">What it may do without asking</legend>{PERMISSIONS.map(([id, title, detail]) => <label key={id} className="checkbox-field"><input type="radio" name="permission" checked={form.permission === id} onChange={() => set('permission', id)}/><span><strong>{title}</strong><small>{detail}</small></span></label>)}</fieldset>}
      {code && form.permission !== 'read-only' && <p className="inline-note">A question waits in your Inbox. If nobody answers in time, the run ends as “not approved”.</p>}
      <div className="button-row"><button type="submit" className="primary" disabled={busy}>{form.id ? 'Save' : 'Add schedule'}</button><button type="button" className="text-button" disabled={busy} onClick={() => setForm(null)}>Cancel</button></div>
    </form>}
    <p className="room-empty">{data.runsToday} of {data.limits?.runsPerDay} runs used today. Up to {data.limits?.schedules} schedules.</p>
  </section>;
}
