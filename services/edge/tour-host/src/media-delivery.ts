import type { Env } from "./types";
import { fetchUpstreamJSON } from "./upstream";

const headers = {"Access-Control-Allow-Origin":"https://studio.rendprop.com","Access-Control-Expose-Headers":"Content-Length, Content-Range, ETag, Content-Type, Content-Disposition, Last-Modified","Cache-Control":"no-store, max-age=0","CDN-Cache-Control":"no-store","Cloudflare-CDN-Cache-Control":"no-store","X-Content-Type-Options":"nosniff","Referrer-Policy":"no-referrer","X-Robots-Tag":"noindex, nofollow"};
const unavailable=(status=404)=>new Response(null,{status,headers});
const MAX_OBJECT_BYTES = 256 * 1024 * 1024;
const MAX_STREAM_BYTES = 8 * 1024 * 1024;
const BODY_DEADLINE_MS = 60_000;
type Delivery={schema:1;slug:string;objects:Record<string,"renders"|"uploads">;stream_uid:string|null};
function safeIdentity(value:string):boolean{return value.length>0&&value.length<=1024&&!value.split("/").some(v=>!v||v==="."||v===".."||/[\\%?#\u0000-\u001f]/.test(v));}
function decode(value:string):string|null{try{return decodeURIComponent(value);}catch{return null;}}
function contract(value:unknown,slug:string):value is Delivery{
  if(!value||typeof value!=="object"||Array.isArray(value))return false;
  const d=value as Delivery;
  return d.schema===1&&d.slug===slug&&Boolean(d.objects)&&typeof d.objects==="object"&&!Array.isArray(d.objects)&&Object.keys(d.objects).length<=500&&Object.entries(d.objects).every(([k,v])=>safeIdentity(k)&&["uploads","renders"].includes(v))&&(d.stream_uid===null||/^[a-f0-9]{32}$/.test(d.stream_uid));
}
function etagMatch(header:string|null,etag:string,weak=true):boolean{return Boolean(header&&header.split(",").some(v=>v.trim()==="*"||(weak?v.trim().replace(/^W\//,""):v.trim())===etag));}
/** Authorization is deliberately before HEAD, Range, 304, 412 and object bytes.
 * No cache read/write or redirect ever bypasses the current exact DB mapping. */
export async function handleMediaDelivery(req:Request,env:Env):Promise<Response>{
  const u=new URL(req.url),match=u.pathname.match(/^\/media\/([A-Za-z0-9_-]{1,64})\/(r2|stream)\/([^/]+)(?:\/([^/]+))?$/);
  const brand=u.pathname.match(/^\/media-brand\/(renders\/([a-f0-9-]{36})\/brand\/[a-f0-9-]{36}\.(?:jpg|png))$/);
  const privateMatch=u.pathname.match(/^\/private-media\/([A-Za-z0-9_-]+\.[a-f0-9]{64})$/);
  if((!match&&!brand&&!privateMatch)||u.search||!["GET","HEAD"].includes(req.method))return unavailable();
  if(privateMatch&&privateMatch[1].length>4096)return unavailable();
  const slug=privateMatch?"private":brand?brand[2]:match![1],kind=privateMatch||brand?"r2":match![2],encodedPath=match?.[4];
  const authorityPath=privateMatch?"/tours/private-media":brand?`/tours/business-logo/${slug}?key=${encodeURIComponent(brand[1])}`:`/tours/${encodeURIComponent(slug)}/delivery`;
  const authority=(bytes=0)=>fetchUpstreamJSON(privateMatch?authorityPath:authorityPath+(bytes?`${authorityPath.includes("?")?"&":"?"}bytes=${bytes}`:""),env,true,privateMatch?{cap:privateMatch[1],bytes}:undefined);
  const auth=await authority();
  if(auth.kind!=="ok")return unavailable(auth.kind==="not-found"?404:auth.status);
  if(!contract(auth.value,slug))return unavailable(503);
  const delivery=auth.value;
  const key=privateMatch?Object.keys(delivery.objects).length===1?Object.keys(delivery.objects)[0]:null:brand?brand[1]:decode(match![3]);
  if(!key||!safeIdentity(key)||privateMatch&&delivery.stream_uid!==null)return unavailable();
  const revalidate=async(bytes=0)=>{
    const current=await authority(bytes);
    if(current.kind!=="ok")return current.kind==="not-found"?404:current.status;
    if(!contract(current.value,slug))return 503;
    return kind==="stream" ? current.value.stream_uid===key?200:404 : Object.hasOwn(current.value.objects,key)&&current.value.objects[key]===delivery.objects[key]?200:404;
  };
  if(kind==="stream"){
    const path=encodedPath&&decode(encodedPath);
    if(delivery.stream_uid!==key||!path||!safeIdentity(path))return unavailable();
    return streamResponse(req,env,slug,key,path,revalidate);
  }
  if(encodedPath||!Object.hasOwn(delivery.objects,key))return unavailable();
  const bucket=delivery.objects[key]==="renders"?env.MEDIA_RENDERS:env.MEDIA_UPLOADS;
  if(!bucket)return unavailable(503);
  const head=await bucket.head(key);
  if(!head)return unavailable();
  if(!Number.isSafeInteger(head.size)||head.size<1||head.size>MAX_OBJECT_BYTES)return unavailable(503);
  const fresh=await revalidate();if(fresh!==200)return unavailable(fresh);
  const h=new Headers(headers);head.writeHttpMetadata(h);
  for(const [name,value]of Object.entries(headers))h.set(name,value);
  h.set("ETag",head.httpEtag);h.set("Accept-Ranges","bytes");h.set("Content-Length",String(head.size));h.set("Last-Modified",head.uploaded.toUTCString());
  if(req.headers.has("If-Match")&&!etagMatch(req.headers.get("If-Match"),head.httpEtag,false)){h.set("Content-Length","0");return new Response(null,{status:412,headers:h});}
  const unmodified=req.headers.get("If-Unmodified-Since");
  if(!req.headers.has("If-Match")&&unmodified&&Number.isFinite(Date.parse(unmodified))&&Math.floor(head.uploaded.getTime()/1000)>Math.floor(Date.parse(unmodified)/1000)){h.set("Content-Length","0");return new Response(null,{status:412,headers:h});}
  if(etagMatch(req.headers.get("If-None-Match"),head.httpEtag))return new Response(null,{status:304,headers:h});
  const modified=req.headers.get("If-Modified-Since");
  if(!req.headers.has("If-None-Match")&&modified&&Number.isFinite(Date.parse(modified))&&Math.floor(head.uploaded.getTime()/1000)<=Math.floor(Date.parse(modified)/1000))return new Response(null,{status:304,headers:h});
  let range:{offset:number;length:number}|undefined;
  const rawRange=req.headers.get("Range"),ifRange=req.headers.get("If-Range");
  if(rawRange&&(!ifRange||ifRange===head.httpEtag||ifRange===head.uploaded.toUTCString())){
    const r=/^bytes=(\d*)-(\d*)$/.exec(rawRange);
    if(!r||(!r[1]&&!r[2])||head.size===0){h.set("Content-Range",`bytes */${head.size}`);h.set("Content-Length","0");return new Response(null,{status:416,headers:h});}
    const start=r[1]?Number(r[1]):Math.max(0,head.size-Number(r[2])),end=r[1]&&r[2]?Math.min(Number(r[2]),head.size-1):head.size-1;
    if(!Number.isSafeInteger(start)||!Number.isSafeInteger(end)||start>=head.size||end<start||!r[1]&&Number(r[2])===0){h.set("Content-Range",`bytes */${head.size}`);h.set("Content-Length","0");return new Response(null,{status:416,headers:h});}
    range={offset:start,length:end-start+1};h.set("Content-Range",`bytes ${start}-${end}/${head.size}`);h.set("Content-Length",String(range.length));
  }
  const status=range?206:200;
  if(req.method==="HEAD")return new Response(null,{status,headers:h});
  // Charge the complete response length before GET, including Range. No quota
  // refund follows a failed storage read, response loss or client cancellation.
  const admitted=await revalidate(range?.length??head.size);if(admitted!==200)return unavailable(admitted);
  const object=await bucket.get(key,{onlyIf:{etagMatches:head.etag},...(range?{range}:{})});
  if(!object||!("body"in object))return unavailable(503);
  const final=await revalidate();if(final!==200){void object.body.cancel().catch(()=>{});return unavailable(final);}
  return new Response(boundedBody(object.body,range?.length??head.size),{status,headers:h});
}

/** Signed Stream tokens never reach viewers. Every playlist, segment, init file,
 * caption and key request re-enters the same publication/approval boundary. */
async function streamResponse(req:Request,env:Env,slug:string,uid:string,path:string,revalidate:(bytes?:number)=>Promise<number>):Promise<Response>{
  if(!env.CLOUDFLARE_ACCOUNT_ID||!env.CLOUDFLARE_STREAM_TOKEN||!env.CLOUDFLARE_STREAM_CUSTOMER_CODE||env.STREAM_PRIVATE_PLAYBACK!=="1")return unavailable(503);
  // Stream size is not known before dispatch. Conservatively hold the entire
  // segment ceiling; future enablement still requires actual protected proof.
  const admission=await revalidate(req.method==="GET"?MAX_STREAM_BYTES:0);if(admission!==200)return unavailable(admission);
  const response=await fetch(`https://api.cloudflare.com/client/v4/accounts/${encodeURIComponent(env.CLOUDFLARE_ACCOUNT_ID)}/stream/${uid}/token`,{method:"POST",headers:{Authorization:`Bearer ${env.CLOUDFLARE_STREAM_TOKEN}`,"Content-Type":"application/json"},body:JSON.stringify({exp:Math.floor(Date.now()/1000)+60}),redirect:"error",signal:AbortSignal.timeout(8000)});
  if(!response.ok)return unavailable(503);
  const body=await response.json() as {success?:boolean;result?:{token?:string}},token=body.result?.token;
  if(body.success!==true||!token||!/^[A-Za-z0-9_.-]+$/.test(token)||token.length>8192)return unavailable(503);
  const origin=`https://customer-${env.CLOUDFLARE_STREAM_CUSTOMER_CODE}.cloudflarestream.com`,target=new URL(`${origin}/${token}/${path}`);
  const range=req.headers.get("Range"),conditions=new Headers();
  for(const name of ["Range","If-None-Match","If-Match","If-Modified-Since","If-Unmodified-Since","If-Range"]){const value=req.headers.get(name);if(value)conditions.set(name,value);}
  const upstream=await fetch(target,{method:req.method,headers:conditions,cache:"no-store",redirect:"error",signal:AbortSignal.timeout(15000),cf:{cacheTtl:0,cacheEverything:false}});
  if(![200,206,304,412,416].includes(upstream.status)){void upstream.body?.cancel().catch(()=>{});return unavailable(upstream.status===404?404:503);}
  const h=new Headers(headers);for(const name of ["Content-Type","Content-Length","Content-Range","ETag","Accept-Ranges","Last-Modified"]){const value=upstream.headers.get(name);if(value)h.set(name,value);}
  const fresh=await revalidate();if(fresh!==200){void upstream.body?.cancel().catch(()=>{});return unavailable(fresh);}
  const declared=upstream.headers.get("Content-Length");
  if(declared!==null&&(!/^[0-9]+$/.test(declared)||!Number.isSafeInteger(Number(declared))||Number(declared)>MAX_STREAM_BYTES)){void upstream.body?.cancel().catch(()=>{});return unavailable(503);}
  if(req.method==="HEAD"||upstream.status!==200||!path.endsWith(".m3u8"))return new Response(req.method==="HEAD"?null:upstream.body?boundedBody(upstream.body,declared===null?MAX_STREAM_BYTES:Number(declared),declared!==null):null,{status:upstream.status,headers:h});
  if(range){void upstream.body?.cancel().catch(()=>{});return unavailable(416);}
  const text=await boundedManifest(upstream);
  if(text===null)return unavailable(503);
  const rewrite=(value:string)=>{
    const child=new URL(value,target);
    if(child.origin!==origin||child.search||child.hash||!child.pathname.startsWith(`/${token}/`))throw new Error("Invalid Stream child");
    const childPath=child.pathname.slice(token.length+2);
    if(!safeIdentity(childPath))throw new Error("Invalid Stream child path");
    return `/media/${slug}/stream/${uid}/${encodeURIComponent(childPath)}`;
  };
  try{
    const manifest=text.split(/\r?\n/).map(line=>line.startsWith("#")?line.replace(/URI="([^"]+)"/g,(_all,value)=>`URI="${rewrite(value)}"`):line.trim()?rewrite(line.trim()):line).join("\n");
    const final=await revalidate();if(final!==200)return unavailable(final);
    h.delete("Content-Length");h.delete("ETag");h.set("Content-Type","application/vnd.apple.mpegurl");return new Response(manifest,{headers:h});
  }catch{return unavailable(503);}
}
async function boundedManifest(response:Response):Promise<string|null>{
  const reader=response.body?.getReader();if(!reader)return null;
  let size=0,text="",empty=0;const decoder=new TextDecoder("utf-8",{fatal:true,ignoreBOM:false});
  try{while(true){const part=await reader.read();if(part.done)break;if(!part.value.byteLength){if(++empty>64)return null;continue;}empty=0;size+=part.value.byteLength;if(size>524288)return null;text+=decoder.decode(part.value,{stream:true});}return text+decoder.decode();}catch{return null;}finally{void reader.cancel().catch(()=>{});reader.releaseLock();}
}

/** Forward with backpressure, a byte ceiling and one whole-body deadline.
 * Once response headers leave the edge a size/timeout violation aborts the
 * stream; it cannot be converted into an apparently complete HTTP success. */
function boundedBody(body:ReadableStream<Uint8Array>,expected:number,exact=true):ReadableStream<Uint8Array>{
  const reader=body.getReader();let size=0,empty=0,closed=false;
  let timer:ReturnType<typeof setTimeout>;
  const stop=()=>{closed=true;clearTimeout(timer);void reader.cancel().catch(()=>{});};
  return new ReadableStream<Uint8Array>({
    start(controller){timer=setTimeout(()=>{if(!closed){stop();controller.error(new Error("Media body deadline exceeded"));}},BODY_DEADLINE_MS);},
    async pull(controller){
      try{
        while(!closed){const part=await reader.read();if(closed)return;
          if(part.done){if(exact&&size!==expected)throw new Error("Media size changed");stop();controller.close();return;}
          if(!(part.value instanceof Uint8Array)||part.value.byteLength>expected-size)throw new Error("Media size changed");
          if(!part.value.byteLength){if(++empty>64)throw new Error("Media body made no progress");continue;}
          empty=0;size+=part.value.byteLength;controller.enqueue(part.value);return;
        }
      }catch{if(!closed){stop();controller.error(new Error("Media body could not be completed"));}}
    },
    cancel(){stop();},
  });
}
