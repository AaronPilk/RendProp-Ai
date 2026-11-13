import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { publicationFixture, publicationID } from "../_shared/photo-publication.fixture.ts";

// Exercise the actual PATCH route with an accepted photo proof whose current
// ai-router candidate key is hidden by the Presenter SELECT policy. The service
// preflight may identify it, but only the signed-in listing editor can bind an
// exact uploaded result through the existing authenticated database RPC.
const ACTOR = "f6201105-0000-4000-8000-000000000001";
const ORG = "f6201105-0000-4000-8000-000000000002";
const OTHER_ORG = "f6201105-0000-4000-8000-000000000003";
const LISTING = "f6201105-0000-4000-8000-000000000004";
const OTHER_LISTING = "f6201105-0000-4000-8000-000000000005";
const PROOF = "f6201105-0000-4000-8000-000000000006";
const ASSET = "f6201105-0000-4000-8000-000000000007";
const EVIDENCE = "f6201105-0000-4000-8000-000000000008";
const CHECK = "f6201105-0000-4000-8000-000000000009";
const OTHER_ACTOR = "f6201105-0000-4000-8000-000000000010";
const originalKey = `renders/${ORG}/${LISTING}/original-${ASSET}.jpg`;
const alteredKey = `renders/${ORG}/${LISTING}/gallery-${ASSET}.jpg`;

for (const [key, value] of Object.entries({
  SUPABASE_URL: "https://compliance-patch-fixture.invalid",
  SUPABASE_SERVICE_ROLE_KEY: "fixture-service",
  SUPABASE_ANON_KEY: "fixture-anon",
})) Deno.env.set(key, value);

// The shared Supabase client captures these fixture variables at module load.
// Load the Studio handler only after the fixture environment is installed.
const { handleListingActions } = await import("../studio/listing-actions.ts");

type Handler = (request: Request) => Promise<Response>;
let handler!: Handler;
let directPatch!: typeof import("./index.ts").handleCompliancePatch;
const serve = Object.getOwnPropertyDescriptor(Deno, "serve")!;
try {
  Object.defineProperty(Deno, "serve", {
    configurable: true,
    writable: true,
    value: (fn: Handler) => { handler = fn; return {}; },
  });
  directPatch = (await import("./index.ts")).handleCompliancePatch;
} finally {
  Object.defineProperty(Deno, "serve", serve);
}

type Mode = "owned" | "foreign-listing" | "revoked-team" | "marketing" |
  "wrong-org" | "wrong-library" | "hidden-unbound" | "missing" |
  "held" | "foreign-actor" | "unrelated-hidden" | "invalid-asset" | "open-check" | "foreign-check";

async function attempt(mode: Mode, patch: Record<string, unknown> = { altered_asset_id: ASSET }): Promise<{ status: number; body: Record<string, unknown>; calls: string[] }> {
  const previous = globalThis.fetch;
  const calls: string[] = [];
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
  const prior = mode === "missing" ? null : {
    id: PROOF,
    org_id: mode === "wrong-org" ? OTHER_ORG : ORG,
    listing_id: mode === "hidden-unbound" ? null : mode === "foreign-listing" ? OTHER_LISTING : LISTING,
    kind: "declutter",
    altered_key: mode === "unrelated-hidden" ? "private/unrelated.jpg" :
      `ai-router/${mode === "wrong-org" ? OTHER_ORG : ORG}/photo-evidence/${ACTOR}/${EVIDENCE}/candidate.jpg`,
    qc: { publishable: mode !== "held", action: mode === "held" ? "hold" : "accept", evidence_id: EVIDENCE, check_id: CHECK },
  };
  globalThis.fetch = async (input, init) => {
    const req = new Request(input, init), url = new URL(req.url);
    assertEquals(url.hostname, "compliance-patch-fixture.invalid");
    calls.push(`${req.method} ${url.pathname}`);
    if (url.pathname === "/auth/v1/user") return json({ id: ACTOR, is_anonymous: false });
    if (url.pathname === "/rest/v1/media_provenance") {
      assertEquals(url.searchParams.get("id"), `eq.${PROOF}`);
      const serviceRead = req.headers.get("authorization") === "Bearer fixture-service";
      // Presenter RLS hides this row from the user until its altered key is
      // attached; the service fallback reads bounded proof fields for an
      // accepted result only, never its media contents.
      assertEquals(url.searchParams.get("select"), serviceRead ? "id,org_id,listing_id,kind,altered_key,qc" : "id,org_id,listing_id");
      return json(serviceRead ? prior : null);
    }
    if (url.pathname === "/rest/v1/rpc/listing_library_scope") {
      const body = await req.json();
      assertEquals(body.p_actor, ACTOR);
      assertEquals(body.p_listing, prior?.listing_id);
      if (mode === "foreign-listing") return json({ message: "RP404: Listing unavailable" }, 400);
      return json({
        actor_id: ACTOR, listing_id: LISTING, org_id: ORG, library_org_id: ORG,
        listing_owner_user_id: ACTOR, library_owner_user_id: ACTOR,
        role: mode === "marketing" ? "marketing" : "owner", access_mode: "own", can_read: true,
        can_write: mode !== "revoked-team",
        can_manage_subscription: true, billing_org_id: ORG, team_org_id: null,
      });
    }
    if (url.pathname === "/rest/v1/photo_edit_evidence") {
      assertEquals(req.headers.get("authorization"), "Bearer fixture-service");
      assertEquals(url.searchParams.get("provenance_id"), `eq.${PROOF}`);
      return json([{
        id: EVIDENCE, actor_id: mode === "foreign-actor" ? OTHER_ACTOR : ACTOR,
        org_id: ORG, library_org_id: ORG, listing_id: LISTING,
        provenance_id: PROOF, state: "accept", purpose: "prospective",
        output: { key: prior?.altered_key },
      }]);
    }
    if (url.pathname === "/rest/v1/photo_quality_checks") {
      assertEquals(req.headers.get("authorization"), "Bearer fixture-service");
      assertEquals(url.searchParams.get("evidence_id"), `eq.${EVIDENCE}`);
      assertEquals(url.searchParams.get("automatic"), "eq.true");
      return json([{ id: mode === "foreign-check" ? OTHER_ORG : CHECK, evidence_id: EVIDENCE, state: mode === "open-check" ? "checking" : "accept", automatic: true }]);
    }
    if (url.pathname === "/rest/v1/rpc/set_provenance_media") {
      assertEquals(req.headers.get("authorization"), "Bearer fixture-user");
      const body = await req.json();
      assertEquals(body.p_id, PROOF);
      assertEquals(body.p_original_asset, null);
      assertEquals(body.p_altered_asset, ASSET);
      if (mode === "invalid-asset") return json({ message: "RP409: Asset is not an uploaded photo in this listing" }, 400);
      if (mode === "marketing") return json({ message: "RP403: your role does not permit editing AI provenance" }, 400);
      return json({
        id: PROOF, org_id: ORG, listing_id: LISTING, kind: "declutter",
        label: null, disclosure: "Digitally decluttered; compare with the original.",
        original_key: originalKey, altered_key: alteredKey, created_at: "2026-11-05T15:00:00Z",
      });
    }
    if (url.pathname === "/rest/v1/rpc/studio_presenter_media_visibility") {
      const body = await req.json();
      assertEquals(body.p_listing, LISTING);
      return json({ assets: {}, renders: {}, keys: Object.fromEntries(body.p_keys.map((key: string) => [key, false])) });
    }
    throw Error(`Unexpected fixture request: ${req.method} ${url.pathname}`);
  };
  try {
    const response = await handler(new Request(`https://edge.invalid/me/compliance/${PROOF}`, {
      method: "PATCH",
      headers: {
        authorization: "Bearer fixture-user",
        "content-type": "application/json",
        "x-org-id": mode === "wrong-library" ? OTHER_ORG : ORG,
      },
      body: JSON.stringify(patch),
    }));
    return { status: response.status, body: await response.json(), calls };
  } finally { globalThis.fetch = previous; }
}

Deno.test("accepted AI-router disclosure can attach the exact result after caller listing authority", async () => {
  const result = await attempt("owned");
  assertEquals(result.status, 200);
  assertEquals(result.body.ok, true);
  assertEquals(result.calls.filter((x) => x.endsWith("/set_provenance_media")).length, 1);
  assertEquals(result.calls.filter((x) => x.endsWith("/listing_library_scope")).length, 3);
  // The restrictive user SELECT is intentionally irrelevant to listing-bound
  // identity; media links stay withheld by their independent visibility gate.
  assertEquals(result.body.provenance && (result.body.provenance as Record<string, unknown>).altered_url, null);
});

Deno.test("service preflight never turns another listing, org, or library into a writable disclosure", async () => {
  for (const mode of ["foreign-listing", "revoked-team", "wrong-org", "wrong-library", "hidden-unbound", "missing", "held", "foreign-actor", "unrelated-hidden"] as const) {
    const result = await attempt(mode);
    assert(result.status === 403 || result.status === 404 || result.status === 503, `${mode}: ${result.status}`);
    assertEquals(result.calls.some((x) => x.endsWith("/set_provenance_media")), false, mode);
  }
});

Deno.test("authenticated binding still refuses marketing role and non-listing assets", async () => {
  for (const [mode, status] of [["marketing", 403], ["invalid-asset", 409]] as const) {
    const result = await attempt(mode);
    assertEquals(result.status, status);
    assertEquals(result.body.ok, undefined);
    assertEquals(result.calls.filter((x) => x.endsWith("/set_provenance_media")).length, 1);
  }
});

Deno.test("hidden provenance cannot be relabeled or have its original reassigned through fallback", async () => {
  for (const body of [
    { label: "Unsafe replacement" },
    { original_asset_id: ASSET },
    { altered_asset_id: ASSET, label: "Unsafe replacement" },
  ]) {
    const result = await attempt("owned", body);
    assertEquals(result.status, 404);
    assertEquals(result.calls.some((x) => x.endsWith("/set_provenance_media")), false);
    assertEquals(result.calls.some((x) => x.endsWith("/photo_edit_evidence")), false);
  }
});

Deno.test("an accepted edit can attach its exact result while its advisory check is still open", async () => {
  const result = await attempt("open-check");
  assertEquals(result.status, 200);
  assertEquals(result.body.ok, true);
  assertEquals(result.calls.filter((x) => x.endsWith("/set_provenance_media")).length, 1);
  // The check must still be this edit's own automatic check.
  const foreign = await attempt("foreign-check");
  assertEquals(foreign.status, 404);
  assertEquals(foreign.calls.some((x) => x.endsWith("/set_provenance_media")), false);
});

type RecoveryMode = "same" | "new" | "marketing" | "wrong-actor" | "wrong-listing" |
  "wrong-sha" | "wrong-key" | "refused" | "canonical-conflict";

async function savedResultRetry(mode: RecoveryMode) {
  const f = await publicationFixture({ bound: true });
  const priorAsset = mode === "same" ? f.asset : publicationID(31);
  const priorKey = mode === "same" ? f.targetKey : `renders/${f.org}/${f.listing}/gallery-${priorAsset}.jpg`;
  let pointer = f.outputKey;
  let firstPatchCount = 0;
  const calls: string[] = [];
  const previous = globalThis.fetch;
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
    status, headers: { "content-type": "application/json" },
  });
  globalThis.fetch = async (input, init) => {
    const req = new Request(input, init), url = new URL(req.url);
    assertEquals(url.hostname, "compliance-patch-fixture.invalid");
    calls.push(`${req.method} ${url.pathname}`);
    if (url.pathname === "/rest/v1/media_provenance") {
      assertEquals(url.searchParams.get("id"), `eq.${f.original}`);
      const service = req.headers.get("authorization") === "Bearer fixture-service";
      assertEquals(url.searchParams.get("select"), service ? "id,org_id,listing_id,kind,altered_key,qc" : "id,org_id,listing_id");
      return json(service ? {
        id: f.original, org_id: f.org, listing_id: mode === "wrong-listing" ? publicationID(99) : f.listing,
        kind: "declutter", altered_key: pointer,
        qc: { publishable: true, action: "accept", evidence_id: f.evidence, check_id: f.check },
      } : null);
    }
    if (url.pathname === "/rest/v1/rpc/listing_library_scope") {
      const body = await req.json();
      assertEquals(body.p_actor, f.actor);
      return json({ actor_id: f.actor, listing_id: f.listing, org_id: f.org, library_org_id: f.library,
        listing_owner_user_id: f.actor, library_owner_user_id: f.actor,
        role: mode === "marketing" ? "marketing" : "owner", access_mode: "own", can_read: true, can_write: true,
        can_manage_subscription: true, billing_org_id: f.org, team_org_id: null });
    }
    if (url.pathname === "/rest/v1/photo_edit_evidence") {
      assertEquals(req.headers.get("authorization"), "Bearer fixture-service");
      assertEquals(url.searchParams.get("provenance_id"), `eq.${f.original}`);
      return json([{ id: f.evidence, actor_id: mode === "wrong-actor" ? publicationID(98) : f.actor,
        org_id: f.org, library_org_id: f.library, listing_id: f.listing, provenance_id: f.original,
        state: mode === "refused" ? "refuse" : "accept", purpose: "prospective",
        output: { key: f.outputKey, sha256: f.outputSHA, bytes: f.output.length, mime: "image/jpeg" } }]);
    }
    if (url.pathname === "/rest/v1/photo_quality_checks") return json([
      { id: f.check, evidence_id: f.evidence, state: "checking", automatic: true },
    ]);
    if (url.pathname === "/rest/v1/capture_assets") {
      assertEquals(req.headers.get("authorization"), "Bearer fixture-service");
      assertEquals(url.searchParams.get("id"), `eq.${f.asset}`);
      return json({ id: f.asset, listing_id: f.listing, kind: "photo", bucket: "renders", uploaded: true,
        storage_key: mode === "wrong-key" ? `renders/${f.org}/${publicationID(99)}/wrong.jpg` : f.targetKey,
        sha256: mode === "wrong-sha" ? "0".repeat(64) : f.outputSHA,
        bytes: f.output.length, content_type: "image/jpeg" });
    }
    if (url.pathname === "/rest/v1/rpc/set_provenance_media") {
      const body = await req.json();
      assertEquals(body.p_id, f.original);
      assertEquals(body.p_altered_asset, priorAsset);
      firstPatchCount++;
      pointer = priorKey;
      return json({ id: f.original, org_id: f.org, listing_id: f.listing, kind: "declutter",
        label: null, disclosure: "Digitally decluttered; compare the submitted source.",
        original_key: `renders/${f.org}/${f.listing}/original.jpg`, altered_key: pointer });
    }
    if (url.pathname === "/rest/v1/rpc/studio_presenter_media_visibility") {
      const body = await req.json();
      return json({ assets: {}, renders: {}, keys: Object.fromEntries(body.p_keys.map((key: string) => [key, false])) });
    }
    throw Error(`Unexpected fixture request: ${req.method} ${url.pathname}`);
  };
  const request = (asset: string) => new Request(`https://edge.invalid/me/compliance/${f.original}`, {
    method: "PATCH", headers: { authorization: "Bearer fixture-user", "content-type": "application/json", "x-org-id": f.library },
    body: JSON.stringify({ altered_asset_id: asset }),
  });
  try {
    if (mode === "same" || mode === "new") {
      const first = await directPatch(request(priorAsset), f.actor, f.original);
      assertEquals(first.status, 200);
      assertEquals(firstPatchCount, 1);
    } else pointer = priorKey;
    if (mode === "canonical-conflict") f.state.resolveError = "RP409: This saved photo already has a different canonical publication target";
    try {
      const response = await directPatch(request(f.asset), f.actor, f.original, { client: f.client, io: f.io });
      return { status: response.status, body: await response.json(), calls, state: f.state, firstPatchCount, fixture: f };
    } catch (error) {
      if (!error || typeof error !== "object" || !("status" in error)) throw error;
      return { status: Number(error.status), body: {}, calls, state: f.state, firstPatchCount, fixture: f };
    }
  } finally { globalThis.fetch = previous; }
}

Deno.test("a failed gallery attach can recover the same saved upload or a fresh exact upload without another disclosure mutation", async () => {
  for (const mode of ["same", "new"] as const) {
    const result = await savedResultRetry(mode);
    assertEquals(result.status, 200, mode);
    assertEquals(result.body.source_provenance_id, publicationID(9));
    assertEquals((result.body.provenance as Record<string, unknown>).id, publicationID(10));
    assertEquals(result.state.phase, "prepared");
    assertEquals(result.firstPatchCount, 1);
    assertEquals(result.calls.filter((call) => call.endsWith("/set_provenance_media")).length, 1);
    assertEquals(result.state.calls.map(({ name }) => name).filter((name) => name.startsWith("photo_publication_")), [
      "photo_publication_target", "photo_publication_resolve", "photo_publication_reserve", "photo_publication_finish",
    ]);
  }
});

Deno.test("a fresh exact retry proceeds from recovered disclosure to the ordinary Studio attachment", async () => {
  const { status, fixture: f } = await savedResultRetry("new");
  assertEquals(status, 200);
  const steps: string[] = [];
  const scope = { actor_id: f.actor, org_id: f.org, library_org_id: f.library, listing_id: f.listing,
    listing_owner_user_id: f.actor, library_owner_user_id: f.actor, role: "owner", access_mode: "own",
    can_read: true, can_write: true, can_manage_subscription: false, billing_org_id: f.org, team_org_id: null };
  const admin = {
    rpc: async (name: string, args: Record<string, unknown>) => {
      if (name === "listing_library_scope") return { data: scope, error: null };
      if (name === "studio_attach_photo_from_upload") {
        steps.push("attach");
        assertEquals(args, { p_actor: f.actor, p_org: f.org, p_listing: f.listing,
          p_asset: f.asset, p_caption: "Edited kitchen", p_provenance: f.pub });
        assertEquals(f.state.phase, "prepared");
        return { data: { ok: true, created: true, photo: { id: f.asset, listing_id: f.listing } }, error: null };
      }
      return await f.client.rpc(name, args);
    },
    from: (table: string) => {
      assertEquals(table, "photo_edit_evidence");
      const query = {
        select: (_columns: string) => query,
        eq: (_key: string, _value: string) => query,
        limit: (_count: number) => query,
        then: (resolve: (value: unknown) => void) => {
          steps.push("evidence");
          resolve({ data: [{ ...f.state.e, output: { sha256: f.outputSHA, bytes: f.output.length } }], error: null });
        },
      };
      return query;
    },
  };
  const db = { from: (table: string) => {
    assertEquals(table, "capture_assets");
    const query = {
      select: (_columns: string) => query,
      eq: (_column: string, _value: string) => query,
      maybeSingle: async () => {
        steps.push("asset-read");
        assertEquals(f.state.phase, "prepared");
        return { data: { id: f.asset, listing_id: f.listing, uploaded: true,
          bucket: "renders", kind: "photo", content_type: "image/jpeg", storage_key: f.targetKey }, error: null };
      },
    };
    return query;
  } };
  const response = await handleListingActions(new Request("https://edge.invalid/functions/v1/studio/photos", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ listing_id: f.listing, asset_id: f.asset, provenance_id: f.original, caption: "Edited kitchen" }),
  }), { userId: f.actor, orgId: f.org, authorizeListing: async (listing) => assertEquals(listing, f.listing),
    admin, db, publicationIO: f.io });
  assertEquals(response?.status, 201);
  assertEquals(steps, ["evidence", "asset-read", "attach"]);
  assertEquals(f.state.claims, 1);
  assertEquals(f.state.writes, 1);
});

Deno.test("saved-output recovery refuses role, identity, key, SHA, evidence and canonical-target conflicts", async () => {
  for (const [mode, status] of [
    ["marketing", 403], ["wrong-actor", 404], ["wrong-listing", 404], ["wrong-sha", 404],
    ["wrong-key", 404], ["refused", 404], ["canonical-conflict", 409],
  ] as const) {
    const result = await savedResultRetry(mode);
    assertEquals(result.status, status, mode);
    assertEquals(result.firstPatchCount, 0, mode);
    assertEquals(result.state.phase, null, mode);
    assertEquals(result.calls.some((call) => call.endsWith("/set_provenance_media")), false, mode);
  }
});
