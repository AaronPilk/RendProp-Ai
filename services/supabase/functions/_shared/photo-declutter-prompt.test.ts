import {assert,assertEquals,assertThrows}from"https://deno.land/std@0.224.0/assert/mod.ts";
import {buildRealEstateDeclutterPrompt}from"./photo-declutter-prompt.ts";
import {preparePhoto4KInput}from"../ai-photo/photo-quality.ts";
import {prepareOwnerQaPhotoPro4KInput}from"../ai-photo/owner-photo-qa.ts";
import {mediaAttemptQuote,inputHash}from"./funded-serving.ts";

function existingLocks(source:string){
 const begin=source.indexOf("const CONDITION_LOCK ="),end=source.indexOf("\n/**\n * The photographer",begin),ref=source.indexOf("const REFLECTION_CLAUSE ="),refEnd=source.indexOf("\n// Real-estate-only prompt set.",ref);
 assert(begin>0&&end>begin&&ref>0&&refEnd>ref);
 const custom='Keep every original paint color and property condition unchanged.';
 return new Function("CUSTOM_PHOTO_FIXED_FEATURES",source.slice(begin,end)+source.slice(ref,refEnd)+";return{LOCK,REFLECTION_CLAUSE};")(custom)as{LOCK:string;REFLECTION_CLAUSE:string};
}
const jpeg=()=>btoa(String.fromCharCode(...[255,216,255,192,0,11,8,8,0,6,0,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]));
Deno.test("real-estate removal prompt retains exact existing locks/reflection clause and a fully priced source",async()=>{
 const source=await Deno.readTextFile(new URL("../ai-photo/index.ts",import.meta.url)),locks=existingLocks(source),prompt=buildRealEstateDeclutterPrompt(locks.LOCK,locks.REFLECTION_CLAUSE);
 assert(prompt.includes(locks.LOCK));assert(prompt.includes(locks.REFLECTION_CLAUSE));assert(new TextEncoder().encode(prompt).byteLength<8192);
 const image=jpeg(),input={task:"photo.declutter",prompt,image_b64:image,extra:{image_mime:"image/jpeg"}},prepared=prepareOwnerQaPhotoPro4KInput(input),flash=preparePhoto4KInput(input);
 assertEquals(prepared.image_b64,image);assertEquals(flash.image_b64,image);assertEquals(prepared.prompt,prompt);
 const step:any={provider:"gemini",model:"gemini-3-pro-image",params:{image_size:"4K"}};
 const expected=(Number(prepared.extra?.photo_input_allowance)*2+4096*12+2000*120)/10000;
 assertEquals(mediaAttemptQuote(step,prepared)?.cents,expected);
 assert(await inputHash(prepared)!==await inputHash({...prepared,prompt:"Remove all personal items and keep decor identical."}),"The actual new removal instructions enter paid-attempt identity; old operation receipts are not rewritten");
});
Deno.test("bounded remove-only instructions preserve uncertainty, local continuation and furniture rather than request staging",()=>{
 const prompt=buildRealEstateDeclutterPrompt("EXACT property lock. ","EXACT reflection protection. ");
 for(const required of["REMOVE-ONLY cleanup","DO NOT ADD ANY OBJECT","no new mirror, shelf, lamp, light, plant, furniture","If an object's purpose or whether it is clutter is uncertain, leave it unchanged","Keep existing furniture and intentional decor","only the small image areas directly occupied","leave the original object and area unchanged","No crop, zoom, wider view","wall-mounted, ceiling-mounted and built-in"]){assert(prompt.includes(required),required);}
 for(const args of[["","reflection"],["lock",""],[null,"reflection"],["x".repeat(6001),"reflection"]])assertThrows(()=>buildRealEstateDeclutterPrompt(...args as[string,string]));
 assert(!/855|Central Ave|standing mirror|specific room|named owner/i.test(prompt),"No tested-property information is hardcoded");
});
