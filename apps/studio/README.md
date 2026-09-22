# Rendprop Studio

The web creation workspace for the existing Rendprop product. React + TypeScript,
original Rendprop branding, the same Supabase identity and organization model.

## Run and verify

```bash
npm ci --no-audit --no-fund
npm run dev
npm run verify
npx playwright install chromium
node tests/browser-workspace.mjs --start-preview --base-url=http://127.0.0.1:4181
node tests/browser-editor.mjs --start-preview --base-url=http://127.0.0.1:4182
node tests/browser-connected.mjs
node tests/browser-connected-control.mjs
npx wrangler deploy --dry-run
```

Node 22.12 or later and ffmpeg/ffprobe are required for all verification. Browser
tests use synthetic media, not a production login or customer files. On macOS an
existing browser can be selected with `STUDIO_BROWSER_EXECUTABLE`.

The editor and planner run without configuration or an account. Local media stays
on the device; edit instructions and planned captions stay in browser storage.
This is **not** cloud backup or automatic social publication. Original files must
be reselected after a reload, and their full hashes must match the saved edit.
Undo/Redo keeps up to 20 recent steps within 64 KiB of metadata. Undoing removal
restores the edit instructions, not the released file. Content plans can be
downloaded as versioned JSON and restored with an explicit Merge/Replace preview.
The connected browser harness compiles a separate offline test entry; it proves
App/session behavior, not live Apple sign-in. It never overwrites production dist.

## Connected accounts

Use only public Supabase values from `.env.example`. The build rejects unexpected
`VITE_` fields and server-role keys. Never put any server secret in a Vite variable.
The September 14 release configures Apple web sign-in for `com.rendprop.studio`,
associated with the existing native `com.rendprop.app` identity. It deploys the
authenticated `studio` media function and Studio-origin signed GET/HEAD access to
the private R2 buckets. Existing native audiences and redirect URLs are preserved.

Production builds need the two public fields in `.env.production.local` (ignored
by Git), or the equivalent build environment. Building without them produces a
local-only preview. `npm run verify` validates both public configuration and built
assets; `node scripts/verify-deployed.mjs` compares live assets with that build.

See [the current release and verification record](../../docs/web-client/release-2026-09-14/README.md).
Workspace/library reads share the iPhone account's existing RLS. Listings and
memberships paginate within the selected workspace; refresh uses the signed-in
user's token. Browser edit plans and content plans remain local, not cloud writes.

## Boundaries

- `src/data/`: exact wire DTOs, account/workspace fencing, bounded authenticated reads.
- `src/editor/`: validated immutable edit intent, bounded media import and actual export.
- `src/Planner.tsx` / `src/workspace.ts`: account-scoped local plans and UTC reminders.
- `src/App.tsx`: orchestration, not a second billing service or server queue.
- `public/`: original mark and private workspace response policies.
- `services/supabase/functions/studio/` at the repository root: RLS-scoped media bridge.

The static Worker is separate from the public tour-host. Its configuration does not
replace any existing tour, upload domain, or iOS backend. An upload dry-run is only
packaging evidence; deployed functionality requires a separate read-back receipt.

`Cache-Control: no-store, no-transform` is deliberate. Cloudflare's zone-level
JavaScript Detection injected an extra inline script into the first live HTML,
breaking exact-byte verification and conflicting with the strict CSP. The
[documented no-transform response directive](https://developers.cloudflare.com/cloudflare-challenges/challenge-types/javascript-detections/)
prevents that injection for Studio responses only. It does not change zone-wide
bot/WAF settings or other hostnames; JSD signals will be missing for these responses.
Do not remove it or permit inline scripts simply to make a browser test green.
