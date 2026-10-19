import {RecordingClock} from "../src/editor/recording-clock";
import {exportFormats, exportLocalVideo} from "../src/editor/export";
import {inspectFile} from "../src/editor/media";
import {newDraft, validateDraft} from "../src/editor/model";
// Separate browser fixture. Only locally generated source bytes are consumed.
const fixture = {config:{speed:1,stall:false,hiccup:false,decodeFailure:false,split:false,cancelAfterBuffer:false,playResolutionDelayMs:0,mix:""},result:null as unknown};
Object.assign(window,{audioExportFixture:fixture});
document.querySelector("button")!.addEventListener("click",async()=>{
  fixture.result=null;
  const controller=new AbortController(), timers:ReturnType<typeof setTimeout>[]=[];
  const gainMethods=["setValueAtTime","setTargetAtTime","setValueCurveAtTime","cancelScheduledValues"] as const;
  const nativeGains=gainMethods.map(name=>AudioParam.prototype[name]);
  const nativeSourceStart=AudioBufferSourceNode.prototype.start;
  const gainEvidence:Array<Record<string,unknown>>=[],sourceEvidence:Array<Record<string,unknown>>=[];
  const play=HTMLMediaElement.prototype.play, decode=AudioContext.prototype.decodeAudioData, createBuffer=AudioContext.prototype.createBufferSource;
  let injected=false, decodeCalls=0; const playEvidence:Array<{event:string;wall:number;media:number}>=[];
  const playHoldEvidence:Array<Record<string,unknown>>=[];
  const nativeClockRead=RecordingClock.prototype.read;
  RecordingClock.prototype.read=function(...args: Parameters<RecordingClock["read"]>){
    (window as unknown as {audioExportObserveClock?:(args: Parameters<RecordingClock["read"]>)=>void}).audioExportObserveClock?.(args);
    return Reflect.apply(nativeClockRead,this,args);
  };
  try {
    gainMethods.forEach((name,index)=>{(AudioParam.prototype as unknown as Record<string,unknown>)[name]=function(this:AudioParam,...args:unknown[]){const began=performance.now();try{return Reflect.apply(nativeGains[index],this,args);}finally{gainEvidence.push({method:name,costMs:performance.now()-began,when:name==="setValueCurveAtTime"?args[1]:args[name==="cancelScheduledValues"?0:1],...(name==="setValueCurveAtTime"?{points:(args[0] as Float32Array).length,duration:args[2]}:{})});}};});
    AudioBufferSourceNode.prototype.start=function(...args:Parameters<AudioBufferSourceNode["start"]>){const began=performance.now();try{return Reflect.apply(nativeSourceStart,this,args);}finally{sourceEvidence.push({when:args[0],offset:args[1]??0,currentTime:this.context.currentTime,costMs:performance.now()-began});}};
    const file=(document.querySelector("input") as HTMLInputElement).files![0];
    const local=await inspectFile(file,controller.signal);
    AudioContext.prototype.decodeAudioData=function(...args: Parameters<AudioContext["decodeAudioData"]>){
      decodeCalls++;
      return fixture.config.decodeFailure ? Promise.reject(new DOMException("Synthetic unsupported audio container","EncodingError")) : Reflect.apply(decode,this,args);
    };
    AudioContext.prototype.createBufferSource=function(...args){
      const source=Reflect.apply(createBuffer,this,args);
      if(fixture.config.cancelAfterBuffer) queueMicrotask(()=>controller.abort(new DOMException("Synthetic export cancelled","AbortError")));
      return source;
    };
    HTMLMediaElement.prototype.play=function(...args){
      const result=Reflect.apply(play,this,args) as Promise<void>;
      if(fixture.config.stall&&!injected){
        injected=true;
        result.then(()=>timers.push(setTimeout(()=>{
          this.pause();this.dispatchEvent(new Event("waiting"));
          timers.push(setTimeout(()=>Reflect.apply(play,this,[]).catch(()=>{}),100));
        },800)));
      }
      // A transient decoder hiccup: Chromium delivers `waiting` after playback
      // has already resumed. Nothing pauses, so no original audio is lost.
      if(fixture.config.hiccup&&!injected){
        injected=true;
        result.then(()=>timers.push(setTimeout(()=>{this.dispatchEvent(new Event("waiting"));this.dispatchEvent(new Event("playing"));},800)));
      }
      // Playback and recording run normally. Delay only the awaited promise's
      // delivery, exposing a mismatched clock origin without injecting media loss.
      if(fixture.config.playResolutionDelayMs){
        injected=true;
        return result.then(()=>{
          const began=performance.now(), initialMedia=this.currentTime;
          playEvidence.push({event:"native-play-resolved",wall:began,media:initialMedia});
          if(fixture.config.mix){
            // Alignment requires real native playback during the hold, not
            // only elapsed wall time. No seek/rate/pause or clock is changed.
            const hold={minimumWallMs:fixture.config.playResolutionDelayMs,minimumMediaAdvanceSeconds:.15,deadlineMs:1500,samples:0,elapsedMs:0,mediaAdvanceSeconds:0,readyState:this.readyState,paused:this.paused,seeking:this.seeking,ended:this.ended,status:"pending"};
            playHoldEvidence.push(hold);
            return new Promise<void>((resolve,reject)=>{
              let timer:ReturnType<typeof setTimeout>|undefined,settled=false;
              const finish=(error?:unknown)=>{
                if(settled)return;settled=true;
                if(timer!==undefined)clearTimeout(timer);
                controller.signal.removeEventListener("abort",aborted);
                if(error!==undefined)reject(error);else resolve();
              };
              const aborted=()=>{hold.status="aborted";finish(controller.signal.reason??new DOMException("Synthetic alignment readiness aborted","AbortError"));};
              const poll=()=>{
                hold.samples++;hold.elapsedMs=performance.now()-began;hold.mediaAdvanceSeconds=this.currentTime-initialMedia;
                hold.readyState=this.readyState;hold.paused=this.paused;hold.seeking=this.seeking;hold.ended=this.ended;
                if(controller.signal.aborted){aborted();return;}
                // Check terminal budget before admitting even a late-ready sample.
                if(hold.elapsedMs>=hold.deadlineMs){hold.status="timed-out";finish(new Error("Synthetic alignment play readiness timed out before promise delivery",{cause:{...hold}}));return;}
                if(hold.elapsedMs>=hold.minimumWallMs&&hold.mediaAdvanceSeconds>hold.minimumMediaAdvanceSeconds&&!this.paused&&!this.ended&&!this.seeking&&this.readyState>=HTMLMediaElement.HAVE_FUTURE_DATA){
                  hold.status="delivered";playEvidence.push({event:"delayed-promise-delivered",wall:performance.now(),media:this.currentTime});finish();return;
                }
                timer=setTimeout(poll,10);timers.push(timer);
              };
              controller.signal.addEventListener("abort",aborted,{once:true});poll();
            });
          }
          return new Promise<void>(resolve=>timers.push(setTimeout(()=>{playEvidence.push({event:"delayed-promise-delivered",wall:performance.now(),media:this.currentTime});resolve();},fixture.config.playResolutionDelayMs)));
        });
      }
      return result;
    };
    const clip={id:"source",source:local.source,start:.5,end:2.5,caption:"",focusX:.5,focusY:.5,speed:fixture.config.speed};
    const clips=fixture.config.split?[{...clip,end:1.5},{...clip,id:"source-2",start:1.5}]:[clip];
    let narrationBlob:Blob|undefined,musicBlob:Blob|undefined;
    const optional:Record<string,unknown>={};
    if(fixture.config.mix){
      const wav=(hz:number,seconds:number)=>{
        const rate=48000,count=Math.round(rate*seconds),data=new ArrayBuffer(44+count*2),v=new DataView(data);
        const text=(at:number,s:string)=>{for(let i=0;i<s.length;i++)v.setUint8(at+i,s.charCodeAt(i));};
        text(0,"RIFF");v.setUint32(4,36+count*2,true);text(8,"WAVE");text(12,"fmt ");v.setUint32(16,16,true);v.setUint16(20,1,true);v.setUint16(22,1,true);v.setUint32(24,rate,true);v.setUint32(28,rate*2,true);v.setUint16(32,2,true);v.setUint16(34,16,true);text(36,"data");v.setUint32(40,count*2,true);
        for(let i=0;i<count;i++)v.setInt16(44+i*2,Math.round(.35*Math.sin(2*Math.PI*hz*i/rate)*32767),true);
        return new Blob([data],{type:"audio/wav"});
      };
      narrationBlob=wav(660,1.2);musicBlob=wav(220,3);
      const digest=await crypto.subtle.digest("SHA-256",await musicBlob.arrayBuffer());
      optional.narration={resultId:"10000000-0000-4000-8000-000000000001",label:"Closed narration",offset:fixture.config.mix==="offset-fade"?.35:0,volume:.8,wordCaptions:false,words:[]};
      optional.music={source:{name:"closed-music.wav",size:musicBlob.size,lastModified:0,sha256:Array.from(new Uint8Array(digest),x=>x.toString(16).padStart(2,"0")).join(""),duration:3,mime:"audio/wav"},start:.2,end:2.8,offset:.1,volume:.4,fadeIn:fixture.config.mix==="offset-fade"?.5:0,fadeOut:0,ducking:fixture.config.mix==="offset-fade"?"original":"none",licensed:true};
    }
    const draft=validateDraft({...newDraft(),ratio:"16:9",clips,...optional});
    const media=new Map(clips.map(item=>[item.id,local]));
    const format=exportFormats().find(format=>format.extension==="mp4")!;
    const result=await exportLocalVideo({draft,media,narrationBlob,musicBlob,format,signal:controller.signal,currentDraft:()=>draft,onProgress:()=>{}});
    const bytes=new Uint8Array(await result.blob.arrayBuffer());let binary="";for(const byte of bytes)binary+=String.fromCharCode(byte);
    fixture.result={ok:true,base64:btoa(binary),duration:result.duration,decodeCalls,injected,playEvidence,playHoldEvidence,gainEvidence,sourceEvidence};
    URL.revokeObjectURL(local.url);
  }catch(error){fixture.result={ok:false,error:String(error),cause:error instanceof Error?error.cause:undefined,decodeCalls,injected,playEvidence,playHoldEvidence};}
  finally{gainMethods.forEach((name,index)=>{(AudioParam.prototype as unknown as Record<string,unknown>)[name]=nativeGains[index];});AudioBufferSourceNode.prototype.start=nativeSourceStart;for(const timer of timers)clearTimeout(timer);RecordingClock.prototype.read=nativeClockRead;HTMLMediaElement.prototype.play=play;AudioContext.prototype.decodeAudioData=decode;AudioContext.prototype.createBufferSource=createBuffer;controller.abort();}
});
