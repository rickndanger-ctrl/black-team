import React, {useEffect, useState} from 'react';
import {native} from './desktop.mjs';
import Icon from './Icons.jsx';

// The agents found on this computer, each one step from opening with the model in use.
export default function Harnesses({status, busy, onAction, onChat, onSettings}) {
  const [found, setFound] = useState(null);
  useEffect(() => {
    let active = true;
    native('installed-discover').then(value => {if (active) setFound(value);}).catch(() => {if (active) setFound({apps: [], terminals: []});});
    return () => {active = false;};
  }, []);
  const saved = status.integrations?.harnesses || [];
  const model = status.config?.model?.name || 'your model';
  const ready = status.setupComplete;
  const working = busy || status.runtime?.busy;
  const apps = found?.apps || [];
  const savedFor = app => saved.find(item => item.id === app.id || item.executable === app.executable);
  const own = saved.filter(item => !apps.some(app => savedFor(app) === item));
  const open = item => onAction('harness-launch', {id: item.id}, `${item.name} opened with ${model}.`);
  return <section className="local-model-panel harnesses">
    <span className="eyebrow">AGENTS & APPS</span><h2>Choose how you work</h2>
    <p>Black Team Chat and Code are built in. The agents found on this computer are listed here: connect one once, then open it any time with the model you are using.</p>
    <ul>
      <li><div><strong>Black Team Code</strong><span>Built in. Edits files, runs commands, shows every change.</span></div><button className="primary" disabled={busy || !ready} onClick={() => onChat('agent')}><Icon name="terminal" size={16}/>Open Code</button></li>
      {apps.map(app => {const item = savedFor(app); return <li key={app.id}>
        <div><strong>{app.name}</strong><span>{item ? (item.preset ? `Connected. Opens in a terminal using ${model}.` : 'Connected. Opens in a terminal with its own settings.') : app.preset ? 'Found on this computer. Connect it to use your local model.' : 'Found on this computer. Uses its own model settings.'}</span></div>
        {item ? <button className="secondary" disabled={working || !ready} onClick={() => open(item)}>Open</button> : <button className="secondary" disabled={working} onClick={() => onAction('harness-connect', {id: app.id}, `${app.name} connected. Open it from here any time.`)}>Connect</button>}
      </li>;})}
      {own.map(item => <li key={item.id}><div><strong>{item.name}</strong><span>Your own launcher.</span></div><button className="secondary" disabled={working || !ready} onClick={() => open(item)}>Open</button></li>)}
    </ul>
    {found && !apps.length && !own.length && <p className="inline-note">No other agents were found on this computer. Claude Code, Codex, Pi, OpenCode, DeepSeek Harness, Aider and Hermes are recognised once installed.</p>}
    {!ready && <p className="inline-note">Set up a model above to open these.</p>}
    <div className="button-row"><button className="text-button" onClick={() => onSettings('agents')}>Add another app or change launch options</button></div>
    <small>Each agent opens in its own terminal and keeps its own history; its work is not mirrored to your phone. Keep Black Team open while one uses a model Black Team started.</small>
  </section>;
}
