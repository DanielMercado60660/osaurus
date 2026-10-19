'use strict';

function phoneComputerUseAgents(agents) {
  return agents.filter(agent => agent?.computer_use_enabled === true && !agent.is_built_in);
}

// Single-flight, monotonic scheduling. Both polling and tool-step refreshes obey
// the server's 500 ms minimum. Abort epochs prevent hidden/stale frames appearing.
class PhoneScreenPoller {
  constructor({fetcher=(...args)=>fetch(...args), onFrame, onStatus, now=()=>performance.now(),
    schedule=(fn,delay)=>setTimeout(fn,delay), cancel=id=>clearTimeout(id), interval=1000}) {
    Object.assign(this,{fetcher,onFrame,onStatus,now,schedule,cancel,interval});
    this.active=false;this.epoch=0;this.lastStart=-Infinity;this.timer=null;this.request=null;
  }
  setActive(active) {
    if(this.active===active)return;
    this.active=active;this.epoch++;this.pendingRefresh=false;
    this.cancel(this.timer);this.timer=null;
    this.request?.abort();this.request=null;
    if(active)this.refresh();
    else this.onFrame(null);
  }
  refresh() {
    if(!this.active)return;
    if(this.request){this.pendingRefresh=true;return;}
    this.cancel(this.timer);
    const delay=Math.max(0,500-(this.now()-this.lastStart));
    this.timer=this.schedule(()=>this.poll(),delay);
  }
  async poll() {
    this.timer=null;
    if(!this.active||this.request)return;
    const epoch=this.epoch,request=new AbortController();this.request=request;this.lastStart=this.now();
    let retry=this.interval;
    try {
      const response=await this.fetcher('/phone/api/screen?display=main&max=1280', {cache:'no-store',signal:request.signal});
      if(!response.ok) {
        let message='Screen unavailable.';
        try {const data=await response.json();message=data.error?.message||message;}catch{}
        retry=response.status===429?1000:5000;
        throw new Error(message);
      }
      const blob=await response.blob();
      if(epoch!==this.epoch||!this.active)return;
      this.onFrame(blob);this.onStatus('Live screen · Tap to enlarge, pinch to zoom');
    } catch(error) {
      if(epoch!==this.epoch||!this.active)return;
      this.onFrame(null); // Revocation must not leave the last private frame on screen.
      if(error.name!=='AbortError')this.onStatus(error.message);
    } finally {
      if(epoch===this.epoch){
        this.request=null;
        if(this.active){
          if(this.pendingRefresh){this.pendingRefresh=false;this.refresh();}
          else this.timer=this.schedule(()=>this.poll(),retry);
        }
      }
    }
  }
  streamEvent(item) {
    if(item.osaurus_agent_tool?.phase==='completed')this.refresh();
  }
}

class PhoneScreenPanel {
  constructor({get, onModeChange}) {
    this.get=get;this.onModeChange=onModeChange;this.open=false;this.objectURL=null;
    this.poller=new PhoneScreenPoller({onFrame:blob=>this.frame(blob),onStatus:text=>{get('screen-status').textContent=text;}});
    get('screen-tab').onclick=()=>this.setOpen(true);
    get('chat-tab').onclick=()=>this.setOpen(false);
    get('screen-enlarge').onclick=()=>{
      const enlarged=get('screen-image').classList.toggle('enlarged');
      get('screen-enlarge').setAttribute('aria-pressed',String(enlarged));
    };
    document.addEventListener('visibilitychange',()=>this.poller.setActive(this.open&&!document.hidden));
    window.addEventListener('pagehide',()=>this.poller.setActive(false));
    window.addEventListener('pageshow',()=>this.poller.setActive(this.open&&!document.hidden));
  }
  setOpen(open) {
    if(this.open===open)return;
    this.open=open;this.get('screen-panel').hidden=!open;
    this.get('screen-tab').setAttribute('aria-pressed',String(open));
    this.get('chat-tab').setAttribute('aria-pressed',String(!open));
    this.get('prompt').placeholder=open?'Ask about this screen':'Message your agent';
    this.get('prompt-label').textContent=open?'Ask about this screen':'Message';
    this.onModeChange(open);this.poller.setActive(open&&!document.hidden);
  }
  frame(blob) {
    const old=this.objectURL;
    this.objectURL=blob?URL.createObjectURL(blob):null;
    const img=this.get('screen-image');
    if(this.objectURL)img.src=this.objectURL;else img.removeAttribute('src');
    this.get('screen-enlarge').hidden=!blob;
    if(old)URL.revokeObjectURL(old);
  }
}
