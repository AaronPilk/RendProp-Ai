// events — first-party product analytics ingest. The ONLY writer of app_events.
//
//   POST /events         OWNER JWT *or* the anon key as bearer -> 202
//        { device_id, session_id, app_version, os,
//          events: [ { name, t, props } ] }                    (max 100 events)
//     -> 202 { ok, accepted, dropped_props, dropped_events }
//   GET  /events/health  -> { ok: true }
//
// WHY THIS FUNCTION EXISTS. The owner is about to run Meta ads at the iOS app
// and today the app reports nothing: no funnel, no crash count, no idea which
// step loses people. This is the ingest half of the first-party pipeline
// (migration 0020 is the storage, admin/funnel.ts the read). There is no
// Firebase, no Mixpanel, no ad SDK and no IDFA anywhere in it — which is what
// keeps the privacy manifest honest and App Review boring.
//
// ── WHO MAY CALL IT ──────────────────────────────────────────────────────────
//
// Both signed-in and signed-out people, because half the funnel (app_open,
// paywall_viewed) happens before anyone signs in. The app therefore sends the
// owner JWT when it has one and the project's ANON key otherwise — the anon key
// IS a project-signed JWT, so this function deploys WITH verify_jwt ON (the
// default) and the gateway does the first filter. Do NOT deploy it
// --no-verify-jwt: that would make it an open write endpoint on the internet.
//
// A bearer that is not a user (the anon key) is not an error here — it is the
// signed-out case. `resolveIdentity` tries getUser() and, on failure, records
// the batch with user_id = org_id = null.
//
// ── THE FOUR RULES ───────────────────────────────────────────────────────────
//
// 1. IDS COME FROM THE TOKEN, NEVER THE BODY. `user_id` and `org_id` are
//    resolved with getUser() + orgForUser(). The body carries no user id and
//    one is never read from it, so a client cannot attribute its events —
//    or its crashes — to somebody else's account.
//
// 2. NO PII, ENFORCED THREE TIMES. Vocabulary → per-event props whitelist →
//    regex scrub of every string value. All three live in ./schema.ts and are
//    tested in ./events.test.ts. Unknown props are DROPPED and counted, never
//    rejected; an unknown event NAME is a 400 that lists the vocabulary,
//    because the only client is our own app and a new name means a deploy.
//
// 3. IT CANNOT BE USED AS A FIREHOSE. 120 calls/hour per device_id and 600/hour
//    per IP (durable, Postgres-backed), 100 events per call, 1 KB per event.
//    A device is a UUID the app generates and keeps in its own Keychain item —
//    not the IDFA, not the IDFV, and never asked for via App Tracking
//    Transparency, because the app does not track across apps.
//
// 4. ANALYTICS NEVER BREAKS THE APP. The client fires and forgets; this
//    function answers 202 and does not make the caller wait on anything it
//    could have done later. A malformed batch still 400s (so a bug is visible
//    in the app's own logs), but a partially-bad batch inserts the good rows.
//
// Errors carry { error, code } (see _shared/http.ts).

import { handleOptions } from "../_shared/cors.ts";
import {
  HttpError,
  assert,
  clientIp,
  json,
  pathSegments,
  readJsonLimited,
  respondError,
} from "../_shared/http.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";
import { adminClient, getUser, orgForUser, preferredOrg } from "../_shared/supabase.ts";
import {
  ALLOWED_EVENT_NAMES,
  MAX_EVENTS_PER_CALL,
  UUID_RE,
  normalizeBatch,
  scrubMeta,
} from "./schema.ts";

interface EventsBody {
  device_id?: string;
  session_id?: string;
  app_version?: string;
  os?: string;
  events?: unknown;
}

// Per DEVICE: an hour of normal use is a handful of flushes (the app batches
// and flushes every 60 s at most while foregrounded). 120 leaves enormous
// headroom for a retry storm and still bounds a single phone.
const DEVICE_MAX_PER_HOUR = 120;
// Per IP: an office, a coffee shop or a CI runner is many devices behind one
// address, so this is deliberately five times the device limit.
const IP_MAX_PER_HOUR = 600;
const HOUR_SECONDS = 3600;
/**
 * Hard ceiling on the bytes read off the wire, before any JSON parsing.
 *
 * The contract is 100 events x 1 KB, but that 1 KB is measured AFTER the props
 * whitelist and the scrubber have run — a legitimate batch of crash summaries
 * can be several times larger on the way in. 1 MB is far above anything the app
 * builds and far below anything that threatens the isolate.
 */
const MAX_EVENTS_BODY_BYTES = 1024 * 1024;

interface Identity {
  userId: string | null;
  orgId: string | null;
}

/**
 * Who is this? A valid USER token gives us both ids; anything else — including
 * the project anon key, which is the signed-out client's bearer — gives us
 * neither, and that is a normal, expected outcome, not an error.
 *
 * Never throws: an analytics write must not fail because a membership lookup
 * hiccuped. The row still lands, just unattributed.
 */
async function resolveIdentity(req: Request): Promise<Identity> {
  let userId: string | null = null;
  try {
    const user = await getUser(req);
    userId = user.id;
  } catch {
    return { userId: null, orgId: null }; // signed out (anon key) or expired token
  }
  try {
    const orgId = await orgForUser(userId, preferredOrg(req));
    return { userId, orgId };
  } catch {
    return { userId, orgId: null }; // a brand-new account can have no membership yet
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();

  try {
    const seg = pathSegments(req, "events");

    // ---- GET /events/health ----
    // Deliberately says nothing else: no counts, no schema, no version. It is a
    // liveness probe for the deploy script, reachable by anyone the gateway let
    // through, so it must not become a way to learn about the pipeline.
    if (req.method === "GET" && seg[0] === "health") {
      return json({ ok: true });
    }

    if (req.method !== "POST" || seg.length > 0) {
      throw new HttpError(405, "Only POST /events and GET /events/health are supported");
    }

    // ---- POST /events ----
    // Capped BEFORE it is buffered. This route is reachable with the project
    // ANON key — which ships inside the app — so `req.json()` on an unbounded
    // body is an out-of-memory kill of the isolate that no per-IP limiter can
    // catch, because one request is enough. 100 events x 1 KB is the contract;
    // 1 MB is generous headroom for a body that is about to be validated
    // properly anyway.
    const body = await readJsonLimited<EventsBody>(req, MAX_EVENTS_BODY_BYTES);

    const deviceId = String(body.device_id ?? "").trim().toLowerCase();
    assert(UUID_RE.test(deviceId), 400, "device_id must be a UUID the app generated");

    const sessionRaw = String(body.session_id ?? "").trim().toLowerCase();
    const sessionId = UUID_RE.test(sessionRaw) ? sessionRaw : null;

    assert(Array.isArray(body.events), 400, "events must be an array");
    const rawEvents = body.events as unknown[];
    assert(rawEvents.length > 0, 400, "events must not be empty");
    assert(
      rawEvents.length <= MAX_EVENTS_PER_CALL,
      413,
      `At most ${MAX_EVENTS_PER_CALL} events per call`,
      "payload_too_large",
    );

    // Rate limit AFTER the shape checks (so a malformed body is a cheap 400 and
    // does not spend the device's hourly allowance) and BEFORE any database
    // write. Both counters are charged; the device one is the meaningful bound
    // and the IP one catches a fleet of fabricated device ids.
    if (!(await durableRateLimit(`events:dev:${deviceId}`, DEVICE_MAX_PER_HOUR, HOUR_SECONDS))) {
      throw new HttpError(429, "Too many event batches from this device — try again later.", "rate_limited");
    }
    if (!(await durableRateLimit(`events:ip:${clientIp(req)}`, IP_MAX_PER_HOUR, HOUR_SECONDS))) {
      throw new HttpError(429, "Too many event batches from this network — try again later.", "rate_limited");
    }

    const now = new Date();
    const batch = normalizeBatch(rawEvents, now);

    // An unknown event name is our own client sending something this deploy has
    // never heard of, so the 400 names the whole vocabulary rather than making
    // someone go and read the contract.
    if (batch.unknownName !== null) {
      throw new HttpError(
        400,
        `Unknown event name "${batch.unknownName}". Allowed: ${ALLOWED_EVENT_NAMES.join(", ")}`,
      );
    }
    assert(batch.events.length > 0, 400, "No storable events in this batch");

    const identity = await resolveIdentity(req);
    const appVersion = scrubMeta(body.app_version);
    const os = scrubMeta(body.os);

    // ONE insert for the whole batch. The admin client is required: app_events
    // has RLS on with no policies and no tenant grant, by design (0020 §2).
    const rows = batch.events.map((e) => ({
      t: e.t,
      name: e.name,
      device_id: deviceId,
      session_id: sessionId,
      user_id: identity.userId,
      org_id: identity.orgId,
      app_version: appVersion,
      os,
      props: e.props,
    }));

    const { error } = await adminClient().from("app_events").insert(rows);
    if (error) throw new HttpError(500, `Event insert failed: ${error.message}`);

    return json({
      ok: true,
      accepted: rows.length,
      dropped_props: batch.droppedProps,
      dropped_events: batch.droppedEvents,
    }, 202);
  } catch (err) {
    return respondError(err);
  }
});
