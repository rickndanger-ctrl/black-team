// Retain an unsubmitted pairing key only in memory. Retry transient failures
// without putting the secret back into the URL or browser storage.
export function createCompanionInitializer({desktop,location,replaceURL,post}) {
  let captured=false, key=null, pending=null;
  return function initialize() {
    if(desktop)return Promise.resolve();
    if(!captured){
      captured=true;
      const fragment=new URLSearchParams(location.hash.slice(1));
      if(fragment.has('pair')){
        key=fragment.get('pair');
        replaceURL(location.pathname+location.search);
      }
    }
    if(key===null)return Promise.resolve();
    if(pending)return pending;
    pending=Promise.resolve().then(async()=>{
      if(!/^[a-f0-9]{64}$/i.test(key||''))throw new Error('Invalid pairing link.');
      await post('/api/pair',{key});
      key=null;
    }).catch(()=>{
      const error=new Error('Pairing could not finish. Connect both devices to Tailscale and try again. If this link is no longer valid, scan the current code in Black Team on your computer.');
      error.status=401;
      throw error;
    }).finally(()=>{pending=null;});
    return pending;
  };
}
