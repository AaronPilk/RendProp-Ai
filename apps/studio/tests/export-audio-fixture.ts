import {exportFormats, exportLocalVideo} from "../src/editor/export";
import {inspectFile} from "../src/editor/media";
import {newDraft, validateDraft} from "../src/editor/model";
// Separate browser fixture. Only locally generated source bytes are consumed.
const fixture = {config:{speed:1,stall:false,hiccup:false,decodeFailure:false,split:false,cancelAfterBuffer:false},result:null as unknown};
Object.assign(window,{audioExportFixture:fixture});
document.querySelector("button")!.addEventListener("click",async()=>{
  fixture.result=null;
  const controller=new AbortController(), timers:ReturnType<typeof setTimeout>[]=[];
  const play=HTMLMediaElement.prototype.play, decode=AudioContext.prototype.decodeAudioData, createBuffer=AudioContext.prototype.createBufferSource;
  let injected=false, decodeCalls=0;
  try {
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
      return result;
    };
    const clip={id:"source",source:local.source,start:.5,end:2.5,caption:"",focusX:.5,focusY:.5,speed:fixture.config.speed};
    const clips=fixture.config.split?[{...clip,end:1.5},{...clip,id:"source-2",start:1.5}]:[clip];
    const draft=validateDraft({...newDraft(),ratio:"16:9",clips});
    const media=new Map(clips.map(item=>[item.id,local]));
    const format=exportFormats().find(format=>format.extension==="mp4")!;
    const result=await exportLocalVideo({draft,media,format,signal:controller.signal,currentDraft:()=>draft,onProgress:()=>{}});
    const bytes=new Uint8Array(await result.blob.arrayBuffer());let binary="";for(const byte of bytes)binary+=String.fromCharCode(byte);
    fixture.result={ok:true,base64:btoa(binary),duration:result.duration,decodeCalls,injected};
    URL.revokeObjectURL(local.url);
  }catch(error){fixture.result={ok:false,error:String(error),decodeCalls,injected};}
  finally{for(const timer of timers)clearTimeout(timer);HTMLMediaElement.prototype.play=play;AudioContext.prototype.decodeAudioData=decode;AudioContext.prototype.createBufferSource=createBuffer;controller.abort();}
});
