import React, {useCallback, useEffect, useState} from 'react';
import {native} from './desktop.mjs';
import {approvableIds, cardView, readyMessage, resultKey, stateLabel} from './setupPlan.mjs';
import {onModelReady} from './setupOffer.mjs';

// "Set up your agents": one approval connects every agent found on this computer and installs Hermes. The engine makes the plan
// and runs the steps (Desktop/DesktopSetup.swift); progress comes back in status.setupRun. Nothing is installed, downloaded or
// connected until Approve. `mode` says where the card is: 'welcome' (right after the first model is ready), 'workspace' (offered when
// something new is found, unless the person said "Not now") or 'settings' (the person asked, so it is always shown).
const reasons = {welcome: 'model-ready', workspace: 'found-something-new', settings: 'asked'};
const size = bytes => bytes >= 1e6 ? `${(bytes / 1e6).toFixed(1)} MB/s` : `${Math.round(bytes / 1e3)} kB/s`;
const closedKey = 'black-team-setup-closed';
const readClosed = () => {try {return window.sessionStorage.getItem(closedKey);} catch {return null;}};
const writeClosed = value => {try {window.sessionStorage.setItem(closedKey, value);} catch {/* a private window keeps nothing; the result shows again */}};

export default function SetupCard({status, busy, mode = 'workspace', onChat, onDone}) {
  const run = status.setupRun || {};
  const [offer, setOffer] = useState(null);
  const [picked, setPicked] = useState([]);
  const [titles, setTitles] = useState({});
  const [hidden, setHidden] = useState(false);
  const [closed, setClosed] = useState(readClosed);
  const [reviewing, setReviewing] = useState(null);
  const [asking, setAsking] = useState(false);
  const [error, setError] = useState('');
  const asked = mode === 'settings';

  const load = useCallback(async () => {
    try {
      const next = await native('setup-plan', {reason: reasons[mode] || 'asked'});
      setOffer(next);
      setPicked(approvableIds(next.plan));
    } catch (cause) {setError(cause.message);}
  }, [mode]);
  // Read again when a run ends, so what it did is reflected, and when a model has just become ready.
  useEffect(() => {load();}, [load, run.running, run.done]);
  useEffect(() => onModelReady(() => {setHidden(false); load();}), [load]);

  const ask = async (action, data) => {
    setAsking(true); setError('');
    try {return await native(action, data);} catch (cause) {setError(cause.message); return null;} finally {setAsking(false);}
  };
  const approve = async () => {
    const steps = offer?.plan?.steps || [];
    setTitles(Object.fromEntries(steps.map(step => [step.id, step.title])));
    setClosed(null);
    await ask('setup-apply', {ids: steps.map(step => step.id).filter(id => picked.includes(id))});
  };
  const notNow = async () => {
    setHidden(true);
    await ask('setup-dismiss');
    onDone?.();
  };
  const close = () => {writeClosed(resultKey(run)); setClosed(resultKey(run)); setHidden(true); onDone?.();};

  // A finished run is shown until it is closed; "Review and try again" puts the plan back in its place.
  const key = resultKey(run);
  const view = cardView({offer, run: reviewing === key ? {} : run, hidden: hidden || (Boolean(run.done) && reviewing !== key && closed === key), asked});
  if (!view) return error ? <p className="inline-note error-text" role="alert">{error}</p> : null;
  const steps = offer?.plan?.steps || [];
  const nameOf = id => titles[id] || steps.find(step => step.id === id)?.title || id;

  if (view === 'progress') {
    return <section className="setup-card" aria-busy="true" aria-label="Setting up your agents">
      <span className="eyebrow">SETTING UP</span><h2>Setting up your agents</h2>
      <ul className="setup-steps">{(run.steps || []).map(row => {
        const percent = typeof row.fraction === 'number' ? Math.round(row.fraction * 100) : null;
        return <li key={row.id} className={`setup-step ${row.status}`}>
          <div><strong>{nameOf(row.id)}</strong><small role="status">{row.status === 'waiting' ? 'Waiting' : row.stage || 'Working…'}{percent === null || row.status !== 'running' ? '' : ` · ${percent}%`}{row.bytesPerSecond > 0 ? ` · ${size(row.bytesPerSecond)}` : ''}</small></div>
          {row.status === 'running' && percent !== null && <progress max="100" value={percent} aria-label={nameOf(row.id)}/>}
        </li>;
      })}</ul>
      <div className="button-row"><button type="button" className="secondary" disabled={asking} onClick={() => ask('setup-cancel')}>Stop</button></div>
      <small>Stopping keeps what was downloaded, so the next try carries on from there.</small>
    </section>;
  }

  if (view === 'result') {
    const headline = run.error ? {title: 'Setup did not finish', ready: false} : readyMessage(run);
    const results = run.results || [];
    const failed = results.filter(result => result.status === 'failed' || result.status === 'stopped');
    const more = steps.some(step => step.state === 'will-do' && step.kind !== 'note');
    return <section className="setup-card" aria-label="Setup result">
      <span className="eyebrow">{headline.ready ? 'ALL SET' : 'NOT FINISHED'}</span><h2 role="status">{headline.title}</h2>
      {run.error && <p className="inline-note error-text" role="alert">{run.error}</p>}
      <ul className="setup-steps">{results.map(result => <li key={result.id} className={`setup-step ${result.status}`}><div><strong>{nameOf(result.id)}</strong><small>{result.message}</small></div></li>)}</ul>
      {failed.length > 0 && <p className="inline-note error-text" role="alert">Something did not finish. Nothing else was affected. You can try again.</p>}
      <div className="button-row">
        {headline.ready && onChat && <button type="button" className="primary" onClick={() => {close(); onChat('agent');}}>Start an agent conversation</button>}
        {(failed.length > 0 || more) && <button type="button" className="secondary" disabled={asking} onClick={() => {setReviewing(key); setHidden(false); load();}}>Review and try again</button>}
        <button type="button" className="text-button" onClick={close}>Close</button>
      </div>
    </section>;
  }

  const todo = steps.filter(step => step.kind !== 'note' && step.state !== 'done');
  const notes = steps.filter(step => step.kind === 'note');
  const nothing = approvableIds(offer.plan).length === 0;
  return <section className="setup-card" aria-label="Set up your agents">
    <span className="eyebrow">{mode === 'welcome' ? 'STEP 2 OF 2 · YOUR AGENTS' : 'SET UP EVERYTHING'}</span>
    <h2>Set up your agents</h2>
    <p>{nothing ? 'Everything Black Team can set up on this computer is done.' : `One approval connects the agents found on this computer to ${status.config?.model?.name || 'your model'}. Nothing is installed or changed until you approve.`}</p>
    <ul className="setup-steps">{steps.filter(step => step.kind !== 'note').map(step => <li key={step.id} className={`setup-step ${step.state}`}>
      <div><strong>{step.title}</strong><small>{step.state === 'needs-something' && step.needs ? step.needs : step.detail}</small></div>
      <em>{stateLabel(step.state)}</em>
    </li>)}</ul>
    {todo.some(step => step.state === 'will-do') && <details className="setup-details"><summary>Details: what each step downloads or changes</summary>
      {steps.filter(step => step.state === 'will-do' && step.kind !== 'note').map(step => <fieldset key={step.id} disabled={asking}>
        <label className="checkbox-field"><input type="checkbox" checked={picked.includes(step.id)} onChange={event => setPicked(event.target.checked ? [...picked, step.id] : picked.filter(id => id !== step.id))}/><strong>{step.title}</strong></label>
        <ul>{step.changes.map(change => <li key={change}>{change}</li>)}</ul>
      </fieldset>)}
      <small>Untick a step to leave it out. Some steps need an earlier one (Hermes has to be installed before it can be connected).</small>
    </details>}
    {notes.map(note => <div className="inline-note" key={note.id}>
      <strong>{note.title}</strong> <span>{note.detail}</span>
      <ul className="setup-commands">{note.commands.map(hint => <li key={hint.name}>{hint.name}: <code>{hint.command}</code></li>)}</ul>
    </div>)}
    {error && <p className="inline-note error-text" role="alert">{error}</p>}
    <div className="button-row">
      {!nothing && <button type="button" className="primary" disabled={busy || asking || !picked.length} onClick={approve}>Approve</button>}
      {!nothing && !asked && <button type="button" className="secondary" disabled={asking} onClick={notNow}>Not now</button>}
      {(nothing || asked) && onDone && <button type="button" className="text-button" onClick={onDone}>Close</button>}
    </div>
    {mode === 'welcome' && onChat && <div className="button-row"><button type="button" className="text-button" onClick={() => onChat('chat')}>Skip and start chatting</button></div>}
  </section>;
}
