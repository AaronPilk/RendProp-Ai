/** Server-only, one-attempt wake. A lost acknowledgment never starts a new
 * generation/check; the CPU controller deduplicates the existing check UUID. */
export async function startPhotoComparison(checkId:string,signal?:AbortSignal):Promise<{started:boolean}>{
 if(!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(checkId))return{started:false};
 const base=Deno.env.get('PHOTO_QUALITY_RENDER_URL')?.trim(),key=Deno.env.get('PHOTO_QUALITY_RENDER_TRIGGER_KEY')?.trim();
 if(!base||!key)return{started:false};
 let url:URL;try{url=new URL(base);if(url.protocol!=='https:'||url.username||url.password||url.port||url.search||url.hash||!['','/'].includes(url.pathname))return{started:false};url.pathname='/photo-quality/start';}catch{return{started:false};}
 try{const reply=await fetch(url,{method:'POST',headers:{authorization:`Bearer ${key}`,'content-type':'application/json'},body:JSON.stringify({check_id:checkId}),redirect:'error',credentials:'omit',signal:signal?AbortSignal.any([signal,AbortSignal.timeout(10000)]):AbortSignal.timeout(10000)});
  if(![200,202].includes(reply.status)){await reply.body?.cancel().catch(()=>{});return{started:false};}
  const reader=reply.body?.getReader();if(!reader)return{started:false};let text='',count=0;const decoder=new TextDecoder();for(;;){const part=await reader.read();if(part.done)break;count+=part.value.byteLength;if(count>4096){await reader.cancel();return{started:false};}text+=decoder.decode(part.value,{stream:true});}text+=decoder.decode();const body=JSON.parse(text);return{started:body?.accepted===true&&body?.check_id===checkId};
 }catch{return{started:false};}
}
