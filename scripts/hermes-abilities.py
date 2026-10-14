"""Reads what a connected Hermes install can do, without starting an agent: its tool groups and how much text each one adds to
every message. Black Team runs this with the install's own Python, once, after the person has connected Hermes, in a scratch
HERMES_HOME that is deleted afterwards. It only imports Hermes's tool table and reads it; it makes no network request, starts
no tool and writes nothing outside that scratch folder. Output: one line, `BT_ABILITIES=<json>`, on standard output.
"""
import contextlib
import importlib.util
import json
import os
import sys

source = os.environ['BLACK_TEAM_HERMES_SOURCE']
sys.dont_write_bytecode = True  # reading the install must not add files to it
sys.path.insert(0, source)


def companion_schema(folder):
    """The schema of Black Team's own companion tool, read by calling its register() with a recorder."""
    path = os.path.join(folder, '__init__.py')
    if not os.path.isfile(path):
        return {}
    spec = importlib.util.spec_from_file_location('black_team_companion_probe', path)
    module = importlib.util.module_from_spec(spec)
    found = {}

    class Recorder:
        def register_tool(self, name, toolset, schema, handler=None, **extra):
            found[name] = schema

        def __getattr__(self, name):
            return lambda *a, **k: None

    with contextlib.redirect_stdout(sys.stderr):
        spec.loader.exec_module(module)
        module.register(Recorder())
    return found


def main():
    report = {'version': 1, 'toolsets': [], 'tools': {}, 'companion': {}}
    with contextlib.redirect_stdout(sys.stderr):
        import toolsets
        entries = {}
        try:
            import model_tools
            from tools.registry import registry
            model_tools.discover_builtin_tools()
            entries = {entry.name: entry for entry in registry.get_all_entries()}
        except Exception as error:  # the tool table is optional: groups are still listed, without their cost
            report['costError'] = str(error)[:200]
        for name, spec in sorted(toolsets.TOOLSETS.items()):
            tools = toolsets.resolve_toolset(name, include_registry=False)
            env = sorted({variable for tool in tools if tool in entries for variable in (entries[tool].requires_env or [])
                          if isinstance(variable, str)})
            ready = None
            if entries:
                try:
                    ready = bool(registry.is_toolset_available(name))
                except Exception:
                    ready = None
            report['toolsets'].append({
                'name': name, 'description': str(spec.get('description', '')), 'tools': tools,
                'includes': list(spec.get('includes', [])), 'posture': bool(spec.get('posture')),
                'role': spec.get('role'), 'requiresEnv': env, 'ready': ready,
            })
        for tool, entry in entries.items():
            report['tools'][tool] = {'chars': len(json.dumps(entry.schema)), 'toolset': entry.toolset}
    folder = os.environ.get('BLACK_TEAM_COMPANION_PLUGIN', '')
    if folder:
        for tool, schema in companion_schema(folder).items():
            report['companion'][tool] = {'chars': len(json.dumps(schema))}
    sys.stdout.write('BT_ABILITIES=' + json.dumps(report) + '\n')


main()
