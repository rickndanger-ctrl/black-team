import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('configure_jev',Path(__file__).parents[1]/'scripts/configure-jev.py')
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class JevKeyTests(unittest.TestCase):
    def test_private_storage_is_disabled_and_replaces_without_printing(self):
        with tempfile.TemporaryDirectory() as directory:
            file=Path(directory)/'private/jev.json'
            module.save_key(file,'fixture-key')
            self.assertEqual(json.loads(file.read_text()),{'api_key':'fixture-key','enabled':False})
            self.assertEqual(file.stat().st_mode&0o777,0o600)
            self.assertEqual(file.parent.stat().st_mode&0o777,0o700)
            module.save_key(file,'replacement')
            self.assertEqual(json.loads(file.read_text())['api_key'],'replacement')
            self.assertEqual(len(list(file.parent.iterdir())),1)
            with self.assertRaises(ValueError):module.save_key(file,'bad\nkey')
    def test_symlink_is_not_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            original=Path(directory)/'original'
            original.write_text('unchanged')
            link=Path(directory)/'key'
            link.symlink_to(original)
            with self.assertRaises(ValueError):module.save_key(link,'fixture')
            self.assertEqual(original.read_text(),'unchanged')
