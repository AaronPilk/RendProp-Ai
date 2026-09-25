import type {StudioServices} from "../../data";
const CHUNK=8*1024*1024,HASH=/^[a-f0-9]{64}$/;
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const MIMES=new Set(["image/jpeg","image/png","image/webp","video/mp4","video/quicktime","video/webm","audio/mpeg","audio/mp4","audio/wav","audio/x-wav","audio/wave","audio/ogg","audio/webm"]);
export type SavedMedia={id:string;sha256:string;bytes:number;mime:string;filename:string;modified:number;complete:boolean;parts:{index:number;bytes:number;sha256:string|null;complete:boolean;url?:string}[]};
export function decodeSavedMedia(raw:unknown,hash:string):SavedMedia|null {
 const m=(raw as {media:SavedMedia|null})?.media;if(m===null)return null;
 if(!m||!UUID.test(m.id)||m.sha256!==hash||!HASH.test(hash)||!Number.isSafeInteger(m.bytes)||m.bytes<1||m.bytes>128*1024*1024||!Array.isArray(m.parts)||m.parts.length!==Math.ceil(m.bytes/CHUNK)||typeof m.filename!=="string"||!m.filename.length||m.filename.length>255||/[\u0000-\u001f]/.test(m.filename)||!MIMES.has(m.mime)||!Number.isSafeInteger(m.modified)||m.modified<0||typeof m.complete!=="boolean")throw new Error("The saved original could not be verified.");
 for(const [index,p] of m.parts.entries())if(!p||p.index!==index||p.bytes!==Math.min(CHUNK,m.bytes-index*CHUNK)||typeof p.complete!=="boolean"||(p.sha256!==null&&!HASH.test(p.sha256))||(p.complete&&!p.sha256)||(m.complete&&(!p.complete||typeof p.url!=="string")))throw new Error("Saved original parts are incomplete.");
 return m;
}
function mime(file:File):string{if(file.type)return file.type.toLowerCase();const ext=file.name.toLowerCase().split('.').pop();return ({jpg:"image/jpeg",jpeg:"image/jpeg",png:"image/png",webp:"image/webp",mp4:"video/mp4",mov:"video/quicktime",webm:"video/webm",mp3:"audio/mpeg",m4a:"audio/mp4",wav:"audio/wav",ogg:"audio/ogg"} as Record<string,string>)[ext??""]??"application/octet-stream";}
export async function saveCloudOriginal(services:StudioServices,orgId:string,file:File,hash:string,signal:AbortSignal,progress?:(value:number)=>void):Promise<SavedMedia>{
 let saved=decodeSavedMedia(await services.api(`/functions/v1/studio/project-media?sha256=${hash}`,{orgId,signal}),hash);
 if(saved?.complete){if(saved.bytes!==file.size)throw new Error("Original file size does not match saved media.");return saved;}
 saved=decodeSavedMedia(await services.api("/functions/v1/studio/project-media",{orgId,method:"POST",signal,body:{id:saved?.id??crypto.randomUUID(),sha256:hash,bytes:file.size,mime:mime(file),filename:file.name,modified:file.lastModified}}),hash);
 if(!saved)throw new Error("The original could not be reserved.");
 for(let index=0;index<saved.parts.length;index++){
  signal.throwIfAborted();if(!saved.parts[index].complete)saved=decodeSavedMedia(await services.api(`/functions/v1/studio/project-media/${saved.id}/${index}`,{orgId,method:"PUT",binary:file.slice(index*CHUNK,Math.min((index+1)*CHUNK,file.size)),signal,timeoutMs:90_000}),hash)!;
  if(!saved)throw new Error("The upload receipt was missing.");progress?.((index+1)/saved.parts.length);
 }
 if(!saved.complete)throw new Error("The original is not fully uploaded. Retry saving this project.");return saved;
}
export async function downloadSavedMedia(saved:SavedMedia,signal:AbortSignal):Promise<File>{
 if(!saved.complete)throw new Error("The original is still uploading on the other device.");
 const chunks:BlobPart[]=[];
 for(const part of saved.parts){
  signal.throwIfAborted();const url=new URL(part.url!);if(url.protocol!=="https:"||url.username||url.password||url.hash||!url.hostname.endsWith(".r2.cloudflarestorage.com"))throw new Error("The original download address is invalid.");
  const response=await fetch(url,{signal:AbortSignal.any([signal,AbortSignal.timeout(60_000)]),credentials:"omit",redirect:"error",referrerPolicy:"no-referrer"});
  if(!response.ok||!response.body||Number(response.headers.get("content-length"))>part.bytes){void response.body?.cancel().catch(()=>{});throw new Error("A saved original could not be downloaded.");}
  const reader=response.body.getReader(),pieces:Uint8Array<ArrayBuffer>[]=[];let size=0;
  try{for(;;){const p=await reader.read();if(p.done)break;size+=p.value.length;if(size>part.bytes)throw new Error("Saved media part was too large.");pieces.push(new Uint8Array(p.value));}}finally{void reader.cancel().catch(()=>{});reader.releaseLock();}
  if(size!==part.bytes)throw new Error("Saved media part was incomplete.");const blob=new Blob(pieces);const hash=Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",await blob.arrayBuffer())),n=>n.toString(16).padStart(2,"0")).join("");
  if(hash!==part.sha256)throw new Error("Saved media part failed its integrity check.");chunks.push(blob);
 }
 const file=new File(chunks,saved.filename,{type:saved.mime,lastModified:saved.modified});
 const hash=Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",await file.arrayBuffer())),n=>n.toString(16).padStart(2,"0")).join("");
 if(hash!==saved.sha256)throw new Error("The saved original differs from this project. Its local copy is preserved.");return file;
}
export async function loadCloudOriginal(services:StudioServices,orgId:string,hash:string,signal:AbortSignal):Promise<File|null>{const saved=decodeSavedMedia(await services.api(`/functions/v1/studio/project-media?sha256=${hash}`,{orgId,signal}),hash);return saved?downloadSavedMedia(saved,signal):null;}
