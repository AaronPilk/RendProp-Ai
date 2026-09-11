// logic.test.ts — the two account-deletion decisions an external release audit
// found broken.
//
//   deno test --allow-env services/supabase/functions/me/logic.test.ts
//
// Everything under test is PURE (logic.ts has no network, no env, no
// Deno.serve), so these are exact assertions rather than approximations: no
// stubbed fetch, no database, no server. index.ts is deliberately not imported
// — it calls Deno.serve at module load (same split as events/schema.ts,
// apple-subscriptions/logic.ts).
//
// What is being defended:
//   1. P0-4     cleanup_complete (via payloadEmpty) must read false while ANY
//               destructive step — including the two that used to run AFTER
//               the tombstone was already marked completed (forgetting
//               analytics, deleting the profile row) — has not actually
//               finished. Apple requires that a reported account deletion is
//               real; a payload that "looks done" while one field still holds
//               a pending id is the exact bug.
//   2. cross-tenant CRM deletion  decideGhlTagAction() is the entire policy
//               for what account deletion may do to a GHL contact shared
//               across a single CRM location. It must never choose "delete"
//               unless this tenant's own tag is confirmed present AND no
//               other tenant's tag is on the same contact.

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { ghlOrgTag } from "../_shared/ghl.ts";
import {
  chunk,
  dbEmpty,
  decideGhlTagAction,
  type DeletionPayload,
  payloadEmpty,
} from "./logic.ts";

function emptyPayload(): DeletionPayload {
  return { r2: [], stream_uids: [], ghl_targets: [], apple_refresh_token: null };
}

// ── 1. payloadEmpty / dbEmpty — the cleanup_complete source of truth ─────────

Deno.test("payloadEmpty: a freshly-constructed empty payload is empty", () => {
  assertEquals(payloadEmpty(emptyPayload()), true);
});
Deno.test("payloadEmpty: a retained Auth identity prevents completion", () => {
  assertEquals(payloadEmpty({ ...emptyPayload(), auth_user_id: "synthetic-user" }), false);
  assertEquals(payloadEmpty({ ...emptyPayload(), auth_user_id: null }), true);
});

Deno.test("payloadEmpty: false while ANY one field still holds work", () => {
  assertEquals(payloadEmpty({ ...emptyPayload(), r2: [{ bucket: "b", key: "k" }] }), false);
  assertEquals(payloadEmpty({ ...emptyPayload(), stream_uids: ["uid1"] }), false);
  assertEquals(
    payloadEmpty({ ...emptyPayload(), ghl_targets: [{ email: "a@b.com", org_id: "o1" }] }),
    false,
  );
  assertEquals(payloadEmpty({ ...emptyPayload(), apple_refresh_token: "rt" }), false);
  assertEquals(payloadEmpty({ ...emptyPayload(), db: { org_ids: ["o1"] } }), false);
});

Deno.test("payloadEmpty: false while analytics-forget or the profile row is still pending (P0-4)", () => {
  // These two are the exact fields that used to be handled OUTSIDE this
  // computation entirely — a failure there could not stop cleanup_complete
  // from reading true, because it was computed and the tombstone already
  // marked `completed` before either step ran.
  assertEquals(
    payloadEmpty({ ...emptyPayload(), analytics_user_id: "user-1" }),
    false,
    "app_events still carries this user's id -> not complete",
  );
  assertEquals(
    payloadEmpty({ ...emptyPayload(), profile_id: "user-1" }),
    false,
    "the profiles row still exists -> not complete",
  );
});

Deno.test("payloadEmpty: null/undefined analytics_user_id and profile_id do not block completion", () => {
  assertEquals(payloadEmpty({ ...emptyPayload(), analytics_user_id: null, profile_id: null }), true);
  // Fields omitted entirely (as a fresh payload literal does) must also count as done.
  assertEquals(payloadEmpty(emptyPayload()), true);
});

Deno.test("dbEmpty: true for undefined, empty object, and every field empty; false for any one non-empty", () => {
  assertEquals(dbEmpty(undefined), true);
  assertEquals(dbEmpty({}), true);
  assertEquals(dbEmpty({ org_ids: [], listing_ids: [], render_ids: [], job_ids: [], asset_ids: [] }), true);
  assertEquals(dbEmpty({ asset_ids: ["a1"] }), false);
});

// ── 2. chunk — bookkeeping every batched cleanup pass relies on ─────────────

Deno.test("chunk: splits evenly, handles a remainder, and never drops an item", () => {
  assertEquals(chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]]);
  assertEquals(chunk([1, 2, 3, 4], 2), [[1, 2], [3, 4]]);
  assertEquals(chunk([], 2), []);
  assertEquals(chunk([1], 200), [[1]]); // default size
});

// ── 3. decideGhlTagAction — the whole cross-tenant deletion fix ─────────────

const ORG_A = "11111111-1111-4111-8111-111111111111";
const ORG_B = "22222222-2222-4222-8222-222222222222";

Deno.test("decideGhlTagAction: only this tenant's tag present -> delete", () => {
  const d = decideGhlTagAction(["rendprop", "tour", ghlOrgTag(ORG_A)], ORG_A);
  assertEquals(d.action, "delete");
  assertEquals(d.tag, ghlOrgTag(ORG_A));
});

Deno.test("decideGhlTagAction: this tenant's tag PLUS another tenant's -> untag, never delete", () => {
  // The exact scenario the audit named: two tenants' leads share one contact
  // in the shared GHL_LOCATION_ID. Deleting outright would destroy org B's
  // contact when org A deletes its account.
  const d = decideGhlTagAction(["rendprop", ghlOrgTag(ORG_A), ghlOrgTag(ORG_B)], ORG_A);
  assertEquals(d.action, "untag");
  assertEquals(d.tag, ghlOrgTag(ORG_A));
  assert(d.reason.includes(ghlOrgTag(ORG_B)), "names the other tenant tag being preserved");
});

Deno.test("decideGhlTagAction: this tenant's tag absent -> leftover, never delete or untag", () => {
  // A contact that matched by email but never carries THIS org's tag is not
  // provably this tenant's contact — e.g. it belongs to org B alone, and org
  // A's lead capture never actually reached GHL for it.
  const d = decideGhlTagAction(["rendprop", ghlOrgTag(ORG_B)], ORG_A);
  assertEquals(d.action, "leftover");
});

Deno.test("decideGhlTagAction: tags missing/unreadable -> leftover, never a guess", () => {
  for (const bad of [undefined, null, "not-an-array", 42, {}]) {
    const d = decideGhlTagAction(bad, ORG_A);
    assertEquals(d.action, "leftover", `tags=${JSON.stringify(bad)}`);
  }
});

Deno.test("decideGhlTagAction: non-string entries in the tags array are ignored, not trusted", () => {
  // deno-lint-ignore no-explicit-any
  const weirdTags: any[] = [ghlOrgTag(ORG_A), 123, null, { not: "a tag" }];
  const d = decideGhlTagAction(weirdTags, ORG_A);
  assertEquals(d.action, "delete"); // only the one real org tag survives filtering
});

Deno.test("decideGhlTagAction: an empty tags array is 'tag absent', not a crash", () => {
  assertEquals(decideGhlTagAction([], ORG_A).action, "leftover");
});

// ── 4. the tag format itself must match what leads/index.ts writes ─────────

Deno.test("ghlOrgTag: matches the literal format leads/index.ts tags a contact with", () => {
  // Pinned as a literal, not just re-derived: leads/index.ts and me/index.ts
  // both import ghlOrgTag() from _shared/ghl.ts now (they cannot drift by
  // construction), but the STRING ITSELF is also the thing already sitting on
  // every GHL contact tagged before this fix shipped — changing the format
  // silently would orphan every one of them from both the writer and the
  // reader at once.
  assertEquals(ghlOrgTag("abc-123"), "rendprop_org:abc-123");
});
