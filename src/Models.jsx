import React from 'react';

// The model in use, as a menu when more than one is set up. Switching is a desktop action.
export function ModelSwitch({models = [], name, disabled, onSwitch}) {
  const active = models.find(model => model.active);
  if (!onSwitch || models.length < 2) return <small>{name}</small>;
  return <select className="model-switch" aria-label="Model in use" title="Switch model" value={active?.key || ''} disabled={disabled} onChange={event => onSwitch(event.target.value)}>
    {!active && <option value="" disabled>{name}</option>}
    {models.map(model => <option key={model.key} value={model.key}>{model.kind === 'cloud' ? `${model.name} · Cloud` : model.name}</option>)}
  </select>;
}

// Optimizing: Black Team starts a model a few times with different settings, measures this computer, and keeps the fastest.
// The engine does the work; its progress is in status.optimize and each model's last result in model.tuning.
const estimate = optimize => {
  const minutes = Math.max(1, Math.round((optimize?.budgetSeconds || 180) / 60));
  return `about ${minutes} minute${minutes === 1 ? '' : 's'}`;
};

export function OptimizeProgress({optimize, onCancel}) {
  if (!optimize) return null;
  if (!optimize.running) {
    if (optimize.error) return <p className="inline-note error-text" role="alert">{optimize.error}</p>;
    if (optimize.stopped) return <p className="inline-note" role="status">Optimizing stopped. Your model is as it was.</p>;
    if (optimize.done && optimize.summary) return <p className="inline-note" role="status">{optimize.server ? 'Measured' : 'Optimized for this computer'}: {optimize.summary}</p>;
    return null;
  }
  const budget = optimize.budgetSeconds || 180, elapsed = Math.min(optimize.elapsedSeconds || 0, budget);
  return <div className="optimize-progress" role="status" aria-live="polite">
    <div><strong>{optimize.server ? 'Measuring' : 'Optimizing'} {optimize.name}</strong><span>{optimize.message}</span></div>
    <progress max={budget} value={elapsed} aria-label="Time used"/>
    <small>{elapsed} seconds so far, up to {Math.round(budget / 60)} minutes. {optimize.server ? '' : 'The model restarts a few times; Black Team starts it again if it was running.'}</small>
    {optimize.log?.length > 1 && <ul>{optimize.log.slice(-5).map((line, index) => <li key={index}>{line}</li>)}</ul>}
    <button type="button" className="secondary" onClick={onCancel}>Stop</button>
  </div>;
}

function OptimizeLine({model, optimize, disabled, onOptimize}) {
  const tuning = model.tuning;
  if (!tuning || tuning.state === 'cloud' || !onOptimize) return null;
  const running = Boolean(optimize?.running);
  const button = (label, primary) => <button type="button" className={primary ? 'primary' : 'secondary'} disabled={disabled || running} onClick={() => onOptimize(model.key)} aria-label={`${label} ${model.name}`}>{label}</button>;
  if (tuning.state === 'optimized') return <div className="optimize-line"><span>Optimized for this computer: {tuning.summary}</span>{button('Optimize again')}</div>;
  if (tuning.state === 'stale') return <div className="optimize-line"><span>Needs optimizing again. {(tuning.reasons || []).join(' ')} Before: {tuning.summary}</span>{button('Optimize')}</div>;
  if (tuning.state === 'measured') return <div className="optimize-line"><span>Measured: {tuning.summary}. Its settings belong to that server.</span>{button('Measure again')}</div>;
  if (tuning.state === 'server') return <div className="optimize-line"><span>Its settings belong to the server, so Black Team can only measure its speed.</span>{button('Measure speed')}</div>;
  return <div className="optimize-line"><span>Not optimized yet. Black Team tries a few settings and keeps the fastest for this computer: {estimate(optimize)}; the model restarts a few times.</span>{button('Optimize')}</div>;
}

export function ModelList({models = [], busy, working, onSwitch, onForget, optimize, onOptimize, onCancelOptimize}) {
  if (!models.length) return null;
  return <section className="model-list" aria-label="Your models">
    <div className="panel-heading"><div><span className="eyebrow">YOUR MODELS</span><h2>Switch between your models</h2></div></div>
    <p className="section-intro">Every model you set up is kept here. Choosing one stops the model in use; your next message starts the new one.</p>
    <OptimizeProgress optimize={optimize} onCancel={onCancelOptimize}/>
    <ul>{models.map(model => <li key={model.key} className={model.active ? 'active' : ''}>
      {model.kind === 'cloud'
        ? <div><strong>{model.name}<em className="cloud-tag">Cloud</em></strong><span>Cloud · {model.provider} · {model.keyConfigured ? 'Key saved on this computer' : 'No key saved'} · {Number(model.context).toLocaleString()} tokens</span></div>
        : <div><strong>{model.name}</strong><span>Local · {model.source === 'server' ? 'Local server' : 'Model file'} · {model.where} · {Number(model.context).toLocaleString()} tokens</span></div>}
      {model.active ? <span className="in-use">In use</span> : <div className="button-row"><button type="button" className="secondary" disabled={busy || working || optimize?.running} onClick={() => onSwitch(model.key)}>Use</button><button type="button" className="text-button" disabled={busy || working || optimize?.running} onClick={() => onForget(model.key)} aria-label={`Remove ${model.name} from your list`}>Remove</button></div>}
      <OptimizeLine model={model} optimize={optimize} disabled={busy || working} onOptimize={onOptimize}/>
    </li>)}</ul>
    {working && <p className="inline-note">Finish or stop the current response before switching models.</p>}
  </section>;
}
