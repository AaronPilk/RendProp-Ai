// Cross-language identity proof, Postgres -> Deno. fixtures/kie-property-identity-pg.json is
// the literal text Postgres 18 returned for
//   json_build_object('quality_identity', property_video_quality_identity('kie-kling3-4k-steady-v1'),
//                     'pinned_route', to_jsonb(<pinned ai_routes row>))
// (jsonb key order, unit_cents rendered 33.5000, timestamps normalised; the row is seeded
// enabled:false). It is regenerated from real Postgres, never written by hand. This test feeds
// that exact text to the SAME TypeScript checks dispatch runs: sameKiePropertyIdentity (the job's
// frozen identity), the pinned-row read the quote and the pre-hold read share
// (propertyVideoQualitySteps -> kiePropertyRouteStep, then reelFramingSteps and the catalog price)
// and samePinnedKieDispatch (the post-hold re-read). Offline: every reader is an in-process double.
import {assert,assertEquals,assertNotEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {KIE_PROPERTY_IDENTITY,KIE_PROPERTY_PROFILE,KIE_PROPERTY_ROUTE_ID,sameKiePropertyIdentity} from "../_shared/property-video-kie.ts";
import {kiePropertyExtra,kiePropertyPricedBasis,kiePropertyRouteStep,propertyVideoQualitySteps,samePinnedKieDispatch} from "./property-video-quality.ts";
import {reelFramingSteps} from "./reel-framing.ts";
import {ceilingVerifiedQuote,routeCatalogQuote} from "../_shared/funded-serving.ts";
import {paramsOf,type RouteStep} from "../_shared/router.ts";

const TEXT=await Deno.readTextFile(new URL("./fixtures/kie-property-identity-pg.json",import.meta.url));
const QUALITY_SOURCE=await Deno.readTextFile(new URL("./property-video-quality.ts",import.meta.url));
// deno-lint-ignore no-explicit-any
type Json=Record<string,any>;
/** A fresh parse of the literal Postgres text: key order exactly as Postgres rendered it. */
const pg=():{quality_identity:Json;pinned_route:Json}=>JSON.parse(TEXT);
/** The pinned row as activation leaves it: `enabled` flipped in place, every other field as seeded. */
const activated=()=>{const p=pg();p.pinned_route.enabled=true;return p;};
/** Postgres jsonb object key order: UTF-8 byte length, then bytewise. */
const byteOrder=(a:string,b:string)=>{const x=new TextEncoder().encode(a),y=new TextEncoder().encode(b);if(x.length!==y.length)return x.length-y.length;for(let i=0;i<x.length;i++)if(x[i]!==y[i])return x[i]-y[i];return 0;};
const jsonbOrdered=(value:unknown):boolean=>{
 if(Array.isArray(value))return value.every(jsonbOrdered);
 if(!value||typeof value!=="object")return true;
 const keys=Object.keys(value);return keys.every((key,i)=>i===0||byteOrder(keys[i-1],key)<0)&&Object.values(value).every(jsonbOrdered);
};
const NEVER=async():Promise<RouteStep[]>=>{throw new Error("the Kie profile never consults the route resolver");};
/** The step the quote (propertyVideoRecipeQuote) and dispatch both reserve from this pinned row. */
async function quoteStep(row:unknown):Promise<RouteStep>{
 const candidates=await propertyVideoQualitySteps("free",NEVER,KIE_PROPERTY_PROFILE,async id=>{assertEquals(id,KIE_PROPERTY_ROUTE_ID);return row;});
 return reelFramingSteps(candidates,"preserve_photo")[0];
}

Deno.test("the frozen identity Postgres returned is the canonical Kie identity (sameKiePropertyIdentity), in true jsonb key order",()=>{
 const p=pg();
 assertEquals(Object.keys(p),["quality_identity","pinned_route"]);
 assert(jsonbOrdered(p.quality_identity)&&jsonbOrdered(p.pinned_route),"Postgres jsonb key order at every level");
 assertEquals(Object.keys(p.quality_identity.prompt_template_sha256),["push_in","pull_back","side_glide","fly_through"]);
 // Not a copy of the code constant's text: an order-sensitive comparison would refuse it.
 assertNotEquals(JSON.stringify(p.quality_identity),JSON.stringify(KIE_PROPERTY_IDENTITY));
 assertEquals(Object.keys(p.quality_identity).sort(),Object.keys(KIE_PROPERTY_IDENTITY).sort());
 assert(sameKiePropertyIdentity(p.quality_identity),"the job's frozen identity exactly as Postgres returns it");
});

Deno.test("the pinned row Postgres returned (enabled flipped in place) passes the quote/pre-hold read, prices as the identity and passes samePinnedKieDispatch",async()=>{
 const seeded=pg();
 assertEquals(seeded.pinned_route.enabled,false,"seeded OFF until the owner-approved activation");
 assertEquals(kiePropertyRouteStep(seeded.pinned_route),null,"the seeded (disabled) row is never a dispatch step");
 const routeText=TEXT.slice(TEXT.indexOf('"pinned_route" :'));
 assert(/"unit_cents": 33\.5000[,}]/.test(routeText),"the numeric column exactly as Postgres renders it");
 const p=activated();
 assertEquals(Object.keys(p.pinned_route),Object.keys(seeded.pinned_route),"flipped in place: key order unchanged");
 assertEquals(JSON.stringify(p.pinned_route.params),'{"sound":false,"kie_mode":"4K"}',"route params in jsonb order (not the identity's order)");
 assertEquals(p.pinned_route.unit_cents,33.5);
 const step=await quoteStep(p.pinned_route);
 assertEquals(step as unknown,kiePropertyRouteStep(p.pinned_route));
 assertEquals([step.route_id,step.task,step.provider,step.model,step.unit,step.unit_cents,step.privacy_tier,step.enabled,paramsOf(step)],
  [KIE_PROPERTY_IDENTITY.route_id,"video.reel_clip","kie","kling-3.0/video","second",33.5,"trains_by_default",true,{kie_mode:"4K",sound:false}]);
 // The quote prices this step at exactly the identity's attempt (67 credits/s x 5 s).
 for(const aspect of["16:9","9:16"]as const){
  const input={task:"video.reel_clip",seconds:5,resolution:"1080p",aspect,framing:"preserve_photo",extra:kiePropertyExtra(aspect)};
  const catalog=routeCatalogQuote(step,input),verified=ceilingVerifiedQuote(step,input,catalog);
  assert(catalog&&verified,aspect);assertEquals(Math.max(catalog.cents,verified.cents),kiePropertyPricedBasis(1).attempt_cents,aspect);
 }
 // Post-hold re-read of the same row, with the job's identity as Postgres returns it.
 assert(samePinnedKieDispatch(p.pinned_route,step,p.quality_identity),"dispatch accepts the Postgres row and identity");
 // What PostgREST returns for the pinned read: only the selected columns, in select order.
 const columns=QUALITY_SOURCE.match(/PINNED_ROUTE_COLUMNS="([^"]+)"/)![1].split(", ");
 const projected=Object.fromEntries(columns.map(c=>[c,p.pinned_route[c]]));
 assertEquals(await quoteStep(projected),step);assert(samePinnedKieDispatch(projected,step,p.quality_identity));
 // The same numeric rendered as a JSON string is the same catalog price.
 const textual={...p.pinned_route,unit_cents:"33.5000"};
 assertEquals(await quoteStep(textual),step);assert(samePinnedKieDispatch(textual,step,p.quality_identity));
});

Deno.test("single-field mutations of what Postgres returned are refused by the same checks dispatch uses",async()=>{
 const base=activated(),step=await quoteStep(base.pinned_route);
 assert(samePinnedKieDispatch(base.pinned_route,step,base.quality_identity),"baseline");
 const flip=(hex:string)=>hex.slice(0,-1)+(hex.endsWith("0")?"1":"0");
 // The job's frozen identity.
 const identityMutations:[string,(q:Json)=>void][]=[
  ["nested prompt hash, one character",q=>{q.prompt_template_sha256.side_glide=flip(q.prompt_template_sha256.side_glide);}],
  ["unit_cents 33.6",q=>{q.unit_cents=33.6;}],
  ["privacy tier",q=>{q.privacy_tier="retained_30d";}],
  ["mode",q=>{q.mode="pro";}],
  ["route id",q=>{q.route_id="7f2c9a3e-4b1d-4e8a-9c55-1d6e0b7a4f22";}],
  ["extra key",q=>{q.extra=true;}],
 ];
 for(const[label,mutate]of identityMutations){
  const p=activated();mutate(p.quality_identity);
  assert(!sameKiePropertyIdentity(p.quality_identity),label);
  assert(!samePinnedKieDispatch(p.pinned_route,step,p.quality_identity),label+": refused at dispatch");
 }
 // The pinned route row. beforeHold: the quote and the pre-hold read already refuse it.
 const rowMutations:[string,(r:Json)=>void,boolean][]=[
  ["params key renamed",r=>{r.params={sound:false,kie_mod:"4K"};},true],
  ["params extra key",r=>{r.params={...r.params,aspect_ratio:"16:9"};},true],
  ["params mode",r=>{r.params={...r.params,kie_mode:"pro"};},true],
  ["unit_cents 33.6",r=>{r.unit_cents=33.6;},true],
  ["unit_cents 33.6 as Postgres renders it",r=>{r.unit_cents="33.6000";},true],
  ["enabled false (the seeded row)",r=>{r.enabled=false;},true],
  ["privacy tier",r=>{r.privacy_tier="retained_30d";},true],
  ["retire_after set in the past",r=>{r.retire_after="2026-01-01";},true],
  ["model",r=>{r.model="kling-3.0/pro";},true],
  ["task",r=>{r.task="video.property_reel_clip";},true],
  // A future retirement date is a live row for the pre-hold read (the SQL rule), but it is
  // not the reserved step: the post-hold comparison refuses it.
  ["retire_after set in the future",r=>{r.retire_after="2099-12-31";},false],
  ["capabilities",r=>{r.capabilities=r.capabilities.filter((c:string)=>c!=="native4k");},false],
 ];
 for(const[label,mutate,beforeHold]of rowMutations){
  const p=activated();mutate(p.pinned_route);
  assert(!samePinnedKieDispatch(p.pinned_route,step,p.quality_identity),label+": refused at dispatch");
  if(beforeHold){
   assertEquals(kiePropertyRouteStep(p.pinned_route),null,label);
   await assertRejects(()=>quoteStep(p.pinned_route),Error,undefined,label+": refused by the quote and the pre-hold read");
  }else assertNotEquals(await quoteStep(p.pinned_route),step,label+": a different row is a different reserved step");
 }
});
