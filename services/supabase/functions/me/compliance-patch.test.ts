import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";

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

type Handler = (request: Request) => Promise<Response>;
let handler!: Handler;
const serve = Object.getOwnPropertyDescriptor(Deno, "serve")!;
try {
  Object.defineProperty(Deno, "serve", {
    configurable: true,
    writable: true,
    value: (fn: Handler) => { handler = fn; return {}; },
  });
  await import("./index.ts");
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
