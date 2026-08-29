# Audit response — 2026-08-28

Responds to the 2026-08-27 NO-GO deployment audit (audited commit `cc9186b`).
Supersedes the status claims in FULL-AUDIT-2026-08-26.md and RELEASE-GATE-AUDIT.md.

**State after this response: all eight P0s are code-complete, deployed to the
production backend, and covered by live regression evidence — except P0-1
(credential rotation), which is inherently a manual gate and has a runbook
below. Remaining manual gates are listed at the end. The release is NOT "ready"
until those gates are walked.**

## What shipped (deployed live via Supabase MCP + migrations)

> **Round 2 (uploads v14, same day).** A follow-up Codex audit correctly found
> that round 1's `/complete` HEAD-verify was a TOCTOU: the presigned PUT URL
> stays valid ~1h, so a verified object could be overwritten afterward, and the
> byte budget escaped with it. I tested whether signing content-length would fix
> it — **it can't**: aws4fetch's `signQuery` puts only `host` in
> `X-Amz-SignedHeaders`, so presigned URLs bind neither content-length nor
> content-type (meaning round 1's "photo PUTs sign the Content-Type" claim was
> also wrong). Round 2 fixes it structurally: single PUTs upload to a
> `_staging/` key, `/complete` verifies THERE, then server-side-copies to the
> final key (header-signed `x-amz-copy-source`) and deletes staging. The final
> key never receives a PUT URL, so the still-valid staging URL can only
> overwrite an orphan that is never served. Multipart assembles at the final key
> under a completing uploadId with no outstanding single-PUT URL, so it is
> verified in place. Also added: `requireWriteRole()` on all three ticket paths
> (marketing is now blocked from uploading, including via `role:"render"`), and
> staging cleanup on abort. New manual gate: an R2 lifecycle rule on the
> `_staging/` prefix. The Gemini runbook key name below was also wrong and is
> corrected (`GEMINI_API_KEY`).

### P0-2 — Upload controls (uploads v14 + migration 0006)
- Ticket limits charged **per file** (batch of 200 = 200 units) via `bump_rate(p_cost)`.
- New per-org **daily byte budget** (200 GB/day) charged per MiB declared.
- Part numbers bounded to `1…parts_total`; completion requires the **exact unique
  part set** or 400s.
- Completion **HEAD-verifies** the object: must exist, size must equal the bytes
  declared at ticket time, observed content-type must be in the per-kind
  allowlist. Mismatches delete the object and reset the row. The row records
  **server-observed** bytes + content-type, not client claims.
- Photo PUT URLs sign the Content-Type (binding). Video PUTs stay unsigned for
  iOS background-session compatibility — the HEAD check is the enforcement
  there (deliberate deviation from the audit's "bind everything": the iOS
  uploader hardcodes `video/quicktime` on single video PUTs, so signing would
  break real uploads; HEAD verification closes the same hole).
- Asset rows are written with the service client only after RLS-scoped reads
  prove membership; migration 0007 revokes the direct write path entirely.

### P0-3 — Render/AI spend (renders v12, ai-video v7, migration 0006)
- `create_render_job()` RPC: atomic membership check + **plan entitlement**
  (free 20 / pro 100 / team 400 renders per month) + **max 3 jobs in flight per
  org** + **Idempotency-Key replay** under a per-org advisory lock.
- `publish_render()` RPC: **callers can no longer supply video_key /
  stream_uid / poster_key / staged** — the video key comes from the job's
  verified `role=render` upload; chapters + job/listing status flips commit in
  one transaction; idempotent via unique `renders.job_id`.
- `log_job_cost()` RPC: ledger insert + cap check + rollup under a row lock —
  the read/sum/insert/update race is gone. `ledger.ts` delegates to it.
- **The monthly-counter kill bug is fixed**: `rate_limits` rows remember their
  own `window_seconds`; cleanup only deletes rows whose own window expired.
- ai-video monthly caps are now **plan-scaled** (free 60 / pro 200 / team 400).
- Rate-limit DB failure falls back to the memory limiter at **a quarter** of
  the ceiling (degraded infra tightens, never loosens).

### P0-4 — Durable account deletion (me v13 + migration 0006)
- `deletion_requests` tombstone records every external cleanup target (R2
  objects, Stream UIDs, CRM lead emails, Apple refresh token) **before**
  anything is destroyed; enumeration failures abort with nothing touched.
- Share links are revoked immediately (renders unpublished → tours 404).
- Inline cleanup attempts R2 + Cloudflare Stream + GoHighLevel contact
  deletion; anything failed/over-cap stays queued and is retried by
  `POST /me/sweep-deletions` (service-role) until the payload drains.
- Sign in with Apple revocation (TN3194): the app now sends the sign-in
  `authorizationCode` to `POST /me/apple-code`; the server exchanges it for a
  refresh token stored on the profile and revokes it at deletion.
  Activation requires the four `APPLE_*` secrets (manual gate).
- The response reports `cleanup_complete` + per-category `pending` counts; iOS
  decodes `ok`/`cleanup_complete` instead of trusting any 2xx, and tells the
  user when background cleanup is still running. Terms §7 wording updated to
  match reality.

### P0-5 — Commerce presentation (iOS)
- Every digital-feature dollar amount removed (the $29–$279 tier prices);
  "Your first video tour is free" → "Included with early access." Tier cards
  now show capability copy only. No StoreKit while early access is free.

### P0-6 — Privacy disclosures (iOS)
- GPS coordinates are rounded to 3 decimals (~110 m) at every point they leave
  the device, so the existing CoarseLocation declaration is now TRUE.
- PrivacyInfo.xcprivacy adds PhoneNumber, PhysicalAddress, OtherUserContent,
  ProductInteraction. Plist validated. (App Store Connect labels = manual gate.)

### P0-7 — Direct Data API (migrations 0006 + 0007)
- `render_jobs`, `renders`, `capture_assets`, `capture_chapters`: members can
  SELECT; INSERT/UPDATE/DELETE revoked — server-only via RPCs/service role.
- Role capabilities: **marketing is read-only** on listings/photos; listing
  deletion needs owner/admin; org profile edits need owner/admin.
- `cost_ledger`, `metering`, `leads`, `rate_limits`, `deletion_requests`,
  `memberships`: direct writes revoked.
- Every change is a committed migration (0006_p0_rpcs.sql, 0007_p0_lockdown.sql).

### P0-8 — Worker dependency graph (tour-host)
- `package-lock.json` committed; wrangler pinned 4.26.0; workers-types resolved
  to the latest v4 line (v5 does not exist for this wrangler era — the audit's
  premise was slightly off; the conflict was the missing lockfile).
  Proven: clean-room `npm ci` → typecheck → `wrangler deploy --dry-run` all pass.

### High-priority extras fixed
- `clientIp()` prefers `cf-connecting-ip` over spoofable `x-forwarded-for`.
- Beacon metering is an atomic RPC upsert with server-side clamps.
- DB constraints (progress 0–1, coords, non-negative counters, duration bounds)
  + missing FK indexes added.
- `services/worker/.env.example` schema corrected to `public`.

## Evidence

**SQL regression battery (run live against prod, 2026-08-28): 10/10 PASS**
1. bump_rate charges per-cost (3+3 rejected against cap 5)
2. cleanup keeps 30-day counters, drops expired ones
3. render_jobs direct INSERT denied (42501) for authenticated
4. capture_assets direct UPDATE denied (42501)
5. non-member SELECT listings returns 0 rows (cross-tenant denial)
6. create_render_job rejects non-member (RP403)
7. create_render_job idempotent replay returns the same job id
8. log_job_cost enforces the cap atomically (1 row written, RP402 on breach)
9. publish_render returns the existing render (no duplicate publish)
10. bump_metering clamps watch/stream/scroll server-side

**Live HTTP smoke (prod endpoints): 9/9 PASS** — beacon demo ack + unknown-slug
404 + oversized-clamp, leads honeypot swallow, 401s on renders/uploads/me/
ai-video/sweep without credentials.

**Static:** `deno check` clean on all 11 functions; tour-host `tsc --noEmit`
clean from a reproducible `npm ci`; privacy plist parses; iOS price/free greps
clean.

## P0-1 — Credential rotation runbook (MANUAL — do this before any release)

Treat every key that ever sat in Secrets.plist, a TestFlight/ad-hoc build, an
Xcode archive, or a Docker image as burned. Rotate ALL of these, in this order,
and never paste a key into chat — set them in the Supabase dashboard
(Edge Functions → Secrets) and local gitignored .env files only.

1. **fal** — fal.ai dashboard → Keys → revoke old, create new → update the
   `FAL_KEY` function secret + `services/pipeline/.env`.
2. **Gemini** — aistudio.google.com/apikey → delete old, create new → update
   the `GEMINI_API_KEY` function secret (this is the exact name ai-photo/
   index.ts reads — NOT `GEMINI_KEY`) + the pipeline .env.
3. **Anthropic** — console.anthropic.com → API Keys → disable old, create new →
   update `ANTHROPIC_API_KEY` (pipeline .env; nothing in the app uses it).
4. **KIE** — kie.ai dashboard → regenerate → pipeline .env.
5. **Higgsfield** — account/API settings → regenerate → pipeline .env.
6. **Supabase service-role** — Dashboard → Project Settings → API Keys →
   rotate. NOTE: on JWT-based keys this also re-mints the anon key — after
   rotating, update `services/worker/.env`, the tour-host Worker secret (if it
   holds one), and the anon key baked into iOS `Config.swift`, then rebuild.
   Edge functions pick up their injected service key automatically.
7. **Binaries** — App Store Connect → TestFlight → expire every old build.
   Delete old archives (Xcode → Organizer) and any ad-hoc IPAs.
8. **Docker** — if any worker image was ever pushed: delete it from the
   registry, prune local images, rebuild from the current tree (which excludes
   .env and runs non-root).

## Remaining manual gates (not closable from the repo)

- Run the rotation runbook above (P0-1).
- App Store Connect privacy labels to match the manifest; review notes
  explaining the free-early-access model.
- Set the four `APPLE_*` function secrets to activate Apple token revocation.
- Set `CLOUDFLARE_STREAM_API_TOKEN` to activate Stream deletion.
- Schedule `POST /me/sweep-deletions` (service key) — e.g. Supabase cron or an
  external scheduler, every 15 min.
- Add an **abort-incomplete-multipart lifecycle rule** (7 days) on the
  rendprop-uploads and rendprop-renders R2 buckets (Cloudflare dashboard →
  bucket → Settings → Object lifecycle).
- Add a **delete rule on the `_staging/` prefix** (1 day) on both buckets, so
  abandoned staged uploads don't accumulate (round-2 upload flow).
- Turnstile: set `TURNSTILE_SECRET_KEY` + add the widget site key to the tour
  lead form to close the fail-open window.
- Per-tenant CRM routing (today all leads land in one GHL location) — product
  decision + build.
- Worker (Python) P1s: atomic `process_specific()` claim, ffmpeg wall-clock
  timeouts/resource limits, pinned requirements + digest-pinned base image.
- iOS P1s: 401 refresh-and-retry in LiveAPIClient, Sendable warnings in
  RenderEngine.
- CI (npm ci + typecheck + deno check + dry-run + the SQL battery) and a final
  signed-Archive/.ipa inspection rehearsal.
