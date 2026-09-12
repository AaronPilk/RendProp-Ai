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
npx wrangler deploy --dry-run
```

Node 22.12 or later and ffmpeg/ffprobe are required for all verification. Browser
tests use synthetic media, not a production login or customer files. On macOS an
existing browser can be selected with `STUDIO_BROWSER_EXECUTABLE`.

The editor and planner run without configuration or an account. Local media stays
on the device; edit instructions and planned captions stay in browser storage.
This is **not** cloud backup or automatic social publication. Original files must
be reselected after a reload, and their full hashes must match the saved edit.

## Connected accounts

Use only public Supabase values from `.env.example`. The build rejects unexpected
`VITE_` fields and server-role keys. Never put any server secret in a Vite variable.
Apple web Services ID/callback configuration, the additive `studio` Edge Function,
and R2 read CORS must be verified before advertising connected account access.
Do not change native Apple configuration or the current App Review submission.

See [the complete implementation and deployment handoff](../../docs/web-client/STUDIO-STATUS.md),
[identity contracts](../../docs/web-client/STUDIO-AUTH.md),
[editor proof](../../docs/web-client/STUDIO-EDITOR.md), and
[public search implementation](../../docs/web-client/STUDIO-SEO.md).

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
