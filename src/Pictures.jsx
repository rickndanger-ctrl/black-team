import React, {useRef} from 'react';

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
