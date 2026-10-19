// DOM/protocol tests without a browser, network, package install or model.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

class Element {
  constructor(tag = 'div') { this.tag=tag; this.children=[]; this.handlers={}; this.value=''; this.hidden=false; this.disabled=false; this._text=''; }
  set textContent(value) { this.children=[]; this._text=String(value); }
  get textContent() { return this._text+this.children.map(c=>c.textContent).join(''); }
  get options() { return this.children; }
  append(...items) { this.children.push(...items); if(this.tag==='select'&&!this.value) this.value=items[0]?.value||''; }
  replaceChildren(...items) { this._text='';this.children=items;if(this.tag==='select')this.value=items[0]?.value||''; }
  removeAttribute(name) { delete this[name]; }
  addEventListener(type,fn) { this.handlers[type]=fn; }
  setAttribute(name,value) { this[name]=value; }
  getContext() { return this.context??=mockCanvasContext(); }
  focus() {}
  setPointerCapture() {}
}
function mockCanvasContext() {
  const calls=[];
  const target={calls,createLinearGradient:()=>({addColorStop(){}})};
  return new Proxy(target,{get(obj,key){if(!(key in obj))obj[key]=(...args)=>calls.push([key,...args]);return obj[key];}});
}
const avatarSource=fs.readFileSync(new URL('../Packages/OsaurusCore/Resources/Phone/phone-avatar.js',import.meta.url),'utf8');
const voiceSource=fs.readFileSync(new URL('../Packages/OsaurusCore/Resources/Phone/phone-voice.js',import.meta.url),'utf8');
const screenSource=fs.readFileSync(new URL('../Packages/OsaurusCore/Resources/Phone/phone-screen.js',import.meta.url),'utf8');
const source=fs.readFileSync(new URL('../Packages/OsaurusCore/Resources/Phone/phone-app.js',import.meta.url),'utf8');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
async function page(run, voice = false, secure = true, agents = [{id:'agent-1',name:'My agent',avatar:'purple'}]) {
  class Recorder {
    static isTypeSupported(type) { return type === 'audio/mp4'; }
    constructor(stream,options){this.mimeType=options.mimeType;this.state='inactive';}
    start(){this.state='recording';}
    stop(){this.state='inactive';this.ondataavailable({data:new Blob(['audio'])});this.onstop();}
  }
  const tracks=[{stop(){}}];
  const elements=new Map(['agents','status','chat','composer','prompt','mic','stop','send','new','speaker','talk','voice-hint','avatar-toggle','avatar-small','companion-toggle','avatar-large','companion-stage','companion-caption','screen-tab','chat-tab','screen-panel','screen-status','screen-enlarge','screen-image','screen-agent-hint','prompt-label'].map(id=>[id,new Element(id==='agents'?'select':'div')]));
  const requests=[], documentEvents={}, windowEvents={};
  const listen=(events,type,fn)=>(events[type]??=[]).push(fn);
  const context=vm.createContext({
    document:{getElementById:id=>elements.get(id),createElement:tag=>new Element(tag),createTextNode:text=>({textContent:text}),hidden:false,addEventListener(type,fn){listen(documentEvents,type,fn);}},
    window:{addEventListener(type,fn){listen(windowEvents,type,fn);},isSecureContext:secure,AudioContext:voice?MockAudioContext:undefined,MediaRecorder:voice?Recorder:undefined,matchMedia:()=>({matches:false,addEventListener(){}})},MediaRecorder:Recorder,
    requestAnimationFrame:()=>1,cancelAnimationFrame(){},
    navigator:voice?{mediaDevices:{getUserMedia:async()=>({getTracks:()=>tracks})}}:{},TextDecoder,AbortController,Blob,FormData,URL,DOMException,performance,setInterval,clearInterval,setTimeout,clearTimeout,
    fetch:async(url,options)=>{
      if(url==='/agents') return Response.json({agents});
      if(url==='/phone/capabilities') return Response.json({transcription:true,speech:true});
      requests.push({url,options});return run(url,options);
    },
  });
  vm.runInContext(voiceSource,context);vm.runInContext(avatarSource,context);vm.runInContext(screenSource,context);vm.runInContext(source,context);await tick();
  return {context,requests,$:id=>elements.get(id),
    visibility(hidden){context.document.hidden=hidden;for(const fn of documentEvents.visibilitychange||[])fn();},
    lifecycle(type){for(const fn of windowEvents[type]||[])fn();},
    async send(text){elements.get('prompt').value=text;await elements.get('composer').handlers.submit({preventDefault(){}});}};
}
function sse(text,done=true){
  const bytes=new TextEncoder().encode(`data: ${JSON.stringify({choices:[{delta:{content:text}}]})}\r\n\r\n${done?'data: [DONE]\r\n\r\n':''}`);
  return new Response(new ReadableStream({start(controller){for(const byte of bytes)controller.enqueue(Uint8Array.of(byte));controller.close();}}));
}

test('streaming decodes split UTF-8 and preserves successful conversation history',async()=>{
  const p=await page(()=>sse('Hello 🦖 **friend**'));
  await p.send('Hi');await p.send('Remember that?');
  const second=JSON.parse(p.requests[1].options.body);
  assert.equal(p.requests[0].url,'/agents/agent-1/run');
  assert.deepEqual(second.messages,[{role:'user',content:'Hi'},{role:'assistant',content:'Hello 🦖 **friend**'},{role:'user',content:'Remember that?'}]);
  assert.equal(p.$('status').textContent,'Ready');assert.equal(p.$('send').disabled,false);assert.equal(p.$('stop').hidden,true);
});

test('truncated stream does not enter history and unlocks composer',async()=>{
  let count=0;const p=await page(()=>sse('partial',++count!==1));
  await p.send('first');assert.match(p.$('status').textContent,/before the agent completed/);
  assert.equal(p.$('send').disabled,false);await p.send('second');
  assert.equal(JSON.parse(p.requests[1].options.body).messages.length,1);
});

test('server errors remain visible and unlock composer',async()=>{
  const p=await page(()=>Response.json({error:{message:'Model unavailable'}},{status:503}));
  await p.send('hello');assert.match(p.$('status').textContent,/503: Model unavailable/);
  assert.equal(p.$('agents').disabled,false);assert.equal(p.$('stop').hidden,true);
});

test('stop aborts an outstanding turn',async()=>{
  const p=await page((url,options)=>new Promise((resolve,reject)=>options.signal.addEventListener('abort',()=>reject(new DOMException('Stopped','AbortError')))));
  const pending=p.send('hello');await tick();p.$('stop').onclick();await pending;
  assert.match(p.$('status').textContent,/Stopped/);assert.equal(p.$('send').disabled,false);
});

test('Markdown uses text nodes and safe links',async()=>{
  const p=await page(()=>sse('ok'));const root=new Element();
  p.context.markdown(root,'<img src=x onerror=alert(1)> **bold** `code` [bad](javascript:alert) [safe](https://example.test)');
  const all=[];function walk(node){all.push(node);for(const child of node.children||[])walk(child);}walk(root);
  assert.equal(all.filter(n=>n.tag==='img'||n.tag==='script').length,0);
  assert.match(root.textContent,/<img src=x onerror/);
  assert.equal(all.find(n=>n.tag==='strong').textContent,'bold');
  assert.deepEqual(all.filter(n=>n.tag==='a').map(n=>n.href),['https://example.test/']);
  assert.equal(all.find(n=>n.tag==='a').textContent,'safe (example.test)');
});

test('new chat clears history and agent picker is populated',async()=>{
  const p=await page(()=>sse('ok'));assert.equal(p.$('agents').options.length,1);
  await p.send('first');p.$('new').onclick();await p.send('second');
  assert.equal(JSON.parse(p.requests[1].options.body).messages.length,1);
});


test('hold-to-talk blocks chat until transcription finishes and leaves reviewable text',async()=>{
  const p=await page(()=>Response.json({text:'spoken words'}),true);
  assert.equal(p.$('mic').hidden,false);
  await p.$('mic').handlers.pointerdown({preventDefault(){},pointerId:1});
  assert.equal(p.$('send').disabled,true);
  await p.$('mic').handlers.pointerup();await tick();
  assert.equal(p.requests[0].url,'/audio/transcriptions');
  assert.equal(p.$('prompt').value,'spoken words');
  assert.equal(p.$('send').disabled,false);
  assert.match(p.$('status').textContent,/Review the transcript/);
});

test('Markdown reveals actual destination host and renders malformed URLs as text',async()=>{
  const p=await page(()=>sse('ok'));const root=new Element();
  p.context.markdown(root,'[Apple ID login](https://apple.com@evil.example:8443/login) [broken](https://[bad)');
  assert.match(root.textContent,/Apple ID login \(evil.example:8443\)/);
  assert.match(root.textContent,/\[broken\]/);
});

class MockAudioContext {
  static instances=[];
  constructor(){this.currentTime=0;this.state='running';this.destination={};this.nodes=[];MockAudioContext.instances.push(this);}
  createAnalyser(){return {fftSize:1024,connect(){},disconnect(){this.disconnected=true;},getFloatTimeDomainData(samples){samples.fill(.1);}};}
  async resume(){this.state='running';}
  createBuffer(channels,length,rate){const data=new Float32Array(length);return {duration:length/rate,getChannelData:()=>data,data};}
  createBufferSource(){
    const context=this;
    const node={connect(){},disconnect(){this.disconnected=true;},stop(){this.stopped=true;},start(at=0){
      this.at=at;context.nodes.push(this);
      setImmediate(()=>{context.currentTime=Math.max(context.currentTime,at+this.buffer.duration);this.onended?.();});
    }};return node;
  }
}
function voiceTypes(){
  const context=vm.createContext({AbortController,DOMException,Uint8Array,Float32Array,performance,setInterval,clearInterval});
  vm.runInContext(voiceSource,context);
  return vm.runInContext('({SentenceRelease,PhoneSpeechQueue,PhoneVAD})',context);
}
const {SentenceRelease,PhoneSpeechQueue,PhoneVAD}=voiceTypes();
const pcm=bytes=>new Response(new ReadableStream({start(c){for(const byte of bytes)c.enqueue(Uint8Array.of(byte));c.close();}}));

test('first sentence releases immediately across deltas, with no repetition at finish',()=>{
  const split=new SentenceRelease();assert.deepEqual([...split.append('Hello',0)],[]);
  assert.deepEqual([...split.append(' world.',10)],['Hello world.']);
  assert.deepEqual([...split.append(' Next sentence! Tail',20)],['Next sentence!']);
  assert.deepEqual([...split.finish()],['Tail']);assert.deepEqual([...split.finish()],[]);
});

test('conversational clause waits 500 ms and at least 40 characters',()=>{
  const split=new SentenceRelease(),clause='This is a sufficiently long introductory clause,';
  assert.deepEqual([...split.append(clause,0)],[]);
  assert.deepEqual([...split.release(499)],[]);
  assert.deepEqual([...split.release(500)],[clause]);
  const short=new SentenceRelease();short.append('Short,',0);assert.deepEqual([...short.release(600)],[]);
});

test('open Markdown waits; speech excludes fenced code and link destinations',()=>{
  const split=new SentenceRelease();assert.deepEqual([...split.append('**Hello.',0)],[]);
  assert.deepEqual([...split.append('** [Read](https://example.com). ```js\nsecret();\n``` End.',10)],['Hello.','Read.','End.']);
});

test('unpunctuated reply chunks are bounded and preserve all words',()=>{
  const split=new SentenceRelease(),text='word '.repeat(1000);
  const chunks=[...split.append(text,0),...split.finish()];
  assert.ok(chunks.every(x=>x.length<=1000));assert.equal(chunks.join(' ').trim(),text.trim());
});

test('PCM queue serializes sentence fetches and schedules sample-exact adjacent audio',async()=>{
  const context=new MockAudioContext(),inputs=[];
  const queue=new PhoneSpeechQueue(context,async(url,opts)=>{inputs.push(JSON.parse(opts.body).input);return pcm([0,128,255,127]);});
  queue.enqueue('One.');queue.enqueue('Two.');await queue.finish();
  assert.deepEqual(inputs,['One.','Two.']);assert.equal(context.nodes.length,4);
  assert.equal(context.nodes[0].buffer.data[0],-1);
  assert.equal(context.nodes[1].buffer.data[0],32767/32768);
  for(let i=1;i<context.nodes.length;i++)assert.equal(context.nodes[i].at,context.nodes[i-1].at+context.nodes[i-1].buffer.duration);
});

test('speech starts before response EOF and interrupt stops nodes, aborts fetch, drops queued sentences',async()=>{
  const context=new MockAudioContext();let streamController,signal,calls=0;
  // Leave nodes live until explicitly interrupted.
  context.createBufferSource=()=>({connect(){},disconnect(){},stop(){this.stopped=true;},start(){context.nodes.push(this);}});
  const queue=new PhoneSpeechQueue(context,async(url,opts)=>{
    calls++;signal=opts.signal;
    return new Response(new ReadableStream({start(c){streamController=c;c.enqueue(Uint8Array.of(0,1));signal.addEventListener('abort',()=>c.error(new DOMException('Stopped','AbortError')));}}));
  });
  queue.enqueue('One.');queue.enqueue('Two.');await tick();
  assert.equal(context.nodes.length,1);queue.interrupt();queue.enqueue('Stale.');await queue.finish();
  assert.equal(signal.aborted,true);assert.equal(context.nodes[0].stopped,true);assert.equal(calls,1);
});

test('empty, odd-length and JSON speech failures surface and prevent later playback',async()=>{
  for(const response of [pcm([]),pcm([1]),Response.json({error:{message:'TTS not configured'}},{status:503})]){
    let calls=0;const queue=new PhoneSpeechQueue(new MockAudioContext(),async()=>{calls++;return response;});
    queue.enqueue('One.');queue.enqueue('Two.');await assert.rejects(queue.finish(),/no audio|incomplete PCM|TTS not configured/);assert.equal(calls,1);
  }
});

test('VAD requires sustained speech, holds through pauses, and ends after hangover',()=>{
  const vad=new PhoneVAD();assert.equal(vad.update(0,0),null);assert.equal(vad.state,'listening');
  assert.equal(vad.update(.1,100),'start');vad.update(.1,450);
  assert.equal(vad.update(0,1000),null);assert.equal(vad.update(0,1150),'end');
  assert.equal(vad.state,'ended');assert.equal(vad.update(.1,1200),null);
});

test('VAD discards a click and bounds continuous recording to 30 seconds',()=>{
  const vad=new PhoneVAD();vad.update(.1,0);assert.equal(vad.update(0,700),'discard');assert.equal(vad.state,'listening');
  assert.equal(vad.update(.1,800),'start');assert.equal(vad.update(.1,30800),'end');
});

test('speaker toggle unlocks one AudioContext and speaks visible content only',async()=>{
  const p=await page(url=>url==='/v1/audio/speech'?pcm([0,1]):sse('Hello. Follow-up!'),true);
  await p.$('speaker').onclick();await p.send('Hi');
  const speech=p.requests.filter(r=>r.url==='/v1/audio/speech');assert.equal(speech.length,2);
  assert.equal(JSON.parse(speech[0].options.body).input,'Hello.');
  const context=vm.runInContext('audioContext',p.context);
  await p.$('speaker').onclick();await p.$('speaker').onclick();
  assert.equal(vm.runInContext('audioContext',p.context),context);assert.equal(p.$('stop').hidden,true);
});

test('talk loop transcribes, sends, speaks, then listens; tap interrupts the next listening phase',async()=>{
  const p=await page(url=>url==='/audio/transcriptions'?Response.json({text:'Hello from mic'}):url==='/v1/audio/speech'?pcm([0,1]):sse('Hello back.'),true);
  let captures=0;
  p.context.captureUtterance=async(context,signal)=>{
    if(++captures===1)return new Blob(['voice'],{type:'audio/mp4'});
    return new Promise((resolve,reject)=>signal.addEventListener('abort',()=>reject(new DOMException('Stopped','AbortError'))));
  };
  const loop=p.$('talk').onclick();
  for(let i=0;i<20&&captures<2;i++)await tick();
  assert.equal(captures,2);assert.equal(p.$('status').textContent,'Listening…');
  assert.deepEqual(p.requests.map(r=>r.url),['/audio/transcriptions','/agents/agent-1/run','/v1/audio/speech']);
  await p.$('talk').onclick();await loop;
  assert.equal(p.$('send').disabled,false);assert.equal(p.$('talk')['aria-pressed'],'false');
});

test('talk tap while thinking aborts the run and does not restart listening',async()=>{
  const p=await page((url,opts)=>url==='/audio/transcriptions'?Response.json({text:'Question'}):new Promise((resolve,reject)=>opts.signal.addEventListener('abort',()=>reject(new DOMException('Stopped','AbortError')))),true);
  p.context.captureUtterance=async()=>new Blob(['voice'],{type:'audio/mp4'});
  const loop=p.$('talk').onclick();for(let i=0;i<10&&p.requests.length<2;i++)await tick();
  await p.$('talk').onclick();await loop;
  assert.equal(p.requests[1].options.signal.aborted,true);assert.equal(p.requests.length,2);assert.equal(p.$('send').disabled,false);
});

test('HTTP fallback explains microphone requirement without opening capture',async()=>{
  const p=await page(()=>sse('ok'),true,false);
  assert.equal(p.$('mic').hidden,true);assert.equal(p.$('talk').hidden,true);assert.match(p.$('voice-hint').textContent,/requires HTTPS/);
});

test('tap during talk playback aborts speech, stops scheduled audio and exits the loop',async()=>{
  let speechSignal;
  const p=await page((url,opts)=>{
    if(url==='/audio/transcriptions')return Response.json({text:'Question'});
    if(url!=='/v1/audio/speech')return sse('Answer.');
    speechSignal=opts.signal;
    return new Response(new ReadableStream({start(c){c.enqueue(Uint8Array.of(0,1));opts.signal.addEventListener('abort',()=>c.error(new DOMException('Stopped','AbortError')));}}));
  },true);
  p.context.captureUtterance=async()=>new Blob(['voice'],{type:'audio/mp4'});
  const loop=p.$('talk').onclick();for(let i=0;i<10&&!speechSignal;i++)await tick();
  assert.equal(p.$('status').textContent,'Speaking…');
  await p.$('talk').onclick();await loop;
  assert.equal(speechSignal.aborted,true);assert.equal(p.$('stop').hidden,true);assert.equal(p.requests.length,3);
});

function captureHarness({latePermission=false,brokenGraph=false}={}) {
  let timer,now=0,level=0,resolvePermission;
  const track={stopped:false,stop(){this.stopped=true;}};
  const stream={getTracks:()=>[track]};
  const recorders=[];
  class Recorder {
    static isTypeSupported(){return true;}
    constructor(){this.mimeType='audio/mp4';this.state='inactive';recorders.push(this);}
    start(){this.state='recording';}
    stop(){this.state='inactive';this.ondataavailable?.({data:new Blob(['audio'])});this.onstop?.();}
  }
  const nodes=[];const node=()=>{const n={connect(){},disconnect(){this.disconnected=true;}};nodes.push(n);return n;};
  const audio={state:'running',destination:{},createMediaStreamSource(){if(brokenGraph)throw new Error('Graph unavailable');return node();},
    createGain:()=>Object.assign(node(),{gain:{value:1}}),createAnalyser:()=>Object.assign(node(),{fftSize:1024,getFloatTimeDomainData(samples){samples.fill(level);}})};
  const context=vm.createContext({AbortController,DOMException,Blob,Float32Array,MediaRecorder:Recorder,
    navigator:{mediaDevices:{getUserMedia:()=>latePermission?new Promise(r=>resolvePermission=r):Promise.resolve(stream)}},
    performance:{now:()=>now},setInterval:fn=>{timer=fn;return 1;},clearInterval:()=>{timer=null;}});
  vm.runInContext(voiceSource,context);
  return {context,audio,track,nodes,recorders,frame(time,rms){now=time;level=rms;timer?.();},grant(){resolvePermission(stream);},hasTimer:()=>!!timer};
}

test('mocked microphone captures one utterance and releases graph/tracks before upload',async()=>{
  const h=captureHarness(),abort=new AbortController();
  const clip=h.context.captureUtterance(h.audio,abort.signal);await tick();
  h.frame(0,.1);h.frame(350,.1);h.frame(1050,0);
  const blob=await clip;assert.equal(blob.type,'audio/mp4');assert.ok(blob.size>0);
  assert.equal(h.track.stopped,true);assert.ok(h.nodes.every(n=>n.disconnected));assert.equal(h.hasTimer(),false);
});

test('capture abort and late microphone permission cannot restart recording',async()=>{
  for(const latePermission of [false,true]) {
    const h=captureHarness({latePermission}),abort=new AbortController();
    const pending=h.context.captureUtterance(h.audio,abort.signal);await tick();
    const rejected=assert.rejects(pending,{name:'AbortError'});
    abort.abort();if(latePermission)h.grant();await rejected;
    h.frame(100,.1);assert.equal(h.track.stopped,true);assert.equal(h.recorders.length,0);assert.equal(h.hasTimer(),false);
  }
});

test('capture graph failure and suspended context release the microphone',async()=>{
  const broken=captureHarness({brokenGraph:true});await assert.rejects(broken.context.captureUtterance(broken.audio,new AbortController().signal),/Graph unavailable/);
  assert.equal(broken.track.stopped,true);
  const h=captureHarness();const pending=h.context.captureUtterance(h.audio,new AbortController().signal);await tick();
  h.audio.state='suspended';h.frame(0,0);await assert.rejects(pending,/Audio paused/);assert.equal(h.track.stopped,true);
});

test('long punctuated sentences and final Markdown tails respect synthesis request bounds',()=>{
  for(const text of ['word '.repeat(1000)+'.','**'+'word '.repeat(1000)]){
    const split=new SentenceRelease();const chunks=[...split.append(text,0),...split.finish()];
    assert.ok(chunks.length>1);assert.ok(chunks.every(x=>x.length<=1000));
  }
});

function avatarHarness(reduced=false) {
  let now=0,nextID=0;
  const frames=new Map(),listeners={},motion={matches:reduced,addEventListener(type,fn){this.changed=fn;}};
  const images=[];
  const document={hidden:false,addEventListener(type,fn){listeners[type]=fn;}};
  const context=vm.createContext({document,window:{devicePixelRatio:2,matchMedia:()=>motion},performance:{now:()=>now},
    requestAnimationFrame:fn=>{frames.set(++nextID,fn);return nextID;},cancelAnimationFrame:id=>frames.delete(id),
    Image:class{constructor(){images.push(this);this.naturalWidth=200;this.naturalHeight=100;}}});
  vm.runInContext(avatarSource,context);
  return {context,frames,images,motion,document,types:vm.runInContext('({PhoneAvatarState,PhoneCompanion,drawPhoneAvatar,phoneMouth,phoneAccessory})',context),
    advance(time){now=time;const callbacks=[...frames.values()];frames.clear();callbacks.forEach(fn=>fn(now));},
    hide(hidden){document.hidden=hidden;listeners.visibilitychange();}};
}

test('avatar mood precedence preserves speaking and listening levels over thinking/error',()=>{
  const {types}=avatarHarness(),state=new types.PhoneAvatarState();
  let frame=state.frame({speaking:true,listening:true,thinking:true,error:true,outputLevel:.8},0,1000);
  assert.equal(frame.mood,'speaking');assert.ok(frame.mouth>.79);
  frame=state.frame({listening:true,thinking:true,error:true,inputLevel:.6},100,1000);
  assert.equal(frame.mood,'listening');assert.equal(frame.mouth,0);assert.ok(frame.level>.59);
  assert.equal(state.frame({thinking:true,error:true},200,100).mood,'thinking');
  assert.equal(state.frame({error:true},300,100).mood,'error');
  assert.equal(state.frame({},400,100).mood,'idle');
});

test('avatar reaction priority, exact expiry and celebration suppression match T09',()=>{
  const {types}=avatarHarness(),state=new types.PhoneAvatarState();
  state.react('happy',0);assert.equal(state.frame({listening:true},100,100).reaction,'happy');
  assert.equal(state.frame({speaking:true,outputLevel:1},200,100).reaction,null);
  assert.equal(state.frame({thinking:true},300,100).reaction,null);
  state.react('oops',400);state.react('happy',500);
  assert.equal(state.frame({error:true},600,100).reaction,'oops');
  state.react('surprised',700);state.react('oops',800);
  assert.equal(state.frame({speaking:true},1599,100).reaction,'surprised');
  assert.equal(state.frame({},1600,1).reaction,null);
  state.react('happy',1600);assert.equal(state.frame({},3400,100).reaction,null);
});

test('mouth clamps invalid levels; smoothing is elapsed-time based',()=>{
  const {types}=avatarHarness();
  for(const value of [NaN,Infinity,-1])assert.equal(types.phoneMouth(value),0);
  assert.equal(types.phoneMouth(2),1);assert.equal(types.phoneMouth(.4),.4);
  const slow=new types.PhoneAvatarState(),fast=new types.PhoneAvatarState();
  const a=slow.frame({speaking:true,outputLevel:1},100,100);
  for(let i=0;i<10;i++)fast.frame({speaking:true,outputLevel:1},i*10,10);
  assert.ok(Math.abs(a.mouth-fast.level)<1e-10);
  const invalid=slow.frame({speaking:true,outputLevel:NaN},200,100);
  assert.ok(Number.isFinite(invalid.mouth));assert.ok(invalid.mouth<a.mouth);
});

test('mock canvas covers every mood, reaction and accessory; reduced pose is time invariant',()=>{
  const {types}=avatarHarness();
  for(const [id,accessory] of [['blue','scarf'],['red','scarf'],['purple','glasses'],['orange','glasses'],['green','leaf'],['yellow','leaf'],[null,'none']]){
    assert.equal(types.phoneAccessory(id),accessory);
    for(const mood of ['idle','listening','thinking','speaking','error'])for(const reaction of [null,'happy','oops','surprised']){
      const canvas=new Element('canvas');canvas.width=canvas.height=320;
      types.drawPhoneAvatar(canvas,{mood,reaction,level:.7,mouth:mood==='speaking'?.7:0,reduceMotion:false,time:1},id);
      assert.ok(canvas.context.calls.some(call=>call[0]==='ellipse'));
    }
  }
  const first=new Element(),second=new Element();first.width=first.height=second.width=second.height=320;
  for(const [canvas,time] of [[first,10],[second,90]])types.drawPhoneAvatar(canvas,{mood:'speaking',reaction:'happy',level:.7,mouth:.7,reduceMotion:true,time},'blue');
  assert.deepEqual(first.context.calls,second.context.calls);
  assert.ok(first.context.calls.some(call=>call[0]==='ellipse'&&call[1]===83&&call[3]===14));
});

test('hidden page cancels animation; reduced-motion idle has no animation loop',()=>{
  const h=avatarHarness(),avatar=new h.types.PhoneCompanion(new Element(),new Element(),new Element());
  assert.equal(h.frames.size,1);h.hide(true);assert.equal(h.frames.size,0);
  avatar.setInput({speaking:true,outputLevel:.8});assert.equal(h.frames.size,0);
  h.hide(false);assert.equal(h.frames.size,1);h.advance(100);
  h.motion.matches=true;h.motion.changed();avatar.setInput({});assert.equal(h.frames.size,0);
  avatar.react('happy');assert.equal(h.frames.size,1);h.advance(2000);assert.equal(h.frames.size,0);
});

test('custom image uses same-origin endpoint, ignores stale image loads, and draws reactive ring',()=>{
  const h=avatarHarness(),small=new Element(),large=new Element(),avatar=new h.types.PhoneCompanion(small,large,new Element());
  avatar.setAgent({id:'a/b',avatar:'green',custom_avatar:true});const old=h.images[0];
  assert.equal(old.src,'/agents/a%2Fb/avatar');
  avatar.setAgent({id:'next',avatar:'red',custom_avatar:true});old.onload();assert.equal(avatar.image,null);
  h.images[1].onload();avatar.setActive(true);avatar.setInput({speaking:true,outputLevel:1});h.advance(1000);
  assert.equal(avatar.image,h.images[1]);assert.ok(large.context.calls.some(c=>c[0]==='drawImage'));
  assert.ok(large.context.calls.some(c=>c[0]==='ellipse'&&c[3]>66));
  avatar.setAgent({id:'no-image',avatar:'yellow'});assert.equal(avatar.image,null);
});

test('playback meter and captions use the audible segment clock, reset and disconnect on interrupt',async()=>{
  const context=new MockAudioContext(),frames=[];
  context.createBufferSource=()=>({connect(to){this.destination=to;},disconnect(){},stop(){},start(at){this.at=at;context.nodes.push(this);}});
  const queue=new PhoneSpeechQueue(context,async()=>pcm([0,1]),()=>{},frame=>frames.push(frame));
  queue.enqueue('First.');queue.enqueue('Second.');await queue.tail;
  assert.equal(context.nodes[0].destination,queue.analyser);
  queue.samplePlayback();assert.equal(frames.at(-1).speaking,false);assert.equal(frames.at(-1).text,'');
  context.currentTime=context.nodes[0].at;queue.samplePlayback();assert.equal(frames.at(-1).text,'First.');assert.ok(frames.at(-1).level>.59);
  context.currentTime=context.nodes[1].at;queue.samplePlayback();assert.equal(frames.at(-1).text,'Second.');
  queue.interrupt();await queue.finish();
  assert.equal(queue.meterTimer,null);assert.equal(queue.analyser.disconnected,true);assert.equal(queue.segments.size,0);
  assert.equal(frames.at(-1).level,0);assert.equal(frames.at(-1).text,'');
});

test('companion tap expands talk, then stops it and shows the interrupt reaction',async()=>{
  const p=await page(()=>sse('ok'),true);
  assert.equal(vm.runInContext('companion.mascot',p.context),'purple');
  p.context.captureUtterance=async(context,signal)=>new Promise((resolve,reject)=>signal.addEventListener('abort',()=>reject(new DOMException('Stopped','AbortError'))));
  const loop=p.$('avatar-toggle').onclick();await tick();
  assert.equal(p.$('companion-stage').hidden,false);assert.equal(p.$('avatar-toggle').hidden,true);
  assert.equal(vm.runInContext('companion.input.listening',p.context),true);
  await p.$('companion-toggle').onclick();await loop;
  assert.equal(p.$('companion-stage').hidden,true);assert.equal(p.$('avatar-toggle').hidden,false);
  assert.equal(vm.runInContext('companion.state.reaction',p.context),'surprised');assert.equal(p.$('companion-caption').textContent,'');
});

test('completed and failed turns publish happy/oops; captions are plain text',async()=>{
  const p=await page(()=>sse('Hello.'));await p.send('hi');
  assert.equal(vm.runInContext('companion.state.reaction',p.context),'happy');
  const failed=await page(()=>Response.json({error:{message:'Failed'}},{status:503}));await failed.send('hi');
  assert.equal(vm.runInContext('companion.state.reaction',failed.context),'oops');
  assert.equal(vm.runInContext('companion.input.error',failed.context),true);
  vm.runInContext('companion.setCaption("<img src=x onerror=alert(1)>")',p.context);
  assert.equal(p.$('companion-caption').children.length,0);
});

test('output graph setup failure reports oops and unlocks the composer',async()=>{
  const p=await page(()=>sse('ok'),true);await p.$('speaker').onclick();
  vm.runInContext('audioContext.createAnalyser=()=>{throw new Error("Output graph unavailable");}',p.context);
  await p.send('hello');assert.match(p.$('status').textContent,/Output graph unavailable/);
  assert.equal(p.$('send').disabled,false);assert.equal(p.$('stop').hidden,true);
  assert.equal(vm.runInContext('companion.state.reaction',p.context),'oops');
});

function screenHarness(fetcher) {
  let now=0,nextID=0;const timers=new Map(),frames=[],statuses=[];
  const context=vm.createContext({AbortController,performance:{now:()=>now}});
  vm.runInContext(screenSource,context);
  const Poller=vm.runInContext('PhoneScreenPoller',context);
  const poller=new Poller({fetcher,onFrame:frame=>frames.push(frame),onStatus:text=>statuses.push(text),now:()=>now,
    schedule:(fn,delay)=>{timers.set(++nextID,{fn,at:now+delay});return nextID;},cancel:id=>timers.delete(id)});
  return {poller,frames,statuses,timers,async advance(ms){now+=ms;const due=[...timers].filter(([,t])=>t.at<=now);for(const [id,t] of due){timers.delete(id);await t.fn();}await tick();}};
}

test('screen agent filtering requires effective capability and excludes built-ins',()=>{
  const context=vm.createContext({});vm.runInContext(screenSource,context);
  const filtered=context.phoneComputerUseAgents([
    {id:'yes',computer_use_enabled:true},{id:'disabled',computer_use_enabled:false},
    {id:'built-in',computer_use_enabled:true,is_built_in:true},{id:'missing'},
  ]);
  assert.deepEqual(Array.from(filtered,a=>a.id),['yes']);
});

test('screen polling starts only while active and stops, aborts and discards stale results',async()=>{
  let calls=0,signal,resolve;
  const h=screenHarness((url,options)=>{calls++;signal=options.signal;assert.equal(options.cache,'no-store');return new Promise(r=>resolve=r);});
  await h.advance(1000);assert.equal(calls,0);
  h.poller.setActive(true);const pending=h.advance(0);await tick();assert.equal(calls,1);
  h.poller.refresh();assert.equal(calls,1);
  h.poller.setActive(false);assert.equal(signal.aborted,true);
  resolve(new Response(new Blob(['stale'])));await pending;
  assert.deepEqual(h.frames,[null]);assert.equal(h.timers.size,0);
  await h.advance(5000);assert.equal(calls,1);
});

test('completed tool trace refreshes at the 500ms boundary and coalesces in-flight refreshes',async()=>{
  let calls=0;
  const h=screenHarness(async()=>{calls++;return new Response(new Blob(['jpeg']));});
  h.poller.setActive(true);await h.advance(0);assert.equal(calls,1);
  h.poller.streamEvent({osaurus_agent_tool:{phase:'started'}});
  await h.advance(100);assert.equal(calls,1);
  h.poller.streamEvent({osaurus_agent_tool:{phase:'completed'}});
  await h.advance(399);assert.equal(calls,1);
  await h.advance(1);assert.equal(calls,2);
  let finish;
  h.poller.fetcher=()=>new Promise(r=>finish=r);
  const pending=h.advance(1000);await tick();
  h.poller.streamEvent({osaurus_agent_tool:{phase:'completed'}});
  finish(new Response(new Blob(['jpeg'])));await pending;
  assert.equal([...h.timers.values()][0].at,2000);
  h.poller.setActive(false);
});

test('screen errors clear private pixels and use a slow retry; foreground can recover',async()=>{
  let calls=0;
  const h=screenHarness(async()=>++calls===1?new Response(new Blob(['jpeg'])):Response.json({error:{message:'Screen viewing is disabled.'}},{status:403}));
  h.poller.setActive(true);await h.advance(0);assert.equal(h.frames.length,1);
  await h.advance(1000);assert.equal(h.frames.at(-1),null);assert.match(h.statuses.at(-1),/disabled/);
  await h.advance(4999);assert.equal(calls,2);
  h.poller.setActive(false);assert.equal(h.timers.size,0);
  h.poller.fetcher=async()=>new Response(new Blob(['new jpeg']));
  h.poller.setActive(true);await h.advance(1);assert.ok(h.frames.at(-1));
  h.poller.setActive(false);
});

test('Screen panel filters picker, sends through ordinary agent run, and forwards completion events',async()=>{
  const agents=[{id:'plain',name:'Plain'},{id:'computer',name:'Computer',computer_use_enabled:true}];
  const p=await page((url)=>{
    if(url.startsWith('/phone/api/screen'))return new Response(new Blob(['jpeg']));
    return new Response('data: {"osaurus_agent_tool":{"phase":"completed","name":"computer_use"},"choices":[]}\n\ndata: {"choices":[{"delta":{"content":"Done"}}]}\n\ndata: [DONE]\n\n');
  },false,true,agents);
  p.$('screen-tab').onclick();
  assert.equal(p.$('agents').options.length,1);assert.equal(p.$('agents').value,'computer');
  assert.equal(p.$('prompt').placeholder,'Ask about this screen');
  vm.runInContext('globalThis.traces=[];const originalScreenEvent=screenPanel.poller.streamEvent.bind(screenPanel.poller);screenPanel.poller.streamEvent=item=>{traces.push(item);originalScreenEvent(item);};',p.context);
  await p.send('Close that dialog');
  const run=p.requests.find(r=>r.url==='/agents/computer/run');assert.ok(run);
  assert.deepEqual(JSON.parse(run.options.body).messages,[{role:'user',content:'Close that dialog'}]);
  assert.equal(p.context.traces[0].osaurus_agent_tool.phase,'completed');
  assert.equal(p.$('status').textContent,'Ready');assert.equal(p.$('stop').hidden,true);
  p.$('chat-tab').onclick();assert.equal(p.$('agents').options.length,2);
  assert.equal(vm.runInContext('screenPanel.poller.active',p.context),false);
});

test('no Computer Use agents explains setup and prevents sending',async()=>{
  const p=await page(()=>{throw Error('must not fetch run');});
  p.$('screen-tab').onclick();
  assert.equal(p.$('agents').options.length,0);assert.equal(p.$('send').disabled,true);
  assert.match(p.$('screen-agent-hint').textContent,/No Computer Use agents/);
  await p.send('Do something');assert.equal(p.requests.length,0);
  p.$('chat-tab').onclick();assert.equal(p.$('send').disabled,false);
});

test('Screen panel visibility and page lifecycle pause polling and clear preview',async()=>{
  const p=await page(()=>new Response(new Blob(['jpeg'])));
  p.$('screen-tab').onclick();assert.equal(vm.runInContext('screenPanel.poller.active',p.context),true);
  p.visibility(true);assert.equal(vm.runInContext('screenPanel.poller.active',p.context),false);
  assert.equal(p.$('screen-image').src,undefined);
  p.visibility(false);assert.equal(vm.runInContext('screenPanel.poller.active',p.context),true);
  p.lifecycle('pagehide');assert.equal(vm.runInContext('screenPanel.poller.active',p.context),false);
  p.lifecycle('pageshow');assert.equal(vm.runInContext('screenPanel.poller.active',p.context),true);
  p.$('chat-tab').onclick();p.visibility(false);
  assert.equal(vm.runInContext('screenPanel.poller.active',p.context),false);
});

test('browser-native fetch and timer defaults are not called with the poller as receiver',async()=>{
  const timers=new Map();let next=0,calls=0;
  function nativeCall(receiver) {assert.notEqual(receiver?.constructor?.name,'PhoneScreenPoller');}
  const context=vm.createContext({AbortController,performance:{now:()=>0},
    fetch:async function(){nativeCall(this);calls++;return new Response(new Blob(['jpeg']));},
    setTimeout:function(fn,delay){nativeCall(this);timers.set(++next,fn);return next;},
    clearTimeout:function(id){nativeCall(this);timers.delete(id);}});
  vm.runInContext(screenSource,context);
  const poller=vm.runInContext('new PhoneScreenPoller({onFrame(){},onStatus(){}})',context);
  poller.setActive(true);await timers.get(1)();assert.equal(calls,1);
  poller.setActive(false);
});

test('switching between Chat and Screen keeps history when the selected agent is unchanged',async()=>{
  const p=await page(()=>sse('Remembered'),false,true,[{id:'computer',name:'Computer',computer_use_enabled:true}]);
  await p.send('Remember milk');p.$('screen-tab').onclick();p.$('chat-tab').onclick();
  await p.send('What was it?');
  assert.equal(JSON.parse(p.requests[1].options.body).messages.length,3);
});
