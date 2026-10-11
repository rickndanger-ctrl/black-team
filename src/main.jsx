import React from 'react';
import {createRoot} from 'react-dom/client';
import App from './App.jsx';
import './style.css';
import './cabinet.css';
import './companion-cabinet.css';
import './brand.css';
import './atmosphere.css';
import './agent-avatar.css';
import './setup.css';

createRoot(document.getElementById('root')).render(<React.StrictMode><App/></React.StrictMode>);
if (!window.blackTeam && 'serviceWorker' in navigator) {
  window.addEventListener('load', () => navigator.serviceWorker.register('/sw.js').catch(() => {}));
}
