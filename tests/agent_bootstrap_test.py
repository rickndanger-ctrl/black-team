"""Hermes dependency activation must not create a runtime per conversation."""
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

RUNNER = Path(__file__).resolve().parents[1] / 'scripts/agent-runner.py'

class AgentBootstrapTests(unittest.TestCase):
    def run_bootstrap(self, resumed=False):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            (source / 'pm').mkdir()
            (source / 'pm/__init__.py').write_text('')
            (source / 'pm/environments.py').write_text(
                "import os\ndef store_root(source):\n assert 'HERMES_HOME' not in os.environ\n return source / 'installed-tools'\n")
            (source / 'hermes_bootstrap.py').write_text(
                "import os\nassert 'HERMES_HOME' not in os.environ\nassert os.environ['BLACK_TEAM_HERMES_PROFILE'] == '/isolated-session'\n")
            environment = {'BLACK_TEAM_HERMES_SOURCE': directory}
            environment['BLACK_TEAM_HERMES_PROFILE' if resumed else 'HERMES_HOME'] = '/isolated-session'
            import subprocess
            code = RUNNER.read_text().split('import argparse', 1)[0]
            code += "\nassert os.environ['HERMES_HOME'] == '/isolated-session'\nassert os.environ['HERMES_RUNTIME_DIR'].endswith('/installed-tools')\n"
            inherited = {key: value for key, value in os.environ.items() if key not in
                         ('HERMES_HOME', 'HERMES_RUNTIME_DIR', 'BLACK_TEAM_HERMES_PROFILE')}
            result = subprocess.run(['python3', '-c', code], env={**inherited, **environment}, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_dependency_bootstrap_uses_installed_home_then_restores_profile(self):
        self.run_bootstrap()

    def test_interpreter_relaunch_restores_profile(self):
        self.run_bootstrap(resumed=True)

if __name__ == '__main__':
    unittest.main()
