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
  replaceChildren(...items) { this._text='';this.children=items; }
  addEventListener(type,fn) { this.handlers[type]=fn; }
  setAttribute(name,value) { this[name]=value; }
  focus() {}
  setPointerCapture() {}
}
const voiceSource=fs.readFileSync(new URL('../Packages/OsaurusCore/Resources/Phone/phone-voice.js',import.meta.url),'utf8');
const source=fs.readFileSync(new URL('../Packages/OsaurusCore/Resources/Phone/phone-app.js',import.meta.url),'utf8');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
async function page(run, voice = false, secure = true) {
  class Recorder {
    static isTypeSupported(type) { return type === 'audio/mp4'; }
    constructor(stream,options){this.mimeType=options.mimeType;this.state='inactive';}
    start(){this.state='recording';}
    stop(){this.state='inactive';this.ondataavailable({data:new Blob(['audio'])});this.onstop();}
  }
  const tracks=[{stop(){}}];
  const elements=new Map(['agents','status','chat','composer','prompt','mic','stop','send','new','speaker','talk','voice-hint'].map(id=>[id,new Element(id==='agents'?'select':'div')]));
  const requests=[];
  const context=vm.createContext({
    document:{getElementById:id=>elements.get(id),createElement:tag=>new Element(tag),createTextNode:text=>({textContent:text}),addEventListener(){}},
    window:{isSecureContext:secure,AudioContext:voice?MockAudioContext:undefined,MediaRecorder:voice?Recorder:undefined},MediaRecorder:Recorder,
    navigator:voice?{mediaDevices:{getUserMedia:async()=>({getTracks:()=>tracks})}}:{},TextDecoder,AbortController,Blob,FormData,URL,DOMException,performance,setInterval,clearInterval,
    fetch:async(url,options)=>{
      if(url==='/agents') return Response.json({agents:[{id:'agent-1',name:'My agent'}]});
      if(url==='/phone/capabilities') return Response.json({transcription:true,speech:true});
      requests.push({url,options});return run(url,options);
    },
  });
  vm.runInContext(voiceSource,context);vm.runInContext(source,context);await tick();
  return {context,requests,$:id=>elements.get(id),async send(text){elements.get('prompt').value=text;await elements.get('composer').handlers.submit({preventDefault(){}});}};
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
