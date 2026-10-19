// Cache only the static application shell, never owner-authenticated API data,
// conversations, models, screen images or audio. Exact paths are allowlisted.
const SHELL='osaurus-phone-shell-v1';
const ASSETS=['/phone','/phone/','/phone/app.js','/phone/connection.js','/phone/voice.js','/phone/avatar.js','/phone/screen.js','/phone/style.css','/phone/manifest.webmanifest','/phone/icon.svg','/phone/icon-192.png','/phone/icon-512.png'];
self.addEventListener('install',event=>event.waitUntil((async()=>{
  const cache=await caches.open(SHELL);
  await cache.addAll(ASSETS);
  await self.skipWaiting();
})()));
self.addEventListener('activate',event=>event.waitUntil((async()=>{
  for(const name of await caches.keys())if(name.startsWith('osaurus-phone-shell-')&&name!==SHELL)await caches.delete(name);
  await self.clients.claim();
})()));
self.addEventListener('fetch',event=>{
  const url=new URL(event.request.url);
  if(event.request.method!=='GET'||url.origin!==self.location.origin||url.search||!ASSETS.includes(url.pathname))return;
  event.respondWith((async()=>{
    const controller=new AbortController();
    const timeout=setTimeout(()=>controller.abort(),5000);
    try { return await fetch(event.request,{signal:controller.signal}); }
    catch { return (await caches.open(SHELL)).match(url.pathname); }
    finally { clearTimeout(timeout); }
  })());
});
