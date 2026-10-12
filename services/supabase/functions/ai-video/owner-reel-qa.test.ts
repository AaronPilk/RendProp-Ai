import { assert, assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { HttpError } from "../_shared/http.ts";
import { paramsOf, type RouteStep } from "../_shared/router.ts";
import { ownerQaReelStep, prepareOwnerQaReelInput, OWNER_REEL_QA_KEY, KIE_REEL_QA_MODEL, OWNER_REEL_QA_CONSENT, KIE_KLING_REEL_QA_MODEL } from "./owner-reel-qa.ts";
import { ProviderError } from "../_shared/providers/common.ts";
import type { GenerateInput } from "../_shared/providers/types.ts";
import { submitReservedVideo } from "./cost-reservation.ts";

// The actual server helper and priced dispatch are imported. The extracted
// routing fragment is production text; only DB, authentication and provider
// boundaries are closed fixtures. No network or real account is exercised.
const ACTOR = "11111111-1111-4111-8111-111111111111";
const ORG = "22222222-2222-4222-8222-222222222222";
const LISTING = "33333333-3333-4333-8333-333333333333";
const OTHER = "44444444-4444-4444-8444-444444444444";
// Hex letters make Foundation uppercase vs Postgres lowercase observable.
const HEX_ACTOR = "aabbccdd-a1b2-4c3d-8e9f-001122aabbcc";
const HEX_ORG = "bbccddee-b2c3-4d4e-9f0a-112233bbccdd";
const HEX_LISTING = "ccddeeaa-c3d4-4e5f-8a0b-223344ccdde0";
const HEX_OTHER = "ddeeaabb-d4e5-4f6a-9b0c-334455ddeea0";
const NOW = new Date("2026-10-12T20:00:00.000Z");
const args = { actorId: ACTOR, orgId: ORG, listingId: LISTING, seconds: 5 };
const grant = {
  enabled: true, actor_id: ACTOR, org_id: ORG, listing_id: LISTING,
  provider: "kie", model: KIE_REEL_QA_MODEL, consent: OWNER_REEL_QA_CONSENT,
  changed_by: ACTOR, created_at: "2026-10-12T19:00:00.000Z",
  expires_at: "2026-10-12T21:00:00.000Z",
};
type DBOptions = { value?: unknown; admin?: unknown; configError?: boolean; adminError?: boolean };
function db(options: DBOptions = {}) {
  const calls: Array<{ table: string; select: string; key: string; value: unknown }> = [];
  const client = {
    from(table: string) {
      const call = { table, select: "", key: "", value: undefined as unknown };
      calls.push(call);
      return {
        select(columns: string) { call.select = columns; return this; },
        eq(key: string, value: unknown) { call.key = key; call.value = value; return this; },
        maybeSingle() {
          if (table === "app_config") return Promise.resolve({
            data: { value: "value" in options ? options.value : { ...grant } },
            error: options.configError ? { message: "synthetic unavailable" } : null,
          });
          assertEquals(table, "profiles", "Unexpected DB boundary");
          return Promise.resolve({ data: { is_admin: "admin" in options ? options.admin : true },
            error: options.adminError ? { message: "synthetic unavailable" } : null });
        },
      };
    },
  };
  return { client: client as unknown as NonNullable<Parameters<typeof ownerQaReelStep>[1]>, calls };
}

Deno.test("owner reel QA accepts only its exact current server grant and fresh administrator", async () => {
  const f = db(); const route = await ownerQaReelStep(args, f.client, NOW);
  assert(route);
  assertEquals([route.provider, route.model, route.unit, route.unit_cents, route.task],
    ["kie", KIE_REEL_QA_MODEL, "second", 3.6, "video.reel_clip"]);
  assertEquals(route.capabilities, ["i2v", "1080p", "5s"]);
  assertEquals(route.privacy_tier, "trains_by_default");
  assertEquals(f.calls, [
    { table: "app_config", select: "value", key: "key", value: OWNER_REEL_QA_KEY },
    { table: "profiles", select: "is_admin", key: "id", value: ACTOR },
  ]);
});

Deno.test("owner reel QA fails closed for malformed identity, duration, grant, consent and clock", async () => {
  const requestChanges = [{ actorId: "not-an-actor" }, { orgId: "not-an-org" },
    { listingId: null }, { listingId: "invalid" }, { seconds: 6 }, { seconds: 0 }, { seconds: NaN }];
  for (const change of requestChanges) {
    const f = db(); assertEquals(await ownerQaReelStep({ ...args, ...change }, f.client, NOW), null);
    assertEquals(f.calls.length, 0, "Invalid request reached grant DB");
  }
  const changes: Array<Record<string, unknown>> = [
    { enabled: false }, { enabled: "true" }, { actor_id: OTHER }, { org_id: OTHER },
    { listing_id: OTHER }, { provider: "fal" }, { model: "arbitrary/model" },
    { consent: null }, { consent: "request-body-consent" }, { changed_by: OTHER },
    { created_at: null }, { created_at: "bad-date" }, { expires_at: "bad-date" },
    { created_at: "2026-10-12T20:00:00.001Z" }, { expires_at: NOW.toISOString() },
    { expires_at: "2026-10-12T18:00:00.000Z" },
    { created_at: "2026-10-11T19:00:00.000Z", expires_at: "2026-10-12T21:00:00.000Z" },
  ];
  for (const change of changes) {
    const f = db({ value: { ...grant, ...change } });
    assertEquals(await ownerQaReelStep(args, f.client, NOW), null, JSON.stringify(change));
    assertEquals(f.calls.length, 1, "Invalid grant reached fresh admin query");
  }
  for (const value of [null, [], "enabled", true]) {
    assertEquals(await ownerQaReelStep(args, db({ value }).client, NOW), null);
  }
  for (const admin of [false, null, "true", 1]) {
    assertEquals(await ownerQaReelStep(args, db({ admin }).client, NOW), null);
  }
  for (const options of [{ configError: true }, { adminError: true }]) {
    assertEquals(await ownerQaReelStep(args, db(options).client, NOW), null);
  }
  assertEquals(await ownerQaReelStep(args, db().client, new Date(NaN)), null);
  const boundary = { ...grant, created_at: NOW.toISOString(), expires_at: "2026-10-13T20:00:00.000Z" };
  assert(await ownerQaReelStep(args, db({ value: boundary }).client, NOW), "Exact 24h grant at opening must work");
});

const encode = (text: string) => "data:application/typescript;base64," +
  btoa(String.fromCharCode(...new TextEncoder().encode(text)));
const absoluteImports = (text: string) => text.replace(/from "(\.\.?\/[^\"]+)"/g,
  (_all, path) => `from ${JSON.stringify(new URL(path, import.meta.url).href)}`);
async function routingFixture() {
  const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  const reel = source.indexOf('seg[0] === "reel-clip"');
  const start = source.indexOf("      await assertVideoReceiptSigningReady();", reel);
  const end = source.indexOf("      const genInput:", start);
  assert(reel > 0 && start > reel && end > start, "Production reel routing anchors changed");
  const fragment = source.slice(start, end);
  assert(fragment.includes('const charge = await guardGenerate(user, req, "reel"'));
  assert(fragment.indexOf("guardGenerate(") < fragment.indexOf("ownerQaReelStep("));
  const dispatch = source.indexOf("await submitReservedVideo({", end);
  const provenance = source.indexOf("await recordProvenance(req,", dispatch);
  assert(dispatch > end && provenance > dispatch, "Owner route bypassed priced dispatch/provenance");
  assert(source.slice(dispatch, provenance).includes('feature: "reel", steps, input: genInput, seconds: secs'));
  const module = await import(encode(`
    import {assert,HttpError} from ${JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)};
    import type {RouteStep} from ${JSON.stringify(new URL("../_shared/router.ts", import.meta.url).href)};
    import {parseReelFraming,reelFramingSteps} from ${JSON.stringify(new URL("./reel-framing.ts", import.meta.url).href)};
    import {ownerQaReelStep as realOwnerQaReelStep} from ${JSON.stringify(new URL("./owner-reel-qa.ts", import.meta.url).href)};
    export async function run(options:any, database:any, now:Date) {
      const events:string[]=[];
      const user={id:options.actor??${JSON.stringify(ACTOR)}};
      const body={listing_id:${JSON.stringify(LISTING)},aspect:"9:16",...options.body};
      const req=new Request("https://closed-fixture.invalid/reel",{method:"POST"});
      const reelListingId=options.assetListing??null,secs=5;
      const MODEL_I2V="bytedance/seedance/v1/pro/fast/image-to-video",APP_AI_UNIT_CENTS={seedance_per_s:4.8};
      const assertVideoReceiptSigningReady=async()=>{events.push("receipt_signing");};
      const guardGenerate=async(...args:any[])=>{events.push("listing_and_paid_guard");if(options.guardRefusal)throw new HttpError(options.guardRefusal,"synthetic refused");return {orgId:${JSON.stringify(ORG)},plan:"team"};};
      const framing=parseReelFraming(body.framing);
      const refundGenerateCharge=async(_charge:any)=>{events.push("allowance_refund");};
      const routerEnabled=async()=>false;
      const ownerQaReelStep=async(args:any)=>{events.push("server_grant");return await realOwnerQaReelStep(args,database,now);};
      const resolveChain=async(_task:any,context:any,legacy:any)=>{events.push("normal_chain");return [{...legacy,context}];};
      const durationNeeds=()=>["5s"];
      const legacyVideoStep=(task:string,model:string,unit:string,unit_cents:number,capabilities:string[])=>({task,model,unit,unit_cents,capabilities,provider:"fal"});
      ${fragment}
      return {steps,events};
    }
  `));
  return module.run as (options: Record<string, unknown>, database: ReturnType<typeof db>["client"], now: Date) => Promise<{ steps: RouteStep[]; events: string[] }>;
}

Deno.test("actual reel routing keeps source/account admission before override and ignores body provider claims", async () => {
  const run = await routingFixture();
  for (const body of [{ provider: "fal", model: "custom", is_admin: false, consent: "other" }, {}]) {
    const f = db(); const result = await run({ body }, f.client, NOW);
    assertEquals(result.steps.length, 1); assertEquals(result.steps[0].provider, "kie");
    assertEquals(result.events, ["receipt_signing", "listing_and_paid_guard", "server_grant"]);
  }
  for (const change of [{ admin: false }, { value: { ...grant, enabled: false } }]) {
    const result = await run({ body: { provider: "kie", model: KIE_REEL_QA_MODEL, is_admin: true, consent: OWNER_REEL_QA_CONSENT } }, db(change).client, NOW);
    assertEquals(result.steps[0].provider, "fal");
    assertEquals(result.events, ["receipt_signing", "listing_and_paid_guard", "server_grant", "normal_chain"]);
  }
  const cross = db(); await assertRejects(() => run({ assetListing: OTHER }, cross.client, NOW), HttpError);
  assertEquals(cross.calls.length, 0, "Cross-listing source reached QA grant");
  for (const guardRefusal of [401, 403, 402, 409]) {
    const f = db(); await assertRejects(() => run({ guardRefusal }, f.client, NOW), HttpError);
    assertEquals(f.calls.length, 0, "Refused normal admission reached QA grant");
  }
});

Deno.test("actual KIE owner dispatch reserves both18-cent holds before one POST and settles accepted receipt", async () => {
  const step = await ownerQaReelStep(args, db().client, NOW); assert(step);
  for (const refusal of [null, "RP402: Workspace processing budget reached", "RP403: Forbidden listing"]) {
    const calls: Array<{ name: string; args: Record<string, unknown> }> = []; let posts = 0;
    const input = { task: "video.reel_clip", image_url: "data:image/jpeg;base64,c2FtZS1zb3VyY2U=", prompt: "bounded camera move", seconds: 5, resolution: "1080p", aspect: "9:16" };
    const promise = submitReservedVideo({ actorId: ACTOR, orgId: ORG, listingId: LISTING,
      key: "owner-qa-one-attempt", feature: "reel", steps: [step], input, seconds: 5,
      allowance: { monthlyWindowStart: "2026-10-01T00:00:00Z", burstWindowStart: "2026-10-12T20:00:00Z" } }, {
      rpc: (name, values) => {
        calls.push({ name, args: values });
        if (name === "app_video_cost_reserve_v2") return Promise.resolve({ data: refusal ? null : { reserved: true }, error: refusal ? { message: refusal } : null });
        if (name === "serving_cost_reserve") return Promise.resolve({ data: { reserved: true }, error: null });
        if (name === "serving_cost_finish") return Promise.resolve({ data: { finished: true }, error: null });
        assertEquals(name, "app_video_cost_settle"); return Promise.resolve({ data: { settled: true }, error: null });
      },
      submit: (selected) => { assertEquals(calls.at(-1)?.name, "serving_cost_reserve"); posts++; return Promise.resolve({ step: selected, value: { id: "owner-qa-accepted" }, latency_ms: 1 }); },
    });
    if (refusal) { await assertRejects(() => promise, HttpError); assertEquals(posts, 0); assertEquals(calls.length, 1); }
    else {
      assertEquals((await promise).value.id, "owner-qa-accepted"); assertEquals(posts, 1);
      assertEquals(calls.filter(x => /reserve/.test(x.name)).map(x => x.args.p_hold_cents), [18, 18]);
      assertEquals(calls[0].args.p_listing, LISTING); assertEquals(calls[0].args.p_actor, ACTOR);
      assertEquals(calls[0].args.p_provider, "kie"); assertEquals(calls[0].args.p_model, KIE_REEL_QA_MODEL);
      assert(!JSON.stringify(calls).includes("data:image"), "Journal retained source media");
      assertEquals(calls.at(-1)?.name, "app_video_cost_settle");
    }
  }
});

Deno.test("compiled owner QA controls expose removal of identity, admin, consent, expiry, provider and duration fences", async () => {
  const original = await Deno.readTextFile(new URL("./owner-reel-qa.ts", import.meta.url));
  const mutations = [
    ["actor", "canonicalUuid(grant.actor_id) !== actorId", "false", { value: { ...grant, actor_id: OTHER } }, args],
    ["org", "canonicalUuid(grant.org_id) !== orgId", "false", { value: { ...grant, org_id: OTHER } }, args],
    ["listing", "canonicalUuid(grant.listing_id) !== listingId", "false", { value: { ...grant, listing_id: OTHER } }, args],
    ["provider", 'grant.provider !== "kie"', "false", { value: { ...grant, provider: "unapproved" } }, args],
    ["model", "grant.model !== KIE_REEL_QA_MODEL", "false", { value: { ...grant, model: "unapproved" } }, args],
    ["consent", "grant.consent !== OWNER_REEL_QA_CONSENT", "false", { value: { ...grant, consent: null } }, args],
    ["changed_by", "canonicalUuid(grant.changed_by) !== actorId", "false", { value: { ...grant, changed_by: OTHER } }, args],
    ["expiry", "end <= clock", "false", { value: { ...grant, expires_at: NOW.toISOString() } }, args],
    ["window", "end - start > MAX_QA_WINDOW_MS", "false", { value: { ...grant, created_at: "2026-10-11T19:00:00.000Z" } }, args],
    ["fresh_admin", "admin.data?.is_admin !== true", "false", { admin: false }, args],
    ["duration", "args.seconds !== 5", "false", {}, { ...args, seconds: 6 }],
  ] as const;
  for (const [name, needle, replacement, options, request] of mutations) {
    assertEquals(original.split(needle).length, 2, `Control anchor changed: ${name}`);
    const changed = absoluteImports(original.replace(needle, replacement));
    const module = await import(encode(changed));
    const leaked = await module.ownerQaReelStep(request, db(options).client, NOW);
    assert(leaked, `Negative control did not expose removed ${name} fence`);
  }
  console.log("OWNER_QA_COMPILED_CONTROLS=11");
});

const bytes = new TextEncoder().encode("selected-unchanged-JPEG-bytes");
const input: GenerateInput = { task: "video.reel_clip", prompt: "property-safe camera move",
  image_url: "data:image/jpeg;base64," + btoa(String.fromCharCode(...bytes)),
  image_b64: "private-source-marker", seconds: 5, resolution: "1080p", aspect: "9:16" };
const identity = { actorId: ACTOR, orgId: ORG, listingId: LISTING };
function staging(options: Record<string, unknown> = {}) {
  const events: string[] = []; const keys: string[] = []; let authCalls = 0, registers = 0;
  return { events, keys, deps: {
    authorize: () => { events.push("authorize"); authCalls++; return Promise.resolve(options.unauthorized !== true && !(options.revoked === true && authCalls === 2)); },
    register: (key: string, length: number) => { registers++; events.push("register" + registers); keys.push(key); assertEquals(length, bytes.length); if (options.registerFails === true || options.finalRegisterFails === true && registers === 2) throw Error("synthetic inventory failure"); return Promise.resolve(); },
    put: (key: string, saved: Uint8Array, mime: string) => { events.push("put"); assertEquals(saved, bytes); assertEquals(mime, "image/jpeg"); if (options.putFails) throw Error("synthetic put failure"); return Promise.resolve({ key: options.wrongStoredKey ? "other/key" : key, bytes: options.wrongStoredBytes ? bytes.length + 1 : bytes.length }); },
    head: (_key: string) => { events.push("head"); return Promise.resolve({ exists: options.noObject !== true, bytes: options.wrongHeadBytes ? bytes.length + 1 : bytes.length }); },
    sign: (key: string) => { events.push("sign"); keys.push(key); if (options.signFails) throw Error("synthetic sign failure"); return Promise.resolve(options.invalidSignedUrl ? "http://invalid-capability.invalid/source" : "https://private-staged.invalid/source"); },
  } };
}

Deno.test("actual owner UUID identity accepts Foundation uppercase and journals canonical lowercase source", async () => {
  const native = { actorId: HEX_ACTOR.toUpperCase(), orgId: HEX_ORG.toUpperCase(), listingId: HEX_LISTING.toUpperCase(), seconds: 5 };
  const lowerGrant = { ...grant, actor_id: HEX_ACTOR, org_id: HEX_ORG, listing_id: HEX_LISTING, changed_by: HEX_ACTOR };
  const upperGrant = { ...lowerGrant, actor_id: HEX_ACTOR.toUpperCase(), org_id: HEX_ORG.toUpperCase(), listing_id: HEX_LISTING.toUpperCase(), changed_by: HEX_ACTOR.toUpperCase() };
  for (const value of [lowerGrant, upperGrant]) {
    const f = db({ value }); assert(await ownerQaReelStep(native, f.client, NOW));
    assertEquals(f.calls.at(-1)?.value, HEX_ACTOR, "Fresh admin identity was not canonical");
  }
  const lower = { actorId: HEX_ACTOR, orgId: HEX_ORG, listingId: HEX_LISTING, seconds: 5 };
  assert(await ownerQaReelStep(lower, db({ value: upperGrant }).client, NOW));
  for (const field of ["actor_id", "org_id", "listing_id", "changed_by"]) {
    assertEquals(await ownerQaReelStep(native, db({ value: { ...upperGrant, [field]: HEX_OTHER.toUpperCase() } }).client, NOW), null);
    for (const bad of [null, 1, "not-uuid"]) assertEquals(await ownerQaReelStep(native, db({ value: { ...upperGrant, [field]: bad } }).client, NOW), null);
  }
  const f = staging(); await prepareOwnerQaReelInput(native, input, f.deps);
  assert(f.keys.every(key => key.startsWith(`ai-router/${HEX_ORG}/owner-qa-input/${HEX_ACTOR}/${HEX_LISTING}/`)));
  assert(f.keys.every(key => key === key.toLowerCase()));
  const original = await Deno.readTextFile(new URL("./owner-reel-qa.ts", import.meta.url));
  assertEquals(original.split("value.toLowerCase()").length, 2, "Canonical UUID control anchor changed");
  const mutant = await import(encode(absoluteImports(original.replace("value.toLowerCase()", "value"))));
  assertEquals(await mutant.ownerQaReelStep(native, db({ value: lowerGrant }).client, NOW), null,
    "Negative control did not expose valid uppercase identity rejection");
  const m = staging(); await mutant.prepareOwnerQaReelInput(native, input, m.deps);
  assert(m.keys.some(key => /[A-F]/.test(key)), "Negative control did not expose uppercase storage namespace");
  console.log("OWNER_QA_UUID_COMPILED_CONTROLS=1");
});

Deno.test("actual owner source staging journals exact identity/hash bytes before storage and capability", async () => {
  const f = staging(); const saved = await prepareOwnerQaReelInput(identity, input, f.deps);
  assertEquals(f.events, ["authorize", "register1", "put", "head", "authorize", "register2", "sign"]);
  const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))).map(x => x.toString(16).padStart(2, "0")).join("");
  assertEquals(f.keys, Array(3).fill(`ai-router/${ORG}/owner-qa-input/${ACTOR}/${LISTING}/${hash}.jpg`));
  assertEquals(saved, { ...input, image_url: "https://private-staged.invalid/source", image_b64: undefined });
  assertEquals(bytes, new TextEncoder().encode("selected-unchanged-JPEG-bytes"));
  assert(input.image_url!.startsWith("data:image/jpeg"), "Caller source mutated");
  const existing = staging(); const https = { ...input, image_url: "https://normal-owned-asset.invalid/source" };
  assertEquals(await prepareOwnerQaReelInput(identity, https, existing.deps), https);
  assertEquals(existing.events, ["authorize"], "Normal resolved owned HTTPS source was restaged");
});

Deno.test("actual owner source failure never signs unregistered, revoked, wrong-size or malformed input", async () => {
  for (const options of [
    { unauthorized: true }, { revoked: true }, { registerFails: true }, { finalRegisterFails: true },
    { putFails: true }, { wrongStoredKey: true }, { wrongStoredBytes: true },
    { noObject: true }, { wrongHeadBytes: true }, { signFails: true }, { invalidSignedUrl: true },
  ]) {
    const f = staging(options);
    const error = await assertRejects(() => prepareOwnerQaReelInput(identity, input, f.deps), ProviderError);
    assertEquals([error.status, error.dispatch_rejected, error.provider], [0, true, "kie"]);
    if (!options.signFails && !options.invalidSignedUrl) assert(!f.events.includes("sign"), "Refused source produced a capability");
  }
  for (const image_url of [undefined, "data:image/jpeg;base64,", "data:text/plain;base64,c291cmNl", "http://untrusted.invalid/source"]) {
    const f = staging(); await assertRejects(() => prepareOwnerQaReelInput(identity, { ...input, image_url }, f.deps), ProviderError);
    assert(!f.events.includes("put") && !f.events.includes("sign"));
  }
  const f = staging(); await assertRejects(() => prepareOwnerQaReelInput({ ...identity, actorId: "invalid" }, input, f.deps), ProviderError);
  assertEquals(f.events.length, 0);
});

Deno.test("compiled staging controls expose registration, fresh authorization and byte-fence removals", async () => {
  const original = await Deno.readTextFile(new URL("./owner-reel-qa.ts", import.meta.url));
  const controls: Array<[string, string, string, Record<string, unknown>, (events: string[]) => boolean]> = [
    ["first inventory registration", "    await deps.register(key, decoded.bytes.byteLength);\n    const stored", "    const stored", {}, events => events[1] === "put"],
    ["fresh authorization", " || !await deps.authorize()) throw", ") throw", { revoked: true }, events => events.includes("sign")],
    ["stored byte count", "stored.bytes !== decoded.bytes.byteLength", "false", { wrongStoredBytes: true }, events => events.includes("sign")],
    ["head byte count", "head.bytes !== decoded.bytes.byteLength", "false", { wrongHeadBytes: true }, events => events.includes("sign")],
    ["final inventory registration", "    await deps.register(key, decoded.bytes.byteLength);\n    const imageUrl", "    const imageUrl", { finalRegisterFails: true }, events => events.includes("sign")],
  ];
  for (const [name, needle, replacement, options, detect] of controls) {
    assertEquals(original.split(needle).length, 2, `Staging control anchor changed: ${name}`);
    const module = await import(encode(absoluteImports(original.replace(needle, replacement))));
    const f = staging(options); await module.prepareOwnerQaReelInput(identity, input, f.deps);
    assert(detect(f.events), `Negative control did not expose removed ${name}`);
  }
  const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  const stage = source.indexOf("const providerInput = ownerQaStep ? await prepareOwnerQaReelInput(");
  const vendor = source.indexOf("adapterFor(step.provider).submit(step, providerInput)", stage);
  assert(stage > 0 && vendor > stage, "Staged owner input was disconnected from actual provider dispatch");
  const callback = source.slice(stage, vendor);
  assert(callback.includes("await contentOrgForUser(user.id, orgId, body.listing_id ?? reelListingId ?? undefined, true)"));
  assert(callback.includes('"register_private_ai_output"'));
  assert(callback.includes("putBytes(R2_BUCKET_RENDERS, key, bytes, mime, true)"));
  assert(callback.includes("presignGet(R2_BUCKET_RENDERS, key, 7200)"));
  console.log("OWNER_QA_STAGING_COMPILED_CONTROLS=5");
});

async function providerCallbackFixture() {
  const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  const start = source.indexOf("            const providerInput = ownerQaStep ? await prepareOwnerQaReelInput(");
  const last = "return await adapterFor(step.provider).submit(step, providerInput);";
  const end = source.indexOf(last, start) + last.length;
  assert(start > 0 && end > start, "Actual provider input callback anchors changed");
  const module = await import(encode(`
    import {prepareOwnerQaReelInput,ownerQaReelStep as realOwnerQaReelStep} from ${JSON.stringify(new URL("./owner-reel-qa.ts", import.meta.url).href)};
    import {assert} from ${JSON.stringify(new URL("../_shared/http.ts", import.meta.url).href)};
    export async function run(options:any, database:any, input:any, now:Date) {
      const events:any[]=[],user={id:${JSON.stringify(ACTOR)}},orgId=${JSON.stringify(ORG)};
      const body={listing_id:${JSON.stringify(LISTING)}},reelListingId=null,secs=5;
      const genInput=input,framing=input.framing,R2_BUCKET_RENDERS="renders",ownerQaStep=options.normal?null:{};
      const step={provider:options.normal?"fal":"kie",model:options.normal?"normal-model":${JSON.stringify(KIE_REEL_QA_MODEL)}};
      const contentOrgForUser=async(actor:any,org:any,listing:any,write:any)=>{events.push({kind:"content_auth",actor,org,listing,write});if(options.revokedAccess)throw Error("content access revoked");return org;};
      const ownerQaReelStep=async(args:any)=>{events.push({kind:"grant_auth",args});return await realOwnerQaReelStep(args,database,now);};
      const adminClient=()=>({rpc:async(name:any,args:any)=>{events.push({kind:"inventory",name,args});return {data:{ok:!options.inventoryError,key:options.inventoryWrongKey?"wrong-key":args.p_key},error:options.inventoryError?{}:null};}});
      const putBytes=async(bucket:any,key:any,bytes:any,mime:any,immutable:any)=>{events.push({kind:"put",bucket,key,bytes:Array.from(bytes),mime,immutable});return {key,bytes:bytes.length};};
      const headObject=async(bucket:any,key:any)=>{events.push({kind:"head",bucket,key});return {exists:true,bytes:${bytes.length}};};
      const presignGet=async(bucket:any,key:any,ttl:any)=>{events.push({kind:"sign",bucket,key,ttl});return "https://qa-capability.invalid/source";};
      const adapterFor=(provider:any)=>({submit:async(step:any,input:any)=>{events.push({kind:"POST",provider,step,input});return {events};}});
      ${source.slice(start, end)}
    }
  `));
  return module.run as (options: Record<string, unknown>, database: ReturnType<typeof db>["client"], input: GenerateInput, now: Date) => Promise<{ events: Array<Record<string, unknown>> }>;
}

Deno.test("actual provider callback rechecks content+grant and registers owned source before capability and POST", async () => {
  const run = await providerCallbackFixture(); const result = await run({}, db().client, input, NOW);
  assertEquals(result.events.map(x => x.kind), ["content_auth", "grant_auth", "inventory", "put", "head", "content_auth", "grant_auth", "inventory", "sign", "POST"]);
  for (const call of result.events.filter(x => x.kind === "content_auth")) {
    assertEquals(call, { kind: "content_auth", actor: ACTOR, org: ORG, listing: LISTING, write: true });
  }
  const inventory = result.events.filter(x => x.kind === "inventory"); assertEquals(inventory.length, 2);
  for (const call of inventory) {
    assertEquals(call.name, "register_private_ai_output");
    const row = call.args as Record<string, unknown>;
    assertEquals([row.p_user, row.p_org, row.p_listing, row.p_bucket, row.p_bytes], [ACTOR, ORG, LISTING, "renders", bytes.length]);
    assert(String(row.p_key).startsWith(`ai-router/${ORG}/owner-qa-input/${ACTOR}/${LISTING}/`));
  }
  const put = result.events.find(x => x.kind === "put")!;
  assertEquals([put.bucket, put.bytes, put.mime, put.immutable], ["renders", Array.from(bytes), "image/jpeg", true]);
  const sign = result.events.find(x => x.kind === "sign")!; assertEquals([sign.bucket, sign.ttl], ["renders", 7200]);
  const post = result.events.at(-1)!; assertEquals(post.provider, "kie");
  assertEquals((post.input as GenerateInput).image_url, "https://qa-capability.invalid/source");
  for (const options of [{ revokedAccess: true }, { inventoryError: true }, { inventoryWrongKey: true }]) {
    const error = await assertRejects(() => run(options, db().client, input, NOW), ProviderError);
    assertEquals([error.status, error.dispatch_rejected], [0, true]);
  }
  await assertRejects(() => run({}, db({ admin: false }).client, input, NOW), ProviderError);
  const normal = await run({ normal: true }, db({ admin: false }).client, input, NOW);
  assertEquals(normal.events.map(x => x.kind), ["POST"]);
  assertEquals((normal.events[0].input as GenerateInput).image_url, input.image_url);
});

Deno.test("owner Kling grant requires current exact Pro silent consent and preserves scope", async () => {
  const klingGrant = { ...grant, model: KIE_KLING_REEL_QA_MODEL, mode: "pro", sound: false };
  const framedArgs={...args,framing:"preserve_photo" as const};
  assertEquals(await ownerQaReelStep(args,db({value:klingGrant}).client,NOW),null,"Old client requests cannot switch to owner Kling without the marker");
  const route = await ownerQaReelStep(framedArgs, db({value:klingGrant}).client, NOW);
  assert(route); assertEquals([route.provider,route.model,route.unit_cents,paramsOf(route)],
    ["kie",KIE_KLING_REEL_QA_MODEL,9,{kie_mode:"pro",sound:false}]);
  for (const change of [{mode:"standard"},{mode:null},{sound:true},{sound:null},{sound:"false"},
    {actor_id:OTHER},{org_id:OTHER},{listing_id:OTHER},{changed_by:OTHER},{expires_at:NOW.toISOString()}]) {
    assertEquals(await ownerQaReelStep(framedArgs,db({value:{...klingGrant,...change}}).client,NOW),null);
  }
  assertEquals(await ownerQaReelStep(framedArgs,db({value:klingGrant,admin:false}).client,NOW),null);
  const native = {actorId:HEX_ACTOR.toUpperCase(),orgId:HEX_ORG.toUpperCase(),listingId:HEX_LISTING.toUpperCase(),seconds:5,framing:"preserve_photo" as const};
  assert(await ownerQaReelStep(native,db({value:{...klingGrant,actor_id:HEX_ACTOR,org_id:HEX_ORG,listing_id:HEX_LISTING,changed_by:HEX_ACTOR}}).client,NOW));
  const original=await Deno.readTextFile(new URL("./owner-reel-qa.ts",import.meta.url));
  for (const [needle,change] of [['grant.mode !== "pro"',{mode:"standard"}],['grant.sound !== false',{sound:true}]] as const) {
    assertEquals(original.split(needle).length,2);
    const mutant=await import(encode(absoluteImports(original.replace(needle,"false"))));
    assert(await mutant.ownerQaReelStep(framedArgs,db({value:{...klingGrant,...change}}).client,NOW),"Compiled control must expose the removed Kling fence");
  }
  const marker='args.framing !== "preserve_photo"';assertEquals(original.split(marker).length,2);
  const noMarker=await import(encode(absoluteImports(original.replace(marker,"false"))));
  assert(await noMarker.ownerQaReelStep(args,db({value:klingGrant}).client,NOW),"Compiled marker control must expose old-client routing leak");
  console.log("KLING_OWNER_COMPILED_CONTROLS=3");
});

Deno.test("actual routing rejects incompatible photo-preservation before supplier admission and keeps legacy routing", async () => {
  const run=await routingFixture();
  const klingGrant={...grant,model:KIE_KLING_REEL_QA_MODEL,mode:"pro",sound:false};
  const accepted=await run({body:{framing:"preserve_photo",provider:"arbitrary",model:"arbitrary"}},db({value:klingGrant}).client,NOW);
  assertEquals(accepted.steps.map(x=>x.model),[KIE_KLING_REEL_QA_MODEL]);
  assertEquals(accepted.events,["receipt_signing","listing_and_paid_guard","server_grant"]);
  await assertRejects(()=>run({body:{framing:"preserve_photo"}},db().client,NOW),HttpError,
    "Photo-preserving motion is unavailable");
  const normal=await run({body:{framing:"preserve_photo",provider:"kie",model:KIE_KLING_REEL_QA_MODEL}},db({admin:false}).client,NOW);
  assertEquals(normal.steps.map(x=>x.provider),["fal"]);
  const old=await run({body:{}},db({value:klingGrant}).client,NOW);
  assertEquals(old.steps.map(x=>x.provider),["fal"],"Actual old client routing stays ordinary even with an active owner Kling grant");
  const source=await Deno.readTextFile(new URL("./index.ts",import.meta.url));
  const route=source.indexOf('seg[0] === "reel-clip"');
  const validation=source.indexOf("parseReelFraming(body.framing)",route);
  const admission=source.indexOf('guardGenerate(user, req, "reel"',route);
  const paid=source.indexOf("await submitReservedVideo({",admission);
  assert(route<validation && validation<admission && source.indexOf("reelFramingSteps(candidateSteps, framing)",admission)<paid);
  assert(source.slice(admission,paid).includes("await refundGenerateCharge(charge)"));
});
