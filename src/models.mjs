// Plain-words helpers for the "Get a model" page. No network and no React here, so they can be tested.

export const size = bytes => bytes >= 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : `${Math.max(1, Math.round(bytes / 1e6))} MB`;

export const FIT_WORDS = {comfortable: 'Fits well', tight: 'Tight fit', tooBig: 'Too big for this computer'};
export const fitWords = fit => FIT_WORDS[fit] || '';

export const PICK_WORDS = {best: 'Best for this computer', code: 'Best for Code (tools)', fastest: 'Fastest'};

// The engine's `modelInstall` (sent with every status) as one state for the page.
export function downloadState(install = {}) {
  if (install.running) return 'running';
  if (install.error) return 'error';
  if (install.done && install.result?.ready) return 'ready';
  if (install.paused) return 'paused';
  return 'idle';
}

// "3 min left" from the bytes per second and fraction the engine reports; '' when unknown.
export function timeLeft(install = {}, totalBytes = 0) {
  if (!(install.bytesPerSecond > 1) || typeof install.fraction !== 'number' || !(totalBytes > 0)) return '';
  const seconds = Math.max(0, (1 - install.fraction) * totalBytes / install.bytesPerSecond);
  if (seconds < 90) return 'less than a minute left';
  if (seconds < 5400) return `about ${Math.round(seconds / 60)} min left`;
  return `about ${(seconds / 3600).toFixed(1)} hours left`;
}

// The request the window sends for a choice. A repository file is sent by repository and path only; the engine asks Hugging Face for
// its size and checksum again.
export function downloadRequest(choice, extras = {}) {
  const base = choice.source === 'hub' ? {source: 'hub', repo: choice.repo, file: choice.file} : {source: 'catalogue', id: choice.id};
  return {...base, vision: Boolean(extras.vision), draft: Boolean(extras.draft)};
}

// What to say under a repository's licence. Always names the maker as someone else.
export function thirdParty(repo) {
  const maker = String(repo || '').split('/')[0] || 'its maker';
  return `Made by ${maker}, not by Black Team, and downloaded from Hugging Face.`;
}

// The ranked list without the picks shown above it.
export function restOf(models = []) {
  return models.filter(entry => !(entry.picks || []).length);
}

export function picksOf(recommendations) {
  const by = id => recommendations?.models?.find(entry => entry.id === id);
  const out = [];
  for (const [key, id] of [['best', recommendations?.bestID], ['code', recommendations?.codeID], ['fastest', recommendations?.fastestID]]) {
    const entry = id && by(id);
    if (!entry) continue;
    const found = out.find(item => item.entry.id === entry.id);
    if (found) found.keys.push(key); else out.push({entry, keys: [key]});
  }
  return out;
}
