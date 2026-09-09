// adopt — hand an anonymous session's org to the account that just signed in.
//
//   POST /adopt   Authorization: <the NEW, identified user's JWT>
//                 { anonymous_token: "<the anonymous session's JWT>" }
//     -> { ok: true, adopted: bool, org_id }
//
// WHY THIS EXISTS. App Review rejected 1.0 under Guideline 5.1.1(v): an app may
// not require registration before someone can use features or buy an IAP that
// is not account-based. The fix is anonymous sessions — a real Supabase user
// carrying no personal information — with Sign in with Apple offered later, in
// Apple's own words, "to access the purchased content from any of their
// supported devices."
//
// The problem that creates: Supabase's NATIVE Apple sign-in
// (`grant_type=id_token`) mints a NEW user. It does not link to the anonymous
// one — `linkIdentity` is a browser redirect flow and does not cover the native
// path. So without this route, an agent who publishes a tour anonymously and
// then signs in loses the link to their own published tour. That is data loss,
// and "sign in first" is precisely what Apple just refused to let us require.
//
// So the anonymous org is TRANSFERRED, not copied: one `memberships.user_id`
// update, which carries every listing, render, published tour, provenance row
// and ledger entry with it because they all hang off `org_id`.
//
// THE SECURITY OF IT, because this route moves ownership of real data:
//   * The anonymous token is verified against GoTrue, never merely decoded. A
//     client-supplied JWT is a claim, not a fact.
//   * It must actually BE anonymous (`is_anonymous`). Without that check this
//     endpoint would transfer any account's org to anyone holding a token for
//     it, which is a full account takeover with extra steps.
//   * The caller must NOT be anonymous. An anonymous user adopting another
//     anonymous user's org is not a flow that exists.
//   * The signed-in user's own org is only discarded when it is EMPTY. If they
//     have real work in it, this refuses — merging two populated orgs is a
//     decision for a person, not a silent side effect of tapping Sign in.
//   * Idempotent: an anon user that no longer exists means it was already
//     adopted, which is `ok` and not an error. Sign-in retries are normal.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, readJson, respondError } from "../_shared/http.ts";
import { adminClient, getUser } from "../_shared/supabase.ts";

/** Tables whose presence means "this org has real work in it".
 *
 * `listings` is very nearly sufficient on its own: renders, capture_assets,
 * render_jobs, capture_chapters and media_provenance all hang off a listing,
 * so an org with no listings has none of them either. `leads` is here because
 * it is the one thing that arrives from OUTSIDE — a buyer can submit a lead
 * against a tour whose listing was later deleted, and losing somebody's lead
 * to a tidy-up would be the worst possible bug in this file.
 *
 * Only these two carry `org_id` at all; the rest are reached through
 * `listing_id`, which is why this list is short and not a schema-wide sweep. */
const CONTENT_TABLES = ["listings", "leads"] as const;

async function orgIsEmpty(admin: ReturnType<typeof adminClient>, orgId: string): Promise<boolean> {
  for (const t of CONTENT_TABLES) {
    const { count, error } = await admin
      .from(t).select("id", { count: "exact", head: true }).eq("org_id", orgId);
    // A failed count is NOT "empty". Treating an error as empty would delete an
    // org because a query hiccupped.
    if (error) throw new HttpError(500, `Could not check the account: ${error.message}`);
    if ((count ?? 0) > 0) return false;
  }
  return true;
}

/** Verify a bearer token with GoTrue and return its user, or null. */
async function userForToken(token: string): Promise<Record<string, unknown> | null> {
  const base = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!base || !anon) throw new HttpError(500, "Auth is not configured on this deploy");
  const res = await fetch(`${base}/auth/v1/user`, {
    headers: { Authorization: `Bearer ${token}`, apikey: anon },
  });
  if (!res.ok) return null;
  return await res.json().catch(() => null);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return handleOptions();
  try {
    assert(req.method === "POST", 405, "Use POST /adopt");

    // The caller: the account that just signed in with Apple.
    const user = await getUser(req);

    const body = await readJson<{ anonymous_token?: unknown }>(req);
    const token = typeof body.anonymous_token === "string" ? body.anonymous_token.trim() : "";
    assert(token.length > 20 && token.length < 4096, 400, "anonymous_token is required");

    const anonUser = await userForToken(token);
    // An expired or already-deleted anonymous session is the ALREADY-ADOPTED
    // case, not a failure: the app retries this after a sign-in and must not
    // show an error for work that has already moved.
    if (!anonUser) return json({ ok: true, adopted: false, reason: "anonymous session no longer valid" });

    const anonId = String(anonUser.id ?? "");
    assert(anonId.length > 0, 400, "That session could not be identified");
    // THE LOAD-BEARING CHECK. Without it, anyone holding any user's token could
    // hand that user's org to themselves.
    assert(anonUser.is_anonymous === true, 403,
           "That session is a real account, not an anonymous one — nothing to adopt");
    if (anonId === user.id) return json({ ok: true, adopted: false, reason: "same user" });

    const admin = adminClient();

    // The anonymous user's org. `handle_new_user` gives every auth user exactly
    // one, as owner.
    const { data: anonRows, error: anonErr } = await admin
      .from("memberships").select("org_id, role").eq("user_id", anonId);
    if (anonErr) throw new HttpError(500, `Membership lookup failed: ${anonErr.message}`);
    if (!anonRows || anonRows.length === 0) {
      return json({ ok: true, adopted: false, reason: "anonymous account had no org" });
    }
    assert(anonRows.length === 1, 409, "That anonymous account has more than one workspace");
    const anonOrg = anonRows[0].org_id as string;

    // Nothing to move? Then the honest answer is "nothing moved", and the empty
    // anonymous account is still cleaned up below.
    if (await orgIsEmpty(admin, anonOrg)) {
      await admin.auth.admin.deleteUser(anonId).catch(() => {});
      return json({ ok: true, adopted: false, reason: "nothing to move", org_id: null });
    }

    // The signed-in user's own org, minted moments ago by the same trigger.
    const { data: mineRows, error: mineErr } = await admin
      .from("memberships").select("org_id, role").eq("user_id", user.id);
    if (mineErr) throw new HttpError(500, `Membership lookup failed: ${mineErr.message}`);
    const mine = (mineRows ?? []).map((r) => r.org_id as string);

    if (mine.length > 1) {
      throw new HttpError(409, "This account already belongs to more than one workspace — nothing was changed.");
    }
    if (mine.length === 1) {
      if (mine[0] === anonOrg) return json({ ok: true, adopted: true, org_id: anonOrg });
      if (!(await orgIsEmpty(admin, mine[0]))) {
        // Deliberately a refusal rather than a merge. Two populated workspaces
        // is a person's decision, not a side effect of tapping Sign in.
        throw new HttpError(409,
          "This Apple account already has work in Rendprop, so the work made before signing in was left where it is. Contact support and we'll merge them.");
      }
      // Their brand-new empty org goes away, so `orgForUser` stays unambiguous.
      await admin.from("memberships").delete().eq("user_id", user.id).eq("org_id", mine[0]);
      await admin.from("orgs").delete().eq("id", mine[0]);
    }

    // THE TRANSFER. One row: every listing, render, published tour, provenance
    // row and ledger entry hangs off `org_id`, so none of them move at all.
    const { error: moveErr } = await admin
      .from("memberships").update({ user_id: user.id }).eq("user_id", anonId).eq("org_id", anonOrg);
    if (moveErr) throw new HttpError(500, `Could not move the workspace: ${moveErr.message}`);

    // The anonymous user is gone, so its token cannot be replayed against this
    // route or any other.
    await admin.auth.admin.deleteUser(anonId).catch(() => {});

    return json({ ok: true, adopted: true, org_id: anonOrg });
  } catch (err) {
    return respondError(err);
  }
});
