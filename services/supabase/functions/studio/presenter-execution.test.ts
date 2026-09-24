// Synthetic MP4 metadata and mocked storage/vendor operations only. These tests
// verify orchestration, not video quality or real account pricing.
import { createPresenterExecution, presenterExecutionInput, type PresenterExecutionDeps, type PresenterObject as O } from "./presenter-execution.ts";
import { originalAsset, presenterOutputUrl, sha256, videoProbe, mediaBytes, PRESENTER_VIDEO_BYTES } from "./presenter-media.ts";
import { ProviderError } from "../_shared/providers/common.ts";
import { syntheticPresenterMP4 } from "./presenter-test-fixtures.ts";

export const TEST_IDS = { org: "10000000-0000-4000-8000-000000000001", listing: "10000000-0000-4000-8000-000000000002", draft: "10000000-0000-4000-8000-000000000003", job: "10000000-0000-4000-8000-000000000004", quote: "10000000-0000-4000-8000-000000000005", key: "10000000-0000-4000-8000-000000000006", photo: "10000000-0000-4000-8000-000000000007", source: "10000000-0000-4000-8000-000000000008", asset: "10000000-0000-4000-8000-000000000009", request: "10000000-0000-4000-8000-000000000010" };
const I = TEST_IDS;
function equal(actual: unknown, expected: unknown) { if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`); }
async function rejects(fn: () => unknown, message?: string) { try { await fn(); } catch (error) { if (message && !(error instanceof Error && error.message.includes(message))) throw error; return; } throw new Error("Expected rejection"); }

async function harness() {
  const video = syntheticPresenterMP4(), photo = new Uint8Array([255, 216, 255, 0, 255, 217]);
  const sourceKey = `uploads/${I.org}/${I.listing}/source.mp4`, photoKey = `uploads/${I.org}/${I.listing}/photo.jpg`, outputKey = `presenter-private/${I.org}/${I.job}/output.mp4`;
  const source = { id: I.source, listing_id: I.listing, bucket: "uploads", storage_key: sourceKey, sha256: await sha256(video), bytes: video.length, duration_s: 999 };
  const refPhoto = { id: I.photo, listing_id: I.listing, bucket: "uploads", storage_key: photoKey, sha256: await sha256(photo), bytes: photo.length };
  const snapshot = { org_id: I.org, source_asset: source, reference_assets: [refPhoto], script: "Preserve this approved performance.", resolution: "720p", draft_id: I.draft, draft_revision: 1, profile_revision: 1 };
  const vendor = { request_id: I.request, status_url: `https://api.higgsfield.ai/requests/${I.request}/status`, cancel_url: `https://api.higgsfield.ai/requests/${I.request}/cancel` };
  const files = new Map<string, Uint8Array<ArrayBuffer>>([[sourceKey, video], [photoKey, photo]]);
  const calls: string[] = [], jobs: O[] = [], quotes: O[] = [];
  let measured: O = {}, activated = true, outputStatus: "completed" | "canceled" = "completed";
  const runtime = { available: true, code: "ready", reason: "Test fixture only." };
  const execution_spec = { version: "presenter-motion-v1", prompt: "Replace only the approved presenter identity. Preserve property details." };
  const permissions = { can_cancel: true, can_review: false, can_preview: false, can_import: false };
  const deps: PresenterExecutionDeps = {
    liveConfigured: () => activated,
    sign: (key) => Promise.resolve(`https://storage.rendprop.com/${key}`),
    fetch: (url, init) => {
      calls.push(`fetch:${new URL(url).hostname}:${init.method ?? "GET"}`);
      if (new URL(url).hostname === "uploads.rendprop.com") return Promise.resolve(new Response(null, { status: 200 }));
      const b = new URL(url).hostname === "vendor.rendprop.com" ? video : files.get(new URL(url).pathname.slice(1));
      if (!b) throw new Error("Unexpected media URL");
      return Promise.resolve(new Response(b, { headers: { "content-type": "video/mp4", "content-length": String(b.length) } }));
    },
    estimate: () => { calls.push("estimate"); return Promise.resolve({ credits: "1.5", usd: "0.17", ceilingCents: 17 }); },
    submit: () => { calls.push("submit"); return Promise.resolve(vendor); },
    poll: () => { calls.push("poll"); return Promise.resolve(outputStatus === "completed" ? { status: "completed", video_url: "https://vendor.rendprop.com/result.mp4" } : { status: "canceled" }); },
    cancel: () => { calls.push("cancel"); return Promise.resolve("accepted"); },
    outputHosts: () => ["vendor.rendprop.com"],
    put: (key, bytes) => { calls.push("private-put"); files.set(key, bytes); return Promise.resolve(); },
    remove: (key) => { calls.push("delete"); files.delete(key); return Promise.resolve(); },
    uploadOrigin: () => "https://uploads.rendprop.com",
    upload: (path) => { calls.push(`upload:${path}`); return Promise.resolve({ asset_id: I.asset, mode: "single", put_url: `https://uploads.rendprop.com/v2/${I.asset}` }); },
    user(action, _listing, payload) {
      calls.push(`user:${action}`);
      if (action === "quote_prepare") return Promise.resolve({ snapshot, source_asset: source, reference_assets: [refPhoto], runtime, execution_spec, price_version: "verified-test-contract" });
      if (action === "quote_commit") { measured = payload.probe as O; quotes.push({ id: I.quote, draft_id: I.draft, draft_revision: 1, profile_revision: 1, quote_cents: 17, max_cost_cents: 100, expires_at: new Date(Date.now() + 120_000).toISOString() }); return Promise.resolve({}); }
      if (action === "create") {
        if (jobs.length) return Promise.resolve({ job: jobs[0], replayed: true });
        jobs.push({ id: I.job, org_id: I.org, listing_id: I.listing, quote_id: I.quote, draft_id: I.draft, draft_revision: 1, profile_revision: 1, revision: 1, state: "reserved", quote_cents: 17, held_cents: 100, max_cost_cents: 100, charged_cents: null, snapshot, probe: measured, output_key: outputKey, permissions });
        return Promise.resolve({ job: jobs[0], replayed: false });
      }
      if (action === "get") return Promise.resolve({ org_id: I.org, listing_id: I.listing, jobs, quotes, runtime });
      const job = jobs[0];
      if (action === "preview") return Promise.resolve({ job: { id: job.id, revision: job.revision }, output_key: outputKey, sha256: source.sha256, bytes: video.length, duration_s: 5 });
      if (action === "accept") { job.state = "accepted"; permissions.can_import = true; return Promise.resolve({ job }); }
      if (action === "cancel") { job.state = "cancel_requested"; job.cancel_requested_at = new Date().toISOString(); return Promise.resolve({ job }); }
      if (action === "reject") { job.state = "rejected"; return Promise.resolve({ job }); }
      if (action === "import_prepare") { job.state = "importing"; return Promise.resolve({ job, output_key: outputKey, sha256: source.sha256, bytes: video.length, duration_s: 5, import_asset_id: job.import_asset_id }); }
      throw new Error(`Unexpected user action ${action}`);
    },
    worker(_id, action, payload = {}) {
      calls.push(`worker:${action}`); const job = jobs[0];
      if (action === "read") return Promise.resolve({ job });
      if (action === "dispatch_prepare") return Promise.resolve({ allowed: job.state === "reserved", job, snapshot, execution_spec, probe: measured });
      if (action === "dispatch_claim") { if (job.state !== "reserved") return Promise.resolve({ claimed: false, job }); job.state = "dispatching"; return Promise.resolve({ claimed: true, dispatch_token: I.key, job }); }
      if (action === "dispatch_result") { Object.assign(job, payload, { state: "queued" }); return Promise.resolve({ job }); }
      if (action === "ambiguous") { job.state = "uncertain"; return Promise.resolve({ job }); }
      if (action === "failed" || action === "cancelled") { Object.assign(job, { state: action, charged_cents: payload.charged_cents, held_cents: 0 }); return Promise.resolve({ job }); }
      if (action === "output_claim") return Promise.resolve({ claimed: job.state === "queued", job, lease_token: I.key, write_deadline: new Date(Date.now() + 240_000).toISOString() });
      if (action === "output_ready") { equal(payload.lease_token, I.key); job.state = "review"; job.output_sha256 = payload.sha256; permissions.can_preview = permissions.can_review = true; return Promise.resolve({ job }); }
      if (action === "cleanup_claim") return Promise.resolve({ claimed: false });
      if (action === "import_bind") { job.import_asset_id = payload.asset_id; return Promise.resolve({ job }); }
      if (action === "import_commit") { job.state = "imported"; job.imported_asset_id = payload.asset_id; return Promise.resolve({ job }); }
      if (action === "status" || action === "sweep" || action === "completed") return Promise.resolve({ job });
      throw new Error(`Unexpected worker action ${action}`);
    },
  };
  const api = createPresenterExecution(deps);
  const quote = () => api.action(I.listing, { action: "quote", draft_id: I.draft, expected_revision: 1, expected_profile_revision: 1 });
  const generate = () => api.action(I.listing, { action: "generate", quote_id: I.quote, idempotency_key: I.key, cost_consent: true, max_cost_cents: 100 });
  return { api, deps, calls, jobs, quotes, files, source, photo: refPhoto, snapshot, video, quote, generate, activate: (v: boolean) => activated = v, cancelStatus: () => outputStatus = "canceled" };
}

Deno.test("presenter execution remains inert before configuration, including quotes", async () => {
  const h = await harness(); h.activate(false);
  await rejects(h.quote, "not activated"); await rejects(h.generate, "not activated");
  equal(h.calls, []);
});
Deno.test("revoked media cleanup proceeds during provider outage without releasing its cost hold", async () => {
  const h = await harness(); await h.quote(); await h.generate();
  h.jobs[0].state = "invalidated";
  const key = String(h.jobs[0].output_key); h.files.set(key, h.video);
  const worker = h.deps.worker;
  h.deps.worker = (id, action, payload) => {
    if (action === "cleanup_claim") return Promise.resolve({ claimed: true, cleanup_token: I.key, targets: [{ bucket: "uploads", key }] });
    if (action === "cleanup_done") { h.calls.push("cleanup-done"); equal(payload, { cleanup_token: I.key, objects_deleted: true }); return Promise.resolve({}); }
    return worker(id, action, payload);
  };
  h.deps.poll = () => Promise.reject(new Error("vendor unavailable"));
  await rejects(() => h.api.progress(I.job), "vendor unavailable");
  equal(h.files.has(key), false); equal(h.calls.includes("cleanup-done"), true);
  equal(h.jobs[0].charged_cents, null); equal(h.jobs[0].held_cents, 100);
  equal(h.calls.filter(c => c === "submit").length, 1);
});
Deno.test("presenter rejects unsupported client provider fields and missing exact cost consent", () => {
  for (const extra of [{ video_url: "https://attacker.com" }, { prompt: "replace approval" }, { quote_cents: 1 }]) {
    const input = { listing_id: I.listing, action: "quote", draft_id: I.draft, expected_revision: 1, expected_profile_revision: 1, ...extra };
    let threw = false; try { presenterExecutionInput(input); } catch { threw = true; } equal(threw, true);
  }
  let threw = false; try { presenterExecutionInput({ listing_id: I.listing, action: "generate", quote_id: I.quote, idempotency_key: I.key }); } catch { threw = true; } equal(threw, true);
});
Deno.test("actual source bytes and clocks override client duration before provider estimate", async () => {
  const h = await harness(); await h.quote(); equal(h.calls.filter((c) => c === "estimate").length, 1);
  await h.generate(); equal((h.jobs[0].probe as O).duration_s, 5);
  equal(h.jobs[0].held_cents, 100); equal(h.jobs[0].quote_cents, 17);
});
Deno.test("source or reference mutation cannot reach provider estimate", async () => {
  for (const target of ["source", "photo"] as const) {
    const h = await harness(); h[target].sha256 = "0".repeat(64);
    await rejects(h.quote, "changed"); equal(h.calls.includes("estimate"), false);
  }
});
Deno.test("approval changed during original verification cannot reach estimate", async () => {
  const h = await harness(), user = h.deps.user; let prepares = 0;
  h.deps.user = async (...args) => { const result = await user(...args); if (args[0] === "quote_prepare" && ++prepares === 2) return { ...result, snapshot: { ...h.snapshot, draft_revision: 2 } }; return result; };
  await rejects(h.quote, "changed"); equal(h.calls.includes("estimate"), false);
});
Deno.test("simulated quoted generation stays private until subject accepts then imports once", async () => {
  const h = await harness(); await h.quote(); await h.generate();
  equal(h.jobs[0].state, "queued"); equal(h.calls.some((c) => c.startsWith("upload:")), false);
  const reviewed = await h.api.action(I.listing, { action: "check", job_id: I.job, expected_revision: 1 });
  equal(h.jobs[0].state, "review"); equal(h.calls.filter((c) => c === "private-put").length, 1);
  const output = ((reviewed.jobs as O[])[0].output as O); equal(output.sha256, h.source.sha256);
  equal(h.jobs[0].charged_cents, null); equal(h.jobs[0].held_cents, 100);
  await h.api.action(I.listing, { action: "accept", job_id: I.job, expected_revision: 1, output_sha256: output.sha256, output_consent: true });
  await h.api.action(I.listing, { action: "import", job_id: I.job, expected_revision: 1 });
  equal(h.jobs[0].state, "imported"); equal(h.jobs[0].imported_asset_id, I.asset);
  equal(h.calls.filter((c) => c === "submit").length, 1);
});
Deno.test("ambiguous paid submission holds money and never submits on replay or check", async () => {
  const h = await harness(); h.deps.submit = () => { h.calls.push("submit"); return Promise.reject(new Error("connection lost")); };
  await h.quote(); await h.generate(); await h.generate(); await h.api.progress(I.job, true);
  equal(h.jobs[0].state, "uncertain"); equal(h.jobs[0].held_cents, 100); equal(h.calls.filter((c) => c === "submit").length, 1);
});
Deno.test("explicit provider rejection settles zero but status transport errors retain hold", async () => {
  const h = await harness(); h.deps.submit = () => Promise.reject(new ProviderError("higgsfield", "validation", "rejected", 422));
  await h.quote(); await h.generate(); equal(h.jobs[0].state, "failed"); equal(h.jobs[0].charged_cents, 0);
  const p = await harness(); await p.quote(); await p.generate(); p.deps.poll = () => Promise.reject(new Error("temporary"));
  await rejects(() => p.api.progress(I.job)); equal(p.jobs[0].state, "queued"); equal(p.jobs[0].held_cents, 100);
});
Deno.test("cancel acknowledgment alone is not refunded; terminal canceled status is", async () => {
  const h = await harness(); await h.quote(); await h.generate();
  h.deps.poll = () => Promise.resolve({ status: "in_progress" });
  await h.api.action(I.listing, { action: "cancel", job_id: I.job, expected_revision: 1 });
  equal(h.jobs[0].held_cents, 100); equal(h.calls.includes("cancel"), true);
  h.deps.poll = () => Promise.resolve({ status: "canceled" }); await h.api.progress(I.job);
  equal(h.jobs[0].held_cents, 0); equal(h.jobs[0].state, "cancelled");
});
Deno.test("unapproved output host never gets fetched or stored", async () => {
  const h = await harness(); await h.quote(); await h.generate(); h.deps.outputHosts = () => ["different.rendprop.com"];
  await rejects(() => h.api.progress(I.job), "not been approved"); equal(h.calls.includes("private-put"), false); equal(h.calls.includes("fetch:vendor.rendprop.com:GET"), false);
});
Deno.test("revoked output claim cannot download or repopulate private output", async () => {
  const h = await harness(); await h.quote(); await h.generate(); const worker = h.deps.worker;
  h.deps.worker = (...args) => args[1] === "output_claim" ? Promise.resolve({ claimed: false }) : worker(...args);
  await h.api.progress(I.job); equal(h.calls.includes("private-put"), false); equal(h.calls.includes("fetch:vendor.rendprop.com:GET"), false);
});
Deno.test("storage scope, URL schemes, MP4 duration and streaming bounds fail closed", async () => {
  const h = await harness();
  await rejects(() => originalAsset({ ...h.source, storage_key: `uploads/${I.org}/${I.listing}/%2e%2e/secret` }, I.org));
  for (const url of ["http://vendor.rendprop.com/x", "https://vendor.rendprop.com@localhost/x", "https://127.0.0.1/x", "https://vendor.rendprop.com:8080/x"]) await rejects(() => presenterOutputUrl(url, ["vendor.rendprop.com"]));
  await rejects(() => videoProbe(syntheticPresenterMP4(31)), "4 and 30");
  await rejects(() => mediaBytes(new Response(new Uint8Array(4), { headers: { "content-length": String(PRESENTER_VIDEO_BYTES + 1) } }), PRESENTER_VIDEO_BYTES));
  await rejects(() => mediaBytes(new Response(new Uint8Array(5)), 4));
});
