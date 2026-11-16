import {assert,assertEquals,assertRejects,assertThrows}from"https://deno.land/std@0.224.0/assert/mod.ts";
for(const key of ["SUPABASE_SECRET_KEYS","RENDPROP_SECRET_KEY_NAME","SUPABASE_PUBLISHABLE_KEYS","RENDPROP_PUBLISHABLE_KEY_NAME"])Deno.env.delete(key);
Deno.env.set("SUPABASE_URL","https://closed-fixture.invalid");Deno.env.set("SUPABASE_SERVICE_ROLE_KEY","closed-fixture-not-valid");Deno.env.set("SUPABASE_ANON_KEY","closed-fixture-not-valid");
const{ownerQaPhotoPro4KStep,prepareOwnerQaPhotoPro4KInput,OWNER_PHOTO_PRO_4K_KEY,OWNER_PHOTO_PRO_4K_CONSENT}=await import("./owner-photo-qa.ts");
const{assertPhotoPro4KGeometry}=await import("./photo-quality.ts");
const{geminiAdapter,geminiImageGenerationConfig,supportsStagingReference,submitPreparedGeminiPhoto4K}=await import("../_shared/providers/gemini.ts");
const{ProviderError}=await import("../_shared/providers/common.ts");
const{mediaAttemptQuote,ceilingVerifiedQuote,geminiPro4KGenerationQuote,fundedAttempt,resetServingModeCache}=await import("../_shared/funded-serving.ts");
const{HttpError}=await import("../_shared/http.ts");
import type{GenerateInput}from"../_shared/providers/types.ts";
import type{FundingContext}from"../_shared/funded-serving.ts";
const A="aabbccdd-a1b2-4c3d-8e9f-001122aabbcc",O="bbccddee-b2c3-4d4e-9f0a-112233bbccdd",L="ccddeeaa-c3d4-4e5f-8a0b-223344ccdde0",X="ddeeaabb-d4e5-4f6a-9b0c-334455ddeea0",NOW=new Date("2026-10-15T07:00:00Z");
const args={actorId:A.toUpperCase(),orgId:O.toUpperCase(),listingId:L.toUpperCase(),task:"photo.stage"};
const grant={enabled:true,actor_id:A,org_id:O,listing_id:L,changed_by:A,task:args.task,provider:"gemini",model:"gemini-3-pro-image",image_size:"4K",consent:OWNER_PHOTO_PRO_4K_CONSENT,created_at:"2026-10-15T06:30:00Z",expires_at:"2026-10-15T08:00:00Z"};
function db(value:unknown=grant,admin:unknown=true,error=false){const calls:any[]=[];return{calls,client:{from(table:string){return{select(){return this;},eq(key:string,value:unknown){calls.push([table,key,value]);return this;},maybeSingle:async()=>({data:table==="profiles"?{is_admin:admin}:{value},error:error?{message:"closed unavailable"}:null})};}}as any};}
function jpeg(w=1536,h=2048){return btoa(String.fromCharCode(...[255,216,255,192,0,11,8,h>>8,h&255,w>>8,w&255,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]));}
const input=(change:Partial<GenerateInput>={}):GenerateInput=>({task:"photo.stage",image_b64:jpeg(),prompt:"Furnish movable furniture only.",extra:{image_mime:"image/jpeg"},...change});
Deno.test("owner Pro4K fresh exact task/actor/library/listing/admin consent is separate from old2K grant",async()=>{
 const f=db(),step=await ownerQaPhotoPro4KStep(args,f.client,NOW);assert(step);assertEquals(step.model,"gemini-3-pro-image");assertEquals(step.unit_cents,30.5536);assertEquals(f.calls,[["app_config","key",OWNER_PHOTO_PRO_4K_KEY],["profiles","id",A]]);
 for(const key of ["actor_id","org_id","listing_id","changed_by"])assertEquals(await ownerQaPhotoPro4KStep(args,db({...grant,[key]:X}).client,NOW),null);
 for(const change of [{task:"photo.declutter"},{enabled:false},{model:"gemini-3-pro-image-preview"},{model:"gemini-3.1-flash-image"},{image_size:"2K"},{consent:"owner-authorized-2k-media-qa-2026-10-12"},{expires_at:NOW.toISOString()},{created_at:"2026-10-15T07:01:00Z"},{created_at:"2026-10-13T07:00:00Z"}])assertEquals(await ownerQaPhotoPro4KStep(args,db({...grant,...change}).client,NOW),null);
 for(const actor of [false,"true",null])assertEquals(await ownerQaPhotoPro4KStep(args,db(grant,actor).client,NOW),null);
 for(const value of [null,[],"grant"])assertEquals(await ownerQaPhotoPro4KStep(args,db(value).client,NOW),null);
 assertEquals(await ownerQaPhotoPro4KStep(args,db(grant,true,true).client,NOW),null);
 for(const task of ["photo.sky","photo.custom","photo.lawn","photo.twilight","video.reel_clip"]){const f=db();assertEquals(await ownerQaPhotoPro4KStep({...args,task},f.client,NOW),null);assertEquals(f.calls,[]);}
 assert(await ownerQaPhotoPro4KStep({...args,task:"photo.declutter"},db({...grant,task:"photo.declutter"}).client,NOW));
});
Deno.test("owner Pro4K input retains exact bytes/reference and full UTF8 tier; masks/oversize refuse",()=>{
 const source=input(),prepared=prepareOwnerQaPhotoPro4KInput(source);assertEquals(prepared.image_b64,source.image_b64);assertEquals(prepared.extra?.owner_photo_pro_4k,true);assertEquals(source.extra,{image_mime:"image/jpeg"});
 const reference=jpeg(1024,768),p=prepareOwnerQaPhotoPro4KInput(input({prompt:"😀".repeat(1000),extra:{image_mime:"image/jpeg",staging_reference_b64:reference,staging_reference_mime:"image/jpeg"}}));assertEquals(p.extra?.staging_reference_b64,reference);assertEquals(p.extra?.photo_input_allowance,16384);assertEquals(p.extra?.photo_input_token_bound,12704);
 for(const changed of [{image_b64:jpeg(2049,1536)},{mask_url:"data:image/png;base64,AA=="},{prompt:"x".repeat(24577)},{image_b64:"broken"}])assertThrows(()=>prepareOwnerQaPhotoPro4KInput(input(changed)),HttpError);
});
Deno.test("Pro4K model-specific official tariffs reserve all three input tiers and closed4K actual payload",async()=>{
 const step=await ownerQaPhotoPro4KStep(args,db().client,NOW);assert(step);const p=prepareOwnerQaPhotoPro4KInput(input());
 assertEquals(geminiImageGenerationConfig(step.model,"4K"),{responseModalities:["IMAGE"],candidateCount:1,maxOutputTokens:4096,imageConfig:{imageSize:"4K"}});assert(supportsStagingReference(step.model));
 for(const[allowance,price]of[[8192,30.5536],[16384,32.192],[24576,33.8304]]){
  const recipe={...p,extra:{...p.extra,photo_input_allowance:allowance}};assertEquals(mediaAttemptQuote(step,recipe)?.cents,price);assertEquals(ceilingVerifiedQuote(step,recipe,null)?.cents,price);
 }
 for(const extra of [{},{...p.extra,owner_photo_pro_4k:false},{...p.extra,photo_input_token_bound:24577},{...p.extra,photo_input_allowance:32768}]){assertEquals(mediaAttemptQuote(step,{...p,extra}),null);assertEquals(ceilingVerifiedQuote(step,{...p,extra},null),null);}
 assertEquals(mediaAttemptQuote(step,{...p,mask_url:"mask"}),null);assertEquals(geminiPro4KGenerationQuote(geminiImageGenerationConfig(step.model)),null);assertThrows(()=>geminiImageGenerationConfig(step.model,"2K"),ProviderError);assertThrows(()=>geminiImageGenerationConfig("gemini-3-pro-image-preview","4K"),ProviderError);
});
Deno.test("actual Gemini adapter dispatches scoped Pro4K once with exact source and refuses bare claim before HTTP",async()=>{
 const step=await ownerQaPhotoPro4KStep(args,db().client,NOW);assert(step);const p=prepareOwnerQaPhotoPro4KInput(input()),prior=globalThis.fetch,key=Deno.env.get("GEMINI_API_KEY");Deno.env.set("GEMINI_API_KEY","closed-never-valid");let posts=0;
 globalThis.fetch=async(url,init)=>{posts++;assert(String(url).endsWith("/gemini-3-pro-image:generateContent"));const b=JSON.parse(String((init as {body?:BodyInit|null}|undefined)?.body));assertEquals(b.generationConfig.imageConfig,{imageSize:"4K"});assertEquals(b.contents[0].parts[1].inline_data.data,p.image_b64);return Response.json({candidates:[{content:{parts:[{inlineData:{mimeType:"image/jpeg",data:jpeg(3584,4800)}}]}}]});};
 try{const ref=await submitPreparedGeminiPhoto4K(step,p,{deadline:Date.now()+1000,signal:new AbortController().signal});assertEquals((await geminiAdapter.poll(ref)).status,"done");
  await assertRejects(()=>geminiAdapter.submit(step,{...p,extra:{...p.extra,owner_photo_pro_4k:false}}),ProviderError);assertEquals(posts,1);
 }finally{globalThis.fetch=prior;if(key===undefined)Deno.env.delete("GEMINI_API_KEY");else Deno.env.set("GEMINI_API_KEY",key);}
});
Deno.test("Pro4K funding admission precedes one supplier and capacity refusal sends none",async()=>{
 const step=await ownerQaPhotoPro4KStep(args,db().client,NOW);assert(step);const p=prepareOwnerQaPhotoPro4KInput(input()),prior=globalThis.fetch;globalThis.fetch=async()=>Response.json("ceiling");resetServingModeCache();
 try{for(const denied of [false,true]){let posts=0;const calls:any[]=[];const c:FundingContext={actorId:A,orgId:O,requestKey:"closed-pro4k",rpc:async(n,a)=>{calls.push([n,a]);return{data:{reserved:true},error:denied&&n==="serving_cost_reserve"?{message:"RP402: This attempt exceeds the shared funded serving allowance"}:null};}};
  const send=()=>fundedAttempt(c,"photo.stage:0",step,p,mediaAttemptQuote(step,p),async()=>{assertEquals(calls.at(-1)[0],"serving_cost_reserve");posts++;return"closed-image";});if(denied)await assertRejects(send,HttpError);else assertEquals(await send(),"closed-image");assertEquals(posts,denied?0:1);assert(Number(calls[0][1].p_hold_cents)>=30.5536);
 }}finally{globalThis.fetch=prior;resetServingModeCache();}
});
Deno.test("Pro4K exact ten published output aspects exclude smaller sizes and Flash-only extremes",()=>{
 for(const [width,height]of[[4096,4096],[3392,5056],[5056,3392],[3584,4800],[4800,3584],[3712,4608],[4608,3712],[3072,5504],[5504,3072],[6336,2688],[3584,4780]])assertPhotoPro4KGeometry({width,height});
 for(const[width,height]of[[2048,8192],[8192,2048],[1536,12288],[12288,1536],[2048,2048],[896,1195],[4800,4800]])assertThrows(()=>assertPhotoPro4KGeometry({width,height}),HttpError);
});

const encoded=(text:string)=>"data:application/typescript;base64,"+btoa(unescape(encodeURIComponent(text)));
const absoluteImports=(text:string,base:string)=>text.replace(/from "(\.\.?\/[^\"]+)"/g,(_all,path)=>`from ${JSON.stringify(new URL(path,base).href)}`);
Deno.test("compiled Pro4K consent task authority and underpriced tariff faults fail independent oracles",async()=>{
 const path=new URL("./owner-photo-qa.ts",import.meta.url),source=await Deno.readTextFile(path),cut=source.indexOf("// Separate from the historical Flash2K selector.");assert(cut>0);
 for(const[anchor,replacement,check]of[
  ["grant.consent!==OWNER_PHOTO_PRO_4K_CONSENT","false",async(m:any)=>assertEquals(await m.ownerQaPhotoPro4KStep(args,db({...grant,consent:"old-owner-consent"}).client,NOW),null)],
  ["grant.task!==args.task","false",async(m:any)=>assertEquals(await m.ownerQaPhotoPro4KStep({...args,task:"photo.declutter"},db().client,NOW),null)],
  ["profile.data?.is_admin!==true","false",async(m:any)=>assertEquals(await m.ownerQaPhotoPro4KStep(args,db(grant,false).client,NOW),null)],
 ]as const){const tail=source.slice(cut);assertEquals(tail.split(anchor).length-1,1);const module=await import(encoded(absoluteImports(source.slice(0,cut)+tail.replace(anchor,replacement),path.href)));await assertRejects(()=>check(module),Error);}
 const pricePath=new URL("../_shared/funded-serving.ts",import.meta.url),price=await Deno.readTextFile(pricePath),anchor="Number(config.maxOutputTokens)*12+2000*120";assertEquals(price.split(anchor).length-1,1);
 const module=await import(encoded(absoluteImports(price.replace(anchor,"Number(config.maxOutputTokens)*3+2520*60"),pricePath.href)));
 await assertRejects(async()=>assertEquals(module.geminiPro4KGenerationQuote(geminiImageGenerationConfig("gemini-3-pro-image","4K"),8192).cents,30.5536),Error);
 console.log("OWNER_PRO_4K_COMPILED_CONTROLS=4");
});
