"""The runner tells Black Team how large each tool description is, so the Hermes screen can show the cost of an MCP server."""
import json
import re
import unittest
from pathlib import Path

RUNNER = Path(__file__).resolve().parents[1] / 'scripts/agent-runner.py'


def load_tool_sizes():
    source = RUNNER.read_text()
    match = re.search(r'^def tool_sizes\(tools\):.*?(?=^def |\Z)', source, re.S | re.M)
    scope = {}
    exec(match.group(0), scope)
    return scope['tool_sizes']


class ToolReportTests(unittest.TestCase):
    def test_sizes_are_the_json_length_of_each_definition(self):
        tool_sizes = load_tool_sizes()
        wrapped = {'type': 'function', 'function': {'name': 'read_file', 'parameters': {'type': 'object'}}}
        bare = {'name': 'mcp__notes__read', 'description': 'x'}
        sizes = tool_sizes([wrapped, bare])
        self.assertEqual(sizes['read_file'], len(json.dumps(wrapped['function'])))
        self.assertEqual(sizes['mcp__notes__read'], len(json.dumps(bare)))

    def test_odd_input_is_skipped_not_fatal(self):
        tool_sizes = load_tool_sizes()
        self.assertEqual(tool_sizes(None), {})
        self.assertEqual(tool_sizes([{'function': {}}, 5, None, {'name': 'ok'}]), {'ok': len(json.dumps({'name': 'ok'}))})

    def test_the_runner_announces_the_report_after_the_model_is_ready(self):
        source = RUNNER.read_text()
        self.assertLess(source.index("'phase':'ready'"), source.index("'type':'black_team_tools'"))


class AbilitiesHelperTests(unittest.TestCase):
    def test_helper_prints_one_marked_json_line_and_touches_only_stdout_and_a_scratch_home(self):
        import os
        import subprocess
        import sys
        import tempfile
        helper = Path(__file__).resolve().parents[1] / 'scripts/hermes-abilities.py'
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'hermes'
            source.mkdir()
            (source / 'toolsets.py').write_text(
                "TOOLSETS = {'file': {'description': 'Files', 'tools': ['read_file'], 'includes': []},"
                " 'both': {'description': 'Both', 'tools': [], 'includes': ['file']}}\n"
                "def resolve_toolset(name, include_registry=True):\n"
                "    spec = TOOLSETS[name]\n"
                "    return sorted(set(spec['tools']).union(*[resolve_toolset(i) for i in spec['includes']]))\n")
            plugin = Path(directory) / 'companion'
            plugin.mkdir()
            (plugin / '__init__.py').write_text("def register(ctx):\n    ctx.register_tool(name='companion_files', toolset='companion', schema={'name': 'companion_files'}, handler=None)\n")
            env = {**os.environ, 'BLACK_TEAM_HERMES_SOURCE': str(source), 'BLACK_TEAM_COMPANION_PLUGIN': str(plugin), 'HERMES_HOME': str(Path(directory) / 'home')}
            result = subprocess.run([sys.executable, str(helper)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = [line for line in result.stdout.splitlines() if line.startswith('BT_ABILITIES=')]
            self.assertEqual(len(lines), 1)
            report = json.loads(lines[0][len('BT_ABILITIES='):])
            # Without Hermes's tool table the groups are still listed, without their cost.
            self.assertIn('costError', report)
            self.assertEqual([item['name'] for item in report['toolsets']], ['both', 'file'])
            self.assertEqual(report['toolsets'][0]['tools'], ['read_file'])
            self.assertEqual(report['companion']['companion_files']['chars'], len(json.dumps({'name': 'companion_files'})))


if __name__ == '__main__':
    unittest.main()
