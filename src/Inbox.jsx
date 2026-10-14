import React, {useCallback, useEffect, useState} from 'react';
import {inboxWords, leftText, timeText} from './schedulesView.mjs';

// What waits for you. A scheduled Code run that reaches a step needing a yes does not fail and does not go on: it waits here (and on the
// phone's approval card) until someone answers, and ends as "not approved" if nobody does in time. The engine holds the question
// (Service/Scheduler.swift); this page shows it and sends the answer.
export default function Inbox({call, onError, onOpenThread, onChange}) {
  const [data, setData] = useState(null);
  const [busy, setBusy] = useState('');

  const load = useCallback(() => call('inbox').then(next => {setData(next); onChange?.(next.waiting);}).catch(cause => onError(cause.message)), [call, onError, onChange]);
  useEffect(() => {
    load();
    const timer = window.setInterval(load, 4000);
    return () => window.clearInterval(timer);
  }, [load]);

  const answer = async (item, choice) => {
    setBusy(item.id);
    try {const next = await call('inbox/answer', {id: item.id, choice}); setData(next); onChange?.(next.waiting);}
    catch (cause) {onError(cause.message); load();}
    finally {setBusy('');}
  };

  if (!data) return <section className="local-model-panel room-card" aria-label="Inbox"><p className="room-empty">Loading…</p></section>;
  const waiting = data.items.filter(item => item.state === 'waiting');
  const earlier = data.items.filter(item => item.state !== 'waiting');
  return <section className="local-model-panel room-card" aria-label="Inbox">
    <span className="eyebrow">WAITING FOR YOU</span>
    <h2>{waiting.length ? `${waiting.length} ${waiting.length === 1 ? 'question' : 'questions'} for you` : 'Nothing is waiting for you'}</h2>
    <p className="section-intro">When a scheduled Code run needs a yes before it changes a file or runs a command, it stops and asks here. Nothing happens until you answer.</p>
    <ul className="room-list inbox-list">{waiting.map(item => <li key={item.id}>
      <div>
        <strong>{item.scheduleName}</strong><em className="room-role">{item.question}</em>
        <pre className="inbox-command">{item.command}</pre>
        <p className="message-note">Asked {timeText(item.created)} · runs out {leftText(item.expires)}{item.threadId && onOpenThread && <> · <button type="button" className="text-button" onClick={() => onOpenThread(item.threadId)}>Open the conversation</button></>}</p>
      </div>
      <div className="button-row">
        <button type="button" className="primary" disabled={busy === item.id} onClick={() => answer(item, 'approve')}>Approve</button>
        <button type="button" className="secondary" disabled={busy === item.id} onClick={() => answer(item, 'deny')}>Deny</button>
      </div>
    </li>)}</ul>
    {earlier.length > 0 && <details className="setup-details"><summary>Earlier questions</summary>
      <ul className="room-list inbox-list">{earlier.slice(0, 20).map(item => <li key={item.id}><div><strong>{item.scheduleName}</strong><em className="room-role">{inboxWords(item.state)}</em><pre className="inbox-command">{item.command}</pre></div></li>)}</ul>
    </details>}
  </section>;
}
