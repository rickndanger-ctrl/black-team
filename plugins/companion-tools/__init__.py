"""Hermes plugin: private artifacts, Taildrop, and Companion approval cards."""
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import threading
import time
import uuid

_lock = threading.Lock()

def emit(event):
    print(json.dumps(event), flush=True)

def ask(request_id, digest, command, description, timeout=300):
    with _lock:
        emit({'type':'companion_approval','id':request_id,'digest':digest,'command':command,
              'description':description,'expires':int((time.time()+timeout)*1000)})
        deadline=time.monotonic()+timeout
        try:
            while time.monotonic()<deadline:
                readable,_,_=select.select([sys.stdin],[],[],max(0,deadline-time.monotonic()))
                if not readable:break
                line=sys.stdin.readline()
                if not line:break
                try:answer=json.loads(line)
                except ValueError:continue
                if answer.get('id')==request_id and answer.get('digest')==digest:
                    return 'once' if answer.get('choice')=='once' else 'deny'
            return 'deny'
        finally:emit({'type':'companion_approval_closed','id':request_id})

def present(request):
    return request.respond(ask(request.request_id,request.digest,request.command,request.description,request.timeout_seconds))

def own_devices():
    status=json.loads(subprocess.check_output(['tailscale','status','--json'],timeout=10))
    owner=status['Self']['UserID']
    return [{'id':p['ID'],'name':p['HostName'],'os':p.get('OS',''),'online':p.get('Online',False),
             'ip':p['TailscaleIPs'][0]} for p in status.get('Peer',{}).values()
            if p.get('UserID')==owner and p.get('TailscaleIPs') and not p.get('Tags')]

def publish(source):
    workspace=Path(os.environ['COMPANION_WORKSPACE']).resolve()
    source=Path(source).expanduser()
    if not source.is_absolute():source=workspace/source
    source=source.resolve(strict=True)
    if not source.is_relative_to(workspace):raise ValueError('Publish files from the chosen workspace. Copy the intended deliverable there first.')
    if not source.is_file():raise ValueError('Publish a regular file; zip folders first.')
    if any(part in {'.env','.ssh','.gnupg','.git'} or part.startswith('.env.') for part in source.relative_to(workspace).parts):
        raise ValueError('Credential/configuration files cannot be published as deliverables.')
    if source.stat().st_size>250*1024*1024:raise ValueError('File exceeds the 250 MB delivery limit.')
    key=uuid.uuid4().hex
    dest=Path(os.environ['COMPANION_ARTIFACT_DIR'])/key
    shutil.copyfile(source,dest);dest.chmod(0o600)
    record={'id':key,'name':source.name,'size':dest.stat().st_size,'sha256':hashlib.sha256(dest.read_bytes()).hexdigest()}
    emit({'type':'companion_artifact',**record})
    return record

def files(args,**kwargs):
    try:
        action=args.get('action')
        if action=='devices':return json.dumps({'devices':own_devices()})
        if action not in {'publish','send'}:raise ValueError('Choose publish, devices, or send.')
        record=publish(args['path'])
        if action=='publish':return json.dumps({'published':record,'message':'File is attached in Companion. You can download it on his phone over Tailscale.'})
        matches=[d for d in own_devices() if d['id']==args.get('device_id')]
        if len(matches)!=1:raise ValueError('Select a device_id returned by devices.')
        device=matches[0]
        if not device['online']:raise ValueError('This device is offline. File remains attached for download.')
        command=f'Send {record["name"]} ({record["size"]} bytes) to {device["name"]} ({device["os"]}) via Taildrop'
        if ask(uuid.uuid4().hex,record['sha256'],command,'Deliver this file to your own device?')!='once':
            return json.dumps({'published':record,'sent':False,'message':'Transfer was not approved. File is still attached.'})
        # Use a named snapshot so the phone receives the original filename.
        spool=Path(os.environ['COMPANION_ARTIFACT_DIR'])
        delivery=spool/('send-'+record['id']);delivery.mkdir(mode=0o700)
        target=delivery/record['name'];shutil.copyfile(spool/record['id'],target)
        try:
            result=subprocess.run(['tailscale','file','cp',str(target),device['ip']+':'],capture_output=True,text=True,timeout=120)
            if result.returncode:raise RuntimeError(result.stderr[-1000:] or 'Taildrop failed')
        finally:shutil.rmtree(delivery)
        emit({'type':'companion_delivery','artifactId':record['id'],'device':device['name']})
        return json.dumps({'published':record,'sent':True,'device':device['name']})
    except Exception as error:return json.dumps({'error':str(error)})

SCHEMA={'name':'companion_files','description':'Attach a workspace file to Companion for private download, list your own Tailscale devices, or send a file with Taildrop after the user approves the transfer in the app. Publish final deliverables with this tool so they appear as download cards.','parameters':{'type':'object','properties':{'action':{'type':'string','enum':['publish','devices','send']},'path':{'type':'string','description':'Path to a file inside the selected workspace.'},'device_id':{'type':'string','description':'Exact ID returned by devices; required for send.'}},'required':['action']}}

def register(ctx):
    ctx.register_approval_transport('companion',present)
    ctx.register_tool(name='companion_files',toolset='companion',schema=SCHEMA,handler=files)
