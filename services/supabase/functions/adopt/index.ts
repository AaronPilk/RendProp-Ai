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
import { HttpError, assert, json, readJson, respondError, throwRpc } from "../_shared/http.ts";
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

    // The route's own header documents that the caller must be identified, and
    // never checked it (Astra F06). An anonymous session adopting another
    // anonymous session is not a flow that exists.
    if ((user as { is_anonymous?: boolean }).is_anonymous) {
      throw new HttpError(403, "Sign in with Apple before adopting a workspace.", "forbidden");
    }

    // ONE TRANSACTION (migration 0033), and it DELETES NOTHING.
    //
    // What used to be here selected `org_id, role` and then threw the role
    // away, so any member of an org that merely counted zero listings and zero
    // leads — a marketing user, not just its owner — could hard-delete it by
    // calling this route with an anonymous token. Empty is not disposable:
    // 0019 detaches subscriptions with ON DELETE SET NULL, so a paid, empty
    // brokerage could be destroyed and its subscription orphaned. The identical
    // bug was caught in team/accept and never back-ported to here, which is the
    // file that pattern was copied from.
    //
    // adopt_anonymous_org transfers the one membership row, re-points
    // `listings.agent_id` off the profile that is about to be deleted, and
    // makes the adopted workspace active. The caller's own workspace is left
    // exactly where it is.
    const { data, error } = await adminClient().rpc("adopt_anonymous_org", {
      p_user: user.id,
      p_anon_user: anonId,
      p_anon_org: anonOrg,
    });
    if (error) throwRpc(error.message);

    // Best effort, and now honest about it: the anonymous user is deleted so
    // its token cannot be replayed, but a failure here is reported rather than
    // swallowed, because the workspace has already moved.
    const del = await admin.auth.admin.deleteUser(anonId).catch((e: unknown) => ({ error: e }));
    const cleanupFailed = Boolean((del as { error?: unknown } | undefined)?.error);

    const r = (data ?? {}) as { org_id?: string };
    return json({ ok: true, adopted: true, org_id: r.org_id ?? anonOrg,
                  source_cleanup_pending: cleanupFailed });
  } catch (err) {
    return respondError(err);
  }
});
