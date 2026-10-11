import React, {useState} from 'react';

// What Code changed in files this turn: each edit as a diff, with a way to put the file back.
export function Changes({events = [], onUndo, busy}) {
  const [undone, setUndone] = useState({});
  const changes = events.filter(event => event.change);
  if (!changes.length) return null;
  const undo = async change => {if (await onUndo(change.id)) setUndone(previous => ({...previous, [change.id]: true}));};
  return <div className="changes"><small>{changes.length} file {changes.length === 1 ? 'change' : 'changes'}</small>{changes.map(({change}, index) => <details key={change.id || index} className={undone[change.id] ? 'undone' : ''}><summary><span className="change-path">{change.path}</span><span className="change-count">{change.created ? 'new file · ' : ''}<i className="plus">+{change.added}</i> <i className="minus">−{change.removed}</i></span>{undone[change.id] ? <em>Undone</em> : <button type="button" disabled={busy} onClick={event => {event.preventDefault(); undo(change);}}>Undo</button>}</summary><pre className="diff">{(change.diff || 'No text difference to show.').split('\n').map((line, n) => <span key={n} className={/^(\+\+\+|---|@@)/.test(line) ? 'hunk' : line.startsWith('+') ? 'plus' : line.startsWith('-') ? 'minus' : ''}>{line + '\n'}</span>)}</pre></details>)}</div>;
}

// Measured speed and how full the working budget is, so "why is it slow" answers itself.
export function SpeedMeter({meter}) {
  if (!meter || !meter.write) return null;
  const share = meter.budget ? Math.min(100, Math.round(meter.used / meter.budget * 100)) : null;
  const detail = `${meter.read !== undefined ? `Reading ${meter.read} tokens/s, w` : 'W'}riting ${meter.write} tokens/s.${share !== null ? ` ${Number(meter.used || 0).toLocaleString()} of a ${meter.budget.toLocaleString()}-token working budget (model window ${Number(meter.window || 0).toLocaleString()}).` : ''}${meter.trims ? ` Trimmed ${meter.trims} time${meter.trims > 1 ? 's' : ''}.` : ''}`;
  return <span className="speed-meter" title={detail} aria-label={detail}>{meter.read !== undefined && <><b>{meter.read}</b> t/s read</>}<b>{meter.write}</b> t/s write{share !== null && <><i><u style={{width: `${share}%`}} className={share > 85 ? 'full' : ''}/></i><b>{share}%</b></>}</span>;
}

export function WorkLog({events = []}) {
  if (!events.length) return null;
  return <details className="context-inspector work-log"><summary><span>Work log</span><span>{events.filter(event => event.type === 'tool_use').length} tool actions</span></summary>{events.map((event, index) => <div key={index} className={event.error ? 'failed' : ''}><strong>{event.type === 'tool_use' ? '↗ ' : event.type === 'tool_result' ? (event.error ? '! ' : '✓ ') : ''}{event.name}</strong><pre>{event.output}</pre></div>)}</details>;
}
