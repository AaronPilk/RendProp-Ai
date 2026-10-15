import {runtimeApiKey} from "../_shared/api-key-config.ts";
/** One authenticated subrequest to a separate Edge function keeps the6MB
 * vision package out of the generation isolate. Its reply never releases media;
 * the caller reads its own scoped authoritative status afterward. */
export async function invokeSavedPhotoJudge(checkId:string,signal?:AbortSignal,maximumMs=45_000):Promise<void>{
 if(!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(checkId))return;
 try{
  const base=Deno.env.get("SUPABASE_URL"),key=runtimeApiKey(Deno.env.get("SUPABASE_SECRET_KEYS"),Deno.env.get("RENDPROP_SECRET_KEY_NAME")??"default","secret",Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
  if(!base||!key)return;
  const url=new URL(base);if(url.protocol!=="https:"||url.username||url.password||url.port||url.search||url.hash||!["","/"].includes(url.pathname))return;url.pathname="/functions/v1/photo-quality-worker/judge";
  const headers:Record<string,string>={apikey:key,"content-type":"application/json"};if(!key.startsWith("sb_secret_"))headers.authorization=`Bearer ${key}`;
  const timeout=AbortSignal.timeout(Math.min(45_000,Math.max(1,Math.floor(maximumMs))));
  const response=await fetch(url,{method:"POST",headers,body:JSON.stringify({check_id:checkId}),credentials:"omit",redirect:"error",signal:signal?AbortSignal.any([signal,timeout]):timeout});
  // Do not parse or trust a reply state. Bound/cancel it, then let the main
  // actor request reconcile through its own fresh status RPC; never retry here.
  const reader=response.body?.getReader();if(!reader)return;let total=0;
  for(;;){const {value,done}=await reader.read();if(done)break;total+=value.byteLength;if(total>4096){await reader.cancel();return;}}
 }catch{/* An unknown response is reconciled by the existing check, never repeated. */}
}
