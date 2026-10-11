import React from 'react';
import {createRoot} from 'react-dom/client';
import App from './App.jsx';
import './theme.css';
import './app.css';
import './brand.css';
import './agent-avatar.css';

createRoot(document.getElementById('root')).render(<React.StrictMode><App/></React.StrictMode>);
if (!window.blackTeam && 'serviceWorker' in navigator) {
  window.addEventListener('load', () => navigator.serviceWorker.register('/sw.js').catch(() => {}));
}
