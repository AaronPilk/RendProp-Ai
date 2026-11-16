import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
for(const[k,v]of Object.entries({SUPABASE_URL:"https://disclosure-fixture.invalid",SUPABASE_SERVICE_ROLE_KEY:"fixture-service",SUPABASE_ANON_KEY:"fixture-anon"}))Deno.env.set(k,v);
const {disclosureFallback,publicProvenanceDisclosure}=await import("./provenance.ts");
Deno.test("current photo disclosures identify AI and request original comparison without geometry guarantees",()=>{
 for(const [kind,edit]of [["virtual_stage",null],["declutter",null],["photo_edit","sky"],["photo_edit","twilight"],["photo_edit","lawn"],["photo_edit","custom"]]as const){
  const text=disclosureFallback(kind,edit);assert(text.includes("AI"));assert(text.includes("Compare with the original"));assert(!text.includes("unchanged"));
  assertEquals(publicProvenanceDisclosure(kind,edit,"Historical geometry guarantee"),text);
 }
});
Deno.test("current presentation leaves stored historical records and video disclosures intact",()=>{
 const row={kind:"virtual_stage",edit:"stage",disclosure:"Historical sentence remains in the private audit"};
 const prior={...row};publicProvenanceDisclosure(row.kind,row.edit,row.disclosure);assertEquals(row,prior);
 for(const kind of ["aerial","reel","video_reflection_removal","other"]){
  assertEquals(publicProvenanceDisclosure(kind,null,"Existing video disclosure"),"Existing video disclosure");
 }
});
