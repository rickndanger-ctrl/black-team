"""Companion's interactive Hermes host: stream events with an actual approval UI.

The CLI one-shot mode deliberately denies interactive actions. This host uses the
installed Hermes session owner and its normal approval callbacks instead. No core
Hermes modules are modified or monkey-patched.
"""
import sys
import os
sys.path.insert(0, os.environ['BLACK_TEAM_HERMES_SOURCE'])
# Session profiles isolate history and settings, not the installed dependency
# store. Resolve Hermes' own store before the profile overrides its home;
# otherwise newer Hermes creates another Python/tool environment for every chat.
from pathlib import Path
profile_home = os.environ.pop('HERMES_HOME', None) or os.environ.get('BLACK_TEAM_HERMES_PROFILE')
if profile_home:
    # Hermes may exec a selected interpreter during bootstrap.
    os.environ['BLACK_TEAM_HERMES_PROFILE'] = profile_home
try:
    if not os.environ.get('HERMES_RUNTIME_DIR'):
        from pm.environments import store_root
        os.environ['HERMES_RUNTIME_DIR'] = str(store_root(Path(os.environ['BLACK_TEAM_HERMES_SOURCE'])))
    # Dependency activation also resolves install generations from the home.
    # Bootstrap against the installed home, then restore the isolated session.
    import hermes_bootstrap
finally:
    if profile_home is not None:
        os.environ['HERMES_HOME'] = profile_home
# Bootstrap exports scratch paths; rederive them for the restored conversation.
if callable(getattr(hermes_bootstrap, 'export_scratch_tmp_env', None)):
    hermes_bootstrap.export_scratch_tmp_env()
import argparse
import os
import atexit
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('--query-file',required=True)
parser.add_argument('--toolsets',required=True)
parser.add_argument('--reasoning',default='none')
parser.add_argument('--resume')
parser.add_argument('--in',dest='workspace',required=True)
parser.add_argument('--max-turns',type=int,default=48)
parser.add_argument('--run-budget',type=float,default=1800)
args=parser.parse_args()
os.chdir(args.workspace)
os.environ['TERMINAL_CWD']=args.workspace
os.environ['HERMES_INTERACTIVE']='1'
os.environ.pop('HERMES_SINGLE_QUERY_SESSION',None)

runtime_context=int(os.environ['BLACK_TEAM_CONTEXT'])

from cli import HermesCLI,_run_cleanup,_install_single_query_signal_handlers
from hermes_cli.stream_json import StreamJsonEmitter
from hermes_cli.plugins import get_plugin_manager
from hermes_cli.approval_transport import ApprovalRequest
from tools.terminal_tool import set_approval_callback
from tools.computer_use.tool import set_approval_callback as set_computer_approval
from agent.redact import redact_sensitive_text

cli=HermesCLI(toolsets=args.toolsets.split(','),reasoning=args.reasoning,
              max_turns=args.max_turns,run_budget=args.run_budget,resume=args.resume,
              checkpoints=True,verbose=False)
# The app's selected folder is explicit on every turn, including resume.
os.chdir(args.workspace);os.environ['TERMINAL_CWD']=args.workspace
cli.tool_progress_mode='off'
atexit.register(_run_cleanup)
_install_single_query_signal_handlers(cli)
emitter=StreamJsonEmitter(model=getattr(cli,'model',''),session_id=cli.session_id or '')

def approval(command,description,**kwargs):
    registered=get_plugin_manager().get_approval_transport('companion')
    if registered is None:return 'deny'
    request=ApprovalRequest.create(command=redact_sensitive_text(command,force=True),
       description=redact_sensitive_text(description,force=True),pattern_key='companion-action',
       pattern_keys=('companion-action',),session_key=cli.session_id or '',surface='companion',
       allow_session=False,allow_permanent=False,timeout_seconds=300)
    decision=registered.present(request)
    return decision.choice if decision.request_id==request.request_id and decision.request_digest==request.digest else 'deny'

try:
    if not cli._claim_active_session('cli',stderr=True):raise RuntimeError('This Hermes session is already running.')
    if not cli._ensure_runtime_credentials() or not cli._init_agent():raise RuntimeError('Hermes could not initialize the configured local model.')
    set_approval_callback(approval);set_computer_approval(approval)
    emitter.attach(cli.agent)
    cli.agent.status_callback=lambda phase,message: emitter._emit({'type':'camp_status','phase':str(phase),'message':str(message)})
    emitter._emit({'type':'camp_status','phase':'ready','message':f'Hermes tools ready · {runtime_context:,} token context · local compaction enabled'})
    # Hermes owns persistence and tool cleanup. Its existing history is restored by the session owner.
    result=cli.agent.run_conversation(user_message=Path(args.query_file).read_text(),conversation_history=cli.conversation_history)
    code=1 if result.get('failed') or result.get('partial') or result.get('completed') is False else 0
    sys.exit(emitter.emit_result(result,session_id=cli.agent.session_id or cli.session_id,exit_code=code))
except KeyboardInterrupt:
    sys.exit(emitter.emit_result({'failed':True,'error':'Agent stopped.'},session_id=cli.session_id,exit_code=130))
except Exception as error:
    sys.exit(emitter.emit_result({'failed':True,'error':str(error)},session_id=cli.session_id,exit_code=1))
