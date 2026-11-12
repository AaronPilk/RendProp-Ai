import {useEffect, useState} from "react";
import {createRoot} from "react-dom/client";
import VideoEditor from "../src/editor/VideoEditor";
import {newDraft, validateDraft, type EditDraft} from "../src/editor/model";

type Props = {active:boolean; readOnly:boolean; populated:boolean};
type Row = {id:number; url:string; terminated:number; init:Record<string,unknown>|null};
const rows:Row[]=[];
const instances:ProbeWorker[]=[];
let replyAutomatically=false;
class ProbeWorker extends EventTarget {
  row:Row;
  constructor(url:string|URL,options:WorkerOptions){
    super();
    const parsed=new URL(String(url),location.href);
    if(parsed.origin!==location.origin || !/encoder-worker-.*\.js$/.test(parsed.pathname) || options?.type!=="module")
      throw new Error("The fixture can replace only the compiled same-origin encoder module worker.");
    if(rows.length>=16)throw new Error("Unexpected worker count exceeded fixture bound.");
    this.row={id:rows.length,url:parsed.href,terminated:0,init:null};rows.push(this.row);instances.push(this);
  }
  postMessage(value:Record<string,unknown>){
    if(this.row.terminated || this.row.init || value.type!=="init" || value.revision!=="format-probe")
      throw new Error("The probe-only fixture rejects content and repeated initialization.");
    this.row.init=structuredClone(value);
    if(replyAutomatically)queueMicrotask(()=>this.reply());
  }
  reply(){
    const input=this.row.init;if(!input)throw new Error("No actual bridge initialization to reply to.");
    this.dispatchEvent(new MessageEvent("message",{data:{...input,type:"ready",credits:{video:2,audio:8}}}));
  }
  terminate(){this.row.terminated++;}
}
// No native Worker, codec or frame is created by this capability-only fixture.
Object.defineProperty(globalThis,"Worker",{value:ProbeWorker,configurable:true,writable:true});
const empty=newDraft();
const populated=validateDraft({...empty,clips:[{id:"synthetic-still",source:{kind:"image",name:"synthetic-still.png",size:1,lastModified:0,sha256:"a".repeat(64),width:800,height:450,duration:0,mime:"image/png"},start:0,end:1,caption:"",focusX:.5,focusY:.5}]});
const fixture={committed:-1,serial:0,rows,configure:(_props:Props,_reset=false)=>{},reply:(id:number)=>instances[id]!.reply(),snapshot:()=>structuredClone(rows),autoReply:(enabled:boolean)=>{replyAutomatically=enabled;}};
Object.assign(window,{codecLifecycleFixture:fixture});
function Fixture(){
  const [state,setState]=useState({active:true,readOnly:false,populated:false,epoch:0,serial:0});
  fixture.configure=(props,reset=false)=>{fixture.serial++;setState(old=>({...props,epoch:old.epoch+Number(reset),serial:fixture.serial}));};
  useEffect(()=>{fixture.committed=state.serial;},[state.serial]);
  const draft:EditDraft=state.populated?populated:empty;
  return <VideoEditor key={state.epoch} active={state.active} readOnly={state.readOnly} initialMode="pro" initialDraft={draft}/>;
}
createRoot(document.getElementById("root")!).render(<Fixture/>);
