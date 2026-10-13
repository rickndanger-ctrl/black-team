import React, {useEffect, useState} from 'react';
import {native} from './desktop.mjs';
import {post} from './http.mjs';
import {AGENT_NAMES} from './Privacy.jsx';

export const PERMISSIONS = [['ask', 'Ask'], ['edit', 'Edit'], ['auto', 'Auto']];
const HINTS = {
  'claude-code': {
    ask: 'Claude Code asks before it changes or runs anything. You approve each step.',
    edit: 'Claude Code can read and edit files in this project and run simple file commands. Other commands are refused.',
    auto: 'Claude Code works on its own judgement inside this project. Roll back is still available.',
  },
  codex: {
    ask: 'Codex can only read here. It cannot ask for approval; switch to Edit or Auto to let it make changes.',
    edit: 'Codex can read, edit and run commands inside its sandbox.',
    auto: 'Codex works on its own inside its sandbox, with its automatic review. Roll back is still available.',
  },
};

// Who does the work: the model in use, or a subscription agent found on this computer.
export function AgentPicker({agents = [], value, disabled, onChange}) {
  const installed = agents.filter(agent => agent.installed);
  if (!installed.length && !value) return null;
  const shown = value && !installed.some(agent => agent.engine === value) ? [...installed, {engine: value, name: AGENT_NAMES[value] || value}] : installed;
  return <select className="agent-picker" aria-label="Who does the work" title="Who does the work" value={value || ''} disabled={disabled} onChange={event => onChange(event.target.value)}>
    <option value="">Your model</option>
    {shown.map(agent => <option key={agent.engine} value={agent.engine}>{agent.name} · your subscription</option>)}
  </select>;
}

// The permission level, with the hint line for the chosen agent and level.
export function PermissionPicker({engine, value, disabled, onChange}) {
  return <>
    <select className="permission-picker" aria-label="Permission" title="What the agent may do without asking" value={value} disabled={disabled} onChange={event => onChange(event.target.value)}>
      {PERMISSIONS.map(([id, label]) => <option key={id} value={id}>{label}</option>)}
    </select>
    <p className="mode-help">{HINTS[engine]?.[value]}</p>
  </>;
}

const versions = new Map();
// The version check line: shown once per agent, cached by the engine for 12 hours.
export function VersionLine({engine}) {
  const [info, setInfo] = useState(null);
  const [note, setNote] = useState('');
  const [error, setError] = useState('');
  useEffect(() => {
    let active = true;
    setInfo(null); setNote(''); setError('');
    if (!engine) return undefined;
    if (!versions.has(engine)) versions.set(engine, native('agents-status', {engine}).catch(() => {versions.delete(engine); return null;}));
    versions.get(engine)?.then(result => {if (active) setInfo(result?.agents?.find(agent => agent.engine === engine) || null);});
    return () => {active = false;};
  }, [engine]);
  if (!engine || !info?.installed) return null;
  const update = async () => {
    setError('');
    try {await native('agent-update', {engine}); setNote('Finish updating in Terminal, then send your message again.');}
    catch (cause) {setError(cause.message);}
  };
  return <div className="agent-version" role="status">
    {info.updateAvailable
      ? <span>{info.name} {info.latestVersion} is available (you have {info.installedVersion}).</span>
      : info.installedVersion && <span>{info.name} {info.installedVersion}</span>}
    {info.updateAvailable && <button type="button" className="link-button" onClick={update}>Update</button>}
    {note && <span>{note}</span>}
    {error && <span className="error-text">{error}</span>}
  </div>;
}

// Under a reply: sign in or update the agent when it asks, and roll back a finished task.
export function AgentRunActions({item, threadId, busy, onError}) {
  const [confirming, setConfirming] = useState(false);
  const [working, setWorking] = useState(false);
  const [note, setNote] = useState('');
  const signIn = item.needsSignIn;
  const update = item.needsUpdate;
  const open = async (action, engine, words) => {
    setWorking(true); setNote('');
    try {await native(action, {engine}); setNote(words);}
    catch (cause) {onError(cause.message);}
    finally {setWorking(false);}
  };
  const rollBack = async () => {
    setWorking(true);
    try {await post('/api/agent/rollback', {threadId, runId: item.run}); setConfirming(false);}
    catch (cause) {onError(cause.message);}
    finally {setWorking(false);}
  };
  const showRollback = item.rollback && item.run && !item.rolledBack;
  if (!signIn && !update && !showRollback && !item.rolledBack && !item.rollbackNote) return null;
  return <div className="agent-actions">
    {signIn && <button type="button" className="secondary" disabled={busy || working} onClick={() => open('agent-signin', signIn, 'Finish signing in in Terminal, then send your message again.')}>Sign in to {AGENT_NAMES[signIn] || signIn}</button>}
    {update && <button type="button" className="secondary" disabled={busy || working} onClick={() => open('agent-update', update, 'Finish updating in Terminal, then send your message again.')}>Update {AGENT_NAMES[update] || update}</button>}
    {note && <p role="status">{note}</p>}
    {showRollback && !busy && !confirming && <button type="button" className="secondary" disabled={working} onClick={() => setConfirming(true)}>Roll back this task</button>}
    {item.rolledBack && <p>Rolled back</p>}
    {!item.rollback && item.rollbackNote && !item.rolledBack && <p>{item.rollbackNote}</p>}
    {confirming && <section className="privacy-card" aria-label="Roll back this task">
      <strong>Roll back this task?</strong>
      <p>The files this task changed go back to how they were before it ran. Files it created are removed.</p>
      <div className="button-row"><button className="danger" disabled={working} onClick={rollBack}>Roll back</button><button className="secondary" disabled={working} onClick={() => setConfirming(false)}>Cancel</button></div>
    </section>}
  </div>;
}
