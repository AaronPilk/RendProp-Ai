/** Server-only nudge of the private video controller (its `/wake` route).
 *
 * The controller otherwise discovers queued video work on its one-minute cron,
 * so a new or resumed job could sit idle for up to a minute before its first
 * step. The wake carries no job, media or user data: the controller answers by
 * reading the same durable queue its cron reads, and SQL claims still decide
 * every action. A lost, refused or unconfigured wake changes nothing; cron
 * remains the safety net. Never awaited by a user response. */
export function propertyVideoWakeUrl(base:string|undefined):URL|null{
 if(!base)return null;
 try{const url=new URL(base.trim());if(url.protocol!=='https:'||url.username||url.password||url.port||url.search||url.hash||!['','/'].includes(url.pathname))return null;url.pathname='/wake';return url;}catch{return null;}
}
export function wakePropertyVideoRender(transport:typeof fetch=fetch):Promise<boolean>{
 // The video controller and the photo-quality controller are one Worker with
 // one trigger key; dedicated names win when they are configured.
 const url=propertyVideoWakeUrl(Deno.env.get('PROPERTY_VIDEO_RENDER_URL')??Deno.env.get('PHOTO_QUALITY_RENDER_URL')),key=(Deno.env.get('PROPERTY_VIDEO_RENDER_TRIGGER_KEY')??Deno.env.get('PHOTO_QUALITY_RENDER_TRIGGER_KEY'))?.trim();
 if(!url||!key)return Promise.resolve(false);
 const work=(async()=>{try{const reply=await transport(url,{method:'POST',headers:{authorization:`Bearer ${key}`},redirect:'error',credentials:'omit',signal:AbortSignal.timeout(5000)});await reply.body?.cancel().catch(()=>{});return reply.status===202;}catch{return false;}})();
 try{const runtime=(globalThis as{EdgeRuntime?:{waitUntil?(work:Promise<unknown>):void}}).EdgeRuntime;if(typeof runtime?.waitUntil==='function')runtime.waitUntil(work);}catch{/* The wake is best-effort. */}
 return work;
}
/** Delay before a supplier-wait follow-up wake. */
export const PROPERTY_VIDEO_FOLLOW_UP_WAKE_MS=20_000;
/** A follow-up is due only when no supplier status check ran in this window,
 * so overlapping ticks (cron plus an earlier follow-up) settle on one chain. */
export const PROPERTY_VIDEO_FOLLOW_UP_QUIET_MS=15_000;
export function followUpWakeDue(lastCheckedAt:unknown,now=Date.now()):boolean{
 const stamps=(Array.isArray(lastCheckedAt)?lastCheckedAt:[lastCheckedAt]).map(v=>typeof v==='string'?Date.parse(v):NaN).filter(Number.isFinite);
 return!stamps.length||now-Math.max(...stamps)>=PROPERTY_VIDEO_FOLLOW_UP_QUIET_MS;
}
/** While a supplier renders, the controller releases its CPU slot and would
 * next look at the job on its one-minute cron. This schedules one extra wake
 * in between, kept alive by the Edge runtime after the reply. It is skipped
 * where background work is unavailable (tests, local runs): cron still polls. */
export function wakePropertyVideoRenderLater(delayMs=PROPERTY_VIDEO_FOLLOW_UP_WAKE_MS,transport:typeof fetch=fetch):boolean{
 try{const runtime=(globalThis as{EdgeRuntime?:{waitUntil?(work:Promise<unknown>):void}}).EdgeRuntime;
  if(typeof runtime?.waitUntil!=='function'||!propertyVideoWakeUrl(Deno.env.get('PROPERTY_VIDEO_RENDER_URL')??Deno.env.get('PHOTO_QUALITY_RENDER_URL')))return false;
  runtime.waitUntil(new Promise(resolve=>setTimeout(resolve,delayMs)).then(()=>wakePropertyVideoRender(transport)).catch(()=>false));return true;
 }catch{return false;}
}
