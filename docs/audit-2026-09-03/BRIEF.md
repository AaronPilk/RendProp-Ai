# Rendprop full-app audit — shared brief for every reviewer agent

## What Rendprop is
iOS-first app (SwiftUI, `apps/ios/Rendprop`) that turns a phone walkthrough video of a space into a
"scroll-to-fly-through" cinematic tour with a shareable link. Owner: Aaron (real-estate/marketing
operator). Multi-industry: `SpaceType` = realEstate / venue / restaurant / retail / fitness / other —
each type must feel like its own app (copy, fields, samples, CTA).

Core loop: New listing → upload a video (or record one) → Review & Submit (tag rooms/areas, pick
render tier, optional AI declutter/restage) → render (on-device engine OR backend) → flythrough
player (WKWebView wrapping `Resources/player/index.html`) → share link (tour-host Worker at
rendprop.com / rendprop.app) → listing detail "tools": Aerial intro (AI establishing shot via
backend `/ai-video/aerial`), Listing photos (Core Image enhance + AI photo edits via `/ai-photo`),
Floor plan (RoomPlan LiDAR), Location map, Manage (sold/archived, Zillow), Reels, etc.

Backend: Supabase Edge Functions (`services/supabase/functions/*`, Deno/TS) + Postgres migrations,
Cloudflare R2 + Stream, a Python render worker (`services/worker`), an AI enhancement pipeline
(`services/pipeline`), and the tour-host Cloudflare Worker (`services/edge/tour-host`, TS) which
serves the marketing site + hosted tours + portfolios + lead capture. iOS talks to the backend via
`Networking/APIClient.swift` (protocol), `LiveAPIClient.swift` (real), `MockAPIClient.swift` (offline).
`Config.swift` decides live vs mock.

Hard rules already established (do NOT regress them):
- New `Codable` model fields must be Optional (back-compat with persisted JSON).
- Navigation must be destination-based (`NavigationLink { Dest() } label: {}`), never value-based for Listing.
- No digital-goods prices / purchase copy compiled into the iOS binary (App Store 3.1). Property prices
  and business-entered fields are fine.
- Brand-new .swift files get dropped from the Xcode target unless `xcodegen generate` is re-run — prefer
  adding types to existing files, or flag clearly that xcodegen must be re-run.
- Contact email everywhere is Aaron@pilk.ai (never skyway.media) in user-facing/backend copy.
- Enforced entitlements must equal published entitlements.

## Your job (READ-ONLY in this phase — do not edit files)
Read EVERY LINE of the files assigned to you. Do not skim, do not sample. Then report, with the
user's lens first: "does the logic make sense at every point?" The owner's example: the Aerial
intro tool asks the AI for an establishing shot of "the property" but never lets the user give it
the address or a photo of the house, so the AI can't know what it's generating. Find every gap of
that kind — features that can't actually work, inputs that are never collected, outputs that are
never used, states you can get stuck in, buttons that do nothing, copy that lies about what happens,
flows that dead-end, data that is collected but never displayed/sent, mismatches between what the
app sends and what the server expects, etc. Also report genuine defects: crashes, force-unwraps
on optional data, main-thread violations, races, persistence bugs, leaks, retain cycles, wrong
math, off-by-ones, error paths that swallow failures silently, and security issues.

Context docs you may read for intent: `docs/context/RENDPROP-FABLE5-BRIEF.md`,
`docs/context/RENDPROP-CONTEXT.md`, `docs/INDUSTRY-LOGIC.md`, `docs/UPLOAD-AND-PUBLISH-CONTRACT.md`,
`docs/AUDIT-RESPONSE-2026-08-28.md`. (`docs/MASTER-BUILD-PROMPT.md` is the original 1100-line spec —
consult sections as needed.)

## Output format (write it to the findings file path given in your prompt, then also return it)
```
# Findings — <slice name>
## Summary
3–6 lines: overall health, the worst problems, what's solid.

## Findings (most severe first)
### F-<slice>-01 · P0|P1|P2|P3 · <short title>
- Where: path:line(s)
- What's wrong: precise description (quote the code when useful)
- User-facing effect: what a real user sees / can't do
- Fix: concrete, code-level plan (which types/functions change, new fields, backend changes needed).
  Keep to the hard rules above.

## Verified OK
Bullet list of things you checked that are correct (so the fix phase doesn't re-litigate them).

## Open questions / needs product decision
```
Severity: P0 = feature cannot work / data loss / crash / security; P1 = wrong behaviour users will hit;
P2 = confusing/incoherent logic or copy; P3 = polish.
Be exhaustive. A long, precise report is what's wanted. Cite line numbers.
