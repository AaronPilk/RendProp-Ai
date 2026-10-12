import { assert, assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import type { FundingContext } from "../_shared/funded-serving.ts";
import { ProviderError } from "../_shared/providers/common.ts";
import type { GenerateInput } from "../_shared/providers/types.ts";
import type { ChainStep } from "../_shared/router.ts";

// Deno's per-file worker owns these inert environment values. Set them before
// importing actual clients so both this focused runner and the whole CI suite
// enter the same closed serving-mode boundary. No real key is read or printed.
for(const key of ["SUPABASE_SECRET_KEYS","RENDPROP_SECRET_KEY_NAME","SUPABASE_PUBLISHABLE_KEYS","RENDPROP_PUBLISHABLE_KEY_NAME"])Deno.env.delete(key);
Deno.env.set("SUPABASE_URL","https://closed-fixture.invalid");Deno.env.set("SUPABASE_SERVICE_ROLE_KEY","closed-fixture-not-valid");Deno.env.set("SUPABASE_ANON_KEY","closed-fixture-not-valid");
const { ownerQaPhotoStep, prepareOwnerQaPhotoInput, assertOwnerQaPhotoOutput, OWNER_PHOTO_QA_CONSENT, OWNER_PHOTO_QA_KEY }=await import("./owner-photo-qa.ts");
const { geminiAdapter, geminiImageGenerationConfig, geminiImagePayload }=await import("../_shared/providers/gemini.ts");
const { ceilingVerifiedQuote, mediaAttemptQuote, fundedAttempt, servingMode, resetServingModeCache }=await import("../_shared/funded-serving.ts");

// Actual production helpers, adapter and reservation authority execute. DB,
// HTTP replies and vendor bytes are closed boundaries; no live quality claim.
const ACTOR="aabbccdd-a1b2-4c3d-8e9f-001122aabbcc", ORG="bbccddee-b2c3-4d4e-9f0a-112233bbccdd";
const LISTING="ccddeeaa-c3d4-4e5f-8a0b-223344ccdde0", OTHER="ddeeaabb-d4e5-4f6a-9b0c-334455ddeea0";
const NOW=new Date("2026-10-12T20:00:00.000Z");
const args={actorId:ACTOR.toUpperCase(),orgId:ORG.toUpperCase(),listingId:LISTING.toUpperCase(),task:"photo.custom"};
const grant={enabled:true,actor_id:ACTOR,org_id:ORG,listing_id:LISTING,changed_by:ACTOR,provider:"gemini",model:"gemini-3.1-flash-image",image_size:"2K",consent:OWNER_PHOTO_QA_CONSENT,created_at:"2026-10-12T19:00:00.000Z",expires_at:"2026-10-12T21:00:00.000Z"};
function db(options:{value?:unknown;admin?:unknown;configError?:boolean;adminError?:boolean}={}) {
 const calls:{table:string;key:string;value:unknown}[]=[];
 const client={from(table:string){const call={table,key:"",value:undefined as unknown};calls.push(call);return{select(_columns:string){return this;},eq(key:string,value:unknown){call.key=key;call.value=value;return this;},maybeSingle(){return Promise.resolve(table==="app_config"?{data:{value:"value"in options?options.value:{...grant}},error:options.configError?{message:"unavailable"}:null}:{data:{is_admin:"admin"in options?options.admin:true},error:options.adminError?{message:"unavailable"}:null});}};}};
 return {client:client as unknown as NonNullable<Parameters<typeof ownerQaPhotoStep>[1]>,calls};
}
function jpeg(width=2048,height=1536) {
 // Complete structural JPEG for geometry admission, not a decoded photo.
 const bytes=new Uint8Array([255,216,255,192,0,11,8,height>>8,height&255,width>>8,width&255,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]);
 return btoa(String.fromCharCode(...bytes));
}
const input=(changes:Partial<GenerateInput>={}):GenerateInput=>({task:"photo.custom",prompt:"Remove loose clutter; preserve the building.",image_b64:jpeg(),extra:{image_mime:"image/jpeg"},...changes});

Deno.test("owner photo2K requires exact canonical current server grant and fresh admin",async()=>{
 const f=db(),step=await ownerQaPhotoStep(args,f.client,NOW);assert(step);
 assertEquals([step.provider,step.model,step.unit_cents,step.params],["gemini","gemini-3.1-flash-image",11.7184,{image_size:"2K"}]);
 assertEquals(f.calls,[{table:"app_config",key:"key",value:OWNER_PHOTO_QA_KEY},{table:"profiles",key:"id",value:ACTOR}]);
 for(const key of ["actor_id","org_id","listing_id","changed_by"]){assertEquals(await ownerQaPhotoStep(args,db({value:{...grant,[key]:OTHER.toUpperCase()}}).client,NOW),null);}
 for(const change of [{enabled:false},{enabled:"true"},{provider:"fal"},{model:"gemini-3.1-flash-lite-image"},{image_size:"4K"},{consent:"body consent"},{created_at:"bad"},{expires_at:NOW.toISOString()},{created_at:"2026-10-12T20:00:00.001Z"},{created_at:"2026-10-11T19:00:00Z"}]){
  const f=db({value:{...grant,...change}});assertEquals(await ownerQaPhotoStep(args,f.client,NOW),null);assertEquals(f.calls.length,1,"Bad grant reached fresh profile query");
 }
 for(const options of [{admin:false},{admin:"true"},{configError:true},{adminError:true},{value:null},{value:[]}])assertEquals(await ownerQaPhotoStep(args,db(options).client,NOW),null);
 for(const change of [{actorId:"invalid"},{listingId:null},{task:"video.reel_clip"}]){const f=db();assertEquals(await ownerQaPhotoStep({...args,...change},f.client,NOW),null);assertEquals(f.calls.length,0);}
 assertEquals(await ownerQaPhotoStep(args,db().client,new Date(NaN)),null);
});

Deno.test("owner photo2K prospectively bounds same source bytes and text without resizing",()=>{
 const original=input(),prepared=prepareOwnerQaPhotoInput(original);
 assertEquals(prepared.image_b64,original.image_b64);assertEquals(original.extra,{image_mime:"image/jpeg"});
 assertEquals(prepared.extra?.owner_photo_2k,true);assertEquals(prepared.extra?.owner_photo_input_bound,4096+new TextEncoder().encode(original.prompt!).byteLength);
 assertThrows(()=>prepareOwnerQaPhotoInput(input({image_b64:jpeg(2049,1536)})),HttpError);
 assertThrows(()=>prepareOwnerQaPhotoInput(input({prompt:"x".repeat(4097)})),HttpError);
 assertThrows(()=>prepareOwnerQaPhotoInput(input({prompt:"😀".repeat(1025)})),HttpError,"verified input bound");
 assertThrows(()=>prepareOwnerQaPhotoInput(input({mask_url:"data:image/png;base64,AA=="})),HttpError);
 assertThrows(()=>prepareOwnerQaPhotoInput(input({extra:{image_mime:"image/jpeg",staging_reference_b64:jpeg(),staging_reference_mime:"image/jpeg"}})),HttpError);
 assertThrows(()=>prepareOwnerQaPhotoInput(input({image_b64:"broken"})),HttpError);
 assertEquals(prepareOwnerQaPhotoInput(input({prompt:"x".repeat(4096)})).extra?.owner_photo_input_bound,8192);
});

Deno.test("actual photo2K geometry gate withholds a smaller supplier image",()=>{
 for(const dimensions of [[2048,2048],[2400,1792],[1792,2400],[2752,1536]])assertOwnerQaPhotoOutput(jpeg(...dimensions as [number,number]),"image/jpeg");
 for(const dimensions of [[1024,1024],[1200,896],[896,1195],[2048,1536],[4096,4096],[4800,3584]])assertThrows(()=>assertOwnerQaPhotoOutput(jpeg(...dimensions as [number,number]),"image/jpeg"),HttpError);
 assertThrows(()=>assertOwnerQaPhotoOutput("broken","image/jpeg"),HttpError);
});

Deno.test("actual2K payload and both quotes agree while ordinary default remains1K",async()=>{
 const step=await ownerQaPhotoStep(args,db().client,NOW);assert(step);const prepared=prepareOwnerQaPhotoInput(input());
 assertEquals(geminiImageGenerationConfig(step.model).imageConfig,{imageSize:"1K"});
 assertEquals(geminiImagePayload(step.model,prepared.prompt!,"image/jpeg",prepared.image_b64!,undefined,"2K").generationConfig,{responseModalities:["IMAGE"],candidateCount:1,maxOutputTokens:4096,imageConfig:{imageSize:"2K"}});
 assertEquals(mediaAttemptQuote(step,prepared)?.cents,11.7184);
 const bound=ceilingVerifiedQuote(step,prepared,null)?.cents;assert(bound!==undefined&&bound>=11.7184&&bound<=11.7185,"Complete2K bound may add one conservative four-decimal rounding increment");
 const normalStep={...step,params:null};assertEquals(ceilingVerifiedQuote(normalStep,input(),null)?.cents,8.3584);
 for(const extra of [{},{owner_photo_2k:true,owner_photo_input_bound:0},{owner_photo_2k:true,owner_photo_input_bound:-1},{owner_photo_2k:true,owner_photo_input_bound:8193},{owner_photo_2k:true,owner_photo_input_bound:4.5},{owner_photo_2k:false,owner_photo_input_bound:4096}]){
  assertEquals(mediaAttemptQuote(step,{...prepared,extra}),null);assertEquals(ceilingVerifiedQuote(step,{...prepared,extra},null),null);
 }
 const unsupported={...step,params:{image_size:"4K"}};assertEquals(mediaAttemptQuote(unsupported,prepared),null);
 const lite={...step,model:"gemini-3.1-flash-lite-image"};assertEquals(ceilingVerifiedQuote(lite,prepared,null),null);
 assertThrows(()=>geminiImageGenerationConfig(lite.model,"2K"),ProviderError);
});

Deno.test("actual adapter captures2K body only after verified input and retains1K normal body",async()=>{
 const step=await ownerQaPhotoStep(args,db().client,NOW);assert(step);const prepared=prepareOwnerQaPhotoInput(input());
 const savedFetch=globalThis.fetch,savedKey=Deno.env.get("GEMINI_API_KEY");Deno.env.set("GEMINI_API_KEY","closed-fixture-never-valid");let bodies:Record<string,unknown>[]=[];
 globalThis.fetch=async(_url,init)=>{bodies.push(JSON.parse(String((init as {body?:BodyInit|null}|undefined)?.body)));return Response.json({candidates:[{content:{parts:[{inlineData:{mimeType:"image/jpeg",data:jpeg()}}]}}]});};
 try{
  for(const variant of [{step,input:prepared,size:"2K"},{step:{...step,params:null},input:input(),size:"1K"}]){
   const ref=await geminiAdapter.submit(variant.step,variant.input);assertEquals((bodies.at(-1)?.generationConfig as {imageConfig:unknown}).imageConfig,{imageSize:variant.size});
   assertEquals((bodies.at(-1)?.contents as {parts:{inline_data?:{data:string}}[]}[])[0].parts[1].inline_data?.data,prepared.image_b64);
   assertEquals((await geminiAdapter.poll(ref)).status,"done");
  }
  for(const bound of [undefined,0,-1,8193,1.5])await assertRejects(()=>geminiAdapter.submit(step,{...prepared,extra:{...prepared.extra,owner_photo_input_bound:bound}}),ProviderError);
  const unsupported:ChainStep={...step,params:{image_size:"4K"}};await assertRejects(()=>geminiAdapter.submit(unsupported,prepared),ProviderError);
  const lite={...step,model:"gemini-3.1-flash-lite-image"};await assertRejects(()=>geminiAdapter.submit(lite,prepared),ProviderError);
  assertEquals(bodies.length,2,"Invalid bound or4K dispatched a provider");
 }finally{globalThis.fetch=savedFetch;if(savedKey===undefined)Deno.env.delete("GEMINI_API_KEY");else Deno.env.set("GEMINI_API_KEY",savedKey);}
});

Deno.test("actual funded2K dispatch holds11.7184 cents before one POST and refusal sends none",async()=>{
 const step=await ownerQaPhotoStep(args,db().client,NOW);assert(step);const prepared=prepareOwnerQaPhotoInput(input());
 const savedFetch=globalThis.fetch;globalThis.fetch=async()=>Response.json("ceiling");resetServingModeCache();
 try{
  assertEquals(await servingMode(),"ceiling","Closed serving mode must enter actual ceiling path");
  for(const denied of [false,true]){
   const calls:{name:string;args:Record<string,unknown>}[]=[];let posts=0;
   const context:FundingContext={actorId:ACTOR,orgId:ORG,requestKey:"closed-2K-reserve",rpc:async(name,params)=>{calls.push({name,args:params});return {data:name==="serving_cost_reserve"?{reserved:true}:{finished:true},error:denied&&name==="serving_cost_reserve"?{message:"RP402: This attempt exceeds the shared funded serving allowance"}:null};}};
   const result=()=>fundedAttempt(context,"photo.custom:0",step,prepared,mediaAttemptQuote(step,prepared),async()=>{assertEquals(calls.at(-1)?.name,"serving_cost_reserve");posts++;return "closed image receipt";});
   if(denied)await assertRejects(result,HttpError);else assertEquals(await result(),"closed image receipt");
   assertEquals(posts,denied?0:1);const held=Number(calls[0].args.p_hold_cents);assert(held>=11.7184&&held<=11.7185,"Actual hold must cover complete2K cost before dispatch");
   if(!denied)assertEquals(calls.at(-1)?.args.p_state,"succeeded");
  }
 }finally{globalThis.fetch=savedFetch;resetServingModeCache();}
});

const encoded=(text:string)=>"data:application/typescript;base64,"+btoa(String.fromCharCode(...new TextEncoder().encode(text)));
const imports=(text:string,base=import.meta.url)=>text.replace(/from "(\.\.?\/[^\"]+)"/g,(_all,path)=>`from ${JSON.stringify(new URL(path,base).href)}`);
Deno.test("compiled owner2K guard removals are detected independently",async()=>{
 const source=await Deno.readTextFile(new URL("./owner-photo-qa.ts",import.meta.url));
 const changes:[string,string,()=>Promise<void>][]=[
  ['profile.data?.is_admin!==true','false',async()=>{const mutant=await import(encoded(imports(source.replace('profile.data?.is_admin!==true','false'))));assertEquals(await mutant.ownerQaPhotoStep(args,db({admin:false}).client,NOW),null,"fresh admin gate");}],
  ['grant.consent!==OWNER_PHOTO_QA_CONSENT','false',async()=>{const mutant=await import(encoded(imports(source.replace('grant.consent!==OWNER_PHOTO_QA_CONSENT','false'))));assertEquals(await mutant.ownerQaPhotoStep(args,db({value:{...grant,consent:"wrong"}}).client,NOW),null,"explicit consent gate");}],
  ['end<=now.getTime()','false',async()=>{const mutant=await import(encoded(imports(source.replace('end<=now.getTime()','false'))));assertEquals(await mutant.ownerQaPhotoStep(args,db({value:{...grant,expires_at:NOW.toISOString()}}).client,NOW),null,"expiry gate");}],
  ['canonical(grant.listing_id)!==listing','false',async()=>{const mutant=await import(encoded(imports(source.replace('canonical(grant.listing_id)!==listing','false'))));assertEquals(await mutant.ownerQaPhotoStep(args,db({value:{...grant,listing_id:OTHER}}).client,NOW),null,"exact listing gate");}],
  ['Math.max(image.width,image.height)>2048','false',async()=>{const mutant=await import(encoded(imports(source.replace('Math.max(image.width,image.height)>2048','false'))));assertThrows(()=>mutant.prepareOwnerQaPhotoInput(input({image_b64:jpeg(2049,1536)})),HttpError,"source geometry gate");}],
  ['tokenBound>8192','false',async()=>{const mutant=await import(encoded(imports(source.replace('tokenBound>8192','false'))));assertThrows(()=>mutant.prepareOwnerQaPhotoInput(input({prompt:"x".repeat(4097)})),HttpError,"input token gate");}],
  ['image.width*image.height<3_800_000','false',async()=>{const mutant=await import(encoded(imports(source.replace('image.width*image.height<3_800_000','false'))));assertThrows(()=>mutant.assertOwnerQaPhotoOutput(jpeg(1200,896),"image/jpeg"),HttpError,"output geometry gate");}],
  ['image.width*image.height>4_800_000','false',async()=>{const mutant=await import(encoded(imports(source.replace('image.width*image.height>4_800_000','false'))));assertThrows(()=>mutant.assertOwnerQaPhotoOutput(jpeg(4096,4096),"image/jpeg"),HttpError,"4K output tariff gate");}],
 ];
 for(const [anchor,_replacement,test] of changes){assertEquals(source.split(anchor).length-1,1,anchor);await assertRejects(test,Error);}
 console.log("OWNER_PHOTO_QA_COMPILED_CONTROLS=8");
});

Deno.test("compiled2K price under-reservations and lost payload resolution are detected",async()=>{
 const path=new URL("../_shared/funded-serving.ts",import.meta.url),source=await Deno.readTextFile(path),step=await ownerQaPhotoStep(args,db().client,NOW);assert(step);const prepared=prepareOwnerQaPhotoInput(input());
 const primary=source.replace("8192*0.5+4096*3+1680*60","8192*0.5+4096*3+1120*60");assert(primary!==source);
 const primaryModule=await import(encoded(imports(primary,path.href)));await assertRejects(async()=>assert(primaryModule.ceilingVerifiedQuote(step,prepared,null).cents>=11.7184,"No1K-priced hold for2K output"),Error);
 const secondary=source.replace("8192*.5+output*3+1680*60","8192*.5+output*3+1120*60");assert(secondary!==source);
 const secondaryModule=await import(encoded(imports(secondary,path.href)));await assertRejects(async()=>assertEquals(secondaryModule.mediaAttemptQuote(step,prepared).cents,11.7184),Error);
 const adapterPath=new URL("../_shared/providers/gemini.ts",import.meta.url),adapterSource=await Deno.readTextFile(adapterPath),lower=adapterSource.replace("{ imageSize }","{ imageSize: \"1K\" }");assert(lower!==adapterSource);
 const adapterModule=await import(encoded(imports(lower,adapterPath.href)));await assertRejects(async()=>assertEquals(adapterModule.geminiImageGenerationConfig(step.model,"2K").imageConfig,{imageSize:"2K"}),Error);
 console.log("OWNER_PHOTO_QA_PRICE_COMPILED_CONTROLS=3");
});

Deno.test("production owner2K route is single-step after normal admission and reauthorizes before priced dispatch",async()=>{
 const source=await Deno.readTextFile(new URL("./index.ts",import.meta.url));
 const override=source.indexOf("const ownerPhotoStep = await ownerQaPhotoStep(");assert(override>source.indexOf("await guardEdit("));
 const beforeBounded=source.slice(override,source.indexOf("chain = await boundedPhotoChain",override));assert(beforeBounded.includes("chain = [ownerPhotoStep]"));assert(beforeBounded.includes("prepareOwnerQaPhotoInput(genInput)"));
 const dispatch=source.indexOf("const ref = await fundedAttempt(",override),fresh=source.indexOf("const currentOrg = await requireEditorRole(",override);
 assert(fresh>override&&fresh<dispatch);assert(source.slice(fresh,dispatch).includes("currentOrg !== orgId"));assert(source.slice(fresh,dispatch).includes("await ownerQaPhotoStep("));
 const full=source.slice(override,dispatch);assert(!full.includes("body.image_size"));assert(!full.includes("body.owner_photo_2k"));
 const cost=source.indexOf("await recordRoutedAiCost(",dispatch),geometry=source.indexOf("assertOwnerQaPhotoOutput(",dispatch);assert(cost>dispatch&&geometry>cost,"Supplier cost must be bound before undersized output is withheld");
});
