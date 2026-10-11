import unittest
import importlib.util
import tempfile
import os
import io
import json
from pathlib import Path
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('companion_plugin',Path(__file__).resolve().parents[1]/'plugins/companion-tools/__init__.py')
plugin=importlib.util.module_from_spec(spec);spec.loader.exec_module(plugin)
class PluginTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name);self.workspace=self.root/'workspace';self.workspace.mkdir();self.spool=self.root/'artifacts';self.spool.mkdir()
  self.env=patch.dict(os.environ,{'COMPANION_WORKSPACE':str(self.workspace),'COMPANION_ARTIFACT_DIR':str(self.spool)});self.env.start()
 def tearDown(self):self.env.stop();self.temp.cleanup()
 def test_publish_is_private_snapshot(self):
  source=self.workspace/'hello.txt';source.write_text('hello')
  with patch.object(plugin,'emit') as emit:record=plugin.publish('hello.txt')
  source.write_text('changed');self.assertEqual((self.spool/record['id']).read_text(),'hello')
  self.assertEqual((self.spool/record['id']).stat().st_mode&0o777,0o600)
  self.assertEqual(emit.call_args.args[0]['type'],'companion_artifact')
 def test_outside_workspace_rejected(self):
  source=self.root/'outside';source.write_text('private')
  with self.assertRaises(ValueError):plugin.publish(str(source))
 def test_symlink_escape_rejected(self):
  source=self.root/'outside';source.write_text('private');(self.workspace/'link').symlink_to(source)
  with self.assertRaises(ValueError):plugin.publish('link')
 def test_env_file_rejected(self):
  (self.workspace/'.env').write_text('SECRET=private')
  with self.assertRaises(ValueError):plugin.publish('.env')
 def test_approval_is_bound_to_exact_request(self):
  read,write=os.pipe();os.write(write,(json.dumps({'id':'wrong','digest':'hash','choice':'once'})+'\n'+json.dumps({'id':'id','digest':'hash','choice':'deny'})+'\n').encode());os.close(write)
  with os.fdopen(read) as stream,patch.object(plugin.sys,'stdin',stream),patch.object(plugin,'emit'):
   self.assertEqual(plugin.ask('id','hash','command','description',1),'deny')
 def test_timed_out_approval_denied(self):
  with patch.object(plugin,'emit'):self.assertEqual(plugin.ask('id','hash','cmd','desc',0),'deny')
 def test_devices_only_owned_untagged(self):
  data={'Self':{'UserID':1},'Peer':{'a':{'ID':'a','UserID':1,'HostName':'phone','OS':'iOS','Online':True,'TailscaleIPs':['100.1.1.1']},'b':{'ID':'b','UserID':2,'TailscaleIPs':['100.1.1.2']},'c':{'ID':'c','UserID':1,'Tags':['tag:shared'],'TailscaleIPs':['100.1.1.3']}}}
  with patch.object(plugin.subprocess,'check_output',return_value=json.dumps(data)):
   self.assertEqual([d['id'] for d in plugin.own_devices()],['a'])
