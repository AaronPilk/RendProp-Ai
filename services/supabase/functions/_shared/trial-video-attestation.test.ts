import { assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { attestTrialVideo, type TrialVideoDependencies } from "./trial-video-attestation.ts";
import { HttpError } from "./http.ts";
const id = (n: number) => `fa000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const scope = { actor: id(1), org: id(2), listing: id(3), asset: id(4) };
function ok(value: unknown): asserts value { if (!value) throw new Error("assertion failed"); }
function eq(a: unknown, b: unknown) { ok(JSON.stringify(a) === JSON.stringify(b)); }
function concat(...parts: Uint8Array[]) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0; for (const part of parts) { out.set(part, at); at += part.length; } return out;
}
function box(name: string, body: Uint8Array) {
  const out = new Uint8Array(body.length + 8); new DataView(out.buffer).setUint32(0, out.length);
  out.set(new TextEncoder().encode(name), 4); out.set(body, 8); return out;
}
function video(seconds = 60, billable = seconds, fragmented = false) {
  const timeline = (value: number) => { const out = new Uint8Array(24), view = new DataView(out.buffer);
    view.setUint32(12, 1000); view.setUint32(16, Math.round(value * 1000)); return out; };
  const tkhd = new Uint8Array(24); new DataView(tkhd.buffer).setUint32(20, seconds * 1000);
  const hdlr = new Uint8Array(12); hdlr.set(new TextEncoder().encode("vide"), 8);
  const stts = new Uint8Array(16), tv = new DataView(stts.buffer);
  tv.setUint32(4, 1); tv.setUint32(8, 1); tv.setUint32(12, Math.round(billable * 1000));
  const stsz = new Uint8Array(12), sv = new DataView(stsz.buffer); sv.setUint32(4, 8); sv.setUint32(8, 1);
  const samples = box("minf", box("stbl", concat(box("stts", stts), box("stsz", stsz))));
  const media = box("mdia", concat(box("mdhd", timeline(billable)), box("hdlr", hdlr), samples));
  const track = box("trak", concat(box("tkhd", tkhd), media));
  return concat(box("ftyp", new Uint8Array(8)), box("moov", concat(box("mvhd", timeline(seconds)), track,
    ...(fragmented ? [box("mvex", new Uint8Array())] : []))), box("mdat", new Uint8Array(32)));
}
type Options = { seconds?: number; billable?: number; fragmented?: boolean; required?: boolean;
  authority?: Record<string, unknown>; head?: Record<string, unknown>; finalHead?: Record<string, unknown>;
  url?: string; rangeETag?: string; rangeTotal?: number; recordError?: string; recordData?: unknown; firstError?: string; selectedOrg?: string; logicalOrg?: string; libraryError?: string };
function fixture(options: Options = {}) {
  const bytes = video(options.seconds, options.billable, options.fragmented), key = `renders/${scope.org}/${scope.listing}/${scope.asset}.mp4`;
  const source = { required: true, actor_id: scope.actor, org_id: scope.org, listing_id: scope.listing, asset_id: scope.asset,
    bucket: "renders", storage_key: key, etag: '"fixture-etag"', bytes: bytes.length, max_video_seconds: 90, ...options.authority };
  const calls: { name: string; args?: Record<string, unknown> }[] = [];
  const url = `https://${"a".repeat(32)}.r2.cloudflarestorage.com/rendprop-renders/${key}?X-Amz-Expires=300&X-Amz-Signature=${"b".repeat(64)}`;
  let heads = 0;
  const deps: TrialVideoDependencies = {
    rendersBucket: "rendprop-renders",
    rpc(name, args) {
      calls.push({ name, args });
      if (name === "subscription_trial_video_context") return Promise.resolve({
        data: options.required === false ? { required: false } : source,
        error: options.firstError ? { message: options.firstError } : null });
      return Promise.resolve({ data: options.recordData === undefined ? { attested: true, duration_s: args.p_duration, billable_s: args.p_billable } : options.recordData,
        error: options.recordError ? { message: options.recordError } : null });
    },
    head(bucket, key, signal) { calls.push({ name: "head" }); eq(bucket, "renders"); ok(key.startsWith(`renders/${scope.org}/`)); ok(!signal.aborted);
      return Promise.resolve({ exists: true, bytes: bytes.length, etag: source.etag, contentType: "video/mp4", ...options.head,
        ...(heads++ ? options.finalHead : {}) }); },
    sign(bucket, key, expires) { calls.push({ name: "sign" }); eq(bucket, "renders"); eq(expires, 300); ok(!key.includes("..")); return Promise.resolve(options.url ?? url); },
    fetch(target, init) { calls.push({ name: "range" }); eq(target, url); eq(init.method, "GET"); eq(init.redirect, "error");
      const h = new Headers(init.headers); eq(h.get("If-Match"), source.etag); ok(init.signal);
      const m = /^bytes=(\d+)-(\d+)$/.exec(h.get("Range") ?? "")!; const first = Number(m[1]), last = Number(m[2]);
      return Promise.resolve(new Response(bytes.slice(first, last + 1), { status: 206,
        headers: { etag: options.rangeETag ?? source.etag, "content-range": `bytes ${first}-${last}/${options.rangeTotal ?? bytes.length}` } })); },
  };
  return { calls, deps, bytes, source };
}
async function denied(options: Options, expected: number, beforeRecord = true) {
  const f = fixture(options);
  try { await attestTrialVideo(scope, f.deps); throw new Error("invalid video accepted"); }
  catch (error) { ok(error instanceof HttpError); eq(error.status, expected); }
  if (beforeRecord) ok(!f.calls.some(c => c.name === "record_subscription_trial_video"));
}
Deno.test("trial video actual MP4 probe admits 60s with both HEAD reads and private attestation only", async () => {
  const f = fixture(); eq(await attestTrialVideo(scope, f.deps), { duration_s: 60, billable_s: 60 });
  eq(f.calls.filter(c => c.name === "head").length, 2);
  eq(f.calls.at(-1)?.name, "record_subscription_trial_video");
  const record = f.calls.at(-1)!.args!; eq(record.p_checker, "mp4-timing-v1"); ok(!JSON.stringify(record).includes("https:"));
  ok(!f.calls.some(c => /create_render|publish_render|cost_reserve/.test(c.name)));
});
Deno.test("trial 90s boundary is admitted", async () => { const f = fixture({ seconds: 90 }); eq((await attestTrialVideo(scope, f.deps))?.duration_s, 90); });
Deno.test("paid override skips physical probe and attestation", async () => { const f = fixture({ required: false }); eq(await attestTrialVideo(scope, f.deps), null); eq(f.calls.length, 1); });
for (const [label, options, status] of [
  ["91 seconds", { seconds: 91 }, 402], ["billable track above cap", { seconds: 89.95, billable: 90.05 }, 402],
  ["fragmented MP4", { fragmented: true }, 400], ["timeline mismatch", { billable: 62 }, 400],
  ["foreign actor", { authority: { actor_id: id(99) } }, 503], ["foreign workspace", { authority: { org_id: id(99) } }, 503],
  ["foreign property", { authority: { listing_id: id(99) } }, 503], ["foreign asset", { authority: { asset_id: id(99) } }, 503],
  ["unbounded bytes", { authority: { bytes: 1073741825 } }, 503], ["unbounded cap", { authority: { max_video_seconds: 91 } }, 503],
  ["unowned key", { authority: { storage_key: "renders/foreign/one.mp4" } }, 503],
  ["missing object", { head: { exists: false } }, 409], ["changed initial ETag", { head: { etag: "changed" } }, 409],
  ["wrong content type", { head: { contentType: "video/webm" } }, 409], ["wrong initial bytes", { head: { bytes: 1 } }, 409],
  ["changed post-probe ETag", { finalHead: { etag: "changed" } }, 409], ["changed post-probe size", { finalHead: { bytes: 1 } }, 409],
  ["changed ranged ETag", { rangeETag: "changed" }, 409], ["changed ranged total", { rangeTotal: 999 }, 409],
  ["foreign signed origin", { url: "https://example.invalid/video.mp4" }, 503],
  ["deleting actor", { firstError: "RP403: Current video workspace authority is required" }, 403],
] as [string, Options, number][]) Deno.test("trial video refuses " + label + " before attestation/action", () => denied(options, status));
Deno.test("revocation during probe is rechecked by actual attestation RPC", () => denied({ recordError: "RP403: Current video workspace authority is required" }, 403, false));
Deno.test("changed receipt during probe is refused by actual attestation RPC", () => denied({ recordError: "RP409: The video changed while its duration was checked" }, 409, false));
Deno.test("malformed attestation response fails closed", () => denied({ recordData: { attested: true, duration_s: 99, billable_s: 99 } }, 503, false));
Deno.test("unexpected transport errors do not release private capability text", async () => {
  const f = fixture(); f.deps.fetch = () => Promise.reject(new TypeError("private-signed-url-must-not-escape"));
  try { await attestTrialVideo(scope, f.deps); throw new Error("failed read accepted"); }
  catch (error) { ok(error instanceof HttpError); eq(error.status, 503); ok(!error.message.includes("private-signed")); }
  ok(!f.calls.some(c => c.name === "record_subscription_trial_video"));
});

Deno.test("headObject preserves existing two-argument callers and honors optional abort signal", async () => {
  const previousFetch = globalThis.fetch;
  const names = ["CLOUDFLARE_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"];
  const previousEnv = names.map(name => Deno.env.get(name));
  names.forEach((name, index) => Deno.env.set(name, index === 0 ? "a".repeat(32) : "synthetic-key"));
  const observed: Request[] = [];
  globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(input, init); observed.push(request);
    return Promise.resolve(new Response(null, { headers: { "content-length": "12", etag: '"head-fixture"', "content-type": "video/mp4" } }));
  }) as typeof fetch;
  try {
    const { headObject } = await import("./r2.ts?trial-head-compatibility");
    const old = await headObject("fixture-bucket", "video.mp4"); eq(old.bytes, 12);
    const controller = new AbortController(); const fresh = await headObject("fixture-bucket", "video.mp4", controller.signal);
    eq(fresh, old); eq(observed.length, 2); eq(observed[0].method, "HEAD"); eq(observed[1].redirect, "error");
    controller.abort(); ok(observed[1].signal.aborted);
  } finally {
    globalThis.fetch = previousFetch;
    names.forEach((name, index) => previousEnv[index] === undefined ? Deno.env.delete(name) : Deno.env.set(name, previousEnv[index]!));
  }
});

let actualRenders: ((req: Request) => Promise<Response>) | undefined;
async function actualPublish(options: Options = {}, replay = false, removeLibraryAuthority = false) {
  const f = fixture(options), previousFetch = globalThis.fetch, names = {
    SUPABASE_URL: "https://trial-render-fixture.invalid", SUPABASE_ANON_KEY: "synthetic-public",
    SUPABASE_SERVICE_ROLE_KEY: "synthetic-service", CLOUDFLARE_ACCOUNT_ID: "a".repeat(32),
    R2_ACCESS_KEY_ID: "synthetic-access", R2_SECRET_ACCESS_KEY: "synthetic-secret",
    R2_BUCKET_RENDERS: "rendprop-renders",
  };
  const prior = Object.fromEntries(Object.keys(names).map(name => [name, Deno.env.get(name)]));
  Object.entries(names).forEach(([name, value]) => Deno.env.set(name, value));
  const operations: string[] = [], job = id(7), render = id(8);
  const response = (value: unknown) => new Response(JSON.stringify(value), { headers: { "content-type": "application/json" } });
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init), url = new URL(req.url);
    if (url.hostname === `${"a".repeat(32)}.r2.cloudflarestorage.com`) {
      operations.push(req.method);
      if (req.method === "HEAD") return new Response(null, { headers: { "content-length": String(f.bytes.length),
        etag: f.source.etag, "content-type": "video/mp4" } });
      const m = /^bytes=(\d+)-(\d+)$/.exec(req.headers.get("range") ?? "")!;
      ok(m); eq(req.headers.get("if-match"), f.source.etag);
      const first = Number(m[1]), last = Number(m[2]);
      return new Response(f.bytes.slice(first, last + 1), { status: 206,
        headers: { etag: f.source.etag, "content-range": `bytes ${first}-${last}/${f.bytes.length}` } });
    }
    eq(url.hostname, "trial-render-fixture.invalid");
    if (url.pathname === "/auth/v1/user") return response({ id: scope.actor, is_anonymous: false, email: "fixture@example.invalid" });
    if (url.pathname.includes("/rpc/")) {
      const name = url.pathname.split("/").at(-1)!, body = await req.json(); operations.push(name);
      if (name === "listing_library_scope") {
        eq(body,{p_actor:scope.actor,p_listing:scope.listing});
        if(options.libraryError)return new Response(JSON.stringify({message:options.libraryError}),
          {status:403,headers:{"content-type":"application/json"}});
        return response({actor_id:scope.actor,org_id:scope.org,listing_id:scope.listing,
          library_org_id:options.logicalOrg??scope.org,library_owner_user_id:scope.actor,
          listing_owner_user_id:scope.actor,role:"owner",access_mode:"own",can_read:true,can_write:true,
          can_manage_subscription:false,billing_org_id:options.logicalOrg??scope.org,team_org_id:null});
      }
      if (name === "subscription_trial_video_context") {
        eq(body,{p_actor:scope.actor,p_org:scope.org,p_listing:scope.listing,p_asset:scope.asset});
        return response(f.source);
      }
      if (name === "record_subscription_trial_video") return options.recordError
        ? new Response(JSON.stringify({ message: options.recordError }), { status: 403, headers: { "content-type": "application/json" } })
        : response({ attested: true, duration_s: body.p_duration, billable_s: body.p_billable });
      if (name === "create_render_job") return response({ id: job, listing_id: scope.listing, capture_asset_id: scope.asset });
      if (name === "publish_render") return response({ id: render, job_id: job, listing_id: scope.listing, slug: "synthetic-trial-tour", duration_s: body.p_duration });
      if (name === "studio_presenter_media_visibility") return response(Object.fromEntries(["assets", "renders", "keys"].map(kind =>
        [kind, Object.fromEntries((body[`p_${kind}`] ?? []).map((value: string) => [value, true]))])));
      throw new Error("unexpected fixture RPC");
    }
    const table = url.pathname.split("/").at(-1);
    if (table === "deletion_requests") return response([]);
    if (table === "capture_assets") return response({ id: scope.asset, listing_id: scope.listing });
    if (table === "listings") return response({ id: scope.listing, org_id: scope.org });
    if (table === "render_jobs") return response(replay ? { id: job, listing_id: scope.listing, capture_asset_id: scope.asset } : null);
    if (table === "renders") return response(replay ? { id: render, published_at: "2026-10-06T00:00:00Z" } : null);
    throw new Error("unexpected fixture table");
  }) as typeof fetch;
  try {
    let run = actualRenders;
    if (!run || removeLibraryAuthority) {
      const descriptor = Object.getOwnPropertyDescriptor(Deno, "serve")!;
      Object.defineProperty(Deno, "serve", { configurable: true, writable: true, value: (fn: typeof actualRenders) => { run = fn; return {}; } });
      try {
        if(removeLibraryAuthority){
          const url=new URL("../renders/index.ts",import.meta.url);
          const source=await Deno.readTextFile(url);
          const anchor="const org = await contentOrgForUser(user.id, preferredOrg(req), listing, true);";
          ok(source.includes(anchor));
          const mutant=source.replace(anchor,"const org = property.org_id;")
            .replace(/from "(\.\.\/[^"]+)"/g,(_all,path)=>`from ${JSON.stringify(new URL(path,url).href)}`);
          await import("data:application/typescript,"+encodeURIComponent(mutant));
        }else{await import("../renders/index.ts");actualRenders=run;}
      } finally { Object.defineProperty(Deno, "serve", descriptor); }
    }
    const result = await run!(new Request("https://trial-render-fixture.invalid/functions/v1/renders/publish-app", {
      method: "POST", headers: { authorization: "Bearer synthetic-owner", "content-type": "application/json",
        "X-Org-Id": options.selectedOrg??scope.org, "Idempotency-Key": "trial-route-actual-key" },
      body: JSON.stringify({ listing_id: scope.listing, asset_id: scope.asset, duration_s: 7199 }),
    }));
    return { status: result.status, body: await result.json(), operations };
  } finally {
    globalThis.fetch = previousFetch;
    Object.keys(names).forEach(name => prior[name] === undefined ? Deno.env.delete(name) : Deno.env.set(name, prior[name]!));
  }
}
Deno.test("actual publish-app probes and records owned duration before either render RPC", async () => {
  const result = await actualPublish(); eq(result.status, 201); eq(result.body.duration_s, 60);
  ok(result.operations.indexOf("record_subscription_trial_video") < result.operations.indexOf("create_render_job"));
  eq(result.operations.filter(value => value === "HEAD").length, 2);
});
Deno.test("actual publish-app rejects over90 before any walkthrough/publication RPC", async () => {
  const result = await actualPublish({ seconds: 91 }); eq(result.status, 402);
  ok(!result.operations.includes("create_render_job") && !result.operations.includes("publish_render"));
});
Deno.test("actual publish-app rejects authority lost after probe before any credit RPC", async () => {
  const result = await actualPublish({ recordError: "RP403: Current video workspace authority is required" }); eq(result.status, 403);
  ok(!result.operations.includes("create_render_job") && !result.operations.includes("publish_render"));
});
Deno.test("actual recorded publication replay skips all duration reads and attestations", async () => {
  const result = await actualPublish({ seconds: 91 }, true); eq(result.status, 201);
  ok(!result.operations.includes("subscription_trial_video_context") && !result.operations.includes("HEAD") &&
    !result.operations.includes("record_subscription_trial_video"));
});

Deno.test("actual publish-app accepts a retained legacy listing's logical library and attests only its original physical video",async()=>{
  const result=await actualPublish({logicalOrg:id(9),selectedOrg:id(9)});
  eq(result.status,201);eq(result.body.duration_s,60);
  ok(result.operations.indexOf("listing_library_scope")<result.operations.indexOf("subscription_trial_video_context"));
  ok(result.operations.indexOf("record_subscription_trial_video")<result.operations.indexOf("create_render_job"));
});
Deno.test("actual publish-app refuses a foreign logical library before probing or credit consumption",async()=>{
  const result=await actualPublish({logicalOrg:id(9),selectedOrg:id(99)});
  eq(result.status,403);ok(!result.operations.includes("HEAD"));
  ok(!result.operations.includes("subscription_trial_video_context"));
  ok(!result.operations.includes("create_render_job")&&!result.operations.includes("publish_render"));
});
Deno.test("actual publish-app rechecks library authority after RLS reads; compiled guard removal fails that oracle",async()=>{
  const oracle=async(remove:boolean)=>{
    const result=await actualPublish({logicalOrg:id(9),selectedOrg:id(9),libraryError:"RP403: The Team library relationship was removed"},false,remove);
    eq(result.status,403);ok(!result.operations.includes("HEAD"));
    ok(!result.operations.includes("create_render_job")&&!result.operations.includes("publish_render"));
  };
  await oracle(false);await assertRejects(()=>oracle(true),Error,"assertion failed");
});
