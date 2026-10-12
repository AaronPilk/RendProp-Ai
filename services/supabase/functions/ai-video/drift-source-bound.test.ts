import { assert, assertEquals, assertRejects, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import { validatePhotoInput } from "../ai-photo/input-policy.ts";
import { DRIFT_SOURCE_EXTRA_INPUT_TOKENS, MAX_DRIFT_FRAME_B64_CHARS, MAX_DRIFT_REQUEST_BODY_BYTES, MAX_DRIFT_SOURCE_B64_CHARS, validateExtendedReelSource } from "./drift-input.ts";

// Closed, procedural media only. No production key or external transport.
for (const key of ["SUPABASE_SECRET_KEYS", "RENDPROP_SECRET_KEY_NAME", "SUPABASE_PUBLISHABLE_KEYS", "RENDPROP_PUBLISHABLE_KEY_NAME"]) Deno.env.delete(key);
Deno.env.set("SUPABASE_URL", "https://closed-fixture.invalid");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "closed-fixture-not-valid");
Deno.env.set("SUPABASE_ANON_KEY", "closed-fixture-not-valid");
const { visionInputTokenBound, textAttemptQuote } = await import("../_shared/funded-serving.ts");
const index = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
const helper = await Deno.readTextFile(new URL("./drift-input.ts", import.meta.url));
const bytes = await Deno.readFile(new URL("./fixtures/reel-source-2048-q95.jpg", import.meta.url));
function encode(data: Uint8Array): string { let s = ""; for (let i = 0; i < data.length; i += 32768) s += String.fromCharCode(...data.subarray(i, i + 32768)); return btoa(s); }
const sourceB64 = encode(bytes);
const sha = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), b => b.toString(16).padStart(2, "0")).join("");
function body(name: string, text = index): string {
  const start = new RegExp(`(?:export )?(?:async )?function ${name}\\(`).exec(text); assert(start, `${name} actual anchor missing`);
  const end = text.indexOf("\n}\n", start.index); assert(end > start.index);
  return text.slice(start.index, end + 3).replace(/^export /, "");
}
function constant(name: string, text = index): string { const v = text.match(new RegExp(`const ${name}[^;]*;`)); assert(v, `${name} actual constant missing`); return v[0]; }
function change(text: string, before: string, after: string): string { assertEquals(text.split(before).length, 2, "Mutation anchor must be unique"); return text.replace(before, after); }
function moduleURL(text: string): string { return "data:application/typescript;base64," + encode(new TextEncoder().encode(text)); }
function imports(text: string): string { return text.replace(/from "(\.[^"]+)"/g, (_m, path) => `from ${JSON.stringify(new URL(path, new URL("./drift-input.ts", import.meta.url)).href)}`); }
function dimensions(width: number, height = 2048): string {
  const data = bytes.slice(); let i = 2;
  while (i < data.length) { assertEquals(data[i++], 255); while (data[i] === 255) i++; const marker = data[i++]; const length = data[i] * 256 + data[i + 1]; if ([192,193,194].includes(marker)) { data[i+3]=height>>8;data[i+4]=height&255;data[i+5]=width>>8;data[i+6]=width&255;return encode(data); } i += length; }
  throw new Error("Actual JPEG SOF missing");
}
const malformed = "!" + sourceB64.slice(1);
const oversized = "A".repeat(MAX_DRIFT_SOURCE_B64_CHARS + 4);
type Mutation = "old-source-cap" | "enlarge-frame" | "drop-source-validation" | "drop-geometry" | "drop-complete-image" | "drop-generation-preflight" | "old-body-cap" | "drop-source-token-bound";
async function compiled(mutation?: Mutation) {
  let h = helper, image = body("requireDriftImage"), cap = constant("MAX_DRIFT_BODY_BYTES");
  const start = index.indexOf('    if (req.method === "POST" && seg.length === 1 && seg[0] === "reel-clip")');
  const finish = index.indexOf("      const { orgId, plan } = charge;", start); assert(start > 0 && finish > start);
  let generation = index.slice(start, finish + "      const { orgId, plan } = charge;".length);
  const tokenStatement = /const judgeInputTokens = visionInputTokenBound\([\s\S]*?;/g.exec(body("judgeDrift")); assert(tokenStatement);
  let token = tokenStatement[0];
  if (mutation === "old-source-cap") image = change(image, 'field === "source_b64" ? MAX_DRIFT_SOURCE_B64_CHARS : MAX_DRIFT_IMAGE_B64_CHARS', "MAX_DRIFT_IMAGE_B64_CHARS");
  if (mutation === "enlarge-frame") image = change(image, 'field === "source_b64" ? MAX_DRIFT_SOURCE_B64_CHARS : MAX_DRIFT_IMAGE_B64_CHARS', "MAX_DRIFT_SOURCE_B64_CHARS");
  if (mutation === "drop-source-validation") image = change(image, 'if (field === "source_b64") validateExtendedReelSource(s, m);', "");
  if (mutation === "drop-geometry") h = change(h, "Math.max(image.width, image.height) > 2048", "Math.max(image.width, image.height) > 8192");
  if (mutation === "drop-complete-image") h = change(h, "const image = validatePhotoInput(b64, mime);", "const image = {width:2048,height:2048};");
  if (mutation === "drop-generation-preflight") generation = change(generation, "validateExtendedReelSource(body.image_b64, mime);", "");
  if (mutation === "old-body-cap") cap = "const MAX_DRIFT_BODY_BYTES = 8_000_000;";
  if (mutation === "drop-source-token-bound") token = change(token, "+ DRIFT_SOURCE_EXTRA_INPUT_TOKENS", "+ 0");
  const hmod = await import(moduleURL(imports(h)));
  const driftBody = index.slice(index.indexOf('    if (req.method === "POST" && seg.length === 1 && seg[0] === "drift")'));
  const read = /const body = await readJsonLimited<DriftBody>\(req, MAX_DRIFT_BODY_BYTES\);/.exec(driftBody); assert(read);
  return { hmod, m: await import(moduleURL(`
    import {assert,readJson,readJsonLimited} from ${JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)};
    import {visionInputTokenBound} from ${JSON.stringify(new URL("../_shared/funded-serving.ts", import.meta.url).href)};
    import {normalizeRoom,parseReelMotion,chooseReelMotion,REEL_MOTIONS,REEL_PRESETS,buildSeedanceReelPreset,buildReelPrompt,type ReelMotion} from ${JSON.stringify(new URL("./motion.ts", import.meta.url).href)};
    import {MAX_DRIFT_FRAME_B64_CHARS,MAX_DRIFT_REQUEST_BODY_BYTES,MAX_DRIFT_SOURCE_B64_CHARS,DRIFT_SOURCE_EXTRA_INPUT_TOKENS,validateExtendedReelSource} from ${JSON.stringify(moduleURL(imports(h)))};
    type DriftImage={b64:string;mime:string};type DriftBody=Record<string,any>;type ReelBody=Record<string,any>;
    ${constant("MAX_DRIFT_IMAGE_B64_CHARS")} ${cap} ${constant("ALLOWED_IMAGE_MIMES")} ${constant("MAX_IMAGE_B64_CHARS")}
    ${image}
    export {requireDriftImage};
    export async function parseBody(req:Request){${read[0]}return body;}
    export function tokens(frameCount:number,rubric:string){const args={frames:new Array(frameCount)};${token}return judgeInputTokens;}
    export async function preflight(req:Request,deps:any){const seg=["reel-clip"],db={},user={id:"fixture-actor"};
      const guardGenerate=deps.admit,resolvePublicAsset=async()=>{throw Error("Asset path outside inline-source fixture");};
      const spaceTypeOf=()=>"real_estate",cleanPrompt=()=>null,SCENE_NOUN={real_estate:"home"};
      const assertVideoReceiptSigningReady=async()=>{},listingSpaceType=async()=>"real_estate",assertFairHousing=()=>{},guardedUserPrompt=()=>"";
      ${generation} return charge; } throw Error("No actual reel route");}
  `)) };
}

Deno.test("actual UIKit2048/q95 source exceeds old2M bound and survives complete-image admission unchanged", () => {
  assertEquals(bytes.length, 2976887); assertEquals(sourceB64.length, 3969184); assert(sourceB64.length > MAX_DRIFT_FRAME_B64_CHARS);
  assertEquals(sha,"7af4b59fa802e07cab9bd2f6e0af5f5ba377e5de0a2d397a15bece37604e24cc");
  assertEquals(validatePhotoInput(sourceB64,"image/jpeg"), {mime:"image/jpeg",bytes:2976887,width:1152,height:2048});
  assertEquals(MAX_DRIFT_FRAME_B64_CHARS,2_000_000);assertEquals(MAX_DRIFT_SOURCE_B64_CHARS,12_000_000);assertEquals(MAX_DRIFT_REQUEST_BODY_BYTES,19_000_000);assertEquals(DRIFT_SOURCE_EXTRA_INPUT_TOKENS,2048);
  validateExtendedReelSource(sourceB64,"image/jpeg");assertEquals(encode(bytes),sourceB64);
  for (const value of [malformed,sourceB64.slice(0,-4),dimensions(2049),oversized]) assertThrows(()=>validateExtendedReelSource(value,"image/jpeg"),HttpError);
  validateExtendedReelSource(btoa("legacy compact source contract"),"image/jpeg");
  console.log(`DRIFT_SOURCE_JPEG_SHA256=${sha}`);
});

Deno.test("actual QC source and body accept high detail while frame ceiling remains2M",async()=>{
  const {m}=await compiled();assertEquals(m.requireDriftImage(sourceB64,"image/jpeg","source_b64"),{b64:sourceB64,mime:"image/jpeg"});
  for(const value of [malformed,dimensions(2049),oversized])assertThrows(()=>m.requireDriftImage(value,"image/jpeg","source_b64"),HttpError);
  assertThrows(()=>m.requireDriftImage(sourceB64,"image/jpeg","frames[0].b64"),HttpError);
  assertEquals(m.requireDriftImage("A".repeat(2_000_000),"image/jpeg","frames[0].b64").b64.length,2_000_000);
  const payload={source_b64:sourceB64,frames:["first","middle","last"].map(at=>({at,b64:"A".repeat(2_000_000),mime:"image/jpeg"}))};
  const encoded=JSON.stringify(payload);assert(encoded.length>8_000_000&&encoded.length<19_000_000);
  assertEquals((await m.parseBody(new Request("https://closed.invalid/drift",{method:"POST",body:encoded}))).source_b64,sourceB64);
  await assertRejects(()=>m.parseBody(new Request("https://closed.invalid/drift",{method:"POST",body:" ".repeat(19_000_001)})),HttpError);
});

Deno.test("actual reel preflight refuses malformed or over2048 source before paid admission",async()=>{
  const {m}=await compiled();let admissions=0;const deps={admit:async()=>{admissions++;return{orgId:"fixture-org",plan:"pro"};}};
  const req=(image_b64:string)=>new Request("https://closed.invalid/reel-clip",{method:"POST",body:JSON.stringify({image_b64,mime:"image/jpeg",listing_id:"fixture-listing",seconds:5})});
  for(const value of [malformed,dimensions(2049),oversized])await assertRejects(()=>m.preflight(req(value),deps),HttpError);
  assertEquals(admissions,0);await m.preflight(req(sourceB64),deps);assertEquals(admissions,1);
});

Deno.test("actual judge input and tariff reserve4096source tokens for both judge attempts",async()=>{
  const {m}=await compiled(),rubric="Keep the photographed property intact.";
  for(const count of [1,2,3]){
    const before=visionInputTokenBound(1+count,new TextEncoder().encode(rubric).byteLength),after=m.tokens(count,rubric);assertEquals(after-before,2048);
    const step={provider:"gemini",model:"gemini-3.1-flash-lite",unit_cents:1,min_plan:"free",enabled:true,params:null,role:"primary",seq:1};
    const quote=textAttemptQuote(step as any,rubric,"",400,true,after),old=textAttemptQuote(step as any,rubric,"",400,true,before);assert(quote&&old);assert(Math.abs(quote.cents-old.cents-0.0512)<1e-9);
  }
  assertEquals((body("judgeDrift").match(/textAttemptQuote\([^\n]*judgeInputTokens\)/g)||[]).length,2,"Both actual initial and escalation calls use the enlarged input bound");
});

Deno.test("compiled source-bound controls reproduce old rejection and lost admission/cost fences",async()=>{
  const cases: [Mutation,(v:Awaited<ReturnType<typeof compiled>>)=>Promise<void>|void][]=[
    ["old-source-cap",({m})=>{m.requireDriftImage(sourceB64,"image/jpeg","source_b64");}],
    ["enlarge-frame",({m})=>{assertThrows(()=>m.requireDriftImage(sourceB64,"image/jpeg","frames[0].b64"),HttpError);}],
    ["drop-source-validation",({m})=>{assertThrows(()=>m.requireDriftImage(malformed,"image/jpeg","source_b64"),HttpError);}],
    ["drop-geometry",({hmod})=>{assertThrows(()=>hmod.validateExtendedReelSource(dimensions(2049),"image/jpeg"),HttpError);}],
    ["drop-complete-image",({hmod})=>{assertThrows(()=>hmod.validateExtendedReelSource(malformed,"image/jpeg"),HttpError);}],
    ["drop-generation-preflight",async({m})=>{let count=0;try{await m.preflight(new Request("https://closed.invalid/reel-clip",{method:"POST",body:JSON.stringify({image_b64:malformed})}),{admit:async()=>{count++;return{orgId:"x",plan:"pro"};}});}catch{}assertEquals(count,0);}],
    ["old-body-cap",async({m})=>{await m.parseBody(new Request("https://closed.invalid/drift",{method:"POST",body:JSON.stringify({source_b64:sourceB64,frames:[0,1,2].map(()=>({b64:"A".repeat(2_000_000)}))})}));}],
    ["drop-source-token-bound",({m})=>{assertEquals(m.tokens(3,"rubric")-visionInputTokenBound(4,6),2048);}],
  ];
  for(const [mutation,oracle]of cases){const v=await compiled(mutation);let failed=false;try{await oracle(v);}catch{failed=true;}assert(failed,`${mutation} escaped the unchanged positive oracle`);}
  console.log(`DRIFT_SOURCE_BOUND_COMPILED_CONTROLS=${cases.length}`);
});
