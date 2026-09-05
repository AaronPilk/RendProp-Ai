# HANDOFF-P3 — product analytics, funnel, crash reporting, ad attribution

Branch `launch-p3`. Two commits: `72326b6` (server), `939d6f2` (iOS).

The owner is about to spend money on Meta ads pointing at an app that currently
reports **nothing**: no funnel, no crash count, no attribution. This is the whole
pipeline, first-party end to end — **no Firebase, no Mixpanel, no ad SDK, no
IDFA, no App Tracking Transparency prompt.**

```
iOS app ──POST /events──▶ app_events (Postgres) ──admin_funnel()──▶ GET /admin/funnel ──▶ Funnel screen
   │
   └─ SKAdNetwork conversion value 0…5 ──(signed postback, sent by iOS)──▶ Meta
```

---

## 1. What I built

| File | What it is |
|---|---|
| `services/supabase/migrations/0020_app_events.sql` | `app_events` table (service-role only), `admin_funnel(interval)`, `purge_app_events(interval)` |
| `services/supabase/functions/events/index.ts` | `POST /events`, `GET /events/health` |
| `services/supabase/functions/events/schema.ts` | vocabulary + per-event props whitelist + PII scrubber (pure, so it can be tested) |
| `services/supabase/functions/events/events.test.ts` | 23 tests |
| `services/supabase/functions/admin/funnel.ts` | `handleFunnel(req)` — `GET /admin/funnel` |
| `services/supabase/functions/admin/funnel.test.ts` | 7 tests |
| `apps/ios/Rendprop/Analytics/Analytics.swift` | the queue, device id, sessions, flush |
| `apps/ios/Rendprop/Analytics/AnalyticsAPI.swift` | `protocol AnalyticsAPI` + Live/Mock |
| `apps/ios/Rendprop/Analytics/CrashReporter.swift` | MetricKit crash/hang/CPU/disk summaries |
| `apps/ios/Rendprop/Analytics/Attribution.swift` | SKAdNetwork conversion values |
| `apps/ios/Rendprop/Screens/AdminFunnelView.swift` | the Funnel screen + `AdminFunnelAPI` |
| `apps/ios/Rendprop/Info.plist` | `SKAdNetworkItems` (Meta) — **edited** |
| `apps/ios/Rendprop/PrivacyInfo.xcprivacy` | DeviceID / CrashData / PerformanceData — **edited** |
| `apps/ios/Rendprop/RendpropApp.swift` | two small hunks — **edited** |

**One file I created that was not in my brief:** `functions/events/schema.ts`. It
exists because `index.ts` calls `Deno.serve` at module load, so a test cannot
import it — and the vocabulary/whitelist/scrubber are exactly the parts that must
be tested. Same split the repo already uses for `_shared/router.ts` +
`router.test.ts`. It sits inside the `events/` directory nobody else owns, and
the Supabase CLI bundles relative imports (see commit `f4c8e8b`), so nothing
about the deploy changes.

---

## 2. Checks run

```
deno check  events/schema.ts  events/index.ts  events/events.test.ts
            admin/funnel.ts   admin/funnel.test.ts                   → all clean
deno test   events/events.test.ts                                    → 23 passed
deno test --allow-env --allow-net admin/funnel.test.ts               → 7 passed
swiftc -parse  Analytics/{Analytics,AnalyticsAPI,CrashReporter,Attribution}.swift
               Screens/AdminFunnelView.swift  RendpropApp.swift      → all clean
plistlib parse Info.plist, PrivacyInfo.xcprivacy                     → both valid
```

`0020_app_events.sql` was **applied, replayed and exercised against a real
PostgreSQL 16** in this container (roles `anon`/`authenticated`/`service_role`
stubbed): idempotent replay is a no-op, both CHECK constraints reject what they
should, `admin_funnel` returns correct step counts / percentages / by_day on
seeded data and a full-shaped empty report on an empty table, the window clamps
(1 h … 365 d) hold, and `purge_app_events` deletes on `received_at`.

**End-to-end wire check.** `EventBatch` was encoded by the real Swift type on
Linux and the resulting JSON fed straight into the server's `normalizeBatch` —
`device_id`/`session_id` pass `UUID_RE`, the event survives with
`droppedProps: 0, droppedEvents: 0`, and `app_version` `"1.0 (1)"` survives the
phone-number rule (it is 7 characters; the rule needs 8+).

**Every insertion in §4 was dry-run applied to a scratch copy of the target file
and re-parsed / re-checked**: the ten `Analytics.track` lines against
`RendpropApp.swift`, `Capture/CaptureView.swift` and
`Screens/FlythroughDetailView.swift` (`swiftc -parse` clean); the `case "funnel"`
+ import against `admin/index.ts` (`deno check` clean); the Funnel tab against
`Screens/SettingsView.swift` (`swiftc -parse` clean). Each anchor matches exactly
once in its file.

**Secrets grep over the whole diff** — `git diff launch...launch-p3 | grep -niE
'(api[_-]?key|secret|password|token|bearer [A-Za-z0-9]|eyJ)'` — every hit is an
env-var NAME, a header name, or `Config.supabaseAnonKey` (the public anon key,
already in `Config.swift` by design). No credential value is added anywhere.

---

## 3. Deploy

### 3a. Migration (FIRST — the function 500s without the table)

```bash
psql "$SUPABASE_DB_URL" -f services/supabase/migrations/0020_app_events.sql
```
Idempotent. Safe to re-run.

### 3b. The `events` function — **verify_jwt ON (the default)**

```bash
supabase functions deploy events --project-ref ymgqpbnjpztwjsyvceld
```

**Do NOT pass `--no-verify-jwt`.** Yes, it is reachable while signed out — but
the client sends the project's **anon key as the bearer**, and the anon key *is*
a project-signed JWT, so the gateway accepts it. That gateway check is the first
of three layers keeping this from being an open write endpoint on the internet.
The function then calls `getUser()`; a bearer that is not a user (the anon key)
is the signed-out case and records `user_id = org_id = null`.

In `services/supabase/deploy-functions.sh`, add `events` to the **owner/JWT**
loop, not the public one:

```diff
-for f in listings uploads renders me ai-enhance ai-photo ai-video ai-voice admin; do
+for f in listings uploads renders me ai-enhance ai-photo ai-video ai-voice admin events; do
```
(and bump the closing echo from "13 functions" to "14").

### 3c. `admin` function — one line in the switch

`services/supabase/functions/admin/index.ts`, in the `switch (route)` block
(currently lines 98–113), immediately after the `case "health":` arm:

```ts
      case "funnel":
        return await handleFunnel(req);
```

and add the import next to the other `_shared` imports at the top of the file
(after the `import type { SupabaseClient }` line, ~line 60):

```ts
import { handleFunnel } from "./funnel.ts";
```

Then extend the 404 message in the `default:` arm so it mentions `/admin/funnel`,
and add the route to the header comment. Redeploy `admin` (JWT-verified, as it
already is — `requireAdmin` runs before the switch, so `funnel` inherits the
401/403 gate and the 60/min rate limit for free).

```bash
supabase functions deploy admin --project-ref ymgqpbnjpztwjsyvceld
```

### 3d. Smoke test after deploy

```bash
# health (anon key is enough)
curl -s -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
  "$BASE/functions/v1/events/health"        # → {"ok":true}

# one signed-out event
curl -s -X POST -H "apikey: $ANON" -H "Authorization: Bearer $ANON" \
  -H "Content-Type: application/json" \
  -d '{"device_id":"11111111-1111-4111-8111-111111111111",
       "session_id":"22222222-2222-4222-8222-222222222222",
       "app_version":"1.0 (1)","os":"iOS 26.4",
       "events":[{"name":"app_open","t":"2026-09-05T12:00:00Z","props":{"cold":"true"}}]}' \
  "$BASE/functions/v1/events"               # → 202 {"ok":true,"accepted":1,...}

# funnel (owner JWT)
curl -s -H "apikey: $ANON" -H "Authorization: Bearer $OWNER_JWT" \
  "$BASE/functions/v1/admin/funnel?window=7d"
```

---

## 4. iOS integration — the exact insertions

### ⚠️ 4a. FIRST: `xcodegen generate` on the Mac (blocking)

I added **five new Swift files**. `apps/ios/Rendprop.xcodeproj/project.pbxproj`
is committed and lists its sources individually;
`Screens/AdminConsoleView.swift`'s header says a new file that skips
`xcodegen generate` is silently dropped from the target and takes the whole
build down ("that has happened twice in this repo").

```bash
cd apps/ios && xcodegen generate
```

**must be run before building**, and the regenerated `project.pbxproj` committed.
If regenerating is off the table for this release, the fallback is to move the
five files' contents into an existing in-target file (`Analytics.swift`,
`AnalyticsAPI.swift`, `CrashReporter.swift` and `Attribution.swift` have no
SwiftUI in them and could all be appended to `Config.swift`; `AdminFunnelView`
would go at the bottom of `Screens/SettingsView.swift` beside `AdminRoutingView`)
— but regenerating is much the better answer.

### 4b. `Screens/SettingsView.swift` — the Funnel tab

In the `Owner console` `Section` (currently lines 227–245), immediately after the
`// MARK: - end router additions` line:

```swift
                    // MARK: - funnel additions (P3)
                    NavigationLink {
                        AdminFunnelView()
                    } label: {
                        Label("Funnel", systemImage: "chart.line.downtrend.xyaxis")
                    }
                    // MARK: - end funnel additions
```

…and replace the Section's `footer` text with:

```swift
                    Text("Spend and providers are read-only. Funnel shows where people stop and whether the app is crashing. AI routing can be changed — it decides which provider runs each AI job. This row is here because the server says this account is an admin; it enforces that on every request, so nothing on this phone can unlock it.")
```

No other change: `AdminFunnelView` carries its own `AdminFunnelAPI` protocol and
both client extensions, and casts `model.api as? AdminFunnelAPI` — the same
pattern as `AdminRoutingAPI`. Nothing in `Networking/APIClient.swift` moves.

### 4c. P1 sink — one line

`RendpropApp.swift` already carries the marker comment
`// P1 WIRE (paywall events) goes here` in the `analytics additions` block at the
end of the `WindowGroup` modifier chain. Replace that comment with:

```swift
            .onAppear { PaywallEvents.sink = Analytics.externalSink }
```

`Analytics.externalSink` is `nonisolated` and hops to the main actor itself, so
P1's `PaywallEvents.sink` can be any `(String, [String: String]) -> Void` on any
queue. If P1's signature differs, this still works as a one-liner:

```swift
            .onAppear { PaywallEvents.sink = { name, props in Analytics.track(name, props) } }
```

P1 owns `paywall_viewed`, `purchase_started`, `purchase_completed`,
`purchase_failed` and `restore` — all five are already in the server vocabulary
and in `Analytics.vocabulary`, and `paywall_viewed` / `purchase_completed` are
SKAdNetwork rungs 4 and 5, raised automatically by `Analytics.track`. P1 needs to
do nothing beyond emitting the names.

### 4d. Instrumentation — paste-ready, **not applied**

Every line below is a one-line insertion into a file I do not own. All are inside
`@MainActor` contexts (`AppModel`, `RenderCoordinator`, SwiftUI views), so
`Analytics.track` can be called directly with no hop. **Props are enums, counts
and booleans only — never an address, a file name, a listing id or a URL.**

Every anchor below was checked to match **exactly once** in its file at
`939d6f2`; line numbers are indicative, the anchor text is authoritative.

**1. `home_created` — `apps/ios/Rendprop/RendpropApp.swift`, `AppModel.startProject(named:)` (~line 2620)**

anchor:
```swift
        add(listing)
        return listing
```
becomes:
```swift
        add(listing)
        Analytics.track("home_created", ["space_type": SpaceType.current.rawValue])
        return listing
```

**2. `capture_started` — `apps/ios/Rendprop/Capture/CaptureView.swift`, `recordButton` (~line 241)**

anchor:
```swift
                camera.startRecording()   // motion logging starts from the first written frame
```
insert immediately after:
```swift
                Analytics.track("capture_started", ["space_type": SpaceType.current.rawValue])
```

**3. `capture_finished` — `apps/ios/Rendprop/Capture/CaptureView.swift`, `handleFinished(_:)` (~line 430)**

anchor (this is *after* the `discardOnFinish` early return, so a discarded take is
correctly not counted):
```swift
        Haptics.success()   // the one "clip saved" haptic (CameraManager no longer fires its own)
```
insert immediately after:
```swift
        Analytics.track("capture_finished", ["space_type": SpaceType.current.rawValue,
                                             "duration_s": String(Int(camera.elapsed))])
```

**4. `render_finished` — `apps/ios/Rendprop/RendpropApp.swift`, `RenderCoordinator` (~line 855)**

anchor:
```swift
        model.uploadedRenderAssets.removeValue(forKey: id)   // a new file: any earlier upload is stale
```
insert immediately **before** it:
```swift
        Analytics.track("render_finished", ["ok": "true", "duration_s": String(Int(output.durationS))])
```

**5. `tour_published` — `apps/ios/Rendprop/RendpropApp.swift`, `publishTour(...)` (~line 558)**

anchor — `pendingPublish.removeAll { $0 == id }` appears **five times** in this
file, so match the whole block:
```swift
                l.status = .ready
                listings[i] = l   // persists via didSet
            }
            pendingPublish.removeAll { $0 == id }
```
insert between the closing `}` and `pendingPublish.removeAll`:
```swift
            Analytics.track("tour_published", ["space_type": SpaceType.current.rawValue, "ok": "true"])
```

**6. `ai_photo_edit` — `apps/ios/Rendprop/Screens/FlythroughDetailView.swift` (~line 2339)**

anchor (inside the `await MainActor.run { … }` after a successful `aiPhotoEdit`):
```swift
                    compare = newPhoto   // show the before/after (and its disclosure)
```
insert immediately after:
```swift
                    Analytics.track("ai_photo_edit", ["task": edit, "ok": "true"])
```
> `edit` is the `String` parameter of `aiEdit(_:_:style:prompt:)` and is already
> one of `twilight | sky | lawn | declutter | stage | custom`
> (`AIPhotoEditRequest.edit`). Send **only** that. Never send `prompt` — it is
> free text the user typed and can contain an address.

**7. `reel_made` — `apps/ios/Rendprop/Screens/FlythroughDetailView.swift` (~line 5475)**

anchor:
```swift
                    lastReel = outURL
                    phase = .done
                    Haptics.success()
```
insert after `Haptics.success()`:
```swift
                    Analytics.track("reel_made", ["ok": "true", "clips": String(clipURLs.count)])
```

**8. `voiceover_added` — `apps/ios/Rendprop/Screens/FlythroughDetailView.swift`, TWO sites**

recorded voice (~line 5079), anchor:
```swift
                    voiceover = vo
                    voPlayer = nil
                    isTranscribing = false
                    Haptics.success()
```
insert after `Haptics.success()`:
```swift
                    Analytics.track("voiceover_added", ["ok": "true", "duration_s": String(Int(dur))])
```

AI voice (~line 5152), anchor:
```swift
                    voiceover = vo
                    voPlayer = nil
                    ttsInFlight = false
                    Haptics.success()
```
insert after `Haptics.success()`:
```swift
                    Analytics.track("voiceover_added", ["ok": "true", "duration_s": String(Int(result.durationS))])
```

**9. `aerial_made` — `apps/ios/Rendprop/Screens/FlythroughDetailView.swift` (~line 4149)**

anchor (the completed-aerial path, after the clip has landed on disk):
```swift
            phase = .result
            Haptics.success()
```
insert after `Haptics.success()`:
```swift
            Analytics.track("aerial_made", ["ok": "true"])
```

**10. `paywall_viewed` — P1 owns this.** If P1's StoreKit paywall does not land
this release, the fallback is the three existing upgrade CTAs that open
`Config.pricingURL`: `Screens/RenderStatusView.swift:270`,
`Screens/FlythroughDetailView.swift:1473` and `:2166`. One line at each,
immediately before the link is opened:
```swift
                        Analytics.track("paywall_viewed", ["source": "quota"])
```

---

## 5. What the OWNER (Aaron) must do

1. **Register the app for SKAdNetwork in Meta Events Manager.** In Meta Ads
   Manager → **Events Manager → Data Sources → Add → App**, add the iOS app by
   its **App Store ID** and confirm the bundle id `com.rendprop.app`. Then open
   the app's **App Events / SKAdNetwork settings** and configure the conversion
   schema so Meta's value ladder matches ours:
   `0 = install · 1 = signup · 2 = home_created · 3 = tour_published ·
   4 = paywall_viewed · 5 = purchase_completed`, coarse `low` 0–1, `medium` 2–3,
   `high` 4–5. Then optimise campaigns for **value 5 (Subscribed)**, not installs.
   Nothing else is needed in the app — the two SKAdNetwork ids are already in
   `Info.plist` and iOS sends the postback itself.
2. **Schedule the retention purge** (otherwise `app_events` grows forever). Once,
   in the Supabase SQL editor:
   ```sql
   select cron.schedule(
     'purge-app-events', '17 4 * * *',
     $$ select public.purge_app_events(interval '180 days'); $$
   );
   ```
3. **App Store Connect privacy answers** — the manifest now declares three new
   things, so the questionnaire must match:
   * **Device ID** — Yes / Linked to the user / **Not** used for tracking /
     Analytics + App Functionality + Developer's Advertising.
   * **Crash Data** and **Performance Data** — Yes / Linked / Not tracking /
     App Functionality + Analytics.
   * **Product Interaction** — this changes from *not linked* to **Linked**, and
     gains **Developer's Advertising or Marketing** as a purpose.
   * **App Tracking Transparency: still No.** SKAdNetwork attribution is not
     tracking under Apple's definition — nothing is joined with another
     company's data and nothing goes to a data broker.
4. **`xcodegen generate` on the Mac** — see §4a. This one is blocking.

---

## 6. Sources

* **Meta SKAdNetwork ids** `v9wttpbfk9.skadnetwork` and `n38lu8286q.skadnetwork`
  — verified 2026-09-05 against Meta's own developer documentation,
  <https://developers.facebook.com/docs/setting-up/platform-setup/ios/SKAdNetwork>,
  which prints exactly those two in its `SKAdNetworkItems` plist snippet. Nothing
  speculative was added: an identifier for a network we do not buy from is dead
  weight in App Review.
* Conversion-value ladder and event vocabulary: `docs/LAUNCH-CONTRACT.md §Events`.

---

## 7. Open risks

1. **New Swift files need `xcodegen generate`** (§4a). Highest-severity item here
   — skipping it breaks the whole build, not just this feature.
2. **The funnel is not a cohort funnel.** A device counted at
   `purchase_completed` need not have appeared at `app_open` inside the same
   window, so a 7-day and a 90-day view can disagree slightly at the tail. The
   server says so in `note` and the screen renders it verbatim. A true cohort
   funnel needs a join per step; not worth it at this scale.
3. **`signup` vs `signin` is per-install, not per-account.** The first time an
   install ever becomes signed in is `signup`; every later sign-in is `signin`.
   A returning customer on a brand-new phone is therefore counted as a signup.
   That matches the device-based funnel and matches SKAdNetwork (rung 1 is
   per-install and monotonic anyway). The exact fix if it ever matters: Supabase
   tells `AuthStore` whether the user row was created, so `AuthStore.applySession`
   would pass an `isNewUser` flag into `Analytics.authChanged(_:isNew:)`.
   `AuthStore.swift` is not mine to edit.
4. **MetricKit is delayed by up to ~24 h** and delivers nothing in the simulator.
   The crash count on the Funnel screen lags reality by a day; the footer says
   so. Do not read a zero on launch day as "no crashes".
5. **`props` values are scrubbed, not proven safe.** The three layers
   (vocabulary → whitelist → regex) are tested, and there is a test that fails if
   anyone ever adds a PII-shaped key like `address` or `listing_id` to the
   schema. But layer 3 is regex: a genuinely novel format could slip. Keep the
   whitelist tight — that is the layer that actually does the work.
6. **`purchase_*` and `paywall_viewed` emit nothing until P1's sink is wired**
   (§4c). Until then the last two funnel steps read 0, which looks like a
   catastrophic drop-off rather than missing instrumentation.
7. **Rate limits are per device and per IP** (120/h, 600/h). A CI runner or a
   simulator farm behind one address could trip the IP limit; a 429 is dropped
   silently by the client and retried with backoff, so nothing breaks, but a
   burst of test traffic will under-report.
