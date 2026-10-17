// AI photo recipe identity (photo-recipe.ts). Closed: no network, no provider,
// no database; the RPC is a synthetic stub that records exactly what was sent.
import {assert,assertEquals,assertRejects,assertNotEquals} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {HttpError} from "../_shared/http.ts";
import {PHOTO_RECIPE_PATTERN,PHOTO_RECIPE_REVISION,photoPromptSha256,recordPhotoRecipe} from "./photo-recipe.ts";

const evidence="f8400000-0000-4000-8000-000000000001",actor="f8400000-0000-4000-8000-000000000002";
const row=()=>({evidence:{id:evidence,actor_id:actor},check:{id:"check"},can_continue:false}) as never;
function admin(reply:(args:Record<string,unknown>)=>unknown){
 const calls:{name:string;args:Record<string,unknown>}[]=[];
 return {calls,client:{rpc:async(name:string,args:Record<string,unknown>)=>{calls.push({name,args});return reply(args);}}};
}

// The revision bump is enforced: these sources define the final prompt text.
// Changing any of them without bumping PHOTO_RECIPE_REVISION (and this pin
// together with it) fails here. prompt_sha256 remains the exact identity of
// every generation either way.
const PINNED={revision:"photo-recipe/2026-10-17.1",fingerprint:"a029ccb161053ccdedf23e428607c7ceecc4991f4fb5efd139ded4e2e26c051c"};
const read=(path:string)=>Deno.readTextFile(new URL(path,import.meta.url));
function region(source:string,start:string,end:string,inclusiveEnd=false):string{
 const a=source.indexOf(start);assert(a>=0&&source.indexOf(start,a+1)<0,"Recipe region start must be unique: "+start);
 const b=source.indexOf(end,a+start.length);assert(b>a,"Recipe region end missing: "+end);
 return source.slice(a,inclusiveEnd?b+end.length:b);
}
async function recipeSources(index?:string):Promise<[string,string][]>{
 index??=await read("./index.ts");
 return [
  ["ai-photo/index.ts#profiles",region(index,"const PROFILES: Record<SpaceType, Profile> = {","\n};\n",true)],
  ["ai-photo/index.ts#locks-and-builders",region(index,"const CONDITION_LOCK =","\ninterface Body {")],
  ["ai-photo/index.ts#custom",region(index,"function customPrompt(","\nexport async function handleAIPhoto(")],
  ["ai-photo/index.ts#composition",region(index,"    let prompt: string;","prompt = `${prompt} ${guardrailsFor(edit)}`;",true)],
  ["_shared/fairhousing.ts#guardrails",region(await read("../_shared/fairhousing.ts"),"export const FAIR_HOUSING_LOCK =","\n// ── The denylist")],
  ["_shared/custom-photo-prompt.ts",await read("../_shared/custom-photo-prompt.ts")],
  ["_shared/photo-stage-prompt.ts",await read("../_shared/photo-stage-prompt.ts")],
  ["_shared/photo-declutter-prompt.ts",await read("../_shared/photo-declutter-prompt.ts")],
 ];
}
const fingerprint=async(parts:[string,string][])=>await photoPromptSha256(parts.map(([name,text])=>name+"\n"+text.length+"\n"+text).join("\n"));

Deno.test("recipe revision is bounded exactly like the SQL column check",async()=>{
 assert(PHOTO_RECIPE_PATTERN.test(PHOTO_RECIPE_REVISION));
 const migration=await read("../../migrations/20261017200000_photo_output_feedback.sql");
 assert(migration.includes("recipe_revision~'^[a-z0-9][a-z0-9./_-]{1,79}$'"),"SQL check and client pattern must agree");
 assertEquals(PHOTO_RECIPE_PATTERN.source,"^[a-z0-9][a-z0-9./_-]{1,79}$");
 for(const bad of ["","Photo-Recipe/1","x","-leading","photo recipe","a".repeat(81)])assert(!PHOTO_RECIPE_PATTERN.test(bad),bad);
});
Deno.test("prompt hash is SHA-256 of the exact UTF-8 prompt",async()=>{
 assertEquals(await photoPromptSha256("abc"),"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
 assertEquals(await photoPromptSha256("é"),"4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c","UTF-8 bytes c3 a9, not UTF-16 code units");
 assertNotEquals(await photoPromptSha256("Keep the doorway clear."),await photoPromptSha256("Keep the doorway clear. "),"A single trailing space is a different recipe");
});
Deno.test("recordPhotoRecipe sends the exact evidence, actor, revision and prompt hash",async()=>{
 const prompt="Convert this daytime exterior photo into a twilight shot. Keep the house identical.";
 const sha=await photoPromptSha256(prompt);
 const db=admin(args=>({data:{evidence_id:args.p_evidence,recipe_revision:args.p_revision,prompt_sha256:args.p_prompt_sha256,replay:false},error:null}));
 const receipt=await recordPhotoRecipe(db.client,row(),prompt);
 assertEquals(db.calls,[{name:"photo_quality_set_recipe",args:{p_actor:actor,p_evidence:evidence,p_revision:PHOTO_RECIPE_REVISION,p_prompt_sha256:sha}}]);
 assertEquals(receipt,{evidence_id:evidence,recipe_revision:PHOTO_RECIPE_REVISION,prompt_sha256:sha,replay:false});
});
Deno.test("any refusal, outage or mismatched receipt aborts with a no-dispatch 503",async()=>{
 const prompt="Remove the boxes only.";
 const replies:((args:Record<string,unknown>)=>unknown)[]=[
  ()=>({data:null,error:{message:"RP409: The photo recipe revision is immutable"}}),
  ()=>({data:null,error:{message:"RP404: Saved photo quality review is unavailable"}}),
  ()=>{throw new Error("socket closed");},
  args=>({data:{evidence_id:args.p_evidence,recipe_revision:"photo-recipe/older",prompt_sha256:args.p_prompt_sha256,replay:true},error:null}),
  args=>({data:{evidence_id:args.p_evidence,recipe_revision:args.p_revision,prompt_sha256:"0".repeat(64),replay:true},error:null}),
  args=>({data:{evidence_id:"f8400000-0000-4000-8000-000000000009",recipe_revision:args.p_revision,prompt_sha256:args.p_prompt_sha256,replay:false},error:null}),
  ()=>({data:null,error:null}),
 ];
 for(const reply of replies){
  const db=admin(reply);
  const error=await assertRejects(()=>recordPhotoRecipe(db.client,row(),prompt),HttpError);
  assertEquals(error.status,503);assertEquals(error.code,"upstream");assertEquals(error.details?.no_provider_dispatch,true);assertEquals(error.details?.failure_phase,"recipe_recording");
  assertEquals(db.calls.length,1);
 }
});
Deno.test("an empty prompt or unbounded revision is refused before any RPC",async()=>{
 for(const [prompt,revision] of [["",PHOTO_RECIPE_REVISION],["A prompt","Not A Revision"]] as const){
  const db=admin(()=>{throw new Error("must not be called");});
  const error=await assertRejects(()=>recordPhotoRecipe(db.client,row(),prompt,revision),HttpError);
  assertEquals(error.status,503);assertEquals(db.calls.length,0);
 }
});
Deno.test("the handler records the recipe after the evidence begins and before any provider dispatch",async()=>{
 const source=await read("./index.ts");
 const begin=source.indexOf("quality=await beginPhotoQuality("),record=source.indexOf("await recordPhotoRecipe(adminClient(),quality,genInput.prompt??\"\")"),
  chain=source.indexOf("attempt = await runChain(task, chain"),dispatch=source.indexOf("const ref = await fundedAttempt(funding, `${task}:${chain.indexOf(step)}`");
 assert(begin>0&&record>begin&&chain>record&&dispatch>chain,"begin < recipe < runChain < funded provider dispatch");
 const failure=source.slice(record,chain);
 for(const required of ["failPhotoQuality(adminClient(),quality,\"recipe_recording\"","no_provider_dispatch:true","await refundEditCharge(charge)","await abortFundingOperationBeforeDispatch(funding)","throw error"])assert(failure.includes(required),required);
 assert(!/genInput\.prompt\s*=|genInput\s*=\s*/.test(source.slice(record,source.indexOf("\nif(import.meta.main)"))),"The hashed prompt is never rewritten after it is recorded");
});
Deno.test("recipe sources match the pinned fingerprint for this revision",async()=>{
 const parts=await recipeSources();
 assertEquals(PHOTO_RECIPE_REVISION,PINNED.revision,"PHOTO_RECIPE_REVISION changed: update PINNED.fingerprint to the new sources in the same change");
 assertEquals(await fingerprint(parts),PINNED.fingerprint,"Photo prompt/guardrail/composition sources changed: bump PHOTO_RECIPE_REVISION in ai-photo/photo-recipe.ts and update PINNED in this test together");
});
Deno.test("the fingerprint is sensitive to a one-word prompt change in every region",async()=>{
 const index=await read("./index.ts");
 const base=await fingerprint(await recipeSources(index));
 for(const [anchor,changed] of [["photo: \"real-estate photo\",","photo: \"real-estate image\","],["Photorealistic, natural, consistent perspective and shadows.","Photorealistic and natural."],
  ["Stay photorealistic and true to the space","Stay realistic"],["FURNISHING BRIEF (quoted data for movable furniture only)","FURNISHING BRIEF"]]){
  assertEquals(index.split(anchor).length-1,1,anchor);
  assertNotEquals(await fingerprint(await recipeSources(index.replace(anchor,changed))),base,anchor);
 }
});
