import React, {useRef, useState} from 'react';
import {native} from './desktop.mjs';

export const MAX_PICTURES = 4;

// The attach button. The chooser is the system file dialog; paste is handled by the composer.
export function PictureButton({busy, disabled, onFiles}) {
  const input = useRef(null);
  return <>
    <input ref={input} type="file" accept="image/*" multiple hidden aria-hidden="true" tabIndex={-1} onChange={event => {const files = [...event.target.files]; event.target.value = ''; if (files.length) onFiles(files);}}/>
    <button type="button" className="secondary picture-button" title="Choose up to 4 images to send with your message" aria-label="Attach pictures" disabled={disabled || busy} onClick={() => input.current?.click()}>{busy ? 'Preparing…' : '+ Files'}</button>
  </>;
}

// The pictures waiting to go with the next message. Each one can be taken off again.
export function PictureChips({items, onRemove}) {
  if (!items.length) return null;
  return <div className="picture-tray" aria-label="Pictures to send">{items.map(item => <div className="picture-chip" key={item.id}>
    <img src={item.url} alt={item.name}/>
    <span>{item.name}<small>{item.width} × {item.height}</small></span>
    <button type="button" aria-label={`Remove ${item.name}`} onClick={() => onRemove(item)}>×</button>
  </div>)}</div>;
}

// The pictures a message was sent with, drawn from the conversation.
export function MessageImages({images, threadId}) {
  if (!images?.length || !threadId) return null;
  return <div className="message-images">{images.map(image => <img key={image.id} src={`/api/image/${encodeURIComponent(threadId)}/${encodeURIComponent(image.id)}`} alt={image.name} width={image.width} height={image.height}/>)}</div>;
}

// A starter model that has no vision file yet: offer the download, then show how far it is. The engine reports progress in
// status.visionInstall; this only starts and stops it.
const megabytes = bytes => bytes >= 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : `${Math.round(bytes / 1e6)} MB`;
export function VisionDownload({status, onError}) {
  const [asking, setAsking] = useState(false);
  const install = status.visionInstall || {};
  const ask = async action => {setAsking(true); try {await native(action);} catch (cause) {onError(cause.message);} finally {setAsking(false);}};
  if (install.running) {
    const percent = typeof install.fraction === 'number' ? Math.round(install.fraction * 100) : null;
    const speed = install.bytesPerSecond > 0 ? ` · ${megabytes(install.bytesPerSecond)}/s` : '';
    return <div className="inline-note vision-download" role="status">
      <span>{install.stage || 'Downloading the vision file'}{percent === null ? '' : ` · ${percent}%`}{speed}</span>
      {percent !== null && <progress max="100" value={percent} aria-label="Vision file download"/>}
      <button type="button" className="secondary" disabled={asking} onClick={() => ask('vision-cancel')}>Stop</button>
    </div>;
  }
  if (!status.vision?.needsFile) return null;
  return <div className="inline-note vision-download">
    <span>This model needs its vision file before it can read images{status.vision.bytes ? ` (${megabytes(status.vision.bytes)})` : ''}.{install.error ? ` ${install.error}` : ''}</span>
    <button type="button" className="secondary" disabled={asking} onClick={() => ask('vision-install')}>{install.error ? 'Try again' : 'Download vision file'}</button>
  </div>;
}
