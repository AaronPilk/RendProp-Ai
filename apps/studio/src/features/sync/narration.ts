import {EDIT_LIMITS} from "../../editor/model";
import {decodeResult} from "../creative/model";

/** A signed result is still read with a bounded stream before audio decoding. */
export async function downloadNarration(value:unknown,id:string,signal:AbortSignal):Promise<Blob>{
  const result=decodeResult(value);
  if(result.id!==id||result.kind!=="voice"||result.state!=="completed"||!result.url||!result.duration||result.duration>300)throw new Error("The saved narration is unavailable. Choose a completed voice result.");
  const response=await fetch(result.url,{signal,credentials:"omit",redirect:"error",referrerPolicy:"no-referrer"});
  if(!response.ok||!response.body||Number(response.headers.get("content-length"))>EDIT_LIMITS.narrationBytes){void response.body?.cancel().catch(()=>{});throw new Error("Narration could not be restored. Retry its saved result.");}
  const reader=response.body.getReader(),chunks:Uint8Array<ArrayBuffer>[]=[];let size=0;
  try{for(;;){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>EDIT_LIMITS.narrationBytes)throw new Error("Narration exceeds the 16 MB browser limit.");chunks.push(new Uint8Array(value));}}
  finally{void reader.cancel().catch(()=>{});reader.releaseLock();}
  if(!size)throw new Error("The saved narration was empty.");
  return new Blob(chunks,{type:response.headers.get("content-type")?.split(";")[0]||"audio/mpeg"});
}
