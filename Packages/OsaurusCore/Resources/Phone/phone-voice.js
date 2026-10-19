'use strict';
// Shared by the browser and the dependency-free Node proof lane.
class SentenceRelease {
  constructor() { this.text=''; this.emitted=0; this.first=true; this.started=null; }
  append(delta, now=performance.now()) { if(this.started===null)this.started=now; this.text+=delta; return this.release(now); }
  plain() {
    return this.text.replace(/```[\s\S]*?```/g,'').replace(/`([^`]+)`/g,'$1')
      .replace(/!?\[([^\]]+)\]\([^)]*\)/g,'$1').replace(/\*\*|__/g,'').replace(/^#{1,6}\s/gm,'');
  }
  release(now=performance.now(), final=false) {
    // An open Markdown construct can still hide text/URLs retroactively.
    if(!final && (['```','**','__','`'].some(m=>(this.text.split(m).length-1)%2) ||
       (this.text.match(/\[/g)||[]).length !== (this.text.match(/\]/g)||[]).length || /\]\([^)]*$/.test(this.text))) return [];
    const text=this.plain(), out=[];
    while(this.emitted<text.length) {
      const rest=text.slice(this.emitted);
      let end=rest.search(/[.!?](?=\s|$)/);
      if(end<0 && this.first && now-this.started>=500) {
        const clause=/[,;]/g;let match;
        while((match=clause.exec(rest))){if(match.index>=39){end=match.index;break;}}
      }
      if((end<0 || end>=1000) && (final || rest.length>1000)) {
        end=rest.length<=1000?rest.length-1:rest.lastIndexOf(' ',999);
        if(end<0)end=999;
      }
      if(end<0)break;
      const sentence=rest.slice(0,end+1).trim(); this.emitted+=end+1;
      if(sentence) { out.push(sentence); this.first=false; }
    }
    return out;
  }
  finish() { return this.release(performance.now(),true); }
}

class PhoneSpeechQueue {
  constructor(context, fetcher, onSpeaking=()=>{}) {
    this.context=context; this.fetcher=fetcher; this.onSpeaking=onSpeaking;
    this.epoch=0; this.tail=Promise.resolve(); this.sources=new Map(); this.nextTime=0;
    this.abort=new AbortController(); this.error=null; this.queued=0;
  }
  enqueue(text) {
    if(this.abort.signal.aborted)return;
    const epoch=this.epoch;
    this.queued+=text.length;
    if(this.queued>16384) { this.error=new Error('Speech queue is full. Turn off the speaker or try a shorter reply.'); return; }
    this.tail=this.tail.then(async()=>{
      if(epoch!==this.epoch || this.error)return;
      try { await this.speak(text,epoch); }
      catch(error) { if(epoch===this.epoch) { this.error=error; this.stopSources(); } }
      finally { this.queued-=text.length; }
    });
  }
  async speak(text,epoch) {
    const response=await this.fetcher('/v1/audio/speech',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({model:'configured',voice:'configured',input:text,response_format:'pcm'}),signal:this.abort.signal});
    if(!response.ok) {
      let message=await response.text(); try {message=JSON.parse(message).error?.message||message;}catch{}
      throw new Error(`Speech: ${response.status}: ${message.slice(0,400)}`);
    }
    if(!response.body)throw new Error('Speech response has no audio stream.');
    const reader=response.body.getReader(); let carry=null, count=0;
    try {
      while(true) {
        if(epoch!==this.epoch)return;
        const {value,done}=await reader.read(); if(done)break;
        if(epoch!==this.epoch)return;
        let bytes=value;
        if(carry!==null){bytes=new Uint8Array(value.length+1);bytes[0]=carry;bytes.set(value,1);}
        const length=bytes.length-bytes.length%2; carry=length<bytes.length?bytes[length]:null;
        // Small scheduled buffers limit memory and let interruption stop promptly.
        for(let offset=0;offset<length;offset+=3840) {
          while(this.nextTime-this.context.currentTime>1 && this.sources.size) {
            await Promise.race(this.sources.values());
            if(epoch!==this.epoch)return;
          }
          if(epoch!==this.epoch)return;
          const n=Math.min(3840,length-offset)/2, buffer=this.context.createBuffer(1,n,24000), samples=buffer.getChannelData(0);
          for(let i=0;i<n;i++){const raw=bytes[offset+2*i]|bytes[offset+2*i+1]<<8;samples[i]=(raw>=32768?raw-65536:raw)/32768;}
          const node=this.context.createBufferSource(); node.buffer=buffer; node.connect(this.context.destination);
          let resolve;const ended=new Promise(r=>resolve=r);
          node.onended=()=>{node.disconnect();this.sources.delete(node);resolve();};
          node.cancelWait=resolve;this.sources.set(node,ended);
          const at=Math.max(this.context.currentTime+0.02,this.nextTime);
          node.start(at);this.nextTime=at+n/24000;count+=n;this.onSpeaking();
        }
      }
      if(carry!==null)throw new Error('Speech stream ended with an incomplete PCM sample.');
      if(!count)throw new Error('Speech returned no audio.');
    } finally { await reader.cancel().catch(()=>{}); reader.releaseLock(); }
  }
  async finish() { await this.tail; await Promise.all(this.sources.values()); if(this.error)throw this.error; }
  stopSources() { for(const [node] of this.sources) {node.onended=null;try{node.stop();}catch{}node.disconnect();node.cancelWait();}this.sources.clear();this.nextTime=0; }
  interrupt() { this.epoch++;this.abort.abort();this.stopSources(); }
}

// Monotonic-time reducer; no timers, browser objects, or model dependencies.
class PhoneVAD {
  constructor() { this.state='listening';this.onset=null;this.lastVoice=0; }
  update(rms,now) {
    if(this.state==='ended')return null;
    if(rms>=0.025) {
      if(this.onset===null){this.onset=now;this.state='speech';this.lastVoice=now;return 'start';}
      this.lastVoice=now;
    }
    if(this.onset!==null && now-this.lastVoice>=700) {
      if(this.lastVoice-this.onset<300){this.onset=null;this.state='listening';return 'discard';}
      this.state='ended';return 'end';
    }
    if(this.onset!==null && now-this.onset>=30000){this.state='ended';return 'end';}
    return null;
  }
}

async function captureUtterance(context, signal) {
  const stream=await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:true,noiseSuppression:true,autoGainControl:true}});
  if(signal.aborted){stream.getTracks().forEach(t=>t.stop());throw new DOMException('Stopped','AbortError');}
  return new Promise((resolve,reject)=>{
    let input,analyser,muted;
    try {
      input=context.createMediaStreamSource(stream);analyser=context.createAnalyser();muted=context.createGain();
      analyser.fftSize=1024;muted.gain.value=0;input.connect(analyser);analyser.connect(muted);muted.connect(context.destination);
    } catch(error) {
      input?.disconnect();analyser?.disconnect();muted?.disconnect();stream.getTracks().forEach(t=>t.stop());reject(error);return;
    }
    const samples=new Float32Array(analyser.fftSize),vad=new PhoneVAD();let recorder,timer,settled=false;
    function cleanup(){clearInterval(timer);signal.removeEventListener('abort',abort);input.disconnect();analyser.disconnect();muted.disconnect();stream.getTracks().forEach(t=>t.stop());}
    function fail(error){if(settled)return;settled=true;if(recorder?.state==='recording'){recorder.onstop=null;recorder.stop();}cleanup();reject(error);}
    function abort(){fail(new DOMException('Stopped','AbortError'));}
    signal.addEventListener('abort',abort,{once:true});
    for(const track of stream.getTracks())track.onended=()=>fail(new Error('Microphone disconnected. Start Talk mode again.'));
    timer=setInterval(()=>{
      try {
        if(context.state==='suspended')throw new Error('Audio paused. Tap Talk mode to resume.');
        analyser.getFloatTimeDomainData(samples);const rms=Math.sqrt(samples.reduce((s,v)=>s+v*v,0)/samples.length);
        const action=vad.update(rms,performance.now());
        if(action==='start') {
          const mime=['audio/mp4','audio/webm;codecs=opus','audio/webm'].find(t=>MediaRecorder.isTypeSupported(t));
          recorder=new MediaRecorder(stream,mime?{mimeType:mime}:{});const chunks=[], active=recorder;
          recorder.ondataavailable=e=>{if(e.data.size)chunks.push(e.data);};
          recorder.onerror=()=>fail(new Error('Microphone recording failed.'));
          recorder.onstop=()=>{if(settled)return;settled=true;cleanup();resolve(new Blob(chunks,{type:active.mimeType}));};
          recorder.start();
        } else if(action==='discard') {recorder.onstop=null;recorder.stop();}
        else if(action==='end')recorder.stop();
      }catch(error){fail(error);}
    },40);
  });
}
