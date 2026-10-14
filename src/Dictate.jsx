import React, {useEffect, useState} from 'react';
import Icon from './Icons.jsx';
import {call} from './http.mjs';

// The system has one dictation session, so pressing a second microphone stops the first instead of starting another.
let live = null;

// A microphone for one text box. Dictated words arrive as typing in the focused box, so the first change to its text
// means the system has finished listening.
export default function MicButton({field, value, disabled, onError}) {
  const [listening, setListening] = useState(false);
  useEffect(() => {if (listening) setListening(false);}, [value]);
  useEffect(() => {if (!listening) return undefined; const timer = window.setTimeout(() => setListening(false), 62000); return () => window.clearTimeout(timer);}, [listening]);
  useEffect(() => {if (!listening && live === setListening) live = null;}, [listening]);
  useEffect(() => () => {if (live === setListening) live = null;}, []);
  const dictate = async () => {
    field.current?.focus();
    try {
      await call('dictate', {});
      if (live && live !== setListening) {live(false); live = null;}
      else if (listening) setListening(false);
      else {live = setListening; setListening(true);}
    } catch (cause) {onError(cause.message);}
  };
  return <button type="button" className={`secondary mic${listening ? ' on' : ''}`} aria-pressed={listening} aria-label={listening ? 'Stop dictation' : 'Dictate'} title={listening ? 'Listening… click to finish' : 'Dictate'} disabled={disabled} onClick={dictate}><Icon name="mic" size={16}/></button>;
}
