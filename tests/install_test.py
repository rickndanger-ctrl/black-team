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
        for folder in ('scripts', 'docs', 'dist', 'node_modules'):
            (self.project / folder).mkdir()
        for source in ('scripts/install.sh', 'docs/DISTRIBUTION.md', 'THIRD-PARTY-NOTICES.md', 'LICENSE'):
            shutil.copyfile(PROJECT / source, self.project / source)
        (self.project / 'main.cjs').write_text('// Fixture only.\n')
        (self.project / 'preload.cjs').write_text('// Fixture only.\n')
        (self.project / 'engine-client.cjs').write_text('// Fixture only.\n')
        self.engine = self.root / 'black-team'
        self.engine.write_bytes(b'\x7fELF fixture engine')
        (self.project / 'dist/index.html').write_text('<title>Fixture</title>')
        (self.project / 'dist/black-team-512.png').write_bytes(b'fixture icon')
        for dependency in ('react', 'react-dom', 'scheduler', 'qrcode', 'dijkstrajs'):
            folder = self.project / 'node_modules' / dependency
            folder.mkdir()
            (folder / ('LICENSE.md' if dependency == 'dijkstrajs' else 'LICENSE')).write_text('Fixture dependency notice')
        self.runtime = self.root / 'runtime.zip'
        with zipfile.ZipFile(self.runtime, 'w') as archive:
            for name, data in {'electron': '#!/bin/sh\nprintf "fixture runtime\\n"\n', 'LICENSE': 'Fixture MIT',
                               'LICENSES.chromium.html': 'Fixture notices', 'version': '40.10.2'}.items():
                entry = zipfile.ZipInfo(name)
                entry.external_attr = (stat.S_IFREG | (0o755 if name == 'electron' else 0o644)) << 16
                archive.writestr(entry, data)
        for name in ('scripts/agent-runner.py', 'scripts/hermes-abilities.py', 'plugins/companion-tools/__init__.py', 'plugins/companion-tools/plugin.yaml'):
            target=self.project/name
            target.parent.mkdir(parents=True,exist_ok=True)
            target.write_text('fixture')
        self.prefix = self.root / "owner's prefix with spaces"
        self.home = self.root / 'home'
        self.home.mkdir()
        self.sysctl = self.root / 'sysctl'
        self.profiles = self.root / 'apparmor.d'
        self.profiles.mkdir()
        self.environment = {**os.environ, 'HOME': str(self.home), 'BLACK_TEAM_SYSCTL_ROOT': str(self.sysctl),
                            'BLACK_TEAM_APPARMOR_DIR': str(self.profiles)}

    def tearDown(self):
        self.temporary.cleanup()

    def distribution(self, version, engine=None):
        (self.project / 'package.json').write_text(json.dumps({'name': 'black-team', 'version': version, 'main': 'main.cjs'}))
        with contextlib.redirect_stdout(io.StringIO()):
            artifact = PACKAGER.build(self.project, self.runtime, self.root / 'out', engine or self.engine)
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

    def test_links_the_terminal_command_when_the_name_is_free(self):
        first = self.distribution('0.1.0-alpha.1')
        result = self.install(first)
        link = self.prefix / 'bin/black-team'
        target = self.prefix / 'share/black-team/current/resources/app/bin/black-team'
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), str(target))
        self.assertTrue(target.is_file())
        self.assertIn(f'Command: {link}', result.stdout)
        # An update keeps the same link, which follows "current" to the new release.
        self.install(self.distribution('0.1.0-alpha.2'))
        self.assertEqual(os.readlink(link), str(target))
        self.assertIn('releases/0.1.0-alpha.2', os.path.realpath(link))

    def fake_systemctl(self, active):
        """A systemctl that records what it is asked and answers is-active as given."""
        bin_dir = self.root / 'fake-bin'
        bin_dir.mkdir(exist_ok=True)
        log = self.root / 'systemctl.log'
        log.write_text('')
        script = bin_dir / 'systemctl'
        answer = 'exit 0' if active else 'exit 3'
        script.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "' + str(log) + '"\ncase "$*" in *is-active*) ' + answer + ' ;; esac\nexit 0\n')
        script.chmod(0o755)
        self.environment['PATH'] = f'{bin_dir}:{os.environ["PATH"]}'
        return log

    def write_unit(self, ours=True, from_this_install=True):
        unit = self.home / '.config/systemd/user/black-team.service'
        unit.parent.mkdir(parents=True, exist_ok=True)
        root = self.prefix / 'share/black-team'
        lines = ['# black-team-managed-v1'] if ours else []
        program = f'{root}/current/resources/app/bin/black-team' if from_this_install else '/elsewhere/black-team'
        lines += ['[Service]', f'ExecStart="{program}" "service" "run"']
        unit.write_text('\n'.join(lines) + '\n')
        return unit

    def test_an_update_stops_a_running_background_service_and_starts_it_again(self):
        self.install(self.distribution('0.1.0-alpha.1'))
        self.write_unit()
        log = self.fake_systemctl(active=True)
        result = self.install(self.distribution('0.1.0-alpha.2'))
        calls = log.read_text().splitlines()
        self.assertEqual(calls, ['--user is-active --quiet black-team.service', '--user stop black-team.service', '--user start black-team.service'])
        self.assertIn('restarted', result.stdout)
        self.assertEqual(os.readlink(self.prefix / 'share/black-team/current'), 'releases/0.1.0-alpha.2')
        # A rollback does the same.
        log.write_text('')
        subprocess.run([str(self.prefix / 'bin/black-team-desktop'), '--rollback'], env=self.environment, capture_output=True, text=True, check=True)
        self.assertEqual(log.read_text().splitlines(), ['--user is-active --quiet black-team.service', '--user stop black-team.service', '--user start black-team.service'])

    def test_a_background_service_that_was_not_running_is_never_started_by_the_installer(self):
        self.install(self.distribution('0.1.0-alpha.1'))
        self.write_unit()
        log = self.fake_systemctl(active=False)
        self.install(self.distribution('0.1.0-alpha.2'))
        self.assertEqual(log.read_text().splitlines(), ['--user is-active --quiet black-team.service'])

    def test_a_unit_that_is_not_ours_or_not_from_this_install_is_never_touched(self):
        self.install(self.distribution('0.1.0-alpha.1'))
        log = self.fake_systemctl(active=True)
        self.write_unit(ours=False)
        self.install(self.distribution('0.1.0-alpha.2'))
        self.assertEqual(log.read_text(), '')
        unit = self.write_unit(from_this_install=False)
        self.install(self.distribution('0.1.0-alpha.3'))
        self.assertEqual(log.read_text(), '')
        self.assertTrue(unit.is_file())

    def test_the_installer_does_not_write_or_enable_the_unit(self):
        log = self.fake_systemctl(active=False)
        self.install(self.distribution('0.1.0-alpha.1'))
        self.assertFalse((self.home / '.config/systemd').exists())
        self.assertEqual(log.read_text(), '')

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

    def kernel(self, **settings):
        for name, value in settings.items():
            target = self.sysctl / {'restrict': 'kernel/apparmor_restrict_unprivileged_userns',
                                    'clone': 'kernel/unprivileged_userns_clone', 'limit': 'user/max_user_namespaces'}[name]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(f'{value}\n')

    def launch(self, *arguments):
        return subprocess.run([str(self.prefix / 'bin/black-team-desktop'), *arguments],
                              env=self.environment, capture_output=True, text=True)

    def test_sandbox_restriction_is_detected_and_explained(self):
        self.prefix = self.root / 'plain-prefix'
        first = self.distribution('0.1.0-alpha.1')
        self.assertNotIn('cannot open its window', self.install(first).stdout)
        self.assertEqual(self.install(first, '--sandbox-status').stdout, 'ok\n')
        self.assertEqual(self.launch().stdout, 'fixture runtime\n')
        self.kernel(restrict=1)
        blocked = self.install(first, '--sandbox-status', ok=False)
        self.assertEqual(blocked.stdout, 'apparmor\n')
        # A window that starts anyway is left alone; one that fails at once gets the explanation.
        self.assertEqual(self.launch().stderr, '')
        runtime = self.prefix / 'share/black-team/current/electron'
        runtime.write_text('#!/bin/sh\nexit 133\n')
        failed = self.launch()
        self.assertEqual(failed.returncode, 133)
        self.assertIn('--enable-sandbox', failed.stderr)
        self.assertIn('Do not use --no-sandbox', failed.stderr)
        profile = self.install(first, '--sandbox-profile').stdout
        root = self.prefix / 'share/black-team'
        name = next(line for line in profile.splitlines() if line.startswith('profile ')).split()[1]
        self.assertRegex(name, r'^black-team-[a-f0-9]{12}$')
        self.assertIn(f'profile {name} {root}/releases/*/electron flags=(unconfined) {{\n  userns,\n', profile)
        # Once the profile exists the launcher goes straight to the window again.
        (self.profiles / name).write_text(profile)
        self.assertEqual(self.install(first, '--sandbox-status').stdout, 'ok\n')
        self.assertIn('already works', self.install(first, '--enable-sandbox').stdout)
        self.assertEqual(self.launch().stderr, '')

    def test_sandbox_notice_after_install_and_for_disabled_namespaces(self):
        self.kernel(restrict=1)
        first = self.distribution('0.1.0-alpha.1')
        installed = self.install(first)
        self.assertIn('--enable-sandbox', installed.stdout)
        # A folder name AppArmor cannot name safely is refused rather than written into a profile.
        refused = self.install(first, '--sandbox-profile', ok=False)
        self.assertEqual(refused.stdout, '')
        self.assertIn('simpler --prefix', refused.stderr)
        self.kernel(restrict=0, limit=0)
        self.assertEqual(self.install(first, '--sandbox-status', ok=False).stdout, 'disabled\n')
        unavailable = self.install(first, '--enable-sandbox', ok=False)
        self.assertIn('turned off', unavailable.stderr)

    def test_payload_allowlist_and_runtime_manifest(self):
        (self.project / 'personal-config.json').write_text('not for distribution')
        (self.project / 'node_modules/private-key').write_text('not for distribution')
        first = self.distribution('0.1.0-alpha.1')
        self.install(first)
        payload = self.prefix / 'share/black-team/current'
        manifest = json.loads((payload / 'MANIFEST.json').read_text())
        self.assertIn('resources/app/bin/black-team', manifest)
        self.assertIn('resources/app/engine-client.cjs', manifest)
        self.assertFalse(any('/lib/' in name for name in manifest))
        self.assertTrue(os.access(payload / 'resources/app/bin/black-team', os.X_OK))
        for name in ('scripts/agent-runner.py', 'scripts/hermes-abilities.py', 'plugins/companion-tools/__init__.py', 'plugins/companion-tools/plugin.yaml'):
            self.assertIn('resources/app/'+name,manifest)
        self.assertFalse(any('node_modules' in name or 'personal-config' in name for name in manifest))
        self.assertEqual(json.loads((payload / 'BUILD.json').read_text())['electron'], '40.10.2')
        self.assertNotIn(str(self.home), (payload / 'BUILD.json').read_text())
        for name, expected in manifest.items():
            self.assertEqual(PACKAGER.digest(payload / name), expected)

    def test_missing_engine_is_refused_with_a_clear_message(self):
        with self.assertRaisesRegex(ValueError, 'Engine binary is missing: .*black-team-missing.*--engine'):
            self.distribution('0.1.0-alpha.1', engine=self.root / 'black-team-missing')
        self.assertFalse((self.root / 'out').exists())

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
