// Real SQL + real controller, synthetic media and mocked network transports.
// Started only by presenter_execution.py --controller inside its owned,
// disposable Unix-socket cluster. No configured DB URL/provider is consulted.
import { createPresenterExecution, type PresenterExecutionDeps, type PresenterObject as O } from "./presenter-execution.ts";
import { syntheticPresenterMP4 } from "./presenter-test-fixtures.ts";
import { sha256 } from "./presenter-media.ts";

const fixturePath = Deno.env.get("PRESENTER_PG_FIXTURE");
const fixture = fixturePath ? JSON.parse(await Deno.readTextFile(fixturePath)) as { psql: string[] } : null;
function eq(a: unknown, b: unknown, label = "value") { if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${label}: ${JSON.stringify(a)} != ${JSON.stringify(b)}`); }
function sqlString(value: unknown) { return value === null ? "null" : "'" + String(value).replaceAll("'", "''") + "'"; }
function sqlJson(value: unknown) { return sqlString(JSON.stringify(value)) + "::jsonb"; }
async function sql(query: string): Promise<string> {
  if (!fixture || !fixture.psql[0].endsWith("/psql") || !fixture.psql.includes("--no-password") || !fixture.psql[fixture.psql.indexOf("-h") + 1].includes("/build/pex-")) throw new Error("Owned local PostgreSQL fixture is required");
  const process = new Deno.Command(fixture.psql[0], { args: fixture.psql.slice(1), stdin: "piped", stdout: "piped", stderr: "piped", clearEnv: true, env: { PATH: "/usr/bin:/bin", LC_ALL: "C" } }).spawn();
  const writer = process.stdin.getWriter(); await writer.write(new TextEncoder().encode(query)); await writer.close();
  const result = await process.output();
  if (!result.success) throw new Error(new TextDecoder().decode(result.stderr));
  return new TextDecoder().decode(result.stdout).trim();
}
async function rpc(name: string, args: unknown[]): Promise<O> { return JSON.parse(await sql(`set role service_role;select public.${name}(${args.map((a) => typeof a === "object" && a !== null ? sqlJson(a) : sqlString(a)).join(",")});`)); }
async function denied(fn: () => Promise<unknown>, contains: string) { try { await fn(); } catch (error) { if (error instanceof Error && error.message.includes(contains)) return; throw error; } throw new Error(`Expected ${contains}`); }
const uuid = (n: number) => `91000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const org = uuid(1), listing = uuid(2), subject = uuid(3), author = uuid(4), photoId = uuid(5), sourceId = uuid(6), draftId = uuid(7);

Deno.test({ name: "real local SQL controller lifecycle: quote, hold, one submit, private subject review, native quota import, cleanup, ambiguous and refunded cancellation", ignore: !fixture, async fn() {
  const video = syntheticPresenterMP4(), photo = new Uint8Array([255, 216, 255, 0, 255, 217]);
  const sourceKey = `uploads/${org}/${listing}/${sourceId}.mp4`, photoKey = `uploads/${org}/${listing}/${photoId}.jpg`;
  const videoSha = await sha256(video), photoSha = await sha256(photo);
  const files = new Map<string, Uint8Array<ArrayBuffer>>([[sourceKey, video], [photoKey, photo]]), operations = new Map<string, O>();
  const calls: string[] = [];
  await sql(`insert into auth.users(id,email) values('${subject}','subject@controller.fixture.invalid'),('${author}','author@controller.fixture.invalid');
    insert into public.orgs(id,name) values('${org}','Controller offline fixture');
    insert into public.memberships(user_id,org_id,role) values('${subject}','${org}','agent'),('${author}','${org}','admin');
    insert into public.listings(id,org_id,agent_id) values('${listing}','${org}','${subject}');
    insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,sha256,bytes,duration_s) values
      ('${photoId}','${listing}','photo','uploads','${photoKey}',true,'${photoSha}',${photo.length},null),
      ('${sourceId}','${listing}','video','uploads','${sourceKey}',true,'${videoSha}',${video.length},5);`);
  const workspace = (actor: string, action: string, payload: O) => rpc("studio_presenter_workspace", [actor, org, listing, action, payload]);
  let prepared = await workspace(subject, "save_profile", { expected_revision: 0, display_name: "Test represented person", reference_asset_ids: [photoId] });
  const profile = (prepared.profiles as O[]).find((p) => p.subject_user_id === subject)!;
  prepared = await workspace(subject, "approve_profile", { profile_id: profile.id, expected_revision: profile.revision, likeness_consent: true });
  const approved = (prepared.profiles as O[]).find((p) => p.id === profile.id)!;
  prepared = await workspace(author, "save_draft", { draft_id: draftId, expected_revision: 0, expected_profile_revision: approved.revision, profile_id: approved.id, title: "Offline fixture", script: "This is a recording guide, not a visual instruction.", source_asset_id: sourceId, format: "listing_intro", resolution: "720p" });
  const draft = (prepared.drafts as O[]).find((d) => d.id === draftId)!;
  prepared = await workspace(subject, "approve_draft", { draft_id: draftId, expected_revision: draft.revision, expected_profile_revision: approved.revision, source_performance_consent: true });
  const approvedDraft = (prepared.drafts as O[]).find((d) => d.id === draftId)!;
  let actor = author, submitMode: "ok" | "uncertain" = "ok", statusMode: "completed" | "canceled" = "completed";
  let submitted = 0;
  const deps: PresenterExecutionDeps = {
    user: (action, scope, payload) => rpc("studio_presenter_execution", [actor, org, scope, action, payload]),
    worker: (job, action, payload = {}) => rpc("studio_presenter_execution_worker", [job, action, payload]),
    liveConfigured: () => true,
    sign: (key) => Promise.resolve(`https://storage.rendprop.com/${key}`),
    outputHosts: () => ["vendor.rendprop.com"],
    estimate: () => { calls.push("estimate"); return Promise.resolve({ credits: "1", usd: "0.17", ceilingCents: 17 }); },
    submit: (input) => {
      calls.push("submit"); submitted++;
      eq(input.prompt?.includes("recording guide"), false, "guide is not visual prompt");
      if (submitMode === "uncertain") return Promise.reject(new Error("simulated lost provider reply"));
      const request_id = crypto.randomUUID();
      return Promise.resolve({ request_id, status_url: `https://api.higgsfield.ai/requests/${request_id}/status`, cancel_url: `https://api.higgsfield.ai/requests/${request_id}/cancel` });
    },
    poll: () => Promise.resolve(statusMode === "canceled" ? { status: "canceled" } : { status: "completed", video_url: "https://vendor.rendprop.com/result.mp4" }),
    cancel: () => Promise.resolve("accepted"),
    put: (key, bytes) => { calls.push("private-put"); files.set(key, bytes); return Promise.resolve(); },
    remove: (key) => { calls.push("delete"); files.delete(key); return Promise.resolve(); },
    uploadOrigin: () => "https://uploads.rendprop.com",
    async fetch(url, init) {
      const parsed = new URL(url);
      if (parsed.hostname === "uploads.rendprop.com") {
        const opId = parsed.pathname.split("/").pop()!, op = operations.get(opId)!;
        if (!op) throw new Error("Unknown upload operation");
        const claim = crypto.randomUUID(); await rpc("claim_upload_operation", [opId, claim]);
        files.set(String(op.object_key), video);
        await rpc("finish_upload_operation", [opId, claim, "stored", "offline-etag", null, "video/mp4"]);
        return new Response(null, { status: 200 });
      }
      if (init.method === "PUT") throw new Error("Unexpected PUT transport");
      const bytes = parsed.hostname === "vendor.rendprop.com" ? video : files.get(parsed.pathname.slice(1));
      if (!bytes) throw new Error("Missing synthetic media");
      return new Response(bytes, { headers: { "content-type": "video/mp4", "content-length": String(bytes.length) } });
    },
    async upload(path, body, requestKey) {
      calls.push(`upload:${path}`);
      let asset: O;
      if (path === "uploads") {
        const assetId = crypto.randomUUID();
        const list = await rpc("reserve_upload_assets", [actor, [{ id: assetId, listing_id: listing, kind: "video", bucket: "renders", storage_key: `renders/${org}/${listing}/${assetId}.mp4`, bytes: body.bytes, content_type: "video/mp4", content_type_declared: true, sha256: body.sha256, idem_key: requestKey }]]) as unknown as O[];
        asset = list[0];
      } else {
        const assetId = path.split("/")[1];
        asset = JSON.parse(await sql(`select row_to_json(a) from public.capture_assets a where id='${assetId}';`));
        if (path.endsWith("/complete")) {
          const op = await rpc("plan_upload_operation", [assetId, "copy", 0]), claim = crypto.randomUUID();
          await rpc("claim_upload_operation", [op.id, claim]); files.set(String(op.object_key), video);
          await rpc("finish_upload_operation", [op.id, claim, "stored", "offline-copy-etag", null, "video/mp4"]);
          return await rpc("settle_upload_reservation", [assetId, true, op.id, body]);
        }
      }
      if (asset.uploaded === true) return { ...asset, asset_id: asset.id, mode: "single" };
      const op = await rpc("plan_upload_operation", [asset.id, "single", 0]); operations.set(String(op.id), op);
      return { ...asset, asset_id: asset.id, mode: "single", put_url: `https://uploads.rendprop.com/v2/${op.id}` };
    },
  };
  const api = createPresenterExecution(deps);
  const quotePayload = { action: "quote", draft_id: draftId, expected_revision: approvedDraft.revision, expected_profile_revision: approved.revision };
  await denied(() => api.action(listing, quotePayload), "not activated"); eq(calls.length, 0, "disabled before media");
  await sql(`insert into public.studio_presenter_runtime(org_id,enabled,enterprise_no_training_confirmed,contract_reference,price_version,max_job_cents,total_budget_cents) values('${org}',true,true,'OFFLINE TEST ONLY','fixture-v1',100,1000);`);
  async function makeJob() {
    const quoted = await api.action(listing, quotePayload), quote = (quoted.quotes as O[])[0];
    const payload = { action: "generate", quote_id: quote.id, idempotency_key: crypto.randomUUID(), cost_consent: true, max_cost_cents: quote.max_cost_cents };
    const created = await api.action(listing, payload), job = (created.jobs as O[]).find((j) => j.quote_id === quote.id)!;
    return { quote, payload, job };
  }
  const first = await makeJob(); eq(first.quote.quote_cents, 17); eq(first.quote.max_cost_cents, 100); eq(first.job.status, "queued"); eq(first.job.held_cents, 100);
  await api.action(listing, first.payload); eq(submitted, 1, "replayed generation is not resubmitted");
  let result = await api.action(listing, { action: "check", job_id: first.job.id, expected_revision: first.job.revision });
  let job = (result.jobs as O[]).find((j) => j.id === first.job.id)!;
  eq(job.status, "review"); eq(job.output, null, "agency cannot view unapproved subject output");
  await denied(() => api.action(listing, { action: "accept", job_id: job.id, expected_revision: job.revision, output_sha256: videoSha, output_consent: true }), "Only the represented person");
  actor = subject; result = await api.envelope(listing); job = (result.jobs as O[]).find((j) => j.id === first.job.id)!;
  eq((job.output as O).sha256, videoSha); eq(typeof (job.output as O).preview_url, "string");
  await api.action(listing, { action: "accept", job_id: job.id, expected_revision: job.revision, output_sha256: videoSha, output_consent: true });
  actor = author; result = await api.envelope(listing); job = (result.jobs as O[]).find((j) => j.id === first.job.id)!;
  result = await api.action(listing, { action: "import", job_id: job.id, expected_revision: job.revision }); job = (result.jobs as O[]).find((j) => j.id === first.job.id)!;
  eq(job.status, "imported"); eq(job.held_cents, 100, "successful billing remains held until confirmed");
  const imported = JSON.parse(await sql(`select row_to_json(a) from public.capture_assets a where id='${job.imported_asset_id}';`));
  eq(imported.uploaded, true); eq(imported.sha256, videoSha); eq(imported.duration_s, 5); eq(imported.presenter_job_id, job.id);
  eq(await sql(`select count(*) from public.media_provenance where altered_key=${sqlString(imported.storage_key)};`), "1");
  eq(await sql(`select state from public.upload_reservations where asset_id='${job.imported_asset_id}';`), "completed");
  actor = subject; await api.action(listing, { action: "reject", job_id: job.id, expected_revision: job.revision });
  eq(await sql(`set role service_role;select public.studio_presenter_asset_access('${imported.id}');`), "f", "rejected imports cannot be read");
  eq(await sql(`select count(*) from public.media_provenance where altered_key=${sqlString(imported.storage_key)};`), "0", "rejected provenance carries no usable output key");
  await sql(`update public.studio_presenter_jobs set output_write_deadline=clock_timestamp()-interval '2 minutes' where id='${job.id}';`);
  await api.cleanup(String(job.id)); eq(files.has(`presenter-private/${org}/${job.id}/output.mp4`), false); eq(files.has(imported.storage_key), false);
  eq(await sql(`select cleanup_state from public.studio_presenter_jobs where id='${job.id}';`), "done");
  actor = author; submitMode = "uncertain"; const second = await makeJob(); eq(second.job.status, "uncertain");
  await api.action(listing, second.payload); await api.progress(String(second.job.id), true); eq(submitted, 2); eq(second.job.held_cents, 100);
  submitMode = "ok"; const third = await makeJob(); statusMode = "canceled";
  result = await api.action(listing, { action: "cancel", job_id: third.job.id, expected_revision: third.job.revision });
  job = (result.jobs as O[]).find((j) => j.id === third.job.id)!;
  eq(job.status, "cancelled"); eq(job.held_cents, 0); eq(job.charged_cents, 0); eq(submitted, 3);
  console.log("Controller/SQL verified: disabled gate, exact estimate+maximum, one POST, private subject review, native reservation/single+copy receipts, publication/provenance, deletion, ambiguity hold, confirmed cancellation refund. No real network/media/cost.");
} });
