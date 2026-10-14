import React, {useEffect, useState} from 'react';
import {api, post} from './http.mjs';
import {canContinue, continueLabel, limitsFrom, runLine, runOf, shownPhase, stoppedLine} from './runState.mjs';

// A Code conversation's run: its phase, Pause / Resume / Continue, what it has spent, and the limits and the check switch.
export default function RunBar({status, thread, threadId, available, onContinue, onError, onNotice}) {
  const job = status.job;
  const run = runOf(thread);
  const running = job?.state === 'running' && job.threadId === threadId;
  const phase = shownPhase({job, threadId, run});
  const [busy, setBusy] = useState(false);
  const [settings, setSettings] = useState(null);
  const [form, setForm] = useState(null);
  const [open, setOpen] = useState(false);
  const query = threadId ? `?thread=${encodeURIComponent(threadId)}` : '';
  const load = () => api(`/api/code/settings${query}`).then(value => {
    setSettings(value);
    const price = value.model?.price;
    setForm({tokens: String(value.tokenCeiling), money: String(value.moneyCeiling || 0), inPrice: price ? String(price.input) : '', outPrice: price ? String(price.output) : ''});
  }).catch(() => {});
  useEffect(() => {if (open) load();}, [open, threadId, status.config?.model?.name]);
  const act = async work => {setBusy(true); try {await work();} catch (cause) {onError(cause.message);} finally {setBusy(false);}};
  const save = patch => act(async () => {const value = await post('/api/code/settings', {...(threadId ? {thread: threadId} : {}), ...patch}); setSettings(value);});
  const saveLimits = event => {
    event.preventDefault();
    const parsed = limitsFrom({...form, cloud: settings?.model?.cloud});
    if (parsed.error) {onError(parsed.error); return;}
    act(async () => {const value = await post('/api/code/settings', {...(threadId ? {thread: threadId} : {}), ...parsed.value}); setSettings(value); onNotice('Limits saved.');});
  };
  const pausing = Boolean(running && job.pausing);
  const line = runLine({phase: running ? phase : '', run, pausing});
  const can = canContinue({phase, running, run});
  const field = name => event => setForm(previous => ({...previous, [name]: event.target.value}));
  return <div className="run-bar">
    {(running && phase) || can ? <div className="run-state" role="status">
      <strong>{running ? line : stoppedLine({phase, run})}</strong>
      <span className="run-actions">
        {running && phase !== 'paused' && !pausing && <button type="button" className="secondary" disabled={busy || phase === 'waiting'} title="The run stops after the step it is on. A tool that is running finishes first." onClick={() => act(() => post('/api/pause', {}))}>Pause</button>}
        {running && (phase === 'paused' || pausing) && <button type="button" className="primary" disabled={busy} onClick={() => act(() => post('/api/resume', {}))}>Resume</button>}
        {can && <button type="button" className="primary" disabled={!available || busy} title="Picks up from the saved to-do list and what it did so far" onClick={onContinue}>{continueLabel({phase})}</button>}
      </span>
    </div> : null}
    {!running && run?.tokens > 0 && <small className="run-total">{runLine({phase: run.phase, run})}</small>}
    <details className="run-settings" open={open} onToggle={event => setOpen(event.currentTarget.open)}>
      <summary>Limits and checks</summary>
      {settings && form ? <div className="run-settings-body">
        <label className="checkbox-field full"><input type="checkbox" checked={!!settings.check} disabled={busy} onChange={event => save({check: event.target.checked})}/><span><strong>Check the work before finishing</strong><small>When the model says it is done, it reviews the result against the request and the to-do list once more, and carries on if something is missing (at most twice). {settings.model?.cloud ? 'On by default for a cloud model.' : 'Off by default for a model on this computer, because each check can take minutes.'}</small></span></label>
        <label className="checkbox-field full"><input type="checkbox" checked={!!settings.summarize} disabled={busy} onChange={event => save({summarize: event.target.checked})}/><span><strong>Summarize earlier steps when trimming</strong><small>{settings.model?.cloud ? 'Older steps are replaced by the work log and to-do list. A short written summary is added too.' : 'Older steps are replaced by the work log and to-do list at no cost. A written summary needs the model to read them and can take minutes here, so it is off.'}</small></span></label>
        <form className="run-limits" onSubmit={saveLimits}>
          <label className="form-field">Stop after this many tokens<input inputMode="numeric" value={form.tokens} onChange={field('tokens')} aria-describedby="token-limit-help"/><small id="token-limit-help">Counts everything read and written in this conversation. 0 means no limit.</small></label>
          {settings.model?.cloud && <>
            <label className="form-field">Stop after spending ($)<input inputMode="decimal" value={form.money} onChange={field('money')}/><small>0 means no limit.</small></label>
            <label className="form-field">Price per million tokens read ($)<input inputMode="decimal" value={form.inPrice} onChange={field('inPrice')}/></label>
            <label className="form-field">Price per million tokens written ($)<input inputMode="decimal" value={form.outPrice} onChange={field('outPrice')}/><small>Black Team has no price list. Enter what {settings.model.name} costs you; the cost shown is worked out from the tokens the service reports.</small></label>
          </>}
          <div className="button-row"><button className="secondary" disabled={busy}>Save limits</button></div>
        </form>
        {!threadId && <small>These apply to new conversations. Open a conversation to set them for that one.</small>}
      </div> : <small>Loading…</small>}
    </details>
  </div>;
}
