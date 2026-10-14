import React, {useCallback, useEffect, useState} from 'react';
import {call} from './http.mjs';

// Settings, App & data: "Keep Black Team running in the background". Off by default. Turning it on writes one small file for this user only
// (a systemd user unit, or a launchd agent on a Mac) and does not start anything now; it starts at the next login, and the window attaches to it.
export default function BackgroundService({status, onError}) {
  const [state, setState] = useState(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');
  const load = useCallback(() => call('service').then(setState).catch(cause => onError(cause.message)), [onError]);
  useEffect(() => {load();}, [load]);

  const toggle = async on => {
    setBusy(true); setMessage('');
    try {
      const next = await call(on ? 'service/install' : 'service/uninstall', {});
      setState(next);
      setMessage(on
        ? (state?.mode === 'background' ? 'On. Black Team keeps running in the background from your next login.' : 'On. It starts at your next login. To start it now, close Black Team and open it again, or run: black-team service start')
        : (state?.mode === 'background' ? 'Off. The background service is stopping, so this window will close. Open Black Team again to carry on; it will run only while the window is open.' : 'Off. The unit was removed.'));
    } catch (cause) {onError(cause.message);} finally {setBusy(false);}
  };
  const change = async (name, value) => {
    setBusy(true);
    try {setState(await call('service/settings', {[name]: Number(value)}));} catch (cause) {onError(cause.message);} finally {setBusy(false);}
  };

  if (!state) return null;
  const unit = state.unit || {};
  const on = Boolean(unit.installed);
  const settings = state.settings || {};
  return <section className="settings-service" aria-label="Keep Black Team running in the background">
    <div className="settings-data">
      <div>
        <h2>Keep Black Team running in the background</h2>
        <p>Runs your scheduled work and keeps Black Team ready on your phone, even when this window is closed. {on ? (state.mode === 'background' ? 'It is running now.' : 'It starts at your next login.') : 'It is off.'}</p>
      </div>
      {unit.supported === false
        ? <small>This computer cannot keep a background service.</small>
        : <label className="checkbox-field"><input type="checkbox" role="switch" checked={on} disabled={busy} onChange={event => toggle(event.target.checked)}/><span><strong>{on ? 'On' : 'Off'}</strong></span></label>}
    </div>
    {message && <p className="inline-note" role="status">{message}</p>}
    <details className="setup-details" open={on}>
      <summary>What this means</summary>
      <ul className="setup-steps">
        <li><div><strong>Memory</strong><small>Your model is loaded only while it has work. It is stopped to free memory after {settings.idleMinutes ? `${settings.idleMinutes} idle minutes` : 'a long idle time (you chose never)'}, and starts again when a message or scheduled run needs it. It is never stopped while a task runs.</small></div></li>
        <li><div><strong>What it can do while you are away</strong><small>Only the schedules you add, in the projects you choose, at the level you choose (read only, ask first, or edit files in the project). A step that needs your yes waits in your Inbox; it never goes ahead on its own.</small></div></li>
        <li><div><strong>Turning it off</strong><small>Switch this off, or run: black-team service uninstall. That removes the one file it wrote. Your data and schedules stay.</small></div></li>
      </ul>
      <div className="sched-row">
        <label className="form-field"><span>Stop the model after (minutes idle, 0 = never)</span><input className="room-input" type="number" min="0" max="1440" defaultValue={settings.idleMinutes} key={`idle-${settings.idleMinutes}`} disabled={busy} onBlur={event => Number(event.target.value) !== settings.idleMinutes && change('idleMinutes', event.target.value)}/></label>
        <label className="form-field"><span>A question waits for you (hours)</span><input className="room-input" type="number" min="1" max="168" defaultValue={settings.approvalHours} key={`hours-${settings.approvalHours}`} disabled={busy} onBlur={event => Number(event.target.value) !== settings.approvalHours && change('approvalHours', event.target.value)}/></label>
        <label className="form-field"><span>Most scheduled runs a day</span><input className="room-input" type="number" min="1" max="200" defaultValue={settings.maxRunsPerDay} key={`runs-${settings.maxRunsPerDay}`} disabled={busy} onBlur={event => Number(event.target.value) !== settings.maxRunsPerDay && change('maxRunsPerDay', event.target.value)}/></label>
      </div>
      {state.helpers?.length > 0 && <ul className="setup-steps">{state.helpers.map(helper => <li key={helper.id}><div><strong>{helper.name}</strong><small>{helper.state}{helper.restarts ? ` · restarted ${helper.restarts} times` : ''}</small></div></li>)}</ul>}
      <small>Version {state.version}. Logs: black-team service logs</small>
    </details>
  </section>;
}
