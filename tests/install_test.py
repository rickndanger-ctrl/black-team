import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest
import zipfile


PROJECT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('black_team_packager', PROJECT / 'scripts/package.py')
PACKAGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGER)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='black-team-install-test-')
        self.root = Path(self.temporary.name)
        self.project = self.root / 'project'
        self.project.mkdir()
        for folder in ('scripts', 'docs', 'lib', 'dist', 'node_modules'):
            (self.project / folder).mkdir()
        for source in ('scripts/install.sh', 'docs/DISTRIBUTION.md', 'THIRD-PARTY-NOTICES.md'):
            shutil.copyfile(PROJECT / source, self.project / source)
        (self.project / 'main.cjs').write_text('// Fixture only.\n')
        (self.project / 'preload.cjs').write_text('// Fixture only.\n')
        (self.project / 'lib/config.cjs').write_text('module.exports = {};\n')
        (self.project / 'dist/index.html').write_text('<title>Fixture</title>')
        (self.project / 'dist/black-team-512.png').write_bytes(b'fixture icon')
        for dependency in ('react', 'react-dom', 'scheduler'):
            folder = self.project / 'node_modules' / dependency
            folder.mkdir()
            (folder / 'LICENSE').write_text('Fixture dependency notice')
        self.runtime = self.root / 'runtime.zip'
        with zipfile.ZipFile(self.runtime, 'w') as archive:
            for name, data in {'electron': '#!/bin/sh\nprintf "fixture runtime\\n"\n', 'LICENSE': 'Fixture MIT',
                               'LICENSES.chromium.html': 'Fixture notices', 'version': '40.10.2'}.items():
                entry = zipfile.ZipInfo(name)
                entry.external_attr = (stat.S_IFREG | (0o755 if name == 'electron' else 0o644)) << 16
                archive.writestr(entry, data)
        for name in ('scripts/agent-runner.py', 'plugins/companion-tools/__init__.py', 'plugins/companion-tools/plugin.yaml'):
            target=self.project/name
            target.parent.mkdir(parents=True,exist_ok=True)
            target.write_text('fixture')
        self.prefix = self.root / "owner's prefix with spaces"
        self.home = self.root / 'home'
        self.home.mkdir()
        self.environment = {**os.environ, 'HOME': str(self.home)}

    def tearDown(self):
        self.temporary.cleanup()

    def distribution(self, version):
        (self.project / 'package.json').write_text(json.dumps({'name': 'black-team', 'version': version, 'main': 'main.cjs'}))
        with contextlib.redirect_stdout(io.StringIO()):
            artifact = PACKAGER.build(self.project, self.runtime, self.root / 'out')
        extract = self.root / f'extracted-{version}'
        extract.mkdir()
        with tarfile.open(artifact) as archive:
            archive.extractall(extract, filter='data')
        return next(extract.iterdir())

    def install(self, source, *extra, ok=True):
        result = subprocess.run(['sh', str(source / 'install.sh'), '--prefix', str(self.prefix), *extra],
                                env=self.environment, text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_install_upgrade_rollback_preserves_data_and_existing_command(self):
        original = self.prefix / 'bin/black-team'
        original.parent.mkdir(parents=True)
        original.write_text('existing personal app')
        data = self.home / '.local/share/black-team-data'
        data.mkdir(parents=True)
        (data / 'conversations.json').write_text('keep my conversations')
        first = self.distribution('0.1.0-alpha.1')
        self.install(first)
        root = self.prefix / 'share/black-team'
        self.assertEqual(os.readlink(root / 'current'), 'releases/0.1.0-alpha.1')
        self.assertFalse((root / 'previous').exists())
        self.assertTrue((self.prefix / 'share/applications/black-team-desktop.desktop').is_file())
        second = self.distribution('0.1.0-alpha.2')
        self.install(second)
        self.assertEqual(os.readlink(root / 'current'), 'releases/0.1.0-alpha.2')
        self.assertEqual(os.readlink(root / 'previous'), 'releases/0.1.0-alpha.1')
        result = subprocess.run([str(self.prefix / 'bin/black-team-desktop'), '--rollback'],
                                env=self.environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(os.readlink(root / 'current'), 'releases/0.1.0-alpha.1')
        self.assertEqual(os.readlink(root / 'previous'), 'releases/0.1.0-alpha.2')
        self.assertEqual((data / 'conversations.json').read_text(), 'keep my conversations')
        self.assertEqual(original.read_text(), 'existing personal app')
        self.assertFalse((root / '.install-lock').exists())

    def test_corruption_does_not_change_active_release(self):
        self.install(self.distribution('0.1.0-alpha.1'))
        second = self.distribution('0.1.0-alpha.2')
        with (second / 'payload.tar.gz').open('ab') as handle:
            handle.write(b'corruption')
        result = self.install(second, ok=False)
        self.assertIn('FAILED', result.stdout)
        root = self.prefix / 'share/black-team'
        self.assertEqual(os.readlink(root / 'current'), 'releases/0.1.0-alpha.1')
        self.assertFalse((root / 'releases/0.1.0-alpha.2').exists())

    def test_refuses_unrelated_launcher_and_duplicate_version(self):
        first = self.distribution('0.1.0-alpha.1')
        launcher = self.prefix / 'bin/black-team-desktop'
        launcher.parent.mkdir(parents=True)
        launcher.write_text('unrelated app')
        self.assertIn('unrelated file', self.install(first, ok=False).stderr)
        self.assertEqual(launcher.read_text(), 'unrelated app')
        launcher.unlink()
        self.install(first)
        self.assertIn('already installed', self.install(first, ok=False).stderr)

    def test_payload_allowlist_and_runtime_manifest(self):
        (self.project / 'personal-config.json').write_text('not for distribution')
        (self.project / 'node_modules/private-key').write_text('not for distribution')
        first = self.distribution('0.1.0-alpha.1')
        self.install(first)
        payload = self.prefix / 'share/black-team/current'
        manifest = json.loads((payload / 'MANIFEST.json').read_text())
        self.assertTrue(any(name.endswith('lib/config.cjs') for name in manifest))
        for name in ('scripts/agent-runner.py', 'plugins/companion-tools/__init__.py', 'plugins/companion-tools/plugin.yaml'):
            self.assertIn('resources/app/'+name,manifest)
        self.assertFalse(any('node_modules' in name or 'personal-config' in name for name in manifest))
        self.assertEqual(json.loads((payload / 'BUILD.json').read_text())['electron'], '40.10.2')
        self.assertNotIn(str(self.home), (payload / 'BUILD.json').read_text())
        for name, expected in manifest.items():
            self.assertEqual(PACKAGER.digest(payload / name), expected)

    def test_rejects_symlink_in_app_payload_and_unsafe_runtime(self):
        (self.project / 'dist/private').symlink_to(self.home)
        with self.assertRaisesRegex(ValueError, 'Symlinks'):
            self.distribution('0.1.0-alpha.1')
        (self.project / 'dist/private').unlink()
        with zipfile.ZipFile(self.runtime, 'a') as archive:
            archive.writestr('../escape', 'unsafe')
        with self.assertRaisesRegex(ValueError, 'unsafe archive'):
            self.distribution('0.1.0-alpha.1')


if __name__ == '__main__':
    unittest.main()
