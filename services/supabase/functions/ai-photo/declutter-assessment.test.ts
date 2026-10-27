import{assertEquals,assert,assertRejects,AssertionError}from"https://deno.land/std@0.224.0/assert/mod.ts";
import{parseDeclutterAssessment,DECLUTTER_ASSESSMENT_INSTRUCTION,DECLUTTER_ASSESSMENT_PROTOCOL}from"./declutter-assessment.ts";
import{photoHelperPayload,photoHelperQuote}from"./helper-policy.ts";
const needed={decision:"needed",confidence:.95,reason:"Loose papers are visible on the table.",targets:["papers"]};
Deno.test("declutter assessment accepts only confident explicit removable targets or confident clear photos",()=>{
 assertEquals(parseDeclutterAssessment(needed),needed);
 assertEquals(parseDeclutterAssessment({...needed,decision:"unnecessary",targets:[]}).decision,"unnecessary");
 for(const value of[undefined,null,{},[],{...needed,confidence:.849},{...needed,targets:[]},{...needed,targets:["door"]},{...needed,targets:["furniture"]},{...needed,targets:["papers","papers"]},{...needed,targets:Array(7).fill("papers")},{...needed,decision:"unnecessary"},{...needed,confidence:NaN},{...needed,confidence:1.01},{...needed,confidence:"0.95"},{...needed,reason:""},{...needed,reason:"a".repeat(161)},{...needed,reason:"hidden\ncontrol"},{...needed,reason:"hidden\u200bcontrol"},{...needed,extra:true},{...needed,decision:"yes"}]){
  assertEquals(parseDeclutterAssessment(value).decision,"uncertain",JSON.stringify(value));
 }
});
Deno.test("declutter parser compiled behavioral controls fail the unchanged uncertain-default oracle",async()=>{
 const source=await Deno.readTextFile(new URL("./declutter-assessment.ts",import.meta.url));
 async function oracle(parse:typeof parseDeclutterAssessment){
  assertEquals(parse(needed).decision,"needed");
  for(const bad of[{...needed,confidence:.6},{...needed,targets:[]},{...needed,targets:["door"]},{...needed,extra:true},{...needed,confidence:NaN},{...needed,targets:["papers","papers"]},{...needed,reason:"hidden\u200bcontrol"}])assertEquals(parse(bad).decision,"uncertain");
 }
 await oracle(parseDeclutterAssessment);
 for(const [name,old,replacement]of[
  ["low-confidence","v.confidence<.85","v.confidence<0"],
  ["missing-visible-target",'v.decision==="needed"&&v.targets.length===0',"false"],
  ["protected-door",'(DECLUTTER_TARGETS as readonly string[]).includes(t)',"true"],
  ["ambiguous-fields",'Object.keys(value).sort().join(",")!=="confidence,decision,reason,targets"',"false"],
  ["non-finite-confidence","!Number.isFinite(v.confidence)||",""],
  ["duplicate-targets","new Set(v.targets).size!==v.targets.length||",""],
  ["invisible-controls",String.raw`/[\p{Cc}\p{Cf}]/u.test(v.reason)`,"false"],
 ]){
  assertEquals(source.split(old).length-1,1,name+" exact mutation anchor");
  const compiled=await import("data:application/typescript;base64,"+btoa(source.replace(old,replacement)));
  await assertRejects(()=>oracle(compiled.parseDeclutterAssessment),AssertionError,undefined);
 }
});
Deno.test("declutter review reuses complete bounded Flash helper payload and exact1024 cap",()=>{
 const payload=photoHelperPayload([{text:DECLUTTER_ASSESSMENT_INSTRUCTION},{inline_data:{mime_type:"image/jpeg",data:"synthetic"}}]);
 assertEquals(payload.generationConfig,{candidateCount:1,maxOutputTokens:1024,temperature:.4,responseMimeType:"application/json"});
 assertEquals(DECLUTTER_ASSESSMENT_PROTOCOL,"declutter-assessment-v1");assert(DECLUTTER_ASSESSMENT_INSTRUCTION.includes("Doors"));
 assert(photoHelperQuote("gemini-3.6-flash",payload)?.cents!>0);assertEquals(photoHelperQuote("different-model",payload),null);
 assertEquals(photoHelperQuote("gemini-3.6-flash",{...payload,generationConfig:{...payload.generationConfig,maxOutputTokens:2048}}),null);
});
