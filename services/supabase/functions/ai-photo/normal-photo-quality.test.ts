import {assert,assertEquals,assertRejects,assertThrows}from"https://deno.land/std@0.224.0/assert/mod.ts";
const environmentKeys=["SUPABASE_SECRET_KEYS","RENDPROP_SECRET_KEY_NAME","SUPABASE_PUBLISHABLE_KEYS","RENDPROP_PUBLISHABLE_KEY_NAME","SUPABASE_URL","SUPABASE_SERVICE_ROLE_KEY","SUPABASE_ANON_KEY"];
async function closedEnvironment<T>(run:()=>Promise<T>|T):Promise<T>{
 const previous=new Map(environmentKeys.map(key=>[key,Deno.env.get(key)]));
 try{
  for(const key of environmentKeys.slice(0,4))Deno.env.delete(key);
  Deno.env.set("SUPABASE_URL","https://closed-quality.invalid");Deno.env.set("SUPABASE_SERVICE_ROLE_KEY","closed-not-valid");Deno.env.set("SUPABASE_ANON_KEY","closed-not-valid");
  return await run();
 }finally{for(const[key,value]of previous){if(value===undefined)Deno.env.delete(key);else Deno.env.set(key,value);}}
}
function test(name:string,run:()=>Promise<void>|void){Deno.test(name,()=>closedEnvironment(run));}
const[normal,quality,funding,gemini,router,http]=await closedEnvironment(()=>Promise.all([
 import("./normal-photo-quality.ts"),import("../_shared/photo-image-quality.ts"),import("../_shared/funded-serving.ts"),import("../_shared/providers/gemini.ts"),import("../_shared/router.ts"),import("../_shared/http.ts")
]));
const{normalPhotoQualityProfile,normalPhotoQualityRoutes,prepareNormalPhotoPro4KInput,priceNormalPhotoQualityRoute,NORMAL_PHOTO_QUALITY_KEY}=normal;
const{NORMAL_PHOTO_PRO4K_PROFILE,normalPhotoPro4KInputAllowance}=quality;
const{mediaAttemptQuote,ceilingVerifiedQuote,boundedPhotoChain,resetServingModeCache}=funding;
const{geminiAdapter,submitPreparedGeminiPhoto4K}=gemini;
const{resetRouterCache}=router;
const{HttpError}=http;
const config={enabled:true,profile:NORMAL_PHOTO_PRO4K_PROFILE};
const profile={profile:NORMAL_PHOTO_PRO4K_PROFILE,task:"photo.stage",routeTask:"photo.quality_stage"}as const;
const row={id:"c43f188c-faf0-46c8-a646-ea71b8481201",task:profile.routeTask,position:1,provider:"gemini",model:"gemini-3-pro-image",unit:"image",unit_cents:30.5536,capabilities:["prompt-edit","fidelity","4K"],max_latency_s:120,min_plan:"free",same_model_as:null,privacy_tier:"retained_30d",enabled:true,retire_after:null,note:"legacy",params:{image_size:"4K"}};
function db(value:unknown=config,error=false){const reads:string[]=[];return{reads,client:{from(table:string){assertEquals(table,"app_config","Ordinary users need no profile/admin/sponsor read");return{select(){return this;},eq(key:string,v:unknown){assertEquals([key,v],["key",NORMAL_PHOTO_QUALITY_KEY]);return this;},maybeSingle:async()=>{reads.push(table);return{data:value===null?null:{value},error:error?{message:"unavailable"}:null};}};}}as any};}
const jpeg=(w=1536,h=2048)=>btoa(String.fromCharCode(...[255,216,255,192,0,11,8,h>>8,h&255,w>>8,w&255,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]));
const input=(task="photo.stage")=>({task,image_b64:jpeg(),prompt:"Preserve the property.",extra:{image_mime:"image/jpeg"}});

test("ordinary preservation policy is independently OFF and restricted to unmasked Stage/Declutter",async()=>{
 for(const value of[null,{enabled:false,profile:NORMAL_PHOTO_PRO4K_PROFILE}])assertEquals(await normalPhotoQualityProfile("photo.stage",false,db(value).client),null);
 for(const task of["photo.stage","photo.declutter"]){const f=db();assertEquals((await normalPhotoQualityProfile(task,false,f.client))?.task,task);assertEquals(f.reads,["app_config"]);}
 for(const task of["photo.sky","photo.twilight","photo.lawn","photo.custom","video.reel_clip"]){const f=db();assertEquals(await normalPhotoQualityProfile(task,false,f.client),null);assertEquals(f.reads,[]);}
 const masked=db();assertEquals(await normalPhotoQualityProfile("photo.declutter",true,masked.client),null);assertEquals(masked.reads,[]);
 for(const value of[{},[],true,{...config,enabled:"true"},{...config,profile:"owner-qa"}])await assertRejects(()=>normalPhotoQualityProfile("photo.stage",false,db(value).client),HttpError);
 await assertRejects(()=>normalPhotoQualityProfile("photo.stage",false,db(config,true).client),HttpError);
});
test("actual ordinary resolver keeps plan/privacy/capability/retirement and active legacy-row checks under both router flags",async()=>{
 const previous=globalThis.fetch;let flag=true,rows:any[]=[row],requested:string[]=[];
 globalThis.fetch=async(url)=>{const u=new URL(String(url)),table=u.pathname.split("/").at(-1);requested.push(table!);
  if(table==="app_config")return Response.json({value:{enabled:flag}});
  if(table==="plan_routing_policy")return Response.json([{plan:"starter",policy:"cheapest"}]);
  if(table==="provider_health")return Response.json([]);
  assertEquals(table,"ai_routes");assertEquals(u.searchParams.get("task"),"eq.photo.quality_stage");assertEquals(u.searchParams.get("enabled"),"eq.true");
  return Response.json(rows.filter(row=>row.enabled&&(!u.searchParams.has("note")||row.note==="legacy")));
 };
 try{for(flag of[true,false]){
  rows=[row];resetRouterCache();const chain=await normalPhotoQualityRoutes(profile,{plan:"starter",needs:["prompt-edit","fidelity"],carries_customer_media:true});
  assertEquals(chain.length,1);assertEquals(chain[0].task,"photo.stage");assertEquals(chain[0].route_id,row.id);assertEquals(chain[0].model,"gemini-3-pro-image");
  for(const changed of[null,{...row,enabled:false},{...row,min_plan:"team"},{...row,privacy_tier:"trains_by_default"},{...row,retire_after:"2000-01-01"},{...row,capabilities:["prompt-edit"]},{...row,model:"gemini-3.1-flash-image"}]){
   rows=changed?[changed]:[];resetRouterCache();await assertRejects(()=>normalPhotoQualityRoutes(profile,{plan:"starter",needs:["prompt-edit","fidelity"]}),HttpError);
  }
 }}finally{globalThis.fetch=previous;resetRouterCache();}
 assert(requested.includes("ai_routes"));assert(!requested.includes("profiles"));
});
test("ordinary source marker is server-prepared and full-tier quote differs from owner grant without changing either tariff",async()=>{
 const canonical={...row,route_id:row.id,task:"photo.stage"}as any,source=input(),prepared=prepareNormalPhotoPro4KInput(source,profile);
 assertEquals(prepared.image_b64,source.image_b64);assertEquals(source.extra,{image_mime:"image/jpeg"});assertEquals(prepared.extra?.owner_photo_pro_4k,undefined);
 for(const[allowance,price]of[[8192,30.5536],[16384,32.192],[24576,33.8304]]){const p={...prepared,extra:{...prepared.extra,photo_input_allowance:allowance}};
  assertEquals(mediaAttemptQuote(canonical,p),{cents:price,version:"photo-preservation-pro4k-standard-20261015"});assertEquals(ceilingVerifiedQuote(canonical,p,null),mediaAttemptQuote(canonical,p));assertEquals(priceNormalPhotoQualityRoute([canonical],p)[0].unit_cents,price);
 }
 for(const p of[input(),{...prepared,task:"photo.sky"},{...prepared,extra:{...prepared.extra,photo_preservation_profile:"owner"}},{...prepared,mask_url:"mask"}])assertEquals(mediaAttemptQuote(canonical,p),null);
 assertEquals(normalPhotoPro4KInputAllowance(prepared),8192);assertThrows(()=>prepareNormalPhotoPro4KInput(input("photo.sky"),profile),HttpError);
 assertThrows(()=>priceNormalPhotoQualityRoute([{...canonical,model:"gemini-3.1-flash-image"}],prepared),HttpError);
 const reference=prepareNormalPhotoPro4KInput({...input(),extra:{image_mime:"image/jpeg",staging_reference_b64:jpeg(1024,768),staging_reference_mime:"image/jpeg"}},profile);assert(reference.extra?.staging_reference_b64);
 const before=globalThis.fetch;resetServingModeCache();globalThis.fetch=async()=>Response.json("funded");
 try{let sponsorshipReads=0;const context:any={actorId:"normal-nonadmin",orgId:"ordinary-starter",rpc:async()=>{sponsorshipReads++;return{data:false,error:null};}};assertEquals((await boundedPhotoChain(context,[canonical],prepared))[0].model,"gemini-3-pro-image");assert(sponsorshipReads>0,"No unlimited sponsor exists or is required");}finally{globalThis.fetch=before;resetServingModeCache();}
});
test("actual ordinary adapter sends exact Pro4K once; unprepared or wrong-task requests cannot call provider",async()=>{
 const previous=globalThis.fetch,key=Deno.env.get("GEMINI_API_KEY");Deno.env.set("GEMINI_API_KEY","closed-not-valid");let calls=0;
 const step={...row,route_id:row.id,task:"photo.stage"}as any,p=prepareNormalPhotoPro4KInput(input(),profile);
 globalThis.fetch=async(url,init)=>{calls++;assert(String(url).endsWith("/gemini-3-pro-image:generateContent"));const body=JSON.parse(String((init as {body?:unknown})?.body));assertEquals(body.generationConfig.imageConfig,{imageSize:"4K"});assertEquals(body.contents[0].parts[1].inline_data.data,p.image_b64);return Response.json({candidates:[{content:{parts:[{inlineData:{mimeType:"image/jpeg",data:jpeg(3584,4800)}}]}}]});};
 try{const ref=await submitPreparedGeminiPhoto4K(step,p,{deadline:Date.now()+1000,signal:new AbortController().signal});assertEquals((await geminiAdapter.poll(ref)).status,"done");
  for(const bad of[input(),{...p,task:"photo.sky"},{...p,extra:{...p.extra,photo_preservation_profile:"unapproved"}}])await assertRejects(()=>geminiAdapter.submit(step,bad));assertEquals(calls,1);
 }finally{globalThis.fetch=previous;if(key===undefined)Deno.env.delete("GEMINI_API_KEY");else Deno.env.set("GEMINI_API_KEY",key);}
});
test("compiled disabled policy or model substitution cannot pass ordinary authorization oracle",async()=>{
 const path=new URL("./normal-photo-quality.ts",import.meta.url),source=(await Deno.readTextFile(path)).replace(/from "(\.\.?\/[^\"]+)"/g,(_all,p)=>`from ${JSON.stringify(new URL(p,path).href)}`);
 for(const[anchor,replacement,oracle]of[
  ['value.enabled===false','false',async(m:any)=>assertEquals(await m.normalPhotoQualityProfile("photo.stage",false,db({enabled:false,profile:NORMAL_PHOTO_PRO4K_PROFILE}).client),null)],
  ['row.model==="gemini-3-pro-image"','true',async(m:any)=>await assertRejects(()=>m.normalPhotoQualityRoutes(profile,{plan:"starter"},async()=>[{...row,route_id:row.id,model:"gemini-3.1-flash-image"}]),HttpError)],
 ]as const){assertEquals(source.split(anchor).length-1,1);const m=await import("data:application/typescript;base64,"+btoa(unescape(encodeURIComponent(source.replace(anchor,replacement)))));await assertRejects(()=>oracle(m),Error);}
});
