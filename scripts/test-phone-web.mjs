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
  focus() {}
  setPointerCapture() {}
}
const source=fs.readFileSync(new URL('../Packages/OsaurusCore/Resources/Phone/phone-app.js',import.meta.url),'utf8');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
async function page(run, voice = false) {
  class Recorder {
    static isTypeSupported(type) { return type === 'audio/mp4'; }
    constructor(stream,options){this.mimeType=options.mimeType;this.state='inactive';}
    start(){this.state='recording';}
    stop(){this.state='inactive';this.ondataavailable({data:new Blob(['audio'])});this.onstop();}
  }
  const tracks=[{stop(){}}];
  const elements=new Map(['agents','status','chat','composer','prompt','mic','stop','send','new'].map(id=>[id,new Element(id==='agents'?'select':'div')]));
  const requests=[];
  const context=vm.createContext({
    document:{getElementById:id=>elements.get(id),createElement:tag=>new Element(tag),createTextNode:text=>({textContent:text}),addEventListener(){}},
    window:{isSecureContext:true,MediaRecorder:voice?Recorder:undefined},MediaRecorder:Recorder,
    navigator:voice?{mediaDevices:{getUserMedia:async()=>({getTracks:()=>tracks})}}:{},TextDecoder,AbortController,Blob,FormData,
    fetch:async(url,options)=>{
      if(url==='/agents') return Response.json({agents:[{id:'agent-1',name:'My agent'}]});
      if(url==='/phone/capabilities') return Response.json({transcription:true,speech:false});
      requests.push({url,options});return run(url,options);
    },
  });
  vm.runInContext(source,context);await tick();
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
  assert.deepEqual(all.filter(n=>n.tag==='a').map(n=>n.href),['https://example.test']);
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
