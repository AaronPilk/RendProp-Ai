/** Closed aerial retention only. Legacy provider/storage helpers stay unchanged.
 * A same-key metadata repair never substitutes or overwrites media bytes. */
import {AwsClient} from 'https://esm.sh/aws4fetch@1.0.20';
import {assert} from '../_shared/http.ts';
import {BUDGETS,MAX_PERSIST_BYTES,fetchBounded} from '../_shared/providers/common.ts';
import type {DoneState} from '../_shared/providers/types.ts';
import {R2_BUCKET_RENDERS} from '../_shared/r2.ts';
import {putCapability} from './storage.ts';

const UUID='[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}';
const PROVIDER_KEY=new RegExp(`^renders/${UUID}/${UUID}/aerial-provider/${UUID}\\.mp4$(?![\\s\\S])`);
const FRAME_KEY=new RegExp(`^renders/${UUID}/${UUID}/aerial-review/${UUID}/frame-(?:0|60|119|120)\\.jpg$(?![\\s\\S])`);
const COPY_CONTENT_HEADERS=['cache-control','content-disposition','content-encoding','content-language','expires','x-amz-website-redirect-location'];
const mimeOf=(h:Headers)=>h.get('content-type')?.split(';')[0].trim().toLowerCase();
const digest=async(b:Uint8Array<ArrayBuffer>)=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',b)),v=>v.toString(16).padStart(2,'0')).join('');
function target(key:string,mime:string):URL {
  assert(mime==='video/mp4'?PROVIDER_KEY.test(key):mime==='image/jpeg'&&FRAME_KEY.test(key),409,'Keep the exact reserved aerial media identity.');
  const account=Deno.env.get('CLOUDFLARE_ACCOUNT_ID')?.trim();
  assert(account,503,'Private aerial storage is unavailable.');
  return new URL(`https://${account}.r2.cloudflarestorage.com/${R2_BUCKET_RENDERS}/${key.split('/').map(encodeURIComponent).join('/')}`);
}
const client=()=>new AwsClient({accessKeyId:Deno.env.get('R2_ACCESS_KEY_ID')?.trim()??'',secretAccessKey:Deno.env.get('R2_SECRET_ACCESS_KEY')?.trim()??'',service:'s3',region:'auto'});
async function request(url:URL,method:string,headers:Record<string,string>={},timeout=10_000):Promise<Response>{
  return await fetch(await client().sign(url,{method,headers,aws:{allHeaders:true}}),{redirect:'error',signal:AbortSignal.timeout(timeout)});
}
async function head(url:URL,bytes:number,mime:string,sha:string){
  const r=await request(url,'HEAD');
  assert(r.status===200,409,'The retained aerial object could not be verified.');
  const etag=r.headers.get('etag'),length=r.headers.get('content-length'),storedSHA=r.headers.get('x-amz-meta-sha256');
  assert(length===String(bytes)&&r.headers.get('content-type')===mime&&etag!==null&&/^"[A-Za-z0-9-]{1,128}"$/.test(etag),409,'The retained aerial size, type or identity changed.');
  assert(storedSHA===null||storedSHA===''||storedSHA===sha,409,'The retained aerial digest conflicts with these saved bytes.');
  return{headers:r.headers,etag,storedSHA};
}
/** Compare the complete stored body to the already hashed supplier/frame bytes.
 * Streaming equality proves the same SHA without allocating a second full body. */
async function sameStoredBytes(url:URL,expected:Uint8Array<ArrayBuffer>,mime:string,etag:string):Promise<void>{
  const r=await request(url,'GET',{'if-match':etag},BUDGETS.transferMs);
  assert(r.status===200&&r.headers.get('etag')===etag&&r.headers.get('content-length')===String(expected.length)&&r.headers.get('content-type')===mime&&r.body,409,'The retained aerial body changed during verification.');
  const reader=r.body.getReader();let offset=0,complete=false;
  try{
    for(;;){const part=await reader.read();if(part.done)break;
      assert(offset+part.value.length<=expected.length,409,'The retained aerial body exceeds its saved size.');
      for(let i=0;i<part.value.length;i++)assert(part.value[i]===expected[offset+i],409,'The retained aerial body differs from the saved result.');
      offset+=part.value.length;
    }
    assert(offset===expected.length,409,'The retained aerial body is incomplete.');complete=true;
  }finally{if(!complete)await reader.cancel().catch(()=>{});reader.releaseLock();}
}
function retainedHeaders(h:Headers):Record<string,string>{
  const result:Record<string,string>={};
  for(const[k,v]of h)if(k.startsWith('x-amz-meta-')||COPY_CONTENT_HEADERS.includes(k))result[k]=v;
  result['content-type']=h.get('content-type')!;
  return result;
}
const sameHeaders=(a:Record<string,string>,b:Record<string,string>)=>JSON.stringify(Object.entries(a).sort(([x],[y])=>x.localeCompare(y)))===JSON.stringify(Object.entries(b).sort(([x],[y])=>x.localeCompare(y)));

/** New writes are immutable and hash-bound. A pre-existing object is reused only
 * after full byte verification; absent metadata alone never authorizes a copy. */
export async function retainAerialBytes(key:string,bytes:Uint8Array<ArrayBuffer>,mime:string){
  const url=target(key,mime),max=mime==='image/jpeg'?393216:MAX_PERSIST_BYTES;
  assert(Number.isSafeInteger(bytes.length)&&bytes.length>0&&bytes.length<=max,409,'Keep the bounded aerial result bytes.');
  const sha=await digest(bytes),cap=await putCapability('renders',key,bytes.length,mime,sha);
  const put=await fetchBounded('r2',cap.put_url,{method:'PUT',redirect:'error',headers:cap.headers,body:bytes},BUDGETS.transferMs);
  await put.body?.cancel().catch(()=>{});
  assert(put.ok||put.status===412,503,'The aerial result could not be retained.');
  const before=await head(url,bytes.length,mime,sha);
  if(put.status!==412){assert(before.storedSHA===sha,409,'The new aerial digest metadata is missing.');return{key,bytes:bytes.length,sha256:sha,etag:before.etag,metadata_repaired:false};}
  await sameStoredBytes(url,bytes,mime,before.etag);
  const current=await head(url,bytes.length,mime,sha);
  assert(current.etag===before.etag&&sameHeaders(retainedHeaders(current.headers),retainedHeaders(before.headers)),409,'The retained aerial metadata changed during verification.');
  if(current.storedSHA===sha)return{key,bytes:bytes.length,sha256:sha,etag:current.etag,metadata_repaired:false};
  const headers={...retainedHeaders(current.headers),'x-amz-copy-source':`/${R2_BUCKET_RENDERS}/${key.split('/').map(encodeURIComponent).join('/')}`,'x-amz-copy-source-if-match':current.etag,'x-amz-metadata-directive':'REPLACE','x-amz-meta-sha256':sha};
  const copy=await request(url,'PUT',headers,BUDGETS.transferMs),xml=await copy.text();
  assert(copy.ok&&!/<Error(?:\s|>)/.test(xml),409,'The verified aerial metadata repair could not be confirmed.');
  const after=await head(url,bytes.length,mime,sha);
  const expected={...retainedHeaders(current.headers),'x-amz-meta-sha256':sha};
  assert(after.etag===current.etag&&after.storedSHA===sha&&sameHeaders(retainedHeaders(after.headers),expected),409,'The verified aerial metadata repair changed the saved identity.');
  return{key,bytes:bytes.length,sha256:sha,etag:after.etag,metadata_repaired:true};
}

/** Only the already accepted saved KIE task supplies this completed MP4. */
export async function persistAerialResult(state:DoneState,key:string,beforeWrite:(intent:{key:string;bytes:number})=>Promise<void>){
  target(key,'video/mp4');
  assert(state.mime==='video/mp4'&&new URL(state.result_url).protocol==='https:',409,'Keep the saved KIE video result.');
  const r=await fetchBounded('kie',state.result_url,{method:'GET'},BUDGETS.transferMs);
  assert(r.ok,503,'The saved KIE result could not be downloaded.');
  const declared=Number(r.headers.get('content-length')??0);
  if(declared>MAX_PERSIST_BYTES){await r.body?.cancel().catch(()=>{});assert(false,409,'The saved KIE result exceeds the retention limit.');}
  const bytes=new Uint8Array(await r.arrayBuffer());
  assert(bytes.length>0&&bytes.length<=MAX_PERSIST_BYTES,409,'Keep the bounded saved KIE result.');
  const type=mimeOf(r.headers);
  assert(!type||['video/mp4','application/octet-stream','binary/octet-stream'].includes(type),409,'The saved KIE result is not a compatible MP4.');
  await beforeWrite({key,bytes:bytes.length});
  return await retainAerialBytes(key,bytes,'video/mp4');
}
