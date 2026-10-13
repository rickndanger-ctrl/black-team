import React, {useCallback, useEffect, useState} from 'react';
import {native} from './desktop.mjs';

// Starter models: a short list Black Team can download and set up by itself (the model file, and the llama.cpp program that runs
// it when none is installed yet). The engine does the work and reports progress in status.starterInstall.
const size = bytes => bytes >= 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : `${Math.round(bytes / 1e6)} MB`;

export default function StarterModels({status}) {
  const [catalogue, setCatalogue] = useState(null);
  const [error, setError] = useState('');
  const [asking, setAsking] = useState(false);
  const install = status.starterInstall || {};
  const load = useCallback(async () => {try {setCatalogue(await native('starter-list'));} catch (cause) {setError(cause.message);}}, []);
  // Loaded once, and again when a download ends, so "Downloaded" is current.
  useEffect(() => {load();}, [load, install.running, install.done]);
  const ask = async (action, data) => {setAsking(true); setError(''); try {await native(action, data);} catch (cause) {setError(cause.message);} finally {setAsking(false);}};
  if (!catalogue) return error ? <section className="found-models setup-form"><p className="inline-note error-text" role="alert">{error}</p></section> : null;
  const percent = typeof install.fraction === 'number' ? Math.round(install.fraction * 100) : null;
  const inUse = status.config?.model?.file || '';
  return <section className="found-models setup-form starter-models" aria-busy={Boolean(install.running)}>
    <div className="panel-heading"><div><span className="eyebrow">GET A STARTER MODEL</span><h2>Download a model to this computer</h2></div></div>
    <p className="section-intro">No account and no other app needed. Pick a size, press Download, and Black Team sets everything up. This computer has {(catalogue.memoryBytes / 1073741824).toFixed(1)} GB of memory; the recommended model fits it comfortably.</p>
    <ul className="starter-list">
      {catalogue.models.map(entry => {
        const model = entry.model, current = entry.installed && inUse.endsWith(`/${model.filename}`);
        return <li key={model.id}>
          <div>
            <strong>{model.name}</strong>
            {entry.recommended && <span className="starter-tag">Recommended</span>}
            {entry.installed && <span className="starter-tag">{current ? 'In use' : 'Downloaded'}</span>}
            <small>{size(model.bytes)} · {model.license} licence · {Number(model.contextSize).toLocaleString()} tokens of context{entry.fits ? '' : ' · Needs more memory than is comfortable'}</small>
            {model.summary && <p>{model.summary}</p>}
          </div>
          {!current && <button type="button" className={entry.recommended ? 'primary' : 'secondary'} disabled={asking || install.running} onClick={() => ask('starter-install', {id: model.id})}>{entry.installed ? 'Use this model' : 'Download'}</button>}
        </li>;
      })}
    </ul>
    {install.running && <div className="inline-note vision-download" role="status">
      <span>{install.stage || 'Starting…'}{percent === null ? '' : ` · ${percent}%`}{install.bytesPerSecond > 0 ? ` · ${size(install.bytesPerSecond)}/s` : ''}</span>
      {percent !== null && <progress max="100" value={percent} aria-label="Starter model download"/>}
      <button type="button" className="secondary" disabled={asking} onClick={() => ask('starter-cancel')}>Stop</button>
    </div>}
    {!install.running && install.error && <p className="inline-note error-text" role="alert">{install.error}</p>}
    {error && <p className="inline-note error-text" role="alert">{error}</p>}
    <p className="inline-note">The download comes from Hugging Face{catalogue.runtime ? '' : ' and GitHub (the llama.cpp program that runs the model)'}. Once it has finished, everything runs on this computer and nothing you write leaves it.</p>
  </section>;
}
