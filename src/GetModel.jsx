import React, {useCallback, useEffect, useRef, useState} from 'react';
import {native} from './desktop.mjs';
import {offerSetupAfterModelReady} from './setupOffer.mjs';
import {PICK_WORDS, downloadRequest, downloadState, fitWords, picksOf, restOf, size, thirdParty, timeLeft} from './models.mjs';

// Get a model: the models that suit this computer, best first; a search of Hugging Face for any other GGUF; and the download, which the
// engine checks, saves and sets up so the model is ready to chat. Sizes, speeds and fits come from the engine; the speed is an estimate.
export default function GetModel({status, onChat}) {
  const [recs, setRecs] = useState(null);
  const [error, setError] = useState('');
  const [asking, setAsking] = useState(false);
  const [query, setQuery] = useState('');
  const [results, setResults] = useState(null);
  const [searching, setSearching] = useState(false);
  const [repo, setRepo] = useState(null);
  const [ticks, setTicks] = useState({});
  const last = useRef(null);   // what was asked for, so a paused download carries on with the same request
  const install = status.modelInstall || {};
  const state = downloadState(install);
  const load = useCallback(async () => {try {setRecs(await native('models-recommend'));} catch (cause) {setError(cause.message);}}, []);
  // Loaded once, and again when a download ends, so "Downloaded" and the free disk space are current.
  useEffect(() => {load();}, [load, install.running, install.done]);

  const ask = async (action, data) => {setAsking(true); setError(''); try {return await native(action, data);} catch (cause) {setError(cause.message); return null;} finally {setAsking(false);}};
  const download = async (choice, bytes) => {
    // The vision and speed-up files come along unless they were unticked.
    const extras = {vision: true, draft: true, ...ticks[choice.id || `${choice.repo}/${choice.file}`]};
    last.current = {request: downloadRequest(choice, extras), bytes};
    await ask('model-get', last.current.request);
  };
  const resume = () => last.current && ask('model-get', last.current.request);
  const stop = discard => ask('model-get-stop', {discard});
  const search = async event => {
    event.preventDefault();
    if (!query.trim()) return;
    setSearching(true); setError(''); setRepo(null);
    try {setResults((await native('models-search', {query})).results);} catch (cause) {setError(cause.message); setResults(null);} finally {setSearching(false);}
  };
  const open = async name => {setError(''); setAsking(true); try {setRepo(await native('models-repo', {repo: name}));} catch (cause) {setError(cause.message);} finally {setAsking(false);}};
  const tick = (key, field) => setTicks(previous => ({...previous, [key]: {...previous[key], [field]: !(previous[key]?.[field] ?? true)}}));

  // A model that has just arrived is measured on this computer straight away, and the agents are offered for setup: once per download.
  const followed = useRef('');
  useEffect(() => {
    const result = install.result;
    if (!install.done || !result?.ready || !result.key || followed.current === result.key || !last.current) return;
    followed.current = result.key;
    // The download lets go of setup a moment after it reports Ready, so a "busy" answer is asked again a few times.
    const optimize = async tries => {
      const answer = await native('optimize-start', {key: result.key}).catch(() => null);
      if (answer && !answer.started && tries > 0) setTimeout(() => optimize(tries - 1), 1500);
    };
    optimize(4);
    offerSetupAfterModelReady();
  }, [install.done, install.result]);

  const busy = asking || state === 'running';
  const percent = typeof install.fraction === 'number' ? Math.round(install.fraction * 100) : null;
  const inUse = status.config?.model?.file || '';

  const Extras = ({id, vision, draft}) => (vision || draft) ? <span className="get-extras">
    {vision && <label className="checkbox-field"><input type="checkbox" checked={ticks[id]?.vision ?? true} onChange={() => tick(id, 'vision')} disabled={busy}/><span>Also get the vision file ({size(vision.bytes)}) so it can read pictures</span></label>}
    {draft && <label className="checkbox-field"><input type="checkbox" checked={ticks[id]?.draft ?? true} onChange={() => tick(id, 'draft')} disabled={busy}/><span>Also get the speed-up file ({size(draft.bytes)})</span></label>}
  </span> : null;

  const Card = ({entry, keys = []}) => {
    const model = entry.model, current = entry.installed && inUse.endsWith(`/${model.filename}`);
    return <li key={model.id} className={keys.length ? 'get-pick' : ''}>
      <div>
        <strong>{model.name}</strong>
        {keys.map(key => <span key={key} className="starter-tag">{PICK_WORDS[key]}</span>)}
        {entry.installed && <span className="starter-tag">{current ? 'In use' : 'Downloaded'}</span>}
        <small>{size(model.bytes)} · {fitWords(entry.fit)} · {entry.speed.text} · {entry.goodFor.join(', ')}</small>
        <p>{entry.reason}</p>
        <small>{model.license} licence · {Number(model.trainingContext || model.contextSize).toLocaleString()} tokens of context · Made by {model.repo.split('/')[0]}, downloaded from Hugging Face</small>
        {!entry.installed && <Extras id={model.id} vision={model.vision} draft={model.draft}/>}
      </div>
      {!current && <button type="button" className={keys.includes('best') ? 'primary' : 'secondary'} disabled={busy || (!entry.installed && !entry.fitsDisk)}
        title={!entry.fitsDisk && !entry.installed ? entry.reason : undefined} onClick={() => download({source: 'catalogue', id: model.id}, model.bytes)}>{entry.installed ? 'Use this model' : 'Download'}</button>}
    </li>;
  };

  const heading = <div className="panel-heading"><div><span className="eyebrow">GET A MODEL</span><h2>Models that suit this computer</h2></div></div>;
  if (!recs) return <section className="found-models setup-form starter-models">{heading}{error ? <p className="inline-note error-text" role="alert">{error}</p> : <p role="status" className="section-intro">Checking this computer…</p>}</section>;
  const picks = picksOf(recs);
  return <section className="found-models setup-form starter-models get-model" aria-busy={state === 'running'}>
    {heading}
    <p className="section-intro">Pick one and Black Team downloads it, checks it and sets it up. No account and no other app needed. This computer: {recs.summary}. Speeds are estimates, not measurements.</p>
    {recs.note && <p className="inline-note">{recs.note}</p>}

    {state === 'ready' && <div className="inline-note get-ready" role="status">
      <strong>{install.result.message}</strong>
      <p>{install.result.modelName} · {install.result.license} licence · {thirdParty(install.result.repo)}</p>
      <div className="button-row">
        {install.result.inUse ? <button type="button" className="primary" onClick={() => onChat?.('chat')}>Start chatting</button>
          : <button type="button" className="primary" disabled={asking} onClick={() => ask('model-switch', {key: install.result.key})}>Use it now</button>}
      </div>
      {install.result.warning && <p>{install.result.warning}</p>}
    </div>}
    {state === 'running' && <div className="inline-note vision-download" role="status">
      <span>{install.stage || 'Starting…'}{percent === null ? '' : ` · ${percent}%`}{install.bytesPerSecond > 0 ? ` · ${size(install.bytesPerSecond)}/s` : ''}{timeLeft(install, last.current?.bytes) ? ` · ${timeLeft(install, last.current?.bytes)}` : ''}</span>
      {percent !== null && <progress max="100" value={percent} aria-label="Model download"/>}
      <div className="button-row"><button type="button" className="secondary" disabled={asking} onClick={() => stop(false)}>Pause</button><button type="button" className="text-button" disabled={asking} onClick={() => stop(true)}>Cancel</button></div>
    </div>}
    {state === 'paused' && <div className="inline-note vision-download" role="status">
      <span>Paused. What has arrived is kept.</span>
      <div className="button-row">{last.current && <button type="button" className="primary" disabled={asking} onClick={resume}>Resume</button>}<button type="button" className="text-button" disabled={asking} onClick={() => stop(true)}>Cancel and delete</button></div>
    </div>}
    {state === 'error' && <div className="inline-note" role="alert"><p className="error-text">{install.error}</p>{last.current && <div className="button-row"><button type="button" className="secondary" disabled={asking} onClick={resume}>Try again</button></div>}</div>}
    {error && <p className="inline-note error-text" role="alert">{error}</p>}

    {picks.length > 0 && <ul className="starter-list" aria-label="Recommended for this computer">{picks.map(({entry, keys}) => <Card key={entry.id} entry={entry} keys={keys}/>)}</ul>}
    {restOf(recs.models).length > 0 && <details className="get-all"><summary>All {recs.models.length} models, best first</summary>
      <ul className="starter-list">{restOf(recs.models).map(entry => <Card key={entry.id} entry={entry}/>)}</ul>
    </details>}

    <div className="get-search">
      <h3>Look for another model on Hugging Face</h3>
      <form onSubmit={search} className="button-row">
        <input type="search" value={query} onChange={event => setQuery(event.target.value)} placeholder="Model name, for example llama or mistral" aria-label="Search Hugging Face for GGUF models" maxLength={100}/>
        <button type="submit" className="secondary" disabled={searching || !query.trim()}>{searching ? 'Searching…' : 'Search'}</button>
      </form>
      <p className="inline-note">Searching contacts huggingface.co, and only when you press Search. Models there are made by other people; read the licence before you use one.</p>
      {results && !results.length && <p className="section-intro">Nothing found. Try a shorter name.</p>}
      {results && results.length > 0 && !repo && <ul className="starter-list">{results.map(item => <li key={item.repo}>
        <div><strong>{item.repo}</strong><small>{item.downloads.toLocaleString()} downloads · {item.likes.toLocaleString()} likes{item.gated ? ' · you must accept its terms on huggingface.co first' : ''}</small></div>
        <button type="button" className="secondary" disabled={asking} onClick={() => open(item.repo)}>See files</button>
      </li>)}</ul>}
      {repo && <div className="get-repo">
        <div className="button-row"><strong>{repo.repo}</strong><button type="button" className="text-button" onClick={() => setRepo(null)}>Back to results</button></div>
        <p className="inline-note">{thirdParty(repo.repo)} Licence: <strong>{repo.license}</strong>. Context up to {repo.trainingContext ? Number(repo.trainingContext).toLocaleString() : 'unknown'} tokens. {repo.toolCalling ? 'Its chat format handles tools.' : 'Tool use is not confirmed.'} <a href={repo.page} target="_blank" rel="noreferrer noopener">Read about it on Hugging Face</a></p>
        {repo.problem && <p className="inline-note error-text" role="alert">{repo.problem}</p>}
        {!repo.problem && repo.files.length === 0 && <p className="section-intro">This repository has no GGUF files.</p>}
        {!repo.problem && <ul className="starter-list">{repo.files.map(item => <li key={item.file.path} className={item.suggested ? 'get-pick' : ''}>
          <div>
            <strong>{item.file.name}</strong>{item.suggested && <span className="starter-tag">Suggested for this computer</span>}
            <small>{item.file.quant || 'quantisation not named'} · {size(item.file.bytes)} · {fitWords(item.fit)} · {item.speed.text}</small>
            {item.unavailable ? <p>{item.unavailable}</p> : !item.fitsDisk ? <p>Not enough free disk space for this file.</p> : null}
            {item.suggested && <Extras id={`${repo.repo}/${item.file.path}`} vision={repo.visionFile} draft={repo.draftFile}/>}
          </div>
          <button type="button" className={item.suggested ? 'primary' : 'secondary'} disabled={busy || Boolean(item.unavailable) || !item.fitsDisk} onClick={() => download({source: 'hub', repo: repo.repo, file: item.file.path}, item.file.bytes)}>Download</button>
        </li>)}</ul>}
      </div>}
    </div>
    <p className="inline-note">Downloads come from Hugging Face{recs.runtime ? '' : ' and GitHub (the llama.cpp program that runs the model)'}. Black Team checks each file against the checksum Hugging Face publishes. Once it has finished, everything runs on this computer and nothing you write leaves it.</p>
  </section>;
}
