'use strict';
// Only a timestamp is persisted. Never persist API responses, agent names,
// messages, screen pixels or audio. Retry reads, never replay mutations/turns.
class PhoneConnection {
  constructor({fetcher, changed, recovered=()=>{}, storage, now=()=>Date.now(), schedule=setTimeout, cancel=clearTimeout}) {
    Object.assign(this,{fetcher,changed,recovered,storage,now,schedule,cancel});
    this.lastSeen=null;this.offline=false;this.attempt=0;this.timer=null;this.probing=false;this.stopped=false;this.epoch=0;this.probeController=null;this.watching=false;
    try { const value=Number(storage?.getItem('osaurus.phone.lastSeen'));if(value>0&&Number.isFinite(value))this.lastSeen=value; } catch {}
  }
  message() {
    return `Your Mac is asleep or offline · Last seen: ${this.lastSeen?new Date(this.lastSeen).toLocaleString():'not yet connected'}. Retrying…`;
  }
  seen() {
    if(this.stopped)return;
    const wasOffline=this.offline;
    this.lastSeen=this.now();this.offline=false;this.attempt=0;
    if(this.timer!==null)this.cancel(this.timer);this.timer=null;
    try { this.storage?.setItem('osaurus.phone.lastSeen',String(this.lastSeen)); } catch {}
    this.changed('');
    if(this.watching)this.timer=this.schedule(()=>{this.timer=null;void this.probe();},30000);
    if(wasOffline)this.recovered();
  }
  failed() {
    if(this.stopped)return;
    if(!this.offline&&this.timer!==null){this.cancel(this.timer);this.timer=null;}
    this.offline=true;this.changed(this.message());this.retry();
  }
  retry() {
    if(this.timer!==null||this.stopped)return;
    const delay=Math.min(30000,1000*2**Math.min(this.attempt++,5));
    this.timer=this.schedule(()=>{this.timer=null;void this.probe();},delay);
  }
  async fetch(url,options={}) {
    // Bound read-only bootstrap/picker requests, but let model turns keep their
    // own cancellation and load deadlines. A timeout never replays a mutation.
    const readOnly=['GET','HEAD'].includes((options.method||'GET').toUpperCase());
    const controller=new AbortController();let timedOut=false;
    const abort=()=>controller.abort();
    if(options.signal?.aborted)abort();
    options.signal?.addEventListener('abort',abort,{once:true});
    const timeout=readOnly?this.schedule(()=>{timedOut=true;controller.abort();},5000):null;
    try {
      const response=await this.fetcher(url,{...options,signal:readOnly?controller.signal:options.signal});
      // Any HTTP response proves connectivity; keep 401/403/500 explanations.
      this.seen();return response;
    } catch(error) {
      if(timedOut||error.name!=='AbortError')this.failed();
      throw error;
    } finally {
      if(timeout!==null)this.cancel(timeout);
      options.signal?.removeEventListener('abort',abort);
    }
  }
  async probe() {
    if(this.probing||this.stopped)return;
    this.probing=true;
    const epoch=this.epoch;
    const controller=new AbortController();this.probeController=controller;
    const timeout=this.schedule(()=>controller.abort(),5000);
    try {
      const response=await this.fetcher('/phone/capabilities',{cache:'no-store',signal:controller.signal});
      if(epoch!==this.epoch)return;
      // Reaching an access-denied Mac is different from being offline.
      this.seen();
      if(!response.ok)this.changed(`Mac is online but phone access failed (${response.status}). Check Phone access on your Mac.`);
    } catch { if(epoch===this.epoch)this.failed(); }
    finally { this.cancel(timeout);if(epoch===this.epoch){this.probing=false;this.probeController=null;} }
  }
  watch() { this.watching=true;this.resume(); }
  resume() { this.stop();this.stopped=false;void this.probe(); }
  stop() { this.stopped=true;this.epoch++;this.probeController?.abort();this.probeController=null;this.probing=false;if(this.timer!==null)this.cancel(this.timer);this.timer=null; }
}
