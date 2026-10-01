// Attach ONLY to a dedicated local agent-browser audit session supplied by the
// caller. CDP is used for real keyboard/touch events, never shared user tabs.
import assert from 'node:assert/strict';
import { writeFileSync } from 'node:fs';
const endpoint=process.env.AUDIT_CDP;
assert.ok(endpoint?.startsWith('ws://127.0.0.1:'),'dedicated local audit CDP required');
const revision=process.argv.find(a=>a.startsWith('--revision='))?.split('=')[1] ?? (process.argv.includes('--revision')?process.argv[process.argv.indexOf('--revision')+1]:null);
assert.ok(!revision||revision==='7bcc624','baseline --revision supports exactly 7bcc624');
assert.equal((await fetch('http://127.0.0.1:8796/f/fixture')).headers.get('x-audit-revision'),revision??'working-tree','runner matches served revision');
const socket=new WebSocket(endpoint);await new Promise((r,j)=>{socket.onopen=r;socket.onerror=j;});
let id=0,sessionId;const pending=new Map();
socket.onmessage=e=>{const m=JSON.parse(e.data);if(m.id&&pending.has(m.id)){const {r,j}=pending.get(m.id);pending.delete(m.id);m.error?j(new Error(JSON.stringify(m.error))):r(m.result);}};
const cdp=(method,params={},session=sessionId)=>new Promise((r,j)=>{const n=++id;pending.set(n,{r,j});socket.send(JSON.stringify({id:n,method,params,...(session?{sessionId:session}:{})}));});
const targets=await cdp('Target.getTargets',{},null);
const target=targets.targetInfos.find(t=>t.type==='page'&&t.url.startsWith('http://127.0.0.1:8796/'));
assert.ok(target,'only dedicated synthetic fixture tab may be controlled');
sessionId=(await cdp('Target.attachToTarget',{targetId:target.targetId,flatten:true},null)).sessionId;
const ev=async expression=>{const r=await cdp('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails));return r.result.value;};
const delay=ms=>new Promise(r=>setTimeout(r,ms));
let assertions=0;const check=(v,m)=>{assertions++;assert.ok(v,m);};
const navigate=async path=>{await cdp('Page.navigate',{url:'http://127.0.0.1:8796'+path});for(let n=0;n<60;n++){await delay(50);if(await ev('document.readyState==="complete"'))return;}throw new Error('fixture did not load');};
const key=async (key,modifiers=0)=>{await cdp('Input.dispatchKeyEvent',{type:'keyDown',key,modifiers});await cdp('Input.dispatchKeyEvent',{type:'keyUp',key,modifiers});};
const sliderState=()=>ev(`(()=>{const e=document.querySelector('[data-ba]');return {p:e.style.getPropertyValue('--p'),value:e.getAttribute('aria-valuenow'),text:e.getAttribute('aria-valuetext'),clip:getComputedStyle(e.querySelector('.disc-f-a')).clipPath};})()`);
const report={};
try{
  await cdp('Emulation.setDeviceMetricsOverride',{width:1024,height:768,deviceScaleFactor:1,mobile:false});
  await navigate('/f/fixture');
  for(let n=0;n<60;n++){if(await ev('document.querySelector("#scrub").readyState>=2'))break;await delay(50);}
  report.track=await ev('({duration:document.querySelector("#scrub").duration,height:parseFloat(document.querySelector("#track").style.height),viewport:innerHeight})');
  check(report.track.duration===410,'actual synthetic 410s video loaded');
  check(report.track.height===29*report.track.viewport,'28 scroll viewports + stage');
  await ev('document.querySelector("#skiptodetails").click()');
  for(let n=0;n<100;n++){await delay(50);if(await ev('Math.abs(document.querySelector("#endcard").getBoundingClientRect().top)<3'))break;}
  report.skip=await ev('({targetY:document.querySelector("#endcard").getBoundingClientRect().top,scrollY})');
  check(Math.abs(report.skip.targetY)<3,'one click reaches details');
  await ev('document.querySelector("[data-ba]").closest("details").open=true;document.querySelector("[data-ba]").focus();');
  await key('Home');report.home=await sliderState();
  await key('End');report.end=await sliderState();
  // Baseline mode retains the working reproducer; default verifies the repair.
  check(report.home.p==='0%'&&report.home.text===(revision?'0% edited version shown':'0% original, 100% edited')&&report.home.clip==='inset(0px 0px 0px 0%)','Home announces its actual fully edited state (baseline reproduces contradiction)');
  check(report.end.p==='100%'&&report.end.text===(revision?'100% edited version shown':'100% original, 0% edited')&&report.end.clip==='inset(0px 0px 0px 100%)','End announces its actual fully original state (baseline reproduces contradiction)');
  await key('ArrowLeft');check((await sliderState()).value==='98','real keyboard changes slider');
  await key('ArrowLeft',8);check((await sliderState()).value==='88','Shift+ArrowLeft changes original amount by ten');
  await key('Home');await key('ArrowDown');check((await sliderState()).value==='0','keyboard clamps below zero');
  await key('End');await key('ArrowUp');check((await sliderState()).value==='100','keyboard clamps above100');
  await navigate('/u/fixture');
  report.unbranded=await ev(`({slider:!!document.querySelector('[role=slider]'),forms:document.querySelectorAll('form,input,textarea').length,skip:!!document.querySelector('#skiptodetails'),html:document.documentElement.outerHTML.includes('endcard')})`);
  check(report.unbranded.slider&&report.unbranded.forms===0&&!report.unbranded.skip&&!report.unbranded.html,'unbranded upgrades comparison without prohibited controls or branded skip');
  await cdp('Emulation.setDeviceMetricsOverride',{width:390,height:844,deviceScaleFactor:1,mobile:true});
  await cdp('Emulation.setTouchEmulationEnabled',{enabled:true,maxTouchPoints:1});
  await ev('document.querySelector("[data-ba]").closest("details").open=true;document.querySelector("[data-ba]").scrollIntoView({block:"center"})');await delay(200);
  report.mobile=await ev(`(()=>{const e=document.querySelector('[data-ba]'),i=e.querySelector('img'),r=e.getBoundingClientRect();const scale=Math.max(r.width/i.naturalWidth,r.height/i.naturalHeight);return {width:r.width,height:r.height,naturalWidth:i.naturalWidth,naturalHeight:i.naturalHeight,horizontalFractionVisible:r.width/scale/i.naturalWidth,touchAction:getComputedStyle(e).touchAction,x:r.x+r.width/2,y:r.y+r.height/2,scrollY};})()`);
  if(revision) check(report.mobile.horizontalFractionVisible<.57,'baseline mobile comparison crops over 43% of 4:3 image width');
  else check(report.mobile.horizontalFractionVisible>.995,'fixed mobile frame preserves landscape width');
  check(report.mobile.touchAction==='pan-y','vertical touch-action retained');
  const {x,y}=report.mobile;
  await cdp('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x,y}]});
  for(let n=1;n<=12;n++){await cdp('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x,y:y+n*12}]});await delay(20);}
  await cdp('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});await delay(500);
  report.mobile.scrollAfter=await ev('scrollY');
  check(report.mobile.scrollAfter<report.mobile.scrollY-50,'real Chromium touch pan scrolls vertically over slider');
  await ev('document.querySelector("[data-ba]").scrollIntoView({block:"center"})');await delay(200);
  const shot=await cdp('Page.captureScreenshot',{format:'png'});writeFileSync('/tmp/call-web-mobile-comparison-'+(revision??'fixed')+'-20260919.png',Buffer.from(shot.data,'base64'));
  if(!revision){
    report.fullImageCases=[];
    for(const width of [390,1024]) for(const shape of ['landscape','portrait','mismatch']){
      await cdp('Emulation.setDeviceMetricsOverride',{width,height:844,deviceScaleFactor:1,mobile:width===390});
      await navigate('/u/fixture?shape='+shape);
      await ev('document.querySelector("[data-ba]").closest("details").open=true;document.querySelector("[data-ba]").scrollIntoView({block:"center"})');
      for(let n=0;n<60;n++){if(await ev('[...document.querySelectorAll("[data-ba] img")].every(i=>i.naturalWidth>0)&&!!document.querySelector("[data-ba]").style.aspectRatio'))break;await delay(50);}
      const fit=await ev(`(()=>{const e=document.querySelector('[data-ba]');return {frameRatio:getComputedStyle(e).aspectRatio,images:[...e.querySelectorAll('img')].map(i=>({width:i.naturalWidth,height:i.naturalHeight,fit:getComputedStyle(i).objectFit,box:i.getBoundingClientRect().toJSON()}))};})()`);
      check(fit.images.every(i=>i.fit==='contain'),'both complete images fit, including mismatched output ratio');
      const [rw,rh]=fit.frameRatio.split('/').map(Number);
      check(Math.abs(rw/rh-fit.images[0].width/fit.images[0].height)<.00001,'shared frame follows original aspect ratio');
      check(fit.images[0].box.width===fit.images[1].box.width&&fit.images[0].box.height===fit.images[1].box.height,'two images share the identical comparison frame');
      report.fullImageCases.push({width,shape,...fit});
      const screenshot=await cdp('Page.captureScreenshot',{format:'png'});writeFileSync(`/tmp/call-web-fixed-${width}-${shape}-20260919.png`,Buffer.from(screenshot.data,'base64'));
    }
  }
  await cdp('Emulation.setDeviceMetricsOverride',{width:1024,height:768,deviceScaleFactor:1,mobile:false});
  await navigate('/nojs/fixture');
  report.nojs=await ev(`(()=>{const e=document.querySelector('[data-ba]');return {on:e.classList.contains('on'),role:e.getAttribute('role'),figures:e.querySelectorAll('figure').length,images:e.querySelectorAll('img').length,display:getComputedStyle(e).display,open:e.closest('details').open,captions:[...e.querySelectorAll('figcaption')].map(x=>x.textContent)};})()`);
  check(!report.nojs.on&&!report.nojs.role&&report.nojs.images===2&&report.nojs.figures===2&&report.nojs.open&&report.nojs.display==='grid','CSP-disabled JS retains open complete two-figure fallback');
  report.dates=[];
  for(const date of ['2026-09-17T23:30:00-04:00','invalid','2019-01-01','2999-01-01']){
    await navigate('/u/fixture?date='+encodeURIComponent(date));const note=await ev('document.querySelector(".lp-mediadate")?.textContent??null');report.dates.push({date,note});
  }
  check(report.dates[0].note.includes('published on September 18, 2026'),'honest publication date uses UTC');
  check(report.dates.slice(1).every(d=>d.note===null),'invalid/old/future publication dates omitted');
  await navigate('/embed/fixture');check(!await ev('!!document.querySelector("#skiptodetails")'),'embed no invalid skip');
  console.log(JSON.stringify({revision:revision??'working-tree',assertions,...report,browser:'Dedicated Chromium, synthetic fixture only',limitations:'No physical iPhone/Safari touch proof'},null,2));
}finally{socket.close();}
