'use strict';
const $ = id => document.getElementById(id);
let history = [], controller, recording, micStream, holding = false, busy = false;
const status = message => { $('status').textContent = message; };
// Small safe Markdown subset: all text is created as DOM text nodes. Raw HTML
// is never interpreted. Links permit http(s) only, never javascript/data URLs.
function inline(parent, text) {
  const pattern = /(`[^`]+`|\*\*[^*]+\*\*|\[[^\]]+\]\(https?:\/\/[^\s)]+\))/g;
  let offset = 0;
  for (const match of text.matchAll(pattern)) {
    parent.append(document.createTextNode(text.slice(offset, match.index)));
    let node;
    if (match[0][0] === '`') { node = document.createElement('code'); node.textContent = match[0].slice(1,-1); }
    else if (match[0].startsWith('**')) { node = document.createElement('strong'); node.textContent = match[0].slice(2,-2); }
    else { const link = /^\[([^\]]+)\]\((.+)\)$/.exec(match[0]); node = document.createElement('a'); node.textContent=link[1]; node.href=link[2]; node.target='_blank'; node.rel='noopener noreferrer'; }
    parent.append(node); offset = match.index + match[0].length;
  }
  parent.append(document.createTextNode(text.slice(offset)));
}
function markdown(node, text) {
  node.replaceChildren();
  text.split('```').forEach((part, index) => {
    if (index % 2) { const pre=document.createElement('pre'); pre.textContent=part.replace(/^\w+\n/, ''); node.append(pre); }
    else part.split('\n').forEach(line => { const p=document.createElement(/^#{1,3} /.test(line)?'h3':'p'); inline(p,line.replace(/^#{1,3} /,'')); node.append(p); });
  });
}
function message(role, text) {
  const article=document.createElement('article'); article.className='message '+role;
  const label=document.createElement('strong'); label.textContent=role==='user'?'You':'Agent';
  const body=document.createElement('div'); markdown(body,text); article.append(label,body); $('chat').append(article); return body;
}
function setBusy(value) {
  busy=value; $('send').disabled=value; $('agents').disabled=value; $('new').disabled=value;
  $('mic').disabled=value&&!holding; $('stop').hidden=!value;
}
async function checked(response) {
  if (!response.ok) { let detail = await response.text(); try { const j=JSON.parse(detail); detail=j.error?.message||j.message||detail; } catch {} throw new Error(`${response.status}: ${detail.slice(0,400)}`); }
  return response;
}
$('composer').addEventListener('submit', async event => {
  event.preventDefault(); if(busy) return;
  const text=$('prompt').value.trim(), agent=$('agents').value; if(!text||!agent) return;
  $('prompt').value=''; message('user',text);
  const turn=[...history,{role:'user',content:text}], output=message('assistant','…'); let answer='', ended=false;
  controller=new AbortController(); setBusy(true); status('Agent is working…');
  try {
    const response=await checked(await fetch(`/agents/${encodeURIComponent(agent)}/run`, {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({messages:turn,stream:true}),signal:controller.signal}));
    const reader=response.body.getReader(), decoder=new TextDecoder(); let buffer='';
    function frame(raw) {
      const data=raw.split('\n').filter(l=>l.startsWith('data:')).map(l=>l.slice(5).trimStart()).join('\n');
      if(!data) return; if(data==='[DONE]'){ended=true;return;}
      const item=JSON.parse(data); if(item.error) throw new Error(item.error.message||String(item.error));
      const delta=item.choices?.[0]?.delta;
      if(delta?.content){ answer+=delta.content; markdown(output,answer); }
      if(delta?.tool_calls) status('Agent is using tools…');
    }
    while(true){ const {done,value}=await reader.read(); if(done) break; buffer+=decoder.decode(value,{stream:true}).replace(/\r/g,''); let end; while((end=buffer.indexOf('\n\n'))>=0){frame(buffer.slice(0,end));buffer=buffer.slice(end+2);} }
    buffer+=decoder.decode(); if(buffer.trim()) frame(buffer);
    if(!ended) throw new Error('Connection ended before the agent completed. Try again.');
    if(!answer) throw new Error('The agent completed without a visible reply.');
    history=[...turn,{role:'assistant',content:answer}]; status('Ready');
  } catch(error) { status(error.name==='AbortError'?'Stopped. Partial reply was not added to history.':error.message); if(!answer) output.textContent='No completed reply.'; }
  finally{ controller=null;setBusy(false);$('prompt').focus(); }
});
$('stop').onclick=()=>controller?.abort();
function clearChat(){history=[];$('chat').replaceChildren();status('New chat');}
$('new').onclick=clearChat; $('agents').onchange=clearChat;
async function stopRecording(){ holding=false; if(recording?.state==='recording') recording.stop(); }
$('mic').addEventListener('pointerdown',async event=>{
  event.preventDefault(); if(busy||holding) return; holding=true; setBusy(true); $('stop').hidden=true; $('mic').setPointerCapture(event.pointerId);
  try {
    micStream=await navigator.mediaDevices.getUserMedia({audio:true});
    if(!holding){micStream.getTracks().forEach(t=>t.stop());setBusy(false);return;}
    const mime=['audio/mp4','audio/webm;codecs=opus','audio/webm'].find(t=>MediaRecorder.isTypeSupported(t));
    recording=new MediaRecorder(micStream,mime?{mimeType:mime}:{}); const chunks=[];
    recording.ondataavailable=e=>{if(e.data.size) chunks.push(e.data);};
    recording.onstop=async()=>{
      micStream.getTracks().forEach(t=>t.stop()); $('mic').textContent='Hold to talk';
      controller=new AbortController(); setBusy(true); status('Transcribing…');
      try {
        const form=new FormData(); form.append('file',new Blob(chunks,{type:recording.mimeType}),recording.mimeType.includes('mp4')?'recording.m4a':'recording.webm');
        const result=await (await checked(await fetch('/audio/transcriptions',{method:'POST',body:form,signal:controller.signal}))).json();
        $('prompt').value=[$('prompt').value,result.text||''].filter(Boolean).join(' ');status('Review the transcript, then Send.');
      } catch(error){status(error.name==='AbortError'?'Transcription stopped.':error.message);} finally{controller=null;setBusy(false);}
    };
    recording.start(); $('mic').textContent='Release to transcribe';status('Recording…');
  } catch(error){ holding=false; micStream?.getTracks().forEach(t=>t.stop());setBusy(false);status(error.message); }
});
for(const event of ['pointerup','pointercancel','lostpointercapture']) $('mic').addEventListener(event,stopRecording);
document.addEventListener('visibilitychange',()=>{if(document.hidden) stopRecording();});
(async()=>{
  try {
    const data=await (await checked(await fetch('/agents'))).json();
    for(const agent of data.agents||[]){const option=document.createElement('option');option.value=agent.id;option.textContent=agent.name;$('agents').append(option);}
    status($('agents').options.length?'Ready':'Create an agent on your Mac first.');
    const capabilities=await (await checked(await fetch('/phone/capabilities'))).json();
    $('mic').hidden=!(capabilities.transcription&&window.isSecureContext&&navigator.mediaDevices?.getUserMedia&&window.MediaRecorder);
    // The core server has no speech endpoint. Do not advertise synthetic browser TTS.
    if('serviceWorker' in navigator&&window.isSecureContext) navigator.serviceWorker.register('/phone/sw.js',{scope:'/phone/'}).catch(()=>{});
  } catch(error){status(error.message);}
})();
