import React from 'react';

// The question Black Team asks before it stops another model server: that server holds the memory this model needs.
// Nothing is stopped until the person says yes; "Cancel" leaves everything as it was.
export default function StopCard({approval, busy, sends, onApprove, onCancel}) {
  return <section className="privacy-card stop-card" role="alert" aria-label="Another model is using the memory">
    <span className="eyebrow">NEEDS YOUR OK</span>
    <strong>{approval.question}</strong>
    <p>{approval.modelName} will not fit beside it. Black Team stops only {approval.otherName}, and only if you say so.{sends ? ' Your message is kept and is sent once it is stopped.' : ''}</p>
    <div className="button-row"><button type="button" className="primary" disabled={busy} onClick={onApprove}>{busy ? 'Stopping…' : sends ? 'Stop it and send' : 'Stop it and start'}</button><button type="button" className="secondary" disabled={busy} onClick={onCancel}>Cancel</button></div>
  </section>;
}
