# Rendprop — 20-Point Pre-Launch Security Checklist

*Verified 2026-08-26 against live code. Most items were already closed by the
release-gate audit (`RELEASE-GATE-AUDIT.md`); this pass verified each and closed
the remaining gaps.*

| # | Item | Status | Evidence / what was done |
|---|------|--------|--------------------------|
| 1 | **Hide API keys** | ✅ Done | `Secrets.plist` + legacy direct-AI clients removed from the app; every provider key lives only in Supabase function secrets / R2 tokens, never in the client or repo. |
| 2 | **Purge Git secrets** | ✅ Verified clean | Scanned **full git history** (all commits) for `AIza…`, `sk-ant…`, `fal_…`, AWS `AKIA…`, private-key blocks, service-role JWTs — **none found**. `Secrets.plist` was never committed (gitignored from day one). |
| 3 | **Use public DB key** | ✅ Done | The app ships only the Supabase **anon** key (public by design); the service-role key stays server-side in function secrets. |
| 4 | **Enable row-level security** | ✅ Done | RLS is `enable`d on every table (verified in audit). `userClient` runs as the caller so Postgres enforces org scoping. |
| 5 | **Encrypt sensitive data** | ✅ Done | Auth tokens moved to the **Keychain** (`AfterFirstUnlockThisDeviceOnly`); R2 + Supabase encrypt at rest; all transport is TLS. |
| 6 | **Enforce server-side auth** | ✅ Done | Every owner route calls `getUser(req)` which validates the JWT against Supabase Auth before any work. |
| 7 | **Lock record access** | ✅ Done | RLS org-scoping + explicit ownership checks; the audit specifically hunted IDOR on uploads/renders/ai-video asset resolution and found none. |
| 8 | **Block field tampering** | ✅ Done | Migration 0005 `REVOKE UPDATE ON orgs` from tenants + column-scoped grant — closes the `plan` self-upgrade (privilege-escalation) hole. `id`/`created_at`/`plan` are service-role-only. |
| 9 | **Secure session cookies** | ✅ N/A | No auth cookies — the app uses bearer JWTs (Keychain), and the public tour site sets no session cookie. Nothing to harden. |
| 10 | **Hash passwords** | ✅ N/A | No passwords stored — auth is **Sign in with Apple** → Supabase. There is no password to hash. |
| 11 | **Rate limit login** | ✅ Done (managed) | Sign-in is handled by Supabase Auth, which rate-limits token endpoints. Our own public endpoints have a **durable Postgres limiter** (migration 0004). |
| 12 | **Add bot protection** | ⚠️ Mostly | Honeypot field + durable per-IP rate limit on `leads`/`beacon`. **Turnstile/CAPTCHA is the one remaining add** before heavy public traffic (documented follow-up). |
| 13 | **Parameterize queries** | ✅ Done | All DB access goes through the Supabase client / PostgREST (parameterized). No raw SQL string concatenation anywhere. |
| 14 | **Validate all input** | ✅ **Fixed this pass** | `leads` now validates email + phone format, caps name/email/phone lengths, and bounds `extra` to 4 KB. Owner routes already assert required fields + allow-list `tier`/`aspect`/`edit`/`style`. |
| 15 | **Escape user content** | ✅ Done | XSS audit confirmed `escapeHtml`/`escapeAttr`/`jsonForScript` on every interpolation in the tour player + portfolio; hex-allowlisted `--accent`. |
| 16 | **Restrict file uploads** | ✅ **Fixed this pass** | `uploads` now enforces **size ceilings** (12 GB video / 50 MB photo) and a **content-type allowlist** (`video/mp4|quicktime|x-m4v`, `image/jpeg|png|heic|heif|webp`). Keys are org-scoped; filename ext already sanitized. |
| 17 | **Trim API responses** | ✅ **Fixed this pass** | `tours` agent_card now **allow-lists** display fields instead of spreading the whole `brand_kit` jsonb, so no internal key can ever leak into the public tour payload. |
| 18 | **Add security headers** | ✅ Done | `public/_headers` (CSP, HSTS, `X-Frame-Options: DENY`, nosniff, Permissions-Policy) for the static site; the Worker sets CSP on dynamic pages. |
| 19 | **Force HTTPS** | ✅ Done | HSTS `max-age=31536000; includeSubDomains`; Cloudflare redirects HTTP→HTTPS at the edge for the whole zone. |
| 20 | **Scan dependencies** | ✅ Done | Wrangler bumped to 4 (cleared the 6 npm advisories — the old `ws` chain). Python worker deps are just `boto3` + `requests` (current, no known criticals). Re-run `npm audit` at each deploy. |

## Fixed this pass (need a function redeploy to go live)
`leads`, `uploads`, `tours` — deploy with:
```
cd ~/"Rendprop AI/repo/services/supabase" && ./deploy-functions.sh
```
(or the three via the Supabase dashboard). Everything else is already live from the audit.

## The only genuine open item
**#12 — Turnstile/CAPTCHA on the public lead form** before you drive real traffic. The honeypot + durable rate limit hold for launch; add Turnstile when volume justifies it. Tracked in `RELEASE-GATE-AUDIT.md`.

## Still your manual step (from the audit)
`cd ~/"Rendprop AI/repo/apps/ios" && xcodegen generate` — regenerates the Xcode project without the deleted secret files. Then rotate the 4 previously-bundled provider keys.
