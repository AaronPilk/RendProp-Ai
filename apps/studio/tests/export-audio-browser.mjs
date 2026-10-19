import assert from "node:assert/strict";
import {mkdtemp,readFile,writeFile} from "node:fs/promises";
import {createHash} from "node:crypto";
import {tmpdir} from "node:os";
import {join,resolve,extname} from "node:path";
import {createServer} from "node:http";
import {execFileSync} from "node:child_process";
import {build} from "vite";
import {chromium,expect} from "@playwright/test";
import {testAudioOutputOption, installTestAudioOutput, verifyTestAudioOutput} from "./export-audio-output.mjs";
const {audioOutput} = testAudioOutputOption(process.argv.slice(2));
const alignmentOnly=process.argv.includes("--alignment-only"),originalOnly=process.argv.includes("--original-only");assert(!(alignmentOnly&&originalOnly));const fault=process.argv.find(x=>x.startsWith("--fault="))??null;assert(fault===null||["--fault=live-original-audio","--fault=late-buffered-wall-origin","--fault=omit-bucket-pacing","--fault=late-optional-track-schedule"].includes(fault));
const root=resolve(import.meta.dirname,".."), artifacts=await mkdtemp(join(tmpdir(),"rendprop-export-original-audio-")),dist=join(artifacts,"dist");
const paths=["src/editor/export.ts","src/editor/recording-clock.ts","src/editor/media.ts","src/editor/model.ts","src/editor/music.ts","src/editor/finishing.ts","tests/export-audio-fixture.ts","tests/export-audio-browser.mjs"];
const hashes=async()=>Object.fromEntries(await Promise.all(paths.map(async path=>[path,createHash("sha256").update(await readFile(join(root,path))).digest("hex")])));
const receipt={status:"running",fault,audioOutput,proof:"Actual browser exporter/MediaRecorder with generated H264/AAC source, real100ms video pause and a transient waiting notification without loss. No live accounts/providers. RMS>.03 retained.",sourceHashes:await hashes(),checks:[],cases:[],externalRequests:[],errors:[]};
let browser,server,page,mutated=false;
try{
 await build({configFile:false,root,publicDir:false,logLevel:"error",plugins:[{name:"passive-gain-preparation-budget",enforce:"pre",transform(code,id){if(!id.endsWith("/src/editor/export.ts"))return;const a="      const musicEnvelope = musicGain ? (() => {",b="      // Gain preparation is complete before capture starts or resumes.";if(!code.includes(a))return;assert.equal(code.split(a).length,2);assert.equal(code.split(b).length,2);return code.replace(a,"      const gainPreparationBegan = performance.now();\n"+a).replace(b,"      globalThis.audioGainPreparationEvidence = {costMs: performance.now() - gainPreparationBegan, points: musicEnvelope?.length ?? 0, recorderState: recorder?.state ?? null};\n"+b);}},...(fault?[{name:"live-original-audio-regression",enforce:"pre",transform(code,id){
  if(!id.endsWith("/src/editor/export.ts"))return;
  if(fault==="--fault=late-optional-track-schedule"){
    const begin="      // BEGIN optional buffered tracks at the fixed segment origin\n",end="      // END optional buffered tracks\n",after="      // PLAYBACK confirmed; all buffered sources are already scheduled.\n";
    assert.equal(code.split(begin).length,2);assert.equal(code.split(end).length,2);assert.equal(code.split(after).length,2);
    const start=code.indexOf(begin),stop=code.indexOf(end,start)+end.length,block=code.slice(start,stop);mutated=true;
    return code.slice(0,start)+code.slice(stop).replace(after,after+block);
  }
  if(fault==="--fault=omit-bucket-pacing"){
    const gate='if (paintBucket !== lastPaintedBucket || elapsed >= duration) {';
    assert.equal(code.split(gate).length,2,"Paint bucket mutation sentinel missing");mutated=true;
    return code.replace(gate,'if (true) {');
  }
  if(fault==="--fault=late-buffered-wall-origin"){
    const origin='const start = originalWallStart ?? performance.now();';
    assert.equal(code.split(origin).length,2,"Buffered-clock origin mutation sentinel missing");mutated=true;
    return code.replace(origin,'const start = performance.now();');
  }
  const buffer='if (originalAudio && audio && clip.source.kind === "video" && (clip.speed ?? 1) === 1 &&';
  const stall='const refuseStall = () => controller.abort(new Error("Original audio playback stalled during export. No download was created. Try a shorter clip or export with audio explicitly muted."));';
  const clock='const recordingClock = new RecordingClock();';
  assert(code.includes(buffer)&&code.includes(stall)&&code.split(clock).length===2,"Original-audio mutation sentinel missing");mutated=true;
  // Isolate the historical bad-audio recording so the unchanged RMS oracle
  // actually sees it. Shipping clock safety is independently tested in the
  // resume suite; retaining it here would intercept the mutant before audio.
  return code.replace(buffer,'if (false && originalAudio && audio && clip.source.kind === "video" && (clip.speed ?? 1) === 1 &&').replace(stall,'const refuseStall = () => {};').replace(clock,'const recordingClock = { read: () => {} };');
 }}]:[])],build:{outDir:dist,rollupOptions:{input:join(root,"tests/export-audio-fixture.html")}}});
 if(fault)assert(mutated,"Negative control did not compile the product mutation");
 server=createServer(async(req,res)=>{const path=resolve(dist,`.${new URL(req.url,"http://localhost").pathname}`);if(!path.startsWith(`${dist}/`)||req.method!=="GET")return res.writeHead(400).end();try{res.setHeader("Content-Type",({".html":"text/html",".js":"application/javascript"})[extname(path)]??"application/octet-stream");res.end(await readFile(path));}catch{res.writeHead(404).end();}});
 await new Promise(done=>server.listen(0,"127.0.0.1",done));const origin=`http://127.0.0.1:${server.address().port}`;
 const tone=join(artifacts,"original-tone.mp4"),silent=join(artifacts,"silent-video.mp4");
 execFileSync("ffmpeg",["-v","error","-f","lavfi","-i","color=c=green:s=640x360:r=30:d=3","-f","lavfi","-i","sine=frequency=880:duration=3","-c:v","libx264","-pix_fmt","yuv420p","-c:a","aac","-shortest",tone]);
 execFileSync("ffmpeg",["-v","error","-f","lavfi","-i","color=c=blue:s=640x360:r=30:d=3","-an","-c:v","libx264","-pix_fmt","yuv420p",silent]);
 browser=await chromium.launch({headless:true,executablePath:process.env.STUDIO_BROWSER_EXECUTABLE});const context=await browser.newContext({viewport:{width:1000,height:800},serviceWorkers:"block"});
 await installTestAudioOutput(context,audioOutput);
 await context.route("**/*",route=>{const u=new URL(route.request().url());if(u.origin===origin&&route.request().method()==="GET"||u.protocol==="blob:")return route.continue();receipt.externalRequests.push(u.href);return route.abort();});
 // Test-only, passive lifecycle evidence. Native nodes/promises and their
 // return values remain unchanged; bounded facts are retained only on failure.
 await context.addInitScript(()=>{
  const events=[],contexts=new Map(),tracks=new Map();let dropped=0;
  const record=(event,audio,track)=>{
   if(events.length>=128){dropped++;return;}
   events.push({event,wallMs:performance.now(),visibility:document.visibilityState,
    ...(audio?{contextId:contexts.get(audio),state:audio.state,currentTime:audio.currentTime}:{}),
    ...(track?{trackKind:track.kind,readyState:track.readyState,muted:track.muted,enabled:track.enabled}:{})});
  };
  const observe=audio=>{
   if(contexts.has(audio))return;
   contexts.set(audio,contexts.size+1);record("context-observed",audio);
   audio.addEventListener("statechange",()=>record("context-statechange",audio));
  };
  const destination=AudioContext.prototype.createMediaStreamDestination;
  AudioContext.prototype.createMediaStreamDestination=function(...args){
   const node=Reflect.apply(destination,this,args);observe(this);record("destination-created",this);
   for(const track of node.stream.getTracks()){
    tracks.set(track,this);record("destination-track-observed",this,track);
    for(const event of ["mute","unmute","ended"])track.addEventListener(event,()=>record(`destination-track-${event}`,this,track));
   }
   return node;
  };
  for(const method of ["resume","close"]){
   const original=AudioContext.prototype[method];
   AudioContext.prototype[method]=function(...args){
    observe(this);record(`context-${method}-requested`,this);
    const result=Reflect.apply(original,this,args);
    result.then(()=>record(`context-${method}-resolved`,this),()=>record(`context-${method}-rejected`,this));
    return result;
   };
  }
  document.addEventListener("visibilitychange",()=>record("document-visibilitychange"));
  // Passive-only native observations. Original method return/throw values are retained.
  let activeRecorder=null,lastReading=null;const clockSamples=[],paintBuckets=new Map(),paintOps={drawImage:{calls:0,totalMs:0,maxMs:0},fillRect:{calls:0,totalMs:0,maxMs:0}},passiveErrors=[];
  for(const method of ["start","resume","pause","stop"]){
   const native=MediaRecorder.prototype[method];
   MediaRecorder.prototype[method]=function(...args){const result=Reflect.apply(native,this,args);activeRecorder=this;return result;};
  }
  window.audioExportObserveClock=args=>{
   if(activeRecorder?.state!=="recording")return;
   try{lastReading={wall:args[0],timeline:args[1],audio:args[2]};const sample={reading:{...lastReading},sampleWallBeforeMs:performance.now(),contexts:[]};
    for(const[audio,contextId]of contexts){const timestamp=typeof audio.getOutputTimestamp==="function"?audio.getOutputTimestamp():null;sample.contexts.push({contextId,state:audio.state,sampleRate:audio.sampleRate,currentTime:audio.currentTime,baseLatency:typeof audio.baseLatency==="number"?audio.baseLatency:null,outputLatency:typeof audio.outputLatency==="number"?audio.outputLatency:null,outputTimestamp:timestamp?{contextTime:timestamp.contextTime,performanceTime:timestamp.performanceTime}:null});}
    sample.sampleWallAfterMs=performance.now();clockSamples.push(sample);if(clockSamples.length>192)clockSamples.shift();
   }catch(error){if(passiveErrors.length<8)passiveErrors.push(String(error));}
  };
  for(const name of ["drawImage","fillRect"]){const native=CanvasRenderingContext2D.prototype[name];
   CanvasRenderingContext2D.prototype[name]=function(...args){const tracked=activeRecorder?.state==="recording"&&this.canvas.width>=1280&&this.canvas.height>=720;const began=tracked?performance.now():0;try{return Reflect.apply(native,this,args);}finally{if(tracked)try{const cost=performance.now()-began,op=paintOps[name];op.calls++;op.totalMs+=cost;op.maxMs=Math.max(op.maxMs,cost);if(name==="drawImage"&&lastReading){const bucket=Math.floor(lastReading.timeline*30),row=paintBuckets.get(bucket)??{bucket,calls:0,totalMs:0,maxMs:0,firstReading:{...lastReading}};row.calls++;row.totalMs+=cost;row.maxMs=Math.max(row.maxMs,cost);paintBuckets.set(bucket,row);}}catch(error){if(passiveErrors.length<8)passiveErrors.push(String(error));}}};
  }
  window.audioExportPassive=()=>({nativeMethodsReturnedUnchanged:true,clockSamples:[...clockSamples],paintOps,paintBuckets:[...paintBuckets.values()],duplicateBuckets:[...paintBuckets.values()].filter(x=>x.calls>1),errors:[...passiveErrors]});
  window.audioExportDiagnostics=()=>({events:[...events],dropped,visibility:document.visibilityState,
   contexts:[...contexts].map(([audio,contextId])=>({contextId,state:audio.state,currentTime:audio.currentTime})),
   tracks:[...tracks].map(([track,audio])=>({contextId:contexts.get(audio),kind:track.kind,readyState:track.readyState,muted:track.muted,enabled:track.enabled}))});
 });
 receipt.passiveRuntime={node:process.version,browser:browser.version(),platform:process.platform,architecture:process.arch};
 page=await context.newPage();page.on("pageerror",error=>receipt.errors.push(error.message));page.setDefaultTimeout(15000);
 const run=async(name,config,{refused=false,silentAudio=false,cancelled=false}={})=>{
  await page.goto(`${origin}/tests/export-audio-fixture.html`);await verifyTestAudioOutput(page,audioOutput);await page.getByLabel("Synthetic source").setInputFiles(silentAudio?silent:tone);
  await page.evaluate(config=>window.audioExportFixture.config={speed:1,stall:false,hiccup:false,decodeFailure:false,split:false,cancelAfterBuffer:false,playResolutionDelayMs:0,...config},config);
  await page.getByRole("button",{name:"Export fixture",exact:true}).click();await expect.poll(()=>page.evaluate(()=>window.audioExportFixture.result)).not.toBeNull();
  const result=await page.evaluate(()=>window.audioExportFixture.result),record={name,...config,audioOutput:await verifyTestAudioOutput(page,audioOutput),ok:result.ok,decodeCalls:result.decodeCalls,injected:result.injected,error:result.error,cause:result.cause};receipt.cases.push(record);record.passive=await page.evaluate(()=>window.audioExportPassive());
  if(!result.ok)record.lifecycle=await page.evaluate(()=>window.audioExportDiagnostics());
  if(config.stall||config.hiccup||config.playResolutionDelayMs)assert(result.injected,"Forced playback fixture not injected");
  if(cancelled){assert.equal(result.ok,false);assert.match(result.error,/Synthetic export cancelled/);assert.equal(result.base64,undefined);return;}
  if(refused){
   assert.equal(result.ok,false,"A media-audio stall must refuse an export");
   // The independently measured recording-clock guard can observe the forced
   // stall before the original-audio guard. Accept only that exact refusal,
   // with its own two successive measured losses; never accept arbitrary errors.
   if(result.error === "Error: Audio and picture timing drifted during export. No download was created. Close other busy tabs and retry.") {
    assert(config.stall && result.injected,"The forced stall must have executed");
    const readings=result.cause?.readings;
    assert(Array.isArray(readings) && readings.length>=2 && Number.isFinite(result.cause.maxLossSeconds) && result.cause.maxLossSeconds>2/30,"Clock refusal must include measured loss");
    for(const reading of readings.slice(-2)) {
     assert(Number.isFinite(reading.wall) && Number.isFinite(reading.timeline) && (reading.audio===undefined || Number.isFinite(reading.audio)),"Clock readings must be finite");
     const drift=Math.max(Math.abs(reading.wall-reading.timeline),reading.audio===undefined?0:Math.abs(reading.wall-reading.audio));
     assert(drift>2/30 && Math.abs(reading.drift-drift)<1e-9,"Both consecutive readings must prove real timing loss");
    }
   } else assert.match(result.error,/Original audio playback stalled/);
   assert.equal(result.base64,undefined);return;
  }
  assert.equal(result.ok,true,result.error);
  const path=join(artifacts,`${name}.mp4`);await writeFile(path,Buffer.from(result.base64,"base64"));
  const probe=JSON.parse(execFileSync("ffprobe",["-v","error","-show_streams","-show_format","-of","json",path],{encoding:"utf8"}));record.probe=probe;
  const expected=2/(config.speed??1);assert(Math.abs(Number(probe.format.duration)-expected)<.18,`Trim/speed duration ${probe.format.duration} expected${expected}`);
  const pcm=execFileSync("ffmpeg",["-v","error","-i",path,"-ss","0.2","-t",String(expected-.4),"-vn","-ac","1","-ar","48000","-f","s16le","pipe:1"]);let weakest=1,crossings=0,power=0;
  for(let offset=0;offset+3840<=pcm.length;offset+=3840){let chunkPower=0;for(let i=offset;i<offset+3840;i+=2)chunkPower+=(pcm.readInt16LE(i)/32768)**2;weakest=Math.min(weakest,Math.sqrt(chunkPower/1920));}
  for(let i=0;i<pcm.length;i+=2){const v=pcm.readInt16LE(i)/32768;power+=v*v;if(i&&v>=0&&pcm.readInt16LE(i-2)<0)crossings++;}
  const rms=Math.sqrt(power/(pcm.length/2)),frequency=crossings/(pcm.length/2/48000);record.weakest40msRMS=weakest;record.rms=rms;record.frequency=frequency;
  if(silentAudio)assert(rms<.001,"Silent source gained sound");
  else{assert(weakest>.03,`Continuous speech through cutaway boundaries: weakest40ms RMS${weakest}`);assert(Math.abs(frequency-880)<30,`Original speech pitch changed: ${frequency}`);}
  // Budget is checked only after the unchanged encoded-duration/PCM oracles.
  if(!config.split){
   const nonterminal=record.passive.paintBuckets.filter(row=>row.bucket<Math.floor(expected*30));
   assert(nonterminal.every(row=>row.calls===1),"Duplicate30fps timeline bucket was repainted");
   assert(record.passive.paintOps.drawImage.calls<=Math.ceil(expected*30)+3,"Capture paint budget exceeded");
  }
 }; if(fault==="--fault=omit-bucket-pacing"){
  await run("bucket-omission-silent",{},{silentAudio:true});
  assert.fail("Compiled paint-budget omission unexpectedly passed");
 }

 if(fault==="--fault=late-buffered-wall-origin"){
  await run("delayed-buffered-start",{playResolutionDelayMs:120});
  assert.fail("Late buffered clock-origin negative control unexpectedly passed");
 }
 if(!alignmentOnly){
 await run("normal-speed-stall",{stall:true});receipt.checks.push("A real100ms video stall preserves uninterrupted normal-speed original audio with exact trim/duration");
 await run("delayed-buffered-start",{playResolutionDelayMs:120});receipt.checks.push("A delayed play-promise delivery preserves buffered speech, original pitch and exact duration without misclassifying a constant startup phase as media loss");
 await run("split-segments",{split:true});receipt.checks.push("Adjacent trimmed source segments export once without overlapping sound or a cut gap");
 await run("double-speed-pitch",{speed:2});receipt.checks.push("Media fallback retains2x duration and original880Hz pitch");
 await run("double-speed-stall",{speed:2,stall:true},{refused:true});
 await run("double-speed-transient-waiting",{speed:2,hiccup:true});receipt.checks.push("A transient waiting notification without measurable audio loss keeps the 2x media-audio export continuous at its original pitch; a real 100 ms stall is still refused");
 await run("decode-failure",{decodeFailure:true});
 await run("decode-failure-stall",{decodeFailure:true,stall:true},{refused:true});receipt.checks.push("Unsupported decoding preserves source audio; speed-adjusted and unsupported audio stalls refuse download");
 await run("cancel-before-audio-start",{cancelAfterBuffer:true},{cancelled:true});receipt.checks.push("Cancellation before scheduled audio start preserves its abort reason and produces no download");
 await run("silent-video",{},{silentAudio:true});receipt.checks.push("A genuinely silent video stays exportable without fabricating or dropping sound");
 }
 if(!originalOnly){
  const marker=join(artifacts,"original-opening-marker.mp4");
  execFileSync("ffmpeg",["-v","error","-f","lavfi","-i","color=c=green:s=640x360:r=30:d=3","-f","lavfi","-i","aevalsrc=if(between(t\\,0.5\\,0.65)\\,0.25*sin(2*PI*990*t)\\,0.25*sin(2*PI*880*t)):s=48000:d=3","-c:v","libx264","-pix_fmt","yuv420p","-c:a","aac","-shortest",marker]);
  const toneAt=(pcm,hz,start,end)=>{const first=Math.round(start*48000),count=Math.round((end-start)*48000);assert(first>=0&&first+count<=pcm.length/4,"Fixed PCM window must exist");let real=0,imaginary=0;for(let i=0;i<count;i++){const sample=pcm.readFloatLE((first+i)*4);assert(Number.isFinite(sample));real+=sample*Math.cos(2*Math.PI*hz*i/48000);imaginary+=sample*Math.sin(2*Math.PI*hz*i/48000);}return 2*Math.hypot(real,imaginary)/count;};
  for(const mix of ["opening","offset-fade"]){
   await page.goto(`${origin}/tests/export-audio-fixture.html`);await verifyTestAudioOutput(page,audioOutput);await page.getByLabel("Synthetic source").setInputFiles(marker);
   await page.evaluate(mix=>window.audioExportFixture.config={speed:1,stall:false,hiccup:false,decodeFailure:false,split:false,cancelAfterBuffer:false,playResolutionDelayMs:250,mix},mix);
   await page.getByRole("button",{name:"Export fixture",exact:true}).click();await expect.poll(()=>page.evaluate(()=>window.audioExportFixture.result)).not.toBeNull();
   const result=await page.evaluate(()=>window.audioExportFixture.result),row={name:"alignment-"+mix,ok:result.ok,error:result.error,cause:result.cause,playEvidence:result.playEvidence,playHoldEvidence:result.playHoldEvidence,gainEvidence:result.gainEvidence,sourceEvidence:result.sourceEvidence,gainPreparation:await page.evaluate(()=>globalThis.audioGainPreparationEvidence??null)};receipt.cases.push(row);
   assert.equal(result.ok,true,result.error);assert(result.injected);assert.equal(result.playEvidence.length,2);assert(result.playEvidence[1].media-result.playEvidence[0].media>.15,"Native video must actually run while only promise delivery is held");
   const path=join(artifacts,`alignment-${mix}.mp4`);await writeFile(path,Buffer.from(result.base64,"base64"));row.path=path;
   const probe=JSON.parse(execFileSync("ffprobe",["-v","error","-show_streams","-show_format","-of","json",path],{encoding:"utf8"}));row.probe=probe;assert(Math.abs(Number(probe.format.duration)-2)<.18,"Existing trim/duration bound");assert.equal(probe.streams.filter(x=>x.codec_type==="audio"&&x.codec_name==="aac").length,1);
   const pcm=execFileSync("ffmpeg",["-v","error","-i",path,"-vn","-ac","1","-ar","48000","-f","f32le","pipe:1"]);row.pcmSHA256=createHash("sha256").update(pcm).digest("hex");
   const voiceOffset=mix==="offset-fade"?.35:0,voiceRef=toneAt(pcm,660,.75,.95),voiceEarly=toneAt(pcm,660,voiceOffset+.055,voiceOffset+.175),voiceTail=toneAt(pcm,660,voiceOffset+1.01,voiceOffset+1.13),voiceAfter=toneAt(pcm,660,voiceOffset+1.31,voiceOffset+1.43);
   const originalOpening=toneAt(pcm,990,.04,.12),originalEarly=toneAt(pcm,880,.2,.3),originalSpeaking=toneAt(pcm,880,.75,.95),originalAfter=toneAt(pcm,880,1.8,1.9),musicEarly=toneAt(pcm,220,.16,.24),musicRef=toneAt(pcm,220,.75,.95);row.pcm={voiceOffset,voiceRef,voiceEarly,voiceTail,voiceAfter,originalOpening,originalEarly,originalSpeaking,originalAfter,musicEarly,musicRef};
   assert(voiceRef>.15,"Narration reference must be genuinely audible");assert(voiceEarly>voiceRef*.7,"Narration onset must honor its saved offset before delayed play delivery");assert(voiceTail>voiceRef*.7,"Narration tail must retain its saved last words");assert(voiceAfter<voiceRef*.08,"Narration must not shift its ending later");assert(originalOpening>.03,"Distinct original opening tone must survive");assert(originalSpeaking/originalAfter>.12&&originalSpeaking/originalAfter<.4,"Original must duck during narration and restore after it");
   if(mix==="opening"){assert(originalEarly/originalAfter<.4,"Early original ducking must apply before play promise resolves");assert(musicEarly>musicRef*.7,"Music onset must honor its saved offset before delayed play delivery");}
   else{
    // Fixed independent PCM oracle: locate the source's first 990 Hz marker
    // within the unchanged two-frame onset bound, never retime the recording.
    // Integral of a linear .5 s fade through the existing .025 s smoothing is
    // u-tau*(1-exp(-u/tau)); allow one30Hz target interval and one5ms onset bin.
    const onsetStep=.005,onsetWindow=.02;let originalOnset;
    for(let time=0;time<=2/30;time+=onsetStep)if(toneAt(pcm,990,time,time+onsetWindow)>originalOpening*.2){originalOnset=time;break;}
    assert(originalOnset!==undefined&&originalOnset<=2/30,"Original encoded onset must stay within two capture intervals");
    const musicOffset=.1,fade=.5,tau=.025,lag=1/30+onsetStep;
    const integral=u=>u*u/2-tau*u-tau*tau*Math.exp(-u/tau);
    const lowerMean=(integral(.2-lag)-integral(.1-lag))/(.1*fade);
    const musicFadeEarly=toneAt(pcm,220,originalOnset+musicOffset+.1,originalOnset+musicOffset+.2);
    const musicFadeLater=toneAt(pcm,220,originalOnset+musicOffset+.3,originalOnset+musicOffset+.4);
    row.fadeOracle={originalOnset,onsetStep,musicOffset,fade,tau,maximumTargetLag:lag,lowerMean,musicFadeEarly,musicFadeLater,codecAmplitudeAllowance:.2};
    assert(musicRef>.015&&musicFadeEarly>=musicRef*lowerMean*.8,"Saved music fade must already be audible before the late-promise music start");
    assert(musicFadeLater>musicFadeEarly*1.5&&musicFadeLater<musicRef*.9,"Saved music fade must increase toward its full ducked gain");
   }
   if(row.gainPreparation){
    assert.equal(row.gainPreparation.recorderState,null,"Gain curve must be prepared before first capture");
    assert(row.gainPreparation.points<=21601,"Bounded music envelope allocation");
    const curves=row.gainEvidence.filter(x=>x.method==="setValueCurveAtTime"),targets=row.gainEvidence.filter(x=>x.method==="setTargetAtTime");
    assert.equal(curves.length,1,"One prepared curve must replace clip-length scheduling");assert(targets.length<=2,"Only exact narration boundaries may be queued");
    const first=row.sourceEvidence[0].when;
    assert(row.sourceEvidence.every(x=>x.currentTime-first<=2/30),"All buffered sources must be scheduled before two capture intervals pass");
    row.setupBudget={calls:row.gainEvidence.length,curveCalls:curves.length,targetCalls:targets.length,nativeMethodCostMs:row.gainEvidence.reduce((sum,x)=>sum+x.costMs,0),maximumSourceSchedulingLagSeconds:Math.max(...row.sourceEvidence.map(x=>x.currentTime-first))};
   }
   receipt.checks.push(`Saved optional-track onset/tail/trim and original opening/ducking/music${mix} remain aligned under250ms native-play promise delivery delay`);
  }
 }
 assert.deepEqual(receipt.errors,[]);assert.deepEqual(receipt.externalRequests,[]);receipt.sourceBoundAtEnd=JSON.stringify(await hashes())===JSON.stringify(receipt.sourceHashes);assert(receipt.sourceBoundAtEnd);receipt.status="passed";
}catch(error){receipt.status="failed";receipt.failure=String(error.stack??error);process.exitCode=1;}
finally{await browser?.close();if(server)await new Promise(done=>server.close(done));await writeFile(join(artifacts,"receipt.json"),JSON.stringify(receipt,null,2));console.log(JSON.stringify({...receipt,artifacts},null,2));}
