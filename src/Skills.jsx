import React, {useEffect, useState} from 'react';

// The skills Code has saved: routines that worked, as folders with a SKILL.md (the format Hermes reads too).
export default function SkillsTab({call, onError, onNotice}) {
  const [data, setData] = useState(null);
  const [open, setOpen] = useState(null);       // {name, text}
  const [draft, setDraft] = useState('');
  const [sure, setSure] = useState('');          // the skill whose Delete is waiting for a second press
  const [busy, setBusy] = useState(false);
  const load = () => call('skills').then(setData).catch(cause => onError(cause.message));
  useEffect(() => {load();}, []);
  const run = async work => {setBusy(true); try {await work();} catch (cause) {onError(cause.message);} finally {setBusy(false);}};
  const view = name => run(async () => {const value = await call(`skills/view?name=${encodeURIComponent(name)}`); setOpen(value); setDraft(value.text);});
  const save = () => run(async () => {setData(await call('skills/save', {name: open.name, text: draft})); setOpen({...open, text: draft}); onNotice(`Saved ${open.name}.`);});
  const toggle = skill => run(async () => setData(await call('skills/enable', {name: skill.name, on: !skill.enabled})));
  const remove = name => run(async () => {setData(await call('skills/remove', {name})); setSure(''); if (open?.name === name) setOpen(null); onNotice(`Removed ${name}. It was moved to the skills trash folder.`);});
  const choose = patch => run(async () => {await call('code/settings', patch); await load();});
  if (!data) return <p className="memory-empty">Opening skills…</p>;
  const dirty = open && draft !== open.text;
  return <div className="skills-page">
    <div className="memory-card">
      <small>SKILLS</small>
      <h2>Routines Code has saved</h2>
      <p>When Code finishes something that worked, it can save the steps as a skill. New conversations are told the names and one-line descriptions; Code loads a skill only when it needs it, and still asks before it runs anything. The files are in <code>{data.folder}</code> and Hermes can use the same ones from the Hermes screen. Nothing here leaves this computer.</p>
      <label className="checkbox-field full"><input type="checkbox" checked={!!data.saveWithoutAsking} disabled={busy} onChange={event => choose({saveSkillsWithoutAsking: event.target.checked})}/><span><strong>Save skills without asking</strong><small>Off: Code shows each new skill and waits for your yes, as it does for a file write. Replacing a skill always asks.</small></span></label>
      <label className="checkbox-field full"><input type="checkbox" checked={!!data.projectWritable} disabled={busy} onChange={event => choose({projectSkillsWritable: event.target.checked})}/><span><strong>Let Code save into a project's skills folder</strong><small>A project can have its own <code>skills/</code> folder. Code reads it; it writes there only if you turn this on.</small></span></label>
    </div>
    {data.skills.length ? <div className="skills-list">{data.skills.map(skill => <div className="memory-card" key={skill.name + skill.source}>
      <small>{skill.source === 'project' ? 'PROJECT SKILL (READ ONLY)' : 'SKILL'}{skill.enabled ? '' : ' · OFF'}</small>
      <h2>{skill.name}</h2>
      <p>{skill.description || 'No description.'}</p>
      <div className="button-row">
        <button className="secondary" disabled={busy} onClick={() => view(skill.name)}>{skill.editable ? 'View and edit' : 'View'}</button>
        <button className="secondary" disabled={busy} onClick={() => toggle(skill)}>{skill.enabled ? 'Turn off' : 'Turn on'}</button>
        {skill.editable && (sure === skill.name
          ? <><button className="primary" disabled={busy} onClick={() => remove(skill.name)}>Yes, delete it</button><button className="secondary" disabled={busy} onClick={() => setSure('')}>Keep it</button></>
          : <button className="secondary" disabled={busy} onClick={() => setSure(skill.name)}>Delete</button>)}
      </div>
    </div>)}</div> : <p className="memory-empty">No skills yet. They appear here after Code saves one.</p>}
    {open && <div className="memory-editor">
      <div className="memory-editor-head"><div><strong>{open.name}</strong><small>SKILL.md · starts with a name and a description between --- lines</small></div>
        <div className="button-row"><button className="secondary" onClick={() => setOpen(null)}>Close</button>{data.skills.find(item => item.name === open.name)?.editable && <button className="primary" disabled={busy || !dirty} onClick={save}>{dirty ? 'Save' : 'Saved'}</button>}</div></div>
      <textarea value={draft} spellCheck={false} readOnly={!data.skills.find(item => item.name === open.name)?.editable} aria-label={`Skill ${open.name}`} onChange={event => setDraft(event.target.value)}/>
    </div>}
  </div>;
}
