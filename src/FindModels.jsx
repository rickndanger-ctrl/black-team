import React, {useEffect, useState} from 'react';
import {native} from './desktop.mjs';

const size = bytes => `${(bytes / 1024 ** 3).toFixed(1)} GB`;
const where = endpoint => endpoint.replace(/^https?:\/\//, '').replace(/\/v1\/?$/, '');
const keyOf = item => item.source === 'server' ? `s:${item.endpoint}:${item.id}` : `f:${item.file}`;

// Shows the models already on this computer and adds the chosen ones in one step.
export default function FindModels({busy, onAction, onAdded, onManual, auto = false, heading = 'Models found on this computer'}) {
  const [found, setFound] = useState(null);
  const [looking, setLooking] = useState(false);
  const [error, setError] = useState('');
  const [picked, setPicked] = useState(() => new Set());
  const usable = item => !item.saved && (item.source === 'server' || Boolean(item.runtime));
  const look = async () => {
    setLooking(true); setError('');
    try {
      const result = await native('models-find');
      setFound(result);
      setPicked(new Set([...result.servers, ...result.files].filter(usable).map(keyOf)));
    } catch (cause) {setError(cause.message);}
    finally {setLooking(false);}
  };
  useEffect(() => {if (auto) look();}, []);
  const all = found ? [...found.servers, ...found.files] : [];
  const chosen = all.filter(item => picked.has(keyOf(item)));
  const toggle = item => setPicked(previous => {const next = new Set(previous); const key = keyOf(item); next.has(key) ? next.delete(key) : next.add(key); return next;});
  const add = async () => {
    const items = chosen.map(({source, endpoint, id, file, runtime, name, context}) => source === 'server' ? {source, endpoint, id, name, context} : {source, file, runtime, name, context});
    const result = await onAction('models-add', {items});
    if (!result) return;
    onAdded?.(result);
    await look();
  };
  const detail = item => item.source === 'server'
    ? `Running now · ${item.provider} · ${where(item.endpoint)} · ${item.contextKnown ? `${item.context.toLocaleString()} tokens` : `context not reported, using ${item.context.toLocaleString()}`}`
    : `Model file · ${size(item.bytes)} · ${item.runtime ? 'Black Team starts it when you use it' : 'needs llama.cpp, which was not found'}${item.tooBig ? ' · larger than this computer’s memory' : ''}`;
  return <section className="found-models setup-form" aria-busy={looking}>
    <div className="panel-heading"><div><span className="eyebrow">FIND MODELS</span><h2>{heading}</h2></div></div>
    {!found && !looking && <><p className="section-intro">Black Team can look for local model servers that are running and for model files in the usual folders. Nothing leaves this computer.</p><div className="button-row"><button type="button" className="secondary" disabled={busy} onClick={look}>Find my models</button></div></>}
    {looking && <p role="status" className="section-intro">Looking for local servers and model files…</p>}
    {found && !looking && <>
      {all.length > 0 ? <>
        <p className="section-intro">Tick the ones you want. You can switch between them at any time, and add or remove models later in Settings.</p>
        <ul>{all.map(item => <li key={keyOf(item)} className={usable(item) ? '' : 'unavailable'}>
          <label><input type="checkbox" checked={picked.has(keyOf(item))} disabled={!usable(item) || busy} onChange={() => toggle(item)}/><span><strong>{item.name}</strong><small>{item.saved ? 'Already in your list' : detail(item)}</small></span></label>
        </li>)}</ul>
        <div className="form-actions"><button type="button" className="primary" disabled={busy || !chosen.length} onClick={add}>{busy ? 'Adding…' : `Add ${chosen.length} ${chosen.length === 1 ? 'model' : 'models'}`}</button><button type="button" className="text-button" disabled={busy} onClick={look}>Look again</button>{onManual && <button type="button" className="text-button" disabled={busy} onClick={onManual}>Set one up by hand</button>}</div>
      </> : <>
        <p className="section-intro">No running model server or model file was found. Start Ollama, LM Studio or llama.cpp, or download a GGUF model, then look again.</p>
        <div className="form-actions"><button type="button" className="secondary" disabled={busy} onClick={look}>Look again</button>{onManual && <button type="button" className="text-button" onClick={onManual}>Set one up by hand</button>}</div>
      </>}
      <small className="looked">Looked for servers on local ports {found.looked.ports.join(', ')}{found.looked.folders.length ? <> and for model files in {found.looked.folders.join(', ')}</> : null}.</small>
    </>}
    {error && <p role="alert" className="error-text inline-note">{error}</p>}
  </section>;
}
