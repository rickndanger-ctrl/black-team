// Only public app assets belong in this cache. Never store conversations,
// configuration, request bodies, authentication responses, or API results.
const CACHE='black-team-portable-shell-v3';
const SHELL=['/','/index.html','/manifest.webmanifest','/black-team-mark.png','/black-team-logo.png','/black-team-180.png','/black-team-192.png','/black-team-512.png','/black-team-maskable-512.png','/fonts/adwaita-sans-variable.woff2','/fonts/jetbrains-mono-regular.woff2','/fonts/jetbrains-mono-bold.woff2'];
const isAsset=url=>SHELL.includes(url.pathname)||/^\/assets\/[A-Za-z0-9_.-]+\.(js|css)$/.test(url.pathname);
self.addEventListener('install',event=>event.waitUntil((async()=>{
  const cache=await caches.open(CACHE);
  for(const file of SHELL){try{const response=await fetch(file,{cache:'no-store'});if(response.ok)await cache.put(file,response);}catch{}}
  await self.skipWaiting();
})()));
self.addEventListener('activate',event=>event.waitUntil((async()=>{
  for(const name of await caches.keys())if(name.startsWith('black-team-')&&name!==CACHE)await caches.delete(name);
  await self.clients.claim();
})()));
self.addEventListener('fetch',event=>{
  const url=new URL(event.request.url);
  if(event.request.method!=='GET'||url.origin!==self.location.origin||url.search||!isAsset(url))return;
  event.respondWith((async()=>{
    const cache=await caches.open(CACHE);
    try{const response=await fetch(event.request);if(response.ok)await cache.put(event.request,response.clone());return response;}
    catch{const cached=await cache.match(event.request);if(cached)return cached;throw new Error('Black Team is offline.');}
  })());
});
