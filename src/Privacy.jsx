import React, {useState} from 'react';
import {native} from './desktop.mjs';

export const AGENT_NAMES = {'claude-code': 'Claude Code', codex: 'Codex'};

// Every conversation says where it is: On this computer, or Leaves this computer · provider.
export function PrivacyTag({leaves, provider}) {
  return <span className={`privacy-tag${leaves ? ' leaves' : ''}`}>{leaves ? `Leaves this computer · ${provider}` : 'On this computer'}</span>;
}

// Tokens reported by the cloud service for this conversation so far (never prices).
export function CloudUsage({thread}) {
  const usage = thread?.usage;
  if (thread?.privacy !== 'cloud' || !usage) return null;
  const n = value => Number(value || 0).toLocaleString();
  return <span className="token-line" title="What the service reported for this conversation so far. Black Team shows tokens, not prices.">{n(usage.prompt)} tokens in · {n(usage.completion)} out{usage.cached > 0 ? ` · ${n(usage.cached)} cached` : ''}</span>;
}

// The notice before the first send of a cloud conversation. It does not block sending.
export function CloudNotice({check}) {
  return <section className="privacy-notice" role="status" aria-label="Before your first message">
    <span className="eyebrow">THIS CONVERSATION LEAVES THIS MAC</span>
    <p>It is sent to {check.provider}, the service behind {check.modelName}, which you chose for it.</p>
    <p>What leaves this computer with each message:</p>
    <ul>{(check.willLeave || []).map(item => <li key={item}>{item}</li>)}</ul>
    <p>Memory is not used in cloud conversations: nothing from your vault is sent, and nothing is written to it from here.</p>
  </section>;
}

// The refusal card: a message is not sent until the person chooses one of these.
export function PrivacyCard({card, busy, canConvert, onStartNew, onSwitch, onConvert, onConfirm, onClose}) {
  const {check, view} = card;
  if (view === 'confirm') return <section className="privacy-card" role="alert" aria-label="Confirm sending to a cloud service">
    <span className="eyebrow">NOT SENT</span>
    <strong>Send this conversation to {check.provider}?</strong>
    <p>{check.convertWarning}</p>
    <div className="button-row"><button className="primary" disabled={busy} onClick={onConfirm}>Send it to {check.provider}</button><button className="secondary" disabled={busy} onClick={onClose}>Cancel</button></div>
  </section>;
  const needsChoice = check.outcome === 'needsChoice';
  const title = check.outcome === 'projectLocalOnly' ? 'This project is local only' : check.outcome === 'phoneNeedsMac' ? 'Open Black Team on your computer' : 'This conversation is private to this computer';
  return <section className="privacy-card" role="alert" aria-label="Message not sent">
    <span className="eyebrow">NOT SENT</span>
    <strong>{title}</strong>
    <p>{check.message}</p>
    <div className="button-row">
      {needsChoice && <button className="secondary" disabled={busy} onClick={onStartNew}>Start a new cloud conversation</button>}
      {check.localModelKey && <button className="secondary" disabled={busy} onClick={onSwitch}>Switch back to {check.localModelName}</button>}
      {needsChoice && canConvert && <button className="secondary" disabled={busy} onClick={onConvert}>Send this conversation to {check.provider}</button>}
      {!needsChoice && <button className="secondary" onClick={onClose}>Dismiss</button>}
    </div>
  </section>;
}

// Per-project switch: a project is local only until its owner allows cloud models in it.
export function ProjectCloud({project, busy, onNotice, onError}) {
  const [asking, setAsking] = useState(false);
  const [working, setWorking] = useState(false);
  if (!project) return null;
  const allowed = Boolean(project.cloudAllowed);
  const set = async (next, confirmed) => {
    setWorking(true); setAsking(false);
    try {
      await native('project-cloud', confirmed ? {id: project.id, allowed: true, confirmed: true} : {id: project.id, allowed: false});
      onNotice(next ? `${project.name} may now use cloud models. Conversations in it that use one leave this computer.` : `${project.name} is local only again.`);
    } catch (cause) {onError(cause.message);}
    finally {setWorking(false);}
  };
  return <div className="project-cloud">
    <button type="button" className="link-button" disabled={busy || working} onClick={() => allowed ? set(false, false) : setAsking(true)}>{allowed ? 'Make local only' : 'Allow cloud models…'}</button>
    {asking && <section className="privacy-card" aria-label="Allow cloud models">
      <span className="eyebrow">{project.name}</span>
      <strong>Allow cloud models in {project.name}?</strong>
      <p>Conversations in this project may then use a cloud model. What you type, and in Code the files the agent reads and the output of its commands, are sent to that service. Conversations that use a local model still stay on this computer.</p>
      <div className="button-row"><button className="primary" onClick={() => set(true, true)}>Allow cloud models</button><button className="secondary" onClick={() => setAsking(false)}>Keep it local only</button></div>
    </section>}
  </div>;
}
