'use strict';
const $ = id => document.getElementById(id);
let history = [], controller, recording, micStream, holding = false, busy = false;
let audioContext, speechQueue, speakerEnabled=false, talkActive=false, talkController;
const agentsByID=new Map();
const companion=new PhoneCompanion($('avatar-small'),$('avatar-large'),$('companion-caption'));
function companionMood(input) { companion.setInput(input); }
function companionError(error) {
  companionMood(error.name==='AbortError'?{}:{error:true});
  companion.setCaption('');companion.react(error.name==='AbortError'?'surprised':'oops');
}
function unlockAudio() {
  if(!audioContext) audioContext=new (window.AudioContext||window.webkitAudioContext)();
  // Invoke resume synchronously inside the gesture, including on iOS Safari.
  const resumed=audioContext.resume();
  const source=audioContext.createBufferSource();source.buffer=audioContext.createBuffer(1,1,24000);
  source.connect(audioContext.destination);source.onended=()=>source.disconnect();source.start();
  return resumed;
}
function voiceButtons() {
  $('speaker').textContent=speakerEnabled?'Speaker on':'Speaker off';
  $('speaker').setAttribute('aria-pressed',String(speakerEnabled));
  $('talk').textContent=talkActive?'End talk / Interrupt':'Talk mode';
  $('talk').setAttribute('aria-pressed',String(talkActive));
  $('avatar-toggle').hidden=talkActive;$('companion-stage').hidden=!talkActive;
  $('avatar-toggle').disabled=$('talk').hidden||busy||!!talkController||!$('agents').value;
  companion.setActive(talkActive);
}
function stopVoice() {
  const interrupted=talkActive||busy;
  talkActive=false;talkController?.abort();controller?.abort();speechQueue?.interrupt();
  companionMood({});companion.setCaption('');if(interrupted)companion.react('surprised');voiceButtons();
}
$('speaker').onclick=async()=>{
  try {
    if(!speakerEnabled)await unlockAudio();
    speakerEnabled=!speakerEnabled;
    if(!speakerEnabled){speechQueue?.interrupt();if(talkActive)stopVoice();}
    voiceButtons();
  }catch(error){status(error.message);}
};
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
    else {
      const link = /^\[([^\]]+)\]\((.+)\)$/.exec(match[0]);
      try {
        const destination = new URL(link[2]);
        if (!['http:', 'https:'].includes(destination.protocol)) throw new Error('Unsupported link');
        node = document.createElement('a'); node.textContent = `${link[1]} (${destination.host})`;
        node.href = destination.href; node.target = '_blank'; node.rel = 'noopener noreferrer';
      } catch { node = document.createTextNode(match[0]); }
    }
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
  busy=value; const locked=value||!!talkController; $('send').disabled=locked; $('agents').disabled=locked; $('new').disabled=locked;
  $('mic').disabled=locked&&!holding; $('stop').hidden=!locked;voiceButtons();
}
async function checked(response) {
  if (!response.ok) { let detail = await response.text(); try { const j=JSON.parse(detail); detail=j.error?.message||j.message||detail; } catch {} throw new Error(`${response.status}: ${detail.slice(0,400)}`); }
  return response;
}
async function sendMessage(text=$('prompt').value.trim()) {
  if(busy) return false;
  const agent=$('agents').value; if(!text||!agent) return false;
  $('prompt').value=''; message('user',text);
  const turn=[...history,{role:'user',content:text}], output=message('assistant','…'); let answer='', ended=false;
  controller=new AbortController(); setBusy(true); status(talkActive?'Thinking…':'Agent is working…');
  companionMood({thinking:true});companion.setCaption('');
  const release=new SentenceRelease();let speechTimer, success=false, queue=null;
  const speak=sentences=>{if(speakerEnabled)for(const sentence of sentences)queue?.enqueue(sentence);};
  try {
    queue=speakerEnabled?new PhoneSpeechQueue(audioContext,fetch,()=>status('Speaking…'), playback=>{
      companionMood({thinking:true,speaking:playback.speaking,outputLevel:playback.level});
      companion.setCaption(playback.text);
    }):null;
    speechQueue=queue;
    if(queue)speechTimer=setInterval(()=>speak(release.release()),50);
    const response=await checked(await fetch(`/agents/${encodeURIComponent(agent)}/run`, {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({messages:turn,stream:true}),signal:controller.signal}));
    const reader=response.body.getReader(), decoder=new TextDecoder(); let buffer='';
    function frame(raw) {
      const data=raw.split('\n').filter(l=>l.startsWith('data:')).map(l=>l.slice(5).trimStart()).join('\n');
      if(!data) return; if(data==='[DONE]'){ended=true;return;}
      const item=JSON.parse(data); if(item.error) throw new Error(item.error.message||String(item.error));
      const delta=item.choices?.[0]?.delta;
      if(delta?.content){ answer+=delta.content; markdown(output,answer); if(queue)speak(release.append(delta.content)); }
      if(delta?.tool_calls) status('Agent is using tools…');
    }
    while(true){ const {done,value}=await reader.read(); if(done) break; buffer+=decoder.decode(value,{stream:true}).replace(/\r/g,''); let end; while((end=buffer.indexOf('\n\n'))>=0){frame(buffer.slice(0,end));buffer=buffer.slice(end+2);} }
    buffer+=decoder.decode(); if(buffer.trim()) frame(buffer);
    if(!ended) throw new Error('Connection ended before the agent completed. Try again.');
    if(!answer) throw new Error('The agent completed without a visible reply.');
    clearInterval(speechTimer);speak(release.finish());
    await queue?.finish();
    if(controller.signal.aborted)throw new DOMException('Stopped','AbortError');
    history=[...turn,{role:'assistant',content:answer}]; success=true;status('Ready');companionMood({});companion.react('happy');
  } catch(error) { controller?.abort(); queue?.interrupt(); companionError(error);status(error.name==='AbortError'?'Stopped. Partial reply was not added to history.':error.message); if(!answer) output.textContent='No completed reply.'; }
  finally{clearInterval(speechTimer); controller=null;speechQueue=null;setBusy(false);if(!talkActive)$('prompt').focus();}
  return success;
}
$('composer').addEventListener('submit',async event=>{event.preventDefault();if(!talkController)await sendMessage();});
$('stop').onclick=()=>{stopVoice();status('Stopped.');setBusy(busy);};
$('talk').onclick=async()=>{
  if(talkActive){stopVoice();status('Stopped.');return;}
  if(busy||talkController)return;
  if(!window.isSecureContext){status('Microphone requires HTTPS. Open the HTTPS phone URL from the Mac.');return;}
  talkActive=true;talkController=new AbortController();const signal=talkController.signal;
  speakerEnabled=true;voiceButtons();setBusy(false);
  try {
    await unlockAudio();
    while(!signal.aborted) {
      status('Listening…');companionMood({listening:true});
      const clip=await captureUtterance(audioContext,signal,level=>companionMood({listening:true,inputLevel:level}));
      if(signal.aborted)break;
      status('Thinking…');companionMood({thinking:true});setBusy(true);
      const form=new FormData();form.append('file',clip,clip.type.includes('mp4')?'recording.m4a':'recording.webm');
      const result=await (await checked(await fetch('/audio/transcriptions',{method:'POST',body:form,signal}))).json();
      if(signal.aborted)break;
      setBusy(false);
      if(!result.text?.trim())continue;
      if(!await sendMessage(result.text.trim()))break;
    }
  }catch(error){companionError(error);status(error.name==='AbortError'?'Stopped.':error.message);}
  finally{talkActive=false;talkController=null;voiceButtons();setBusy(false);}
};
$('avatar-toggle').onclick=()=>{if(!$('avatar-toggle').disabled)return $('talk').onclick();};
$('companion-toggle').onclick=()=>$('talk').onclick();
function clearChat(){history=[];$('chat').replaceChildren();companionMood({});companion.setAgent(agentsByID.get($('agents').value));status('New chat');}
$('new').onclick=clearChat; $('agents').onchange=clearChat;
async function stopRecording(){ holding=false; if(recording?.state==='recording') recording.stop(); }
$('mic').addEventListener('pointerdown',async event=>{
  event.preventDefault(); if(busy||holding||talkController) return;
  if(!window.isSecureContext){status('Microphone requires HTTPS. Open the HTTPS phone URL from the Mac.');return;} holding=true; setBusy(true); $('stop').hidden=true; $('mic').setPointerCapture(event.pointerId);
  try {
    micStream=await navigator.mediaDevices.getUserMedia({audio:true});
    if(!holding){micStream.getTracks().forEach(t=>t.stop());setBusy(false);return;}
    const mime=['audio/mp4','audio/webm;codecs=opus','audio/webm'].find(t=>MediaRecorder.isTypeSupported(t));
    recording=new MediaRecorder(micStream,mime?{mimeType:mime}:{}); const chunks=[];
    recording.ondataavailable=e=>{if(e.data.size) chunks.push(e.data);};
    recording.onstop=async()=>{
      micStream.getTracks().forEach(t=>t.stop()); $('mic').textContent='Hold to talk';
      if(document.hidden){setBusy(false);status('Recording stopped while the page was hidden.');return;}
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
document.addEventListener('visibilitychange',()=>{if(document.hidden){stopVoice();stopRecording();}});
(async()=>{
  try {
    const data=await (await checked(await fetch('/agents'))).json();
    for(const agent of data.agents||[]){agentsByID.set(agent.id,agent);const option=document.createElement('option');option.value=agent.id;option.textContent=agent.name;$('agents').append(option);}
    companion.setAgent(agentsByID.get($('agents').value));
    status($('agents').options.length?'Ready':'Create an agent on your Mac first.');
    const capabilities=await (await checked(await fetch('/phone/capabilities'))).json();
    $('mic').hidden=!(capabilities.transcription&&window.isSecureContext&&navigator.mediaDevices?.getUserMedia&&window.MediaRecorder);
    $('speaker').hidden=!(capabilities.speech&&(window.AudioContext||window.webkitAudioContext));
    $('talk').hidden=$('mic').hidden||$('speaker').hidden;
    if(!window.isSecureContext)$('voice-hint').textContent='Microphone requires HTTPS. Open the HTTPS phone URL from the Mac to use voice input.';
    voiceButtons();
    if('serviceWorker' in navigator&&window.isSecureContext) navigator.serviceWorker.register('/phone/sw.js',{scope:'/phone/'}).catch(()=>{});
  } catch(error){status(error.message);}
})();
