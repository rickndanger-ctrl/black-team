import React, {useEffect, useState} from 'react';

export const THEMES = [['covert', 'Covert'], ['light', 'Light'], ['ghost', 'Ghost']];
const KEY = 'black-team-theme';

export function readTheme() {
  try {const value = localStorage.getItem(KEY); return THEMES.some(([id]) => id === value) ? value : 'covert';}
  catch {return 'covert';}
}

export function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.content = getComputedStyle(document.documentElement).getPropertyValue('--bg').trim() || '#07090c';
}

// Per-device appearance choice. Saved in this browser only; never sent anywhere.
export default function ThemePicker() {
  const [theme, setTheme] = useState(readTheme);
  useEffect(() => {applyTheme(theme); try {localStorage.setItem(KEY, theme);} catch {}}, [theme]);
  return <div className="theme-picker" role="group" aria-label="Appearance">
    {THEMES.map(([id, label]) => <button key={id} type="button" className={theme === id ? 'selected' : ''} aria-pressed={theme === id} onClick={() => setTheme(id)}>{label}</button>)}
  </div>;
}
