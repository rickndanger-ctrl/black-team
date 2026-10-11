import React, {useEffect, useState} from 'react';
import QRCode from 'qrcode';

export default function PhoneSettings({status,busy,onAction}) {
  const [copied,setCopied]=useState(false);
  const [copyError,setCopyError]=useState('');
  const [qr,setQr]=useState('');
  const [qrError,setQrError]=useState(false);
  const [command,setCommand]=useState('');
  const connected=status.phone?.connected;
  const url=connected?status.phone?.url:'';
  useEffect(()=>{
    let active=true;setQr('');setQrError(false);
    if(url)QRCode.toDataURL(url,{width:224,margin:3,errorCorrectionLevel:'M'}).then(value=>{if(active)setQr(value);}).catch(()=>{if(active)setQrError(true);});
    return ()=>{active=false;};
  },[url]);
  useEffect(()=>{setCopied(false);setCopyError('');},[url]);
  const copy=async()=>{
    try{await navigator.clipboard.writeText(url);setCopied(true);setCopyError('');}
    catch{setCopyError('Select the pairing link below and copy it manually.');}
  };
  return <section className="setup-form phone-setup">
    <div className="panel-heading"><div><span className="eyebrow">YOUR PHONE</span><h2>{connected?'Scan. Open. Keep working.':'Take Black Team with you'}</h2></div></div>
    <p className="section-intro">Your phone controls the same local model and agent on this computer. Keep the computer awake and Black Team open.</p>
    <ol className="setup-steps"><li><strong>Connect Tailscale.</strong> Install it on your computer and phone, and sign in with the same account. <button type="button" className="text-button" disabled={busy} onClick={()=>onAction("setup-help",{topic:"tailscale"})}>Get Tailscale</button></li><li><strong>Enable private access.</strong> Black Team finds this computer and your account for you.</li><li><strong>Scan and open.</strong> Scan the QR code with your phone camera. No separate phone app is needed.</li></ol>
    {!connected?<button type="button" className="primary" disabled={busy} onClick={()=>onAction('phone-setup',{},'Private phone access is ready. Scan the QR code on your phone.')}>{busy?'Connecting…':'Enable private phone access'}</button>:<div className="phone-pairing">
      <div className="pairing-qr">{qr?<img width="224" height="224" src={qr} alt="Scan with your phone camera to pair with Black Team"/>:<p role="status">{qrError?'Use the pairing link below.':'Preparing your pairing code…'}</p>}</div>
      <div><span className="connection-label ready"><i className="live-dot"/>Private access ready</span><p>Scan with a phone connected to your Tailscale account. This code grants access to Black Team; share it only with your own devices.</p><button type="button" className="secondary" onClick={copy}>{copied?'Pairing link copied':'Copy pairing link'}</button>{copyError&&<p role="alert">{copyError}</p>}</div>
    </div>}
    {connected&&<div className="phone-home-screen"><h3>Add it to your Home Screen</h3><p><strong>iPhone:</strong> open in Safari → Share → Add to Home Screen.</p><p><strong>Android:</strong> open in Chrome → menu → Add to Home screen or Install.</p><small>Chat and agent work use your computer. Closing the phone does not stop a running task.</small></div>}
    <details className="advanced-settings"><summary>Connection details and troubleshooting</summary>
      <p className="section-intro">{status.config?.phone?.hostname||'The computer and account are detected when you enable access.'}{status.config?.phone?.owner&&<> · {status.config.phone.owner}</>}</p>
      {url&&<label className="form-field">Private pairing link<input readOnly value={url} onFocus={e=>e.target.select()}/></label>}
      <p className="section-intro">If Tailscale needs permission, run the connection command in your terminal, then choose Enable private phone access again.</p>
      {command?<pre>{command}</pre>:<button type="button" className="secondary" disabled={busy} onClick={async()=>{const result=await onAction('phone-command');if(result)setCommand(result.command);}}>Show connection command</button>}
      {status.phone?.enabled&&<div className="button-row"><button type="button" className="secondary" disabled={busy} onClick={()=>onAction('phone-off',{},'Phone access turned off.')}>Turn off phone access</button></div>}
      <p className="inline-note">Access stays on your private Tailscale network. Pairing does not publish your conversations or model on the internet.</p>
    </details>
  </section>;
}
