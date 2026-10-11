'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

function isExecutable(file) {
  try { return fs.statSync(file).isFile() && (fs.accessSync(file, fs.constants.X_OK), true); }
  catch { return false; }
}
function findExecutable(name, dirs) {
  return dirs.map(dir => path.join(dir, name)).find(isExecutable) || '';
}
function inspectHermes(source, python = '') {
  if (typeof source !== 'string' || !path.isAbsolute(source)) return null;
  if (!['hermes_bootstrap.py', 'cli.py'].every(file => fs.existsSync(path.join(source, file)))) return null;
  // Do not resolve Python symlinks: the venv path selects its installed packages.
  const candidates = [python, ...['venv', '.venv'].map(dir => path.join(source, dir, 'bin/python'))];
  const interpreter = candidates.find(file => file && path.isAbsolute(file) && isExecutable(file));
  return interpreter ? {source, python:interpreter} : null;
}
function discoverInstalled({home = os.homedir(), env = process.env, saved = {}} = {}) {
  // Bounded filesystem checks only: never run a discovered executable or scan a user's files.
  const dirs = [...new Set([...(env.PATH || '').split(path.delimiter), path.join(home, '.local/bin'), path.join(home, 'bin')])].filter(path.isAbsolute);
  const hermesBin = findExecutable('hermes', dirs);
  let resolved = '';
  try { if (hermesBin) resolved = fs.realpathSync(hermesBin); } catch {}
  const sources = [...new Set([saved.source, path.join(home, '.hermes/hermes-agent'), path.join(home, 'hermes-agent'), path.join(home, 'Projects/hermes-agent'), path.join(home, '.local/share/hermes/hermes-agent'), resolved && path.dirname(path.dirname(path.dirname(resolved)))].filter(Boolean))];
  const hermes = sources.map(source => inspectHermes(source, source === saved.source ? saved.python : '')).filter(Boolean);
  const terminalSpecs = [['ghostty','Ghostty',['-e']], ['kitty','Kitty',['--']], ['alacritty','Alacritty',['-e']], ['gnome-terminal','GNOME Terminal',['--']], ['konsole','Konsole',['-e']], ['xterm','XTerm',['-e']]];
  const terminals = terminalSpecs.map(([command,name,args]) => ({name,executable:findExecutable(command,dirs),args})).filter(item=>item.executable);
  const apps = [['hermes','Hermes Terminal'],['codex','Codex'],['pi','Pi'],['aider','Aider'],['opencode','OpenCode']].map(([id,name])=>({id,name,executable:findExecutable(id,dirs)})).filter(item=>item.executable);
  return {hermes, terminals, apps, runtime:findExecutable('llama-server',dirs)};
}
module.exports = {discoverInstalled, inspectHermes};
