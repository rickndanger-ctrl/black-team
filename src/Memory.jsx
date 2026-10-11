import React,{useEffect,useMemo,useState} from 'react';

// A small force layout: notes push apart, links pull together. Enough for a few hundred notes.
function layout(nodes,edges,width=1000,height=620){
 const count=nodes.length;if(!count)return new Map();
 const index=new Map(nodes.map((n,i)=>[n.id,i]));
 const x=nodes.map((_,i)=>Math.cos(i/count*Math.PI*2)*220+Math.sin(i*7.3)*40),y=nodes.map((_,i)=>Math.sin(i/count*Math.PI*2)*220+Math.cos(i*5.1)*40);
 const links=edges.map(e=>[index.get(e.from),index.get(e.to)]).filter(([a,b])=>a!==undefined&&b!==undefined);
 const spread=Math.max(70,Math.min(170,1000/Math.sqrt(count)));
 for(let step=0;step<260;step++){
  const fx=new Float64Array(count),fy=new Float64Array(count),cool=1-step/260;
  for(let a=0;a<count;a++)for(let b=a+1;b<count;b++){let dx=x[a]-x[b],dy=y[a]-y[b],d2=dx*dx+dy*dy||0.01;const f=spread*spread/d2;dx*=f;dy*=f;fx[a]+=dx;fy[a]+=dy;fx[b]-=dx;fy[b]-=dy;}
  for(const [a,b] of links){const dx=x[b]-x[a],dy=y[b]-y[a],d=Math.sqrt(dx*dx+dy*dy)||0.01,f=(d-spread)/d*0.5;fx[a]+=dx*f;fy[a]+=dy*f;fx[b]-=dx*f;fy[b]-=dy*f;}
  for(let i=0;i<count;i++){fx[i]-=x[i]*0.11;fy[i]-=y[i]*0.11;const m=Math.sqrt(fx[i]*fx[i]+fy[i]*fy[i])||1,cap=Math.min(m,30*cool+2);x[i]+=fx[i]/m*cap;y[i]+=fy[i]/m*cap;}
 }
 const minX=Math.min(...x),maxX=Math.max(...x),minY=Math.min(...y),maxY=Math.max(...y),pad=70;
 const sx=(width-pad*2)/Math.max(1,maxX-minX),sy=(height-pad*2)/Math.max(1,maxY-minY),scale=Math.min(sx,sy,3.2);
 const ox=(width-(maxX-minX)*scale)/2,oy=(height-(maxY-minY)*scale)/2;
 return new Map(nodes.map((n,i)=>[n.id,{x:(x[i]-minX)*scale+ox,y:(y[i]-minY)*scale+oy}]));
}

function Graph({graph,selected,onOpen}){
 const [hover,setHover]=useState(null);
 const key=graph.nodes.map(n=>n.id).join('|')+'#'+graph.edges.length;
 const positions=useMemo(()=>layout(graph.nodes,graph.edges),[key]);
 const degree=useMemo(()=>{const d=new Map();for(const e of graph.edges){d.set(e.from,(d.get(e.from)||0)+1);d.set(e.to,(d.get(e.to)||0)+1);}return d;},[key]);
 const focus=hover||selected;
 const near=useMemo(()=>{if(!focus)return null;const s=new Set([focus]);for(const e of graph.edges){if(e.from===focus)s.add(e.to);if(e.to===focus)s.add(e.from);}return s;},[focus,key]);
 if(!graph.nodes.length)return <p className="memory-empty">No notes yet. Notes and the links between them appear here.</p>;
 return <svg className="memory-graph" viewBox="0 0 1000 620" role="img" aria-label={`Memory graph: ${graph.nodes.length} notes, ${graph.edges.length} links`}>
  {graph.edges.map((e,i)=>{const a=positions.get(e.from),b=positions.get(e.to);if(!a||!b)return null;const lit=near&&(e.from===focus||e.to===focus);return <line key={i} x1={a.x} y1={a.y} x2={b.x} y2={b.y} className={lit?'lit':near?'dim':''}/>;})}
  {graph.nodes.map(n=>{const p=positions.get(n.id);if(!p)return null;const r=5+Math.min(9,(degree.get(n.id)||0)*1.6);const cls=[n.missing?'missing':n.kind==='project'?'own':n.kind==='core'?'core':'yours',n.id===selected?'selected':'',near&&!near.has(n.id)?'dim':''].join(' ');
   return <g key={n.id} className={cls} transform={`translate(${p.x},${p.y})`} onMouseEnter={()=>setHover(n.id)} onMouseLeave={()=>setHover(null)} onClick={()=>!n.missing&&onOpen(n.id)} tabIndex={n.missing?undefined:0} onKeyDown={e=>{if(e.key==='Enter'&&!n.missing)onOpen(n.id);}}><title>{n.missing?`${n.title} (not written yet)`:n.id}</title><circle r={r}/><text y={r+13}>{n.title.length>26?n.title.slice(0,25)+'…':n.title}</text></g>;})}
 </svg>;
}

export default function MemoryPage({call,onError,status,onUseProject}){
 const [data,setData]=useState(null),[tab,setTab]=useState('graph'),[note,setNote]=useState(null),[draft,setDraft]=useState(''),[query,setQuery]=useState(''),[hits,setHits]=useState(null),[busy,setBusy]=useState(false),[name,setName]=useState(''),[message,setMessage]=useState(''),[naming,setNaming]=useState(null);
 const load=()=>call('memory').then(setData).catch(e=>onError(e.message));
 useEffect(()=>{load();},[]);
 useEffect(()=>{if(!query.trim()){setHits(null);return;}let alive=true;const t=setTimeout(()=>call('memory/search?q='+encodeURIComponent(query)).then(r=>{if(alive)setHits(r.hits);}).catch(()=>{}),250);return()=>{alive=false;clearTimeout(t);};},[query]);
 async function open(id){try{const n=await call('memory/note?id='+encodeURIComponent(id));setNote(n);setDraft(n.content);setTab('notes');}catch(e){onError(e.message);}}
 async function save(){setBusy(true);try{const n=await call('memory/save',{id:note.id,content:draft});setNote(n);await load();}catch(e){onError(e.message);}finally{setBusy(false);}}
 async function remove(){if(!window.confirm(`Move "${note.title}" to the vault's trash?`))return;setBusy(true);try{await call('memory/delete',{id:note.id});setNote(null);await load();}catch(e){onError(e.message);}finally{setBusy(false);}}
 async function create(event){event.preventDefault();const title=(naming||'').trim();if(!title)return;setBusy(true);try{const n=await call('memory/save',{id:title,content:`# ${title}\n\n`});setNaming(null);setNote(n);setDraft(n.content);setTab('notes');await load();}catch(e){onError(e.message);}finally{setBusy(false);}}
 async function tidy(){setBusy(true);setMessage('');try{const r=await call('memory/tidy',{});setMessage(r.message);await load();}catch(e){onError(e.message);}finally{setBusy(false);}}
 async function project(){setBusy(true);try{const p=await call('project-create',{name});setName('');setMessage(`Created ${p.name} in ${p.workspace}.`);await load();}catch(e){onError(e.message);}finally{setBusy(false);}}
 if(!status?.memory)return <div className="notice"><p>Memory is unavailable.</p></div>;
 if(!data)return <p className="memory-empty">Opening memory…</p>;
 const usage=data.keeper.usage,groups=new Map();
 for(const n of data.notes){if(n.kind==='archive')continue;const folder=n.id.includes('/')?n.id.slice(0,n.id.lastIndexOf('/')):'Vault';if(!groups.has(folder))groups.set(folder,[]);groups.get(folder).push(n);}
 const dirty=note&&draft!==note.content;
 return <section className="memory">
  <div className="memory-bar"><div className="mode-toggle" role="group" aria-label="Memory view">{[['graph','Graph'],['notes','Notes'],['projects','Projects']].map(([id,label])=><button key={id} className={tab===id?'selected':''} aria-pressed={tab===id} onClick={()=>setTab(id)}>{label}</button>)}</div>
   <input className="memory-search" value={query} placeholder="Search memory" aria-label="Search memory" onChange={e=>setQuery(e.target.value)}/>
   {naming===null?<button className="secondary" disabled={busy} onClick={()=>setNaming('')}>＋ Note</button>:<form className="memory-new" onSubmit={create}><input className="memory-search" autoFocus value={naming} maxLength={80} placeholder="Name the new note" aria-label="New note name" onChange={e=>setNaming(e.target.value)} onKeyDown={e=>{if(e.key==='Escape')setNaming(null);}}/><button className="primary" disabled={busy||!naming.trim()}>Create</button></form>}</div>
  <div className="memory-usage" title="Everything in the Black Team vault, against its limit"><div><span>Vault</span><strong>{usage.notes} notes · {usage.percent}% of limit</strong></div><div className="meter"><i style={{width:Math.min(100,usage.percent)+'%'}}/></div><small>{usage.oversized.length?`${usage.oversized.length} note${usage.oversized.length>1?'s':''} over the per-note limit`:'All notes within limits'}{usage.archived?` · ${usage.archived} archived`:''}</small><button className="secondary" disabled={busy||status.job?.state==='running'} onClick={tidy}>Tidy now</button></div>
  {message&&<p className="memory-message" role="status">{message}</p>}
  {data.notes.every(n=>n.kind==='core')&&!data.coreWritten&&<div className="memory-intro"><p><strong>Your vault is set up and waiting.</strong> Code saves facts here as it works, and writes a journal for each project. Chat looks things up here for every message. <em>Remember this</em> under any reply saves it too. Nothing in this folder leaves your computer.</p><p>Start with Core: a few lines every conversation is told, such as how you like answers and what you are working on.</p><div className="button-row"><button className="primary" disabled={busy} onClick={()=>open('Core')}>Write Core</button></div></div>}
  {hits?<div className="memory-hits">{hits.length?hits.map((h,i)=><button key={i} onClick={()=>{open(h.id);setQuery('');}}><strong>{h.title}</strong><small>{h.id} · line {h.line}</small><span>{h.text}</span></button>):<p className="memory-empty">Nothing matches.</p>}</div>
  :tab==='graph'?<><Graph graph={data.graph} selected={note?.id} onOpen={open}/><p className="memory-legend"><i className="own"/>Project memory<i className="yours"/>General notes<i className="core"/>Core<i className="missing"/>Linked, not written yet<span>{data.graph.nodes.filter(n=>!n.missing).length} notes · {data.graph.edges.length} links · click a note to open it</span></p></>
  :tab==='projects'?<div className="memory-projects"><div className="memory-card"><small>NEW PROJECT</small><h2>Start a project</h2><p>A project gets a folder inside your workspace and its own notes and journal in memory. Code conversations in that folder are journaled automatically.</p><div className="memory-new"><input className="memory-search" value={name} maxLength={60} placeholder="Project name" aria-label="Project name" disabled={busy} onChange={e=>setName(e.target.value)} onKeyDown={e=>{if(e.key==='Enter'&&name.trim())project();}}/><button className="primary" disabled={busy||!name.trim()} onClick={project}>Create project</button></div></div>
   {status.projects?.length?status.projects.map(p=><div className="memory-card" key={p.id}><small>{p.exists?'PROJECT':'FOLDER MISSING'}</small><h2>{p.name}</h2><p className="file-path">{p.workspace}</p><div className="button-row"><button className="primary" disabled={!p.exists} onClick={()=>onUseProject(p)}>Work on it in Code</button><button className="secondary" onClick={()=>open(`${p.notes}/Overview`)}>Open its notes</button></div></div>):<p className="memory-empty">No projects yet.</p>}</div>
  :<div className="memory-notes"><div className="memory-list">{[...groups.entries()].map(([folder,list])=><div key={folder}><small>{folder}</small>{list.map(n=><button key={n.id} className={note?.id===n.id?'selected':''} onClick={()=>open(n.id)}>{n.title}</button>)}</div>)}</div>
   <div className="memory-editor">{note?<><div className="memory-editor-head"><div><strong>{note.title}</strong><small>{note.id}.md · {new Date(note.updated).toLocaleString()}</small></div><div className="button-row"><button className="secondary" disabled={busy} onClick={remove}>Delete</button><button className="primary" disabled={busy||!dirty} onClick={save}>{dirty?'Save':'Saved'}</button></div></div><textarea value={draft} spellCheck={false} aria-label={`Note ${note.title}`} onChange={e=>setDraft(e.target.value)}/><small className="memory-hint">Markdown. Link notes with [[Note name]]. The note named Core is told to every conversation. Stored only in the Black Team vault on this computer.</small></>:<p className="memory-empty">Choose a note, or open one from the graph.</p>}</div></div>}
  {data.keeper.actions.length>0&&tab!=='notes'&&!hits&&<div className="memory-keeper"><small>KEEPER · RECENT UPKEEP</small>{data.keeper.actions.slice(0,5).map((a,i)=><p key={i}><time>{new Date(a.at).toLocaleDateString()}</time>{a.text}</p>)}</div>}
 </section>;
}
