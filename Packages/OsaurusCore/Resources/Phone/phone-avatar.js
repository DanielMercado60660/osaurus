'use strict';
// Canvas counterpart of DinosaurAvatarRenderer: the same 160-point geometry,
// AgentMascot palette and T09 accessory/reaction policy. No app/audio ownership.
const phoneMascots = {
  blue:[.30,.56,.92], green:[.36,.72,.42], orange:[.95,.58,.24],
  purple:[.62,.42,.92], red:[.91,.38,.36], yellow:[.95,.78,.27]
};
function phoneAccessory(id) {
  if(['blue','red'].includes(id))return 'scarf';
  if(['purple','orange'].includes(id))return 'glasses';
  if(['green','yellow'].includes(id))return 'leaf';
  return 'none';
}
function phoneUnit(value) { return Number.isFinite(value)?Math.min(1,Math.max(0,value)):0; }
function phoneMouth(level) { return phoneUnit(level); }
class PhoneAvatarState {
  constructor() { this.mood='idle';this.level=0;this.reaction=null;this.expiresAt=0; }
  react(next,now) {
    const priority={happy:0,oops:1,surprised:2};
    if(!(next in priority))return;
    if(now>=this.expiresAt)this.reaction=null;
    if(this.reaction && priority[next]<priority[this.reaction])return;
    this.reaction=next;this.expiresAt=now+(next==='surprised'?900:1800);
  }
  frame(input,now,elapsed,reduceMotion=false) {
    if(now>=this.expiresAt)this.reaction=null;
    const mood=input.speaking?'speaking':input.listening?'listening':input.thinking?'thinking':input.error?'error':'idle';
    const old=mood===this.mood?this.level:0;
    const target=phoneUnit(mood==='speaking'?input.outputLevel:mood==='listening'?input.inputLevel:0);
    const dt=Number.isFinite(elapsed)?Math.max(0,elapsed):0;
    this.level=old+(target-old)*(1-Math.exp(-dt/(target>old?65:160)));
    this.mood=mood;
    const reaction=this.reaction==='happy'&&!['idle','listening'].includes(mood)?null:this.reaction;
    return {mood,level:this.level,mouth:mood==='speaking'?phoneMouth(this.level):0,reaction,reduceMotion,time:reduceMotion?0:now/1000};
  }
}
function drawPhoneAvatar(canvas, frame, mascot, image=null) {
  const c=canvas.getContext('2d');if(!c)return;
  const {mood,reaction,reduceMotion,time,mouth}=frame;
  const rgb=phoneMascots[mascot]||phoneMascots.blue;
  const tint=(a=1)=>`rgba(${rgb.map(v=>Math.round(v*255)).join(',')},${a})`;
  const ink='rgb(23,41,56)',cream='rgb(255,240,201)',pink='#ff80aa';
  const attentive=mood==='listening',thinking=mood==='thinking',worried=mood==='error'||reaction==='oops';
  const happy=reaction==='happy',surprised=reaction==='surprised',level=frame.level;
  c.clearRect(0,0,canvas.width,canvas.height);c.save();
  const scale=Math.min(canvas.width,canvas.height)/160;
  c.translate((canvas.width-160*scale)/2,(canvas.height-160*scale)/2);c.scale(scale,scale);
  function oval(x,y,w,h,color){c.beginPath();c.ellipse(x+w/2,y+h/2,w/2,h/2,0,0,Math.PI*2);c.fillStyle=color;c.fill();}
  function path(points,color,stroke=false,width=2){c.beginPath();for(const [op,...args] of points)c[op](...args);if(stroke){c.strokeStyle=color;c.lineWidth=width;c.lineCap='round';c.stroke();}else{c.fillStyle=color;c.fill();}}
  function rounded(x,y,w,h,r,color,stroke=false,width=2){
    // quadratic corners work on older Safari too; no roundRect dependency.
    path([['moveTo',x+r,y],['lineTo',x+w-r,y],['quadraticCurveTo',x+w,y,x+w,y+r],['lineTo',x+w,y+h-r],['quadraticCurveTo',x+w,y+h,x+w-r,y+h],['lineTo',x+r,y+h],['quadraticCurveTo',x,y+h,x,y+h-r],['lineTo',x,y+r],['quadraticCurveTo',x,y,x+r,y],['closePath']],color,stroke,width);
  }
  function ring(x,y,w,h,alpha,width){c.beginPath();c.ellipse(x+w/2,y+h/2,w/2,h/2,0,0,Math.PI*2);c.strokeStyle=tint(alpha);c.lineWidth=width;c.stroke();}
  if(image) {
    c.save();c.beginPath();c.arc(80,80,59,0,Math.PI*2);c.clip();
    const side=Math.min(image.naturalWidth,image.naturalHeight);
    c.drawImage(image,(image.naturalWidth-side)/2,(image.naturalHeight-side)/2,side,side,21,21,118,118);c.restore();
    ring(14-level*3,14-level*3,132+level*6,132+level*6,.4+level*.5,2+level*3);
    c.restore();return;
  }
  oval(36,143,90,8,'rgba(23,41,56,.1)');
  if(attentive)ring(13-level*3,10-level*3,134+level*6,134+level*6,.22+level*.3,2);
  path([['moveTo',110,116],['quadraticCurveTo',148,142,145,105],['quadraticCurveTo',150,151,109,139],['closePath']],tint(.85));
  oval(45,134,29,13,tint());oval(91,134,29,13,tint());
  const lift=!reduceMotion&&happy?Math.abs(Math.sin(time*3))*4:0;
  c.translate(0,(reduceMotion?0:Math.sin(time*1.7)*1.5)-(attentive?3:0)-lift);
  // Reduce Motion retains the simple mouth without changing body geometry.
  const jaw=reduceMotion?0:mouth;
  oval(46,87,73,55+jaw*2,tint());oval(62,102,42,37,cream);
  for(let i=0;i<3;i++){const x=47+i*17;path([['moveTo',x,42],['quadraticCurveTo',x-2,21,x+7,20-i%2*6],['quadraticCurveTo',x+24,26,x+20,41],['closePath']],tint(.7));}
  const gradient=c.createLinearGradient(40,35,110,106);gradient.addColorStop(0,tint(.78));gradient.addColorStop(1,tint());
  rounded(36,34,88,72,30,gradient);
  const noise=Math.abs(Math.sin(Math.floor(time/5)*78.233)*43758.5453)%1;
  const phase=time%5-(1.4+noise*2),blink=!reduceMotion&&((phase>0&&phase<.17)||(noise>.72&&phase>.3&&phase<.43));
  for(const x of [51,87]) {
    oval(x,47,24,29,cream);
    if(blink||happy)path([['moveTo',x+5,61],['quadraticCurveTo',x+12,66,x+19,61]],ink,true,3);
    else {const y=thinking?49:worried?60:55;oval(x+(thinking?10:8),y,10,attentive||surprised?18:13,ink);oval(x+10,y+2,3,4,'white');}
  }
  oval(39,72,87,37+jaw*5,tint());oval(51,80,4,3,'rgba(23,41,56,.45)');oval(109,80,4,3,'rgba(23,41,56,.45)');
  if(surprised&&mood!=='speaking')oval(77,91,13,14,ink);
  else if(mouth>.015){oval(69,92,28,3+mouth*15,ink);oval(76,94+mouth*8,14,2+mouth*5,pink);}
  else {path([['moveTo',65,94],['quadraticCurveTo',83,worried?86:happy?112:104,101,94]],'rgba(23,41,56,.8)',true);if(!worried)rounded(94,96,4,6,1,cream);}
  oval(40,89,13,6,'rgba(255,128,170,.3)');oval(114,89,10,6,'rgba(255,128,170,.3)');
  oval(39,attentive?101:111,17,11,tint());oval(109,attentive?101:111,17,11,tint());
  for(const x of [74,84,94])oval(x,119,3,4,tint(.35));
  switch(phoneAccessory(mascot)) {
    case 'scarf':rounded(48,103,68,9,4,pink);rounded(100,108,10,22,3,pink);break;
    case 'glasses':for(const x of [48,85])rounded(x,47,30,27,7,ink,true,2.5);path([['moveTo',78,58],['lineTo',85,58]],ink,true,2.5);break;
    case 'leaf':path([['moveTo',91,37],['quadraticCurveTo',91,13,118,16],['quadraticCurveTo',124,38,91,37]],'#34c759');path([['moveTo',92,36],['lineTo',111,23]],cream,true,1.5);break;
  }
  c.textAlign='center';c.textBaseline='middle';
  if(happy){c.fillStyle=pink;c.font='19px system-ui';c.fillText('\u2665',134,34);}
  if(surprised||worried){c.fillStyle=tint();c.font='bold 22px system-ui';c.fillText('!',135,surprised?32:44);}
  if(thinking)for(let i=0;i<3;i++){const angle=(reduceMotion?-1.2:time*1.8)+i*.65;oval(120+Math.cos(angle)*14,28+Math.sin(angle)*12,4+i,4+i,tint(.4+i*.2));}
  c.restore();
}

class PhoneCompanion {
  constructor(small,large,caption) {
    this.small=small;this.large=large;this.caption=caption;this.state=new PhoneAvatarState();this.input={};
    this.active=false;this.image=null;this.raf=null;this.last=null;this.lastDraw=-Infinity;
    this.motion=window.matchMedia('(prefers-reduced-motion: reduce)');
    this.motion.addEventListener('change',()=>this.refresh());
    document.addEventListener('visibilitychange',()=>this.refresh());
    this.refresh();
  }
  setAgent(agent) {
    this.mascot=agent?.avatar;this.image=null;this.state=new PhoneAvatarState();this.setCaption('');
    const epoch=this.imageEpoch=(this.imageEpoch||0)+1;
    if(agent?.custom_avatar) {
      const image=new Image();
      image.onload=()=>{if(epoch===this.imageEpoch){this.image=image;this.refresh();}};
      // Only the authenticated same-origin image endpoint; never agent-supplied URLs.
      image.src=`/agents/${encodeURIComponent(agent.id)}/avatar`;
    }
    this.refresh();
  }
  setActive(active) { this.active=active;this.refresh(); }
  setInput(input) { this.input={...input};this.refresh(); }
  setCaption(text) { this.caption.textContent=text;this.caption.hidden=!text; }
  react(reaction) { this.state.react(reaction,performance.now());this.refresh(); }
  refresh() {
    if(this.raf!==null)cancelAnimationFrame(this.raf);
    this.raf=null;this.lastDraw=-Infinity;
    if(document.hidden){this.last=null;return;}
    this.draw(performance.now());
  }
  draw(now) {
    this.raf=null;if(document.hidden)return;
    const interval=this.input.speaking?1000/30:100;
    if(now-this.lastDraw>=interval) {
      const frame=this.state.frame(this.input,now,this.last===null?100:now-this.last,this.motion.matches);
      this.last=now;this.lastDraw=now;
      const canvas=this.active?this.large:this.small;
      const size=Math.round((this.active?280:52)*Math.min(window.devicePixelRatio||1,3));
      if(canvas.width!==size){canvas.width=size;canvas.height=size;}
      drawPhoneAvatar(canvas,frame,this.mascot,this.image);
    }
    if(!this.motion.matches||this.input.speaking||this.input.listening||this.state.reaction)
      this.raf=requestAnimationFrame(time=>this.draw(time));
  }
}
