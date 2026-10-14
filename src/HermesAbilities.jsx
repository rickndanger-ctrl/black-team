import React, {useCallback, useEffect, useState} from 'react';
import {native} from './desktop.mjs';

// Settings → Agents & apps → Hermes: what a Hermes conversation can do. Tool groups (each with the text it adds to every message),
// skills, plugins and web search, MCP servers. Everything shown is read from the connected Hermes by the engine; keys are only ever
// typed here, never shown again.

const tokensText = value => typeof value === 'number' ? `about ${value.toLocaleString()} tokens` : 'cost not measured';

function Label({item}) {
  return <span className={`connection-label${item.label === 'computer' ? ' ready' : ''}`}>{item.labelText}</span>;
}

function KeyField({need, onSave}) {
  const [value, setValue] = useState('');
  return <div className="button-row">
    <label className="form-field">{need.name}{need.configured ? ' (saved, not shown)' : ''}<input type="password" autoComplete="off" value={value} placeholder={need.configured ? 'Enter a new value to replace it' : ''} onChange={e => setValue(e.target.value)}/></label>
    <button type="button" className="secondary" disabled={!value} onClick={async () => { if (await onSave(need.name, value)) setValue(''); }}>Save</button>
    {need.configured && <button type="button" className="text-button" onClick={() => onSave(need.name, null)}>Forget</button>}
  </div>;
}

const blankServer = {name: '', kind: 'program', command: '', args: [''], url: '', env: []};

function McpEditor({onAdd, onCancel}) {
  const [draft, setDraft] = useState(blankServer);
  const set = (field, value) => setDraft(previous => ({...previous, [field]: value}));
  const pickProgram = async () => { try { const file = await window.blackTeam.pick('executable'); if (file) set('command', file); } catch { /* the chooser was closed */ } };
  return <div className="harness-editor full">
    <label className="form-field full">Server name<input value={draft.name} onChange={e => set('name', e.target.value.toLowerCase())} placeholder="notes"/></label>
    <div className="mode-toggle full" role="group" aria-label="How Hermes reaches this server">{[['program', 'A program on this computer'], ['url', 'An address on this computer']].map(([id, text]) => <button type="button" key={id} className={draft.kind === id ? 'selected' : ''} aria-pressed={draft.kind === id} onClick={() => set('kind', id)}>{text}</button>)}</div>
    {draft.kind === 'program' ? <>
      <label className="form-field full">Program<div className="button-row"><input value={draft.command} onChange={e => set('command', e.target.value)} placeholder="/usr/bin/my-mcp-server"/><button type="button" className="secondary" onClick={pickProgram}>Browse</button></div></label>
      <div className="argument-list full"><strong>Argument</strong>{draft.args.map((value, index) => <div className="button-row" key={index}><input aria-label={`Argument ${index + 1}`} value={value} onChange={e => set('args', draft.args.map((item, i) => i === index ? e.target.value : item))}/><button type="button" className="text-button" onClick={() => set('args', draft.args.filter((_, i) => i !== index))}>Remove</button></div>)}<button type="button" className="secondary" onClick={() => set('args', [...draft.args, ''])}>Add argument</button><small>One value per field. They are passed exactly as typed; nothing runs through a shell.</small></div>
    </> : <label className="form-field full">Address<input value={draft.url} onChange={e => set('url', e.target.value)} placeholder="http://127.0.0.1:8000/mcp"/><small>Only a server on this computer can be added.</small></label>}
    <div className="argument-list full"><strong>Environment value</strong>{draft.env.map((item, index) => <div className="button-row" key={index}><input aria-label={`Environment name ${index + 1}`} value={item.name} placeholder="NAME" onChange={e => set('env', draft.env.map((entry, i) => i === index ? {...entry, name: e.target.value} : entry))}/><input type="password" autoComplete="off" aria-label={`Environment value ${index + 1}`} value={item.value} placeholder="value" onChange={e => set('env', draft.env.map((entry, i) => i === index ? {...entry, value: e.target.value} : entry))}/><button type="button" className="text-button" onClick={() => set('env', draft.env.filter((_, i) => i !== index))}>Remove</button></div>)}<button type="button" className="secondary" onClick={() => set('env', [...draft.env, {name: '', value: ''}])}>Add environment value</button><small>Values are kept in a private file and sent to the server only when it starts. They are never shown again.</small></div>
    <div className="button-row"><button type="button" className="primary" onClick={() => onAdd(draft)}>Add server</button><button type="button" className="text-button" onClick={onCancel}>Cancel</button></div>
  </div>;
}

export default function HermesAbilities({status, busy, onAction}) {
  const [view, setView] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [query, setQuery] = useState('');
  const [adding, setAdding] = useState(false);
  const connected = status.integrations?.hermes?.enabled;

  const load = useCallback(async refresh => {
    setLoading(true);
    try { setView(await native('hermes-abilities', refresh ? {refresh: true} : {})); setError(''); }
    catch (cause) { setError(cause.message); }
    finally { setLoading(false); }
  }, []);
  useEffect(() => { if (connected) load(false); else setView(null); }, [connected, load]);

  const save = async (change, message = 'Saved.') => {
    setError('');
    const result = await onAction('hermes-abilities-save', change, message);
    if (result) await load(false);
    return result;
  };
  const saveKey = async (name, value) => {
    const result = await onAction('hermes-key-save', value === null ? {name, remove: true} : {name, value}, value === null ? 'Forgotten.' : 'Saved. It is never shown again.');
    if (result) await load(false);
    return result;
  };
  if (!connected) return null;
  if (!view) return <div className="full"><p className="section-intro">{loading ? 'Reading what your Hermes can do…' : 'What your Hermes can do could not be read.'}</p>{error && <p role="alert" className="error-text inline-note">{error}</p>}</div>;

  const disabled = busy || loading;
  const groups = view.groups || [];
  const usable = groups.filter(group => !group.locked);
  const service = groups.filter(group => group.locked);
  const toggleGroup = (name, on) => save({toolsets: groups.filter(group => group.on && group.name !== name).map(group => group.name).concat(on ? [name] : [])});
  const categories = view.skills?.categories || [];
  const onSkills = categories.flatMap(category => category.skills).filter(skill => skill.on).map(skill => skill.id);
  const setSkills = ids => save({skills: ids});
  const search = query.trim().toLowerCase();
  const matches = skill => !search || skill.id.toLowerCase().includes(search) || skill.description.toLowerCase().includes(search);
  const onPlugins = (view.plugins || []).filter(plugin => plugin.on).map(plugin => plugin.key);
  const servers = view.mcp || [];
  const asSaved = list => list.map(server => ({name: server.name, command: server.command, args: server.args, url: server.url, envNames: (server.env || []).map(item => item.name), enabled: server.enabled}));
  const addServer = async draft => {
    const names = draft.env.filter(item => item.name);
    const entry = {name: draft.name, envNames: names.map(item => item.name), enabled: true, ...(draft.kind === 'program' ? {command: draft.command, args: draft.args.filter(Boolean)} : {url: draft.url})};
    if (!await save({mcp: [...asSaved(servers), entry]}, 'MCP server added.')) return;
    for (const item of names) if (item.value) await onAction('hermes-key-save', {name: `mcp.${draft.name}.${item.name}`, value: item.value}, 'Saved. It is never shown again.');
    setAdding(false);
    await load(false);
  };

  return <fieldset className="full hermes-abilities" disabled={disabled}>
    <div className="panel-heading"><div><h3>What Hermes can do</h3></div><button type="button" className="text-button" onClick={() => load(true)}>Read again</button></div>
    {view.problem && <p className="inline-note full">{view.problem}</p>}
    <div className="connection-card full"><div><h4>Reading cost</h4>
      <p>{typeof view.total?.tokens === 'number' ? <>Everything switched on adds {tokensText(view.total.tokens)} to every message. Black Team’s own file tools are included ({tokensText(view.companionTokens)}).</> : 'The cost of these tools is not known for this Hermes.'}{view.total?.context ? ` Your model reads up to ${view.total.context.toLocaleString()} tokens at once.` : ''}</p>
      {view.total?.warning && <p role="alert" className="error-text inline-note">{view.total.warning}</p>}</div></div>

    <details open className="full"><summary>Tool groups</summary>
      <p className="section-intro">Each group you switch on gives the model more it can do, and more to read before every reply.</p>
      {usable.map(group => <label className="checkbox-field full" key={group.name}><input type="checkbox" checked={group.on} onChange={e => toggleGroup(group.name, e.target.checked)}/><span><strong>{group.name}</strong> — {group.description}<br/><small><Label item={group}/> · {tokensText(group.tokens)}{group.ready === false ? ' · Hermes says it is not set up on this computer yet' : ''}</small></span></label>)}
      {service.length > 0 && <details><summary>Needs the always-running service ({service.length}) — not available yet</summary>{service.map(group => <label className="checkbox-field full" key={group.name}><input type="checkbox" checked={false} disabled/><span><strong>{group.name}</strong> — {group.description}<br/><small>{group.reason}</small></span></label>)}</details>}
    </details>

    <details className="full"><summary>Skills</summary>
      <p className="section-intro">Skills are written instructions the model reads when a task matches. Only a short list is added to each message ({tokensText(view.skills?.indexTokens)} for what is on). Black Team links them from your Hermes; nothing is copied.</p>
      <label className="form-field full">Search skills<input value={query} onChange={e => setQuery(e.target.value)} placeholder="for example: github"/></label>
      {categories.map(category => { const shown = category.skills.filter(matches); if (!shown.length) return null; const all = category.skills.every(skill => skill.on); const some = category.skills.some(skill => skill.on);
        return <details key={category.name} open={!!search}><summary>{category.name} ({category.skills.filter(skill => skill.on).length} of {category.skills.length} on)</summary>
          {category.description && <small>{category.description}</small>}
          <label className="checkbox-field full"><input type="checkbox" checked={all} ref={el => { if (el) el.indeterminate = some && !all; }} onChange={e => setSkills(e.target.checked ? [...new Set([...onSkills, ...category.skills.map(skill => skill.id)])] : onSkills.filter(id => !category.skills.some(skill => skill.id === id)))}/><span>All of {category.name}</span></label>
          {shown.map(skill => <label className="checkbox-field full" key={skill.id}><input type="checkbox" checked={skill.on} onChange={e => setSkills(e.target.checked ? [...onSkills, skill.id] : onSkills.filter(id => id !== skill.id))}/><span><strong>{skill.name}</strong> — {skill.description}</span></label>)}
        </details>; })}
      {(view.skills?.optional || []).length > 0 && <details><summary>Optional skills ({view.skills.optional.length}) — optional, off</summary>{view.skills.optional.filter(matches).map(skill => <p className="inline-note" key={skill.id}><strong>{skill.name}</strong> — {skill.description} <small>(optional, off)</small></p>)}<small>Optional skills are installed with Hermes itself.</small></details>}
      <label className="checkbox-field full"><input type="checkbox" checked={!!view.skills?.own?.on} onChange={e => save({ownSkills: e.target.checked})}/><span>Your own skills — {view.skills?.own?.count || 0} found in <code>{view.skills?.own?.folder}</code>. Put a folder with a SKILL.md inside to add one.</span></label>
    </details>

    <details className="full"><summary>Plugins</summary>
      <p className="section-intro">Extra abilities that come with Hermes, or that you installed in it. Anything that sends data off this computer says so.</p>
      {(view.plugins || []).filter(plugin => !plugin.locked).map(plugin => <div key={plugin.key} className="full"><label className="checkbox-field full"><input type="checkbox" checked={plugin.on} disabled={plugin.locked} onChange={e => save({plugins: e.target.checked ? [...onPlugins, plugin.key] : onPlugins.filter(key => key !== plugin.key)})}/><span><strong>{plugin.name}</strong>{plugin.yours ? ' (installed by you)' : ''} — {plugin.description}<br/><small><Label item={plugin}/>{plugin.reason ? ` · ${plugin.reason}` : ''}{plugin.note ? ` · ${plugin.note}` : ''}</small></span></label>
        {plugin.on && plugin.needs.map(need => <KeyField key={need.name} need={need} onSave={saveKey}/>)}</div>)}
      {(view.plugins || []).some(plugin => plugin.locked) && <details><summary>Left off ({(view.plugins || []).filter(plugin => plugin.locked).length}): memory providers and messaging platforms</summary>{(view.plugins || []).filter(plugin => plugin.locked).map(plugin => <p className="inline-note" key={plugin.key}><strong>{plugin.name}</strong> — {plugin.reason}</p>)}</details>}
      <h4>Web search</h4>
      <p className="section-intro">Used when the Web group is on. Choose one; without a choice, search does not run. Providers that need no key come first.</p>
      <label className="form-field full">Search provider<select value={view.web?.selected || ''} onChange={e => save({webSearch: e.target.value})}><option value="">None</option>{(view.web?.providers || []).map(provider => <option key={provider.name} value={provider.name}>{provider.name} — {provider.needsKey ? 'needs a key or address' : 'no key'}</option>)}</select></label>
      {(view.web?.providers || []).filter(provider => provider.name === view.web.selected).map(provider => <div key={provider.name} className="full"><small>{provider.description}{provider.missingPackage ? ` Your Hermes does not have the “${provider.missingPackage}” package yet.` : ''}</small><br/><small>Searches are sent to the search service, so the words you search for leave this computer.</small>{provider.needs.map(need => <KeyField key={need.name} need={need} onSave={saveKey}/>)}</div>)}
    </details>

    <details className="full"><summary>MCP servers ({servers.length})</summary>
      <p className="section-intro">Extra tool servers for Hermes conversations. Each one adds its tools to every message.</p>
      {servers.map(server => <div className="harness-editor full" key={server.name}>
        <label className="checkbox-field full"><input type="checkbox" checked={server.enabled} onChange={e => save({mcp: asSaved(servers).map(item => item.name === server.name ? {...item, enabled: e.target.checked} : item)})}/><span><strong>{server.name}</strong> — <code>{server.url || [server.command, ...server.args].join(' ')}</code><br/><small>{typeof server.tokens === 'number' ? tokensText(server.tokens) : 'Reading cost: not measured (known after its first conversation)'}</small></span></label>
        {server.env.map(item => <KeyField key={item.name} need={{name: item.name, configured: item.configured}} onSave={(name, value) => onAction('hermes-key-save', value === null ? {name: `mcp.${server.name}.${name}`, remove: true} : {name: `mcp.${server.name}.${name}`, value}, 'Saved.').then(result => { if (result) load(false); return result; })}/>)}
        <button type="button" className="text-button" onClick={() => save({mcp: asSaved(servers).filter(item => item.name !== server.name)}, 'MCP server removed.')}>Remove {server.name}</button>
      </div>)}
      {adding ? <McpEditor onAdd={addServer} onCancel={() => setAdding(false)}/> : <button type="button" className="secondary" disabled={servers.length >= 12} onClick={() => setAdding(true)}>Add an MCP server</button>}
    </details>
    {error && <p role="alert" className="error-text inline-note">{error}</p>}
  </fieldset>;
}
