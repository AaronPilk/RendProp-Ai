// team — seats, invites and members for one org.
//
//   GET    /team                    -> { org, plan, seats:{used,allowed}, members[], invites[], can_manage }
//   POST   /team/invites            { email?, role? } -> { id, code, expires_at }   owner/admin
//   DELETE /team/invites/<id>       -> { ok }                                       owner/admin
//   POST   /team/accept             { code } -> { ok, org_id, org_name, role }      any identified user
//   DELETE /team/members/<user_id>  -> { ok }                                       owner/admin
//
// WHY THIS EXISTS. `plan_entitlements.seats` was a number nothing enforced and
// nobody could use: `memberships` was written only by the signup trigger,
// adopt's one-row transfer, and account deletion. The paywall sold "3 seats"
// that could not be occupied, and a 20-agent brokerage had no way to pay for 20
// of anything. Seats are what makes per-seat pricing a product rather than a
// price list.
//
// ── THE INVITE IS THE TOKEN, NOT THE E-MAIL ─────────────────────────────────
//
// An invited agent signs in with Apple, and Apple hands back a private-relay
// address by default — the owner's own account does exactly this. Matching an
// invite against the address the inviter typed would therefore fail for most
// real people. So a code grants the seat and `email` is only for delivery and
// for showing the owner who they invited. The code is stored HASHED: this table
// is reachable by the service role from every function, and a leaked backup
// must not hand out live seats.
//
// ── WHAT IS GUARDED, BECAUSE THIS ROUTE HANDS OUT ACCESS TO REAL DATA ───────
//
//   * ANONYMOUS SESSIONS CANNOT HOLD A SEAT. Every launch opens one (App Store
//     5.1.1(v)), and it carries no identity — there is nobody for the seat to
//     belong to, and the session dies with the app. Inviting and accepting both
//     require a real Sign in with Apple identity. This is the one place in the
//     app where sign-in is genuinely required, and it is allowed precisely
//     because a team seat IS an account-based feature.
//   * A PENDING INVITE HOLDS A SEAT. Otherwise an owner on 3 seats sends thirty
//     invites and the cap bites the fourth person to accept, which is the worst
//     possible moment to discover it.
//   * THE CAP IS CHECKED AGAIN ON ACCEPT. An invite created when there was room
//     and accepted after the plan lapsed must not open a seat that no longer
//     exists.
//   * 'owner' IS NOT INVITABLE. One owner per org, created by the signup
//     trigger. Handing that role out over a code would let an invited agent
//     delete the org that invited them.
//   * THE JOINER'S OWN ORG IS ONLY DISCARDED WHEN EMPTY — the same rule, and
//     the same two content tables, as adopt. Merging two populated orgs is a
//     decision for a person, not a silent side effect of typing a code.
//   * ACCEPT IS RATE-LIMITED PER IP. A 12-character code over a 30-symbol
//     alphabet is ~59 bits, but a route that answers "was that a real code?"
//     unboundedly is a route worth grinding at.

import { handleOptions } from "../_shared/cors.ts";
import {
  HttpError,
  assert,
  clientIp,
  json,
  pathSegments,
  readJson,
  respondError,
} from "../_shared/http.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import { adminClient, assertNotDeleting, getUser, orgForUser, preferredOrg } from "../_shared/supabase.ts";
import { generateCode, hashCode, normalizeCode, normalizeEmail } from "./codes.ts";

/** Roles allowed to invite, revoke and remove. */
const MANAGER_ROLES = new Set(["owner", "admin"]);
/** Roles an invite may confer. Deliberately no 'owner' — see the header. */
const INVITABLE_ROLES = new Set(["admin", "agent", "marketing"]);

/** Accept attempts per IP per hour. Generous for a person, useless for a grinder. */
const ACCEPT_MAX_PER_HOUR = 20;
/** Invites created per org per hour — an owner inviting a brokerage, not a spammer. */
const INVITE_MAX_PER_HOUR = 60;
const HOUR_SECONDS = 3600;

/** The two tables that mean "this org has real work in it" — same list as adopt.
 *  Everything else (renders, capture_assets, render_jobs, chapters, provenance)
 *  hangs off a listing, and `leads` is here because it arrives from OUTSIDE:
 *  losing somebody's lead to a tidy-up would be the worst bug in this file. */
const CONTENT_TABLES = ["listings", "leads"] as const;

type Admin = ReturnType<typeof adminClient>;

async function orgIsEmpty(admin: Admin, orgId: string): Promise<boolean> {
  for (const t of CONTENT_TABLES) {
    const { count, error } = await admin
      .from(t).select("id", { count: "exact", head: true }).eq("org_id", orgId);
    // A failed count is NOT "empty" — treating an error as empty would delete
    // an org that had work in it.
    if (error) return false;
    if ((count ?? 0) > 0) return false;
  }
  return true;
}

/** The caller's role in `orgId`, or null when they are not a member. */
async function roleInOrg(admin: Admin, userId: string, orgId: string): Promise<string | null> {
  const { data, error } = await admin
    .from("memberships").select("role").eq("user_id", userId).eq("org_id", orgId).maybeSingle();
  if (error) throw new HttpError(500, `Membership lookup failed: ${error.message}`);
  return (data?.role as string | undefined) ?? null;
}

async function seatCounts(admin: Admin, orgId: string): Promise<{ used: number; allowed: number }> {
  const [{ data: used, error: e1 }, { data: allowed, error: e2 }] = await Promise.all([
    admin.rpc("org_seats_used", { p_org: orgId }),
    admin.rpc("org_seats_allowed", { p_org: orgId }),
  ]);
  if (e1 || e2) throw new HttpError(500, `Seat lookup failed: ${(e1 ?? e2)?.message}`);
  return { used: Number(used ?? 0), allowed: Number(allowed ?? 1) };
}

/**
 * The caller, refused unless they are a real signed-in person.
 *
 * An anonymous session is a session, not an identity (Auth/AuthStore.swift says
 * the same thing on the app side). It cannot be invited to anything and cannot
 * accept anything, because there is nobody for the seat to belong to.
 */
async function identifiedUser(req: Request) {
  const user = await getUser(req);
  if ((user as { is_anonymous?: boolean }).is_anonymous) {
    throw new HttpError(
      403,
      "Sign in with Apple first — a team seat belongs to a person, not to one phone.",
      "forbidden",
    );
  }
  return user;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const seg = pathSegments(req, "team");

    // ── POST /team/accept ────────────────────────────────────────────────────
    // First, because it is the only route whose caller is not yet a member of
    // the org they are talking about.
    if (req.method === "POST" && seg[0] === "accept") {
      if (!(await durableRateLimit(`team:accept:${clientIp(req)}`, ACCEPT_MAX_PER_HOUR, HOUR_SECONDS))) {
        throw new HttpError(429, "Too many attempts — try again later.", "rate_limited");
      }
      const user = await identifiedUser(req);
      const body = await readJson<{ code?: unknown }>(req);
      const code = normalizeCode(body.code);
      // A malformed code and a wrong code answer identically: this route must
      // not tell anyone whether their guess had the right shape.
      const invalid = () =>
        new HttpError(404, "That invite code isn't valid, or it has expired.", "not_found");
      if (!code) throw invalid();

      const admin = adminClient();
      const { data: invite, error } = await admin
        .from("org_invites")
        .select("id, org_id, role, expires_at, accepted_at, accepted_by, revoked_at")
        .eq("token_hash", await hashCode(code))
        .maybeSingle();
      if (error) throw new HttpError(500, `Invite lookup failed: ${error.message}`);
      if (!invite) throw invalid();

      // Already accepted BY THIS USER is success, not an error — a retried tap
      // or a second device must not read as a failure.
      if (invite.accepted_at) {
        if (invite.accepted_by === user.id) {
          const { data: org } = await admin
            .from("orgs").select("name").eq("id", invite.org_id).maybeSingle();
          return json({ ok: true, org_id: invite.org_id, org_name: org?.name ?? null, role: invite.role });
        }
        throw invalid();
      }
      if (invite.revoked_at) throw invalid();
      if (new Date(invite.expires_at).getTime() <= Date.now()) throw invalid();

      // Already a member of this org: bind the invite to them and stop.
      const existing = await roleInOrg(admin, user.id, invite.org_id);
      if (existing) {
        await admin.from("org_invites")
          .update({ accepted_at: new Date().toISOString(), accepted_by: user.id })
          .eq("id", invite.id).is("accepted_at", null);
        const { data: org } = await admin
          .from("orgs").select("name").eq("id", invite.org_id).maybeSingle();
        return json({ ok: true, org_id: invite.org_id, org_name: org?.name ?? null, role: existing });
      }

      // The cap is re-checked HERE, not only at invite time: an invite made when
      // there was room must not open a seat that the plan no longer has.
      const seats = await seatCounts(admin, invite.org_id);
      // This invite is itself counted in `used` while pending, so the test is
      // `used > allowed`, not `used >= allowed`.
      if (seats.used > seats.allowed) {
        throw new HttpError(
          402,
          `This team is full — it has ${seats.allowed} seat${seats.allowed === 1 ? "" : "s"} and they are all taken. Ask the owner to add a seat.`,
          "quota_exceeded",
          { seats_used: seats.used, seats_allowed: seats.allowed },
        );
      }

      // The joiner's OWN org — the one the signup trigger gave them. Discarded
      // only when it is empty; otherwise this refuses, because merging two
      // populated orgs is a person's decision.
      const { data: mine, error: mineErr } = await admin
        .from("memberships").select("org_id, role").eq("user_id", user.id);
      if (mineErr) throw new HttpError(500, `Membership lookup failed: ${mineErr.message}`);
      // ONLY orgs they OWN are candidates for discarding. A membership in
      // somebody else's team is not theirs to delete — an earlier draft of this
      // soft-deleted every org the joiner belonged to, which would have wiped a
      // brokerage because one of its agents accepted a second invite.
      const ownOrgs = (mine ?? [])
        .filter((m) => m.role === "owner")
        .map((m) => m.org_id as string);
      for (const orgId of ownOrgs) {
        if (!(await orgIsEmpty(admin, orgId))) {
          throw new HttpError(
            409,
            "You already have homes and tours in your own workspace. Joining this team would leave them behind, so an owner needs to move them across first.",
            "conflict",
          );
        }
      }

      // Join, THEN clean up: a failure between the two leaves the person with
      // both, which is recoverable. The reverse leaves them with neither.
      const { error: joinErr } = await admin
        .from("memberships").insert({ user_id: user.id, org_id: invite.org_id, role: invite.role });
      if (joinErr) throw new HttpError(500, `Could not join the team: ${joinErr.message}`);

      for (const orgId of ownOrgs) {
        await admin.from("memberships").delete().eq("user_id", user.id).eq("org_id", orgId);
        await admin.from("orgs").update({ deleted_at: new Date().toISOString() }).eq("id", orgId);
      }

      // Bind the invite last, and only if still unaccepted, so two devices
      // racing the same code cannot both consume it.
      await admin.from("org_invites")
        .update({ accepted_at: new Date().toISOString(), accepted_by: user.id })
        .eq("id", invite.id).is("accepted_at", null);

      const { data: org } = await admin
        .from("orgs").select("name").eq("id", invite.org_id).maybeSingle();
      return json({ ok: true, org_id: invite.org_id, org_name: org?.name ?? null, role: invite.role });
    }

    // ── Everything below acts on the CALLER'S org ────────────────────────────
    const user = await getUser(req);
    const admin = adminClient();
    const orgId = await orgForUser(user.id, preferredOrg(req));
    const myRole = await roleInOrg(admin, user.id, orgId);
    if (!myRole) throw new HttpError(403, "Not a member of this org", "forbidden");
    const canManage = MANAGER_ROLES.has(myRole);

    const requireManager = () => {
      if (!canManage) {
        throw new HttpError(403, "Only the owner or an admin can change who is on the team.", "forbidden");
      }
    };

    // ── GET /team ────────────────────────────────────────────────────────────
    if (req.method === "GET" && seg.length === 0) {
      const seats = await seatCounts(admin, orgId);
      const { data: rows } = await admin
        .from("memberships").select("user_id, role").eq("org_id", orgId);
      const ids = (rows ?? []).map((r) => r.user_id as string);
      const { data: people } = ids.length
        ? await admin.from("profiles").select("id, name, email").in("id", ids)
        : { data: [] as { id: string; name: string | null; email: string | null }[] };
      const byId = new Map((people ?? []).map((p) => [p.id, p]));

      // Pending invites are visible to MANAGERS ONLY, and never with the code:
      // the plaintext existed once, in the response that created it. An agent
      // on the team has no business reading who else is mid-invite.
      const { data: invites } = canManage
        ? await admin.from("org_invites")
            .select("id, email, role, created_at, expires_at")
            .eq("org_id", orgId).is("accepted_at", null).is("revoked_at", null)
            .gt("expires_at", new Date().toISOString())
            .order("created_at", { ascending: false })
        : { data: [] as unknown[] };

      const { data: org } = await admin
        .from("orgs").select("name, plan").eq("id", orgId).maybeSingle();

      return json({
        org_id: orgId,
        org_name: org?.name ?? null,
        plan: org?.plan ?? null,
        can_manage: canManage,
        seats,
        members: (rows ?? []).map((r) => {
          const p = byId.get(r.user_id as string);
          return {
            user_id: r.user_id,
            role: r.role,
            name: p?.name ?? null,
            email: p?.email ?? null,
            is_you: r.user_id === user.id,
          };
        }),
        invites: invites ?? [],
      });
    }

    // ── POST /team/invites ───────────────────────────────────────────────────
    if (req.method === "POST" && seg[0] === "invites" && seg.length === 1) {
      requireManager();
      // An anonymous session is an owner of its own org (the signup trigger
      // makes it one), so this check is doing real work: it must not be able to
      // mint seats on a workspace that dies with the app.
      if ((user as { is_anonymous?: boolean }).is_anonymous) {
        throw new HttpError(
          403,
          "Sign in with Apple first — a team seat belongs to a person, not to one phone.",
          "forbidden",
        );
      }
      await assertNotDeleting(user.id);
      if (!(await durableRateLimit(`team:invite:${orgId}`, INVITE_MAX_PER_HOUR, HOUR_SECONDS))) {
        throw new HttpError(429, "Too many invites at once — try again later.", "rate_limited");
      }

      const body = await readJson<{ email?: unknown; role?: unknown }>(req);
      const role = typeof body.role === "string" ? body.role.trim().toLowerCase() : "agent";
      assert(INVITABLE_ROLES.has(role), 400, "Role must be admin, agent or marketing");
      const email = body.email === undefined || body.email === null || body.email === ""
        ? null
        : normalizeEmail(body.email);
      assert(body.email === undefined || body.email === null || body.email === "" || email !== null,
             400, "That doesn't look like an email address");

      const seats = await seatCounts(admin, orgId);
      if (seats.used >= seats.allowed) {
        throw new HttpError(
          402,
          `Your plan includes ${seats.allowed} seat${seats.allowed === 1 ? "" : "s"} and ${seats.used} ${seats.used === 1 ? "is" : "are"} taken (a pending invite holds one). Add seats to invite anyone else.`,
          "quota_exceeded",
          { seats_used: seats.used, seats_allowed: seats.allowed },
        );
      }

      const code = generateCode();
      const { data: created, error } = await admin.from("org_invites").insert({
        org_id: orgId,
        email,
        role,
        token_hash: await hashCode(code.replace(/-/g, "")),
        invited_by: user.id,
      }).select("id, email, role, created_at, expires_at").single();

      if (error) {
        // The partial unique index: one LIVE invite per address per org.
        if (/duplicate key|unique/i.test(error.message)) {
          throw new HttpError(409, "That person already has an invite waiting. Revoke it first to send a new code.", "conflict");
        }
        throw new HttpError(500, `Could not create the invite: ${error.message}`);
      }

      // The ONLY time the plaintext code exists. It is not stored and cannot be
      // read back — a lost code is revoked and reissued.
      return json({ ...created, code }, 201);
    }

    // ── DELETE /team/invites/<id> ────────────────────────────────────────────
    if (req.method === "DELETE" && seg[0] === "invites" && seg.length === 2) {
      requireManager();
      const { data, error } = await admin.from("org_invites")
        .update({ revoked_at: new Date().toISOString() })
        .eq("id", seg[1]).eq("org_id", orgId).is("accepted_at", null).is("revoked_at", null)
        .select("id");
      if (error) throw new HttpError(500, `Could not revoke the invite: ${error.message}`);
      // Scoped to the caller's org, so another tenant's invite id is a 404 and
      // not a hint that the id exists.
      if (!data || data.length === 0) throw new HttpError(404, "No pending invite with that id", "not_found");
      return json({ ok: true });
    }

    // ── DELETE /team/members/<user_id> ───────────────────────────────────────
    if (req.method === "DELETE" && seg[0] === "members" && seg.length === 2) {
      requireManager();
      const target = seg[1];
      if (target === user.id) {
        throw new HttpError(400, "You can't remove yourself from your own team.");
      }
      const targetRole = await roleInOrg(admin, target, orgId);
      if (!targetRole) throw new HttpError(404, "That person isn't on this team", "not_found");
      if (targetRole === "owner") {
        throw new HttpError(403, "The owner can't be removed from their own team.", "forbidden");
      }
      // An admin may not remove another admin — only the owner may.
      if (targetRole === "admin" && myRole !== "owner") {
        throw new HttpError(403, "Only the owner can remove an admin.", "forbidden");
      }
      const { error } = await admin.from("memberships")
        .delete().eq("org_id", orgId).eq("user_id", target);
      if (error) throw new HttpError(500, `Could not remove them: ${error.message}`);
      // Their listings and tours stay with the ORG, which is what the team paid
      // for. They keep their account and get a fresh workspace on next launch.
      return json({ ok: true });
    }

    throw new HttpError(
      405,
      "Only GET /team, POST /team/invites, DELETE /team/invites/:id, POST /team/accept and DELETE /team/members/:id are supported",
    );
  } catch (err) {
    return respondError(err);
  }
});
