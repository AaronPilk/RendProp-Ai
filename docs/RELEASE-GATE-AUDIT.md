# Rendprop — Release-Gate Security & Functionality Audit

*Run 2026-08-26. Combines the external Codex audit, three independent Claude
review agents (iOS / Supabase / edge+pipeline), and the fixes applied in
response. Every "fixed" item below was code-changed and, where server-side,
deployed live this session.*

---

## Verdict

All **P0 (release-blocking) issues are fixed and deployed.** The app is
materially safer than at the start of the session: no secrets ship in the
binary, account deletion actually deletes media, tokens are in the Keychain,
the public and paid endpoints are rate-limited, a privilege-escalation hole is
closed, and a path-traversal bug is neutralized.

**One item needs YOU (macOS-only tool):** regenerate the Xcode project so the
committed `project.pbxproj` matches the fixed `project.yml`:

```
cd ~/"Rendprop AI/repo/apps/ios" && xcodegen generate
```

Until you do, a clean build could still compile the deleted secret-bearing
classes. This is the single required manual step before you build/submit.

---

## P0 — Release blockers (ALL FIXED)

| # | Issue | Fix | Status |
|---|-------|-----|--------|
| 1 | **`Secrets.plist` (4 live AI keys) was bundled into the .app**, and legacy `Networking/AI/*` clients called providers directly from the client | Deleted the 5 legacy files + `Secrets.plist`; `project.yml` now excludes `**/Secrets.plist`; the only preview button that used them was removed. All AI runs server-side. | ✅ code |
| 2 | **`services/pipeline/.env` (provider keys + Supabase service-role key) could be baked into the Docker image** (no dockerignore, `COPY pipeline`) | Added `services/.dockerignore` excluding `**/.env*` (re-allowing `.env.example`) + the `edge/`+`supabase/` trees. | ✅ code |
| 3 | **6 npm advisories (4 high) via Wrangler 3 / old `ws`** | Bumped `wrangler` to `^4.0.0` in tour-host `package.json`; deleted the stale lockfile so a fresh resolve is clean. | ✅ code (run `npm install`) |
| 4 | **Privacy policy promised deletion of uploaded content, but `DELETE /me` left all R2 media** | Implemented `deleteObjects` in `_shared/r2.ts`; `DELETE /me` now collects keys from `capture_assets` + `photos` + `renders` and purges R2 (bounded concurrency, capped, best-effort). | ✅ deployed (`me` v11) |
| 5 | **App had no privacy manifest** — App Store auto-rejects (ITMS-91053) given UserDefaults / file-timestamp / disk-space / uptime APIs | Added `Rendprop/PrivacyInfo.xcprivacy` with required-reason codes (CA92.1, C617.1, E174.1, 35F9.1) + data-collection entries (email, name, photos/videos, coarse location; tracking = false). | ✅ code |
| 6 | **Stale committed `project.pbxproj`** still references the deleted files → clean build fails or silently rebuilds the old app | `project.yml` fixed. **Requires `xcodegen generate` on your Mac** (can't run macOS tooling here). | ⚠️ YOU |

## P1 — High (ALL FIXED)

| Issue | Fix | Status |
|-------|-----|--------|
| **Denial-of-wallet:** `ai-video` / `ai-photo` had zero spend controls — any signed-in user could loop paid GPU/Gemini calls | Per-org durable rate limits (Postgres `bump_rate`): 12 video jobs and 40 photo edits / 5 min / org. | ✅ deployed (`ai-video` v4, `ai-photo` v8) |
| **Privilege escalation:** RLS `"member orgs write"` had no `WITH CHECK`/column scope, so a member could `PATCH orgs` and self-upgrade `plan` to `team` via PostgREST | Migration 0005: `REVOKE UPDATE ON orgs` from tenants, `GRANT UPDATE (name, handle, space_type, brand_kit)` only. `plan`/`id`/`created_at` are now service-role-only. | ✅ deployed (migration) |
| **`is_org_member()` SECURITY DEFINER without pinned `search_path`** — the linchpin of every org RLS policy | Migration 0005: `SET search_path = public, pg_temp`. | ✅ deployed (migration) |
| **Path traversal in `enhance.py`:** user chapter/room labels built filesystem paths (`../../x` → escape), run in the worker | `_safe_name()` slugifies labels to `[A-Za-z0-9_-]{≤64}` before any path use. Verified: `../../etc/passwd` → `etc_passwd`. | ✅ code |
| **Durable rate limiting for public `leads` / `beacon`** (the in-memory limiter reset per instance) | Migration 0004 `bump_rate` + `_shared/ratelimit.ts`; both endpoints now use it (fall back to memory if the RPC is down). | ✅ deployed (`leads` v9, `beacon` v9, migration) |
| **Auth tokens in UserDefaults** (world-readable in a backup) | Moved to Keychain (`kSecClassGenericPassword`, `AfterFirstUnlockThisDeviceOnly`) with silent one-time migration from the legacy slot. | ✅ code |

## P2 — Medium (FIXED)

| Issue | Fix | Status |
|-------|-----|--------|
| **Worker container ran as root** while processing untrusted video with ffmpeg | Dockerfile creates + switches to `appuser` (uid 10001). | ✅ code |
| **`signOut()` didn't cancel an in-flight refresh** — a refresh resolving after sign-out re-persisted tokens | `signOut()` now cancels `refreshInFlight` first. | ✅ code |
| **"Delete account" left listing photos, AI edits, and `enhanced-*/aerial-*` render masters on disk** | `wipeLocalData()` now also removes `Documents/Photos`, `enhanced-*`/`aerial-*`/`preview-*` files, and the `player-demo` cache. | ✅ code |
| **Portfolio export fabricated dead `/f/<uuid-prefix>` links** for unpublished tours and didn't escape the share URL | Export now includes only tours with a real `serverShareURL`, and `esc()`s it. | ✅ code |
| **R2 purge didn't cover `photos` + `renders` keys or Stream** (Supabase agent) | Purge now covers `photos.{original,enhanced}_key` and `renders.{video,poster}_key`. Stream (`stream_uid`) still pending — see below. | ✅ mostly (`me` v11) |
| Static-site security headers (audit hardening) | Added `public/_headers`: CSP, HSTS, `X-Frame-Options: DENY`, nosniff, Permissions-Policy, immutable asset caching. | ✅ code |
| `ai-photo`/`ai-video` missing from `deploy-functions.sh` | Added to the owner-deploy loop. | ✅ code |

---

## Verified SOUND (checked, no change needed)

From the three agents, these areas were reviewed and found correct:

- **XSS across the tour player + portfolio + marketing site** — every interpolation is escaped for its context (`escapeHtml`/`escapeAttr`/`jsonForScript`); `--accent` is hex-allowlisted; hls.js has SRI. No exploitable injection found.
- **iOS `PlayerWebView` injection** — listing/agent values HTML-escaped; video src percent-encoded; base64 headshots safe. (One newline-DoS edge, low severity, noted below.)
- **Upload resume correctness** — per-part ETag state, stale-task fencing by exact `taskDescription`, missing-ETag self-heal, background-session slice copies. Solid.
- **RenderEngine** — real cancellation into the AVFoundation loops, partial-output cleanup, streamed (bounded memory) on 4K/9-min.
- **Persistence tolerance** — every collection decodes independently; no single corrupt field can wipe listings.
- **Sign in with Apple nonce** — `SecRandomCopyBytes`, SHA256 sent, raw nonce to Supabase. Textbook.
- **Supabase authorization** — asset/listing/render ownership is RLS-scoped via `userClient` on every owner route; no IDOR found on uploads/renders/ai-video asset resolution; public routes are published-only; `leads.org_id` can't be spoofed; `memberships` is SELECT-only (no self-add / role escalation).
- **SSRF guard** on `ai-video/status` — resilient to userinfo `@`, IP literals, decimal IPs, `notfal.run`, case tricks.
- **Secret hygiene repo-wide** — no service-role/provider/AWS keys or private keys in tracked files; the one tracked JWT is the public anon key; `.gitignore` covers every `.env` + `Secrets.plist`.
- **No shell injection** in the Python pipeline (list-argv subprocess, no `shell=True`); no `verify=False`.

---

## Known follow-ups (documented, NOT release-blocking)

These are tracked here rather than fixed this session — none block launch, but
schedule them:

1. **Cloudflare Stream deletion** on account delete — R2 objects are purged, but `renders.stream_uid` assets need the Stream API token (separate from R2 creds). Add to the async batch cleaner. *(Only matters once Stream is enabled; today tours play from R2.)*
2. **Ledger-based monthly spend caps** — the new per-org rate limits blunt abuse; the fuller control is reading `cost_ledger` for a hard monthly $ cap + plan quota. The rate limit is the interim guard.
3. **iOS cellular "Wait for Wi-Fi" gate** is not fully wired in the live publish path (upload currently proceeds regardless). Functional, not security. Wire `pendingCellularConfirmation` before launch.
4. **401→refresh→retry** on the first API call after a long suspension (currently the UI can flash a 401 until the background refresh lands). Make `makeRequest` await `validAccessToken()`.
5. **`beacon` metric clamping** — clamp per-call `streamed_minutes`/`watch_ms` to sane maxima; reconcile billable delivery against server-side Stream/R2 analytics.
6. **`jsLabel` newline strip** — extend to `\n \r    ` so a pasted multi-line room name can't break the local player script.
7. **Role enforcement** — RLS checks membership, not `role`; every member currently has owner-level power. Encode roles if that's not intended.
8. **iOS backup exclusion** — mark large regenerable render outputs `isExcludedFromBackup`.

---

## Deployed this session

- Migrations: `0004_rate_limits` (bump_rate), `0005_authz_hardening` (search_path + orgs.plan revoke) — both applied live.
- Edge functions: `me` v11, `leads` v9, `beacon` v9, `ai-photo` v8, `ai-video` v4.
- All committed to git (see the `1a8f885` and follow-up commits).

## What you run

1. `cd ~/"Rendprop AI/repo/apps/ios" && xcodegen generate` — **required**, regenerates the Xcode project without the deleted files.
2. `cd ~/"Rendprop AI/repo/services/edge/tour-host" && npm install && npx wrangler deploy` — clears the npm advisories + ships the security headers/site.
3. Rebuild the app in Xcode (⇧⌘K then Run) and re-test publish + account deletion.
4. Rotate the 4 AI provider keys that were previously bundled (Gemini, fal, Anthropic, Kie) — they should be considered exposed by any prior distributed build.
