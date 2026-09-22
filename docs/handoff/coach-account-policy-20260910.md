# Coach account-policy copy repair — 2026-09-10

## Scope and outcome

Prepared on `fix/coach-offline-account-copy-20260910`, isolated from source base
`869c30f1cf74149f79278066aa269cf762a79be6`. This closes the **copy** defect
identified in `docs/audits/2026-09-10/IOS-UX.md`: the actual offline Coach matcher
said Apple sign-in was required to publish. The independent server knowledge
entry contained the same misconception. No authorization gate, endpoint,
provider route, entitlement, purchase, UI navigation or deletion implementation
was changed or exercised.

Both now say no account is required to record/edit/build/publish, publication
needs an internet connection, and Apple sign-in is optional for accessing a
workspace on another device. The server text explicitly distinguishes the app's
anonymous session from an identified Apple account. Neither promises offline
publication or changes subscription/plan policy.

The same entries had misleading deletion claims: server knowledge described
guests as having no server account and only a local wipe; offline text promised
every tour link disappeared. Both explanations now acknowledge anonymous server
accounts, pending cleanup and shared-team data, preserving the separate App Store
subscription distinction. These are informational replies, not instructions to
run a deletion for testing. **No deletion request or destructive action ran.**

## Evidence behind the copy

- Standing brief §2: a session is not an Apple identity; neither gates features.
- `FlythroughDetailView.swift` `publishNow` invokes `FeatureSessionAction`, which
  waits for `AuthStore.ensureSession()` and then `publishWithSession`. This is
  anonymous-session recovery, not an Apple-sign-in gate. Source read only.
- `SettingsView.swift` `deleteAccount` checks for a session, requests server
  deletion first when server accounts are enabled, and stops before local erasure
  if that request fails. It retains an honest pending-cleanup state.
- `me/index.ts` dispatches deletion after `getUser`; `_shared/supabase.ts`
  validates the bearer user without an `is_anonymous`/Apple-identity restriction.
  `handleDelete` separates solo and shared organizations, retains shared-workspace
  content with membership/reassignment handling, and reports cleanup that is
  still pending. This is source evidence, **not a new production deletion test**.

The Supabase skill prompted a public changelog scan and verification of the
[official anonymous-sign-in documentation](https://supabase.com/docs/guides/auth/auth-anonymous).
It confirms that anonymous users have authenticated sessions and can later link
an identity; the app's own source establishes its publication policy. No relevant
changelog breaking change required a code/API change here. No database query,
credential, project setting or Supabase runtime was accessed.

## Actual tests, including red-before-green

Existing `tests/phase1/run-unit.sh` is extended rather than replacing the matcher
with a test implementation. `CoachOfflineTests.swift` compiles the **entire
production** `CoachModel.swift` and `CoachAPI.swift`, directly executes
`CoachOffline.answer`, and supplies only inert unrelated app dependencies. Those
stand-ins trap on API, analytics, purchase, consent or real filesystem access.

Before the production copy edit:

```sh
swiftc -parse-as-library apps/ios/Rendprop/Coach/CoachAPI.swift \
  apps/ios/Rendprop/Coach/CoachModel.swift tests/phase1/CoachOfflineTests.swift \
  -o /tmp/rendprop-coach-account.DTcta7/coach-before
/tmp/rendprop-coach-account.DTcta7/coach-before
deno test --cached-only --deny-net --deny-env --deny-run --deny-read --deny-write \
  services/supabase/functions/coach/knowledge_test.ts
```

Swift compiled successfully, then exited **1** on the actual account response.
Typed Deno exited **1**, with **1 passed / 3 failed**: direct account entry,
formatted knowledge block and anonymous deletion text failed. These were actual
response/value assertions, not only text-presence searches or compiler failures.

After the repair:

```sh
bash tests/phase1/run-unit.sh
deno test --cached-only --deny-net --deny-env --deny-run --deny-read --deny-write \
  services/supabase/functions/coach/
bash -n tests/phase1/run-unit.sh
git diff --check
```

All exited **0**. The existing session suite's four concurrency/recovery
scenarios still pass; the Coach executable passes **37 assertions, 0 skipped**.
Its deliberately false assertion separately exits **1** before the positive
run. Typed Deno passes **32 tests, 0 failed / 0 skipped**: the existing action
tests plus **4 new knowledge tests**, including a negative-policy control.

Evidence: `/tmp/rendprop-coach-account.DTcta7/` contains `swift-before.log`,
`deno-before.log`, `swift-after.log`, `deno-after.log` and `deno-all.log`.
The final Swift binary is retained under the path printed by the phase-1 harness.
No private capture, photos, real app state or credentials enter these fixtures.

## Still unproved / integrator action

This is compiled portable Swift response behavior and typed offline Deno
knowledge/formatting, not a full iOS target build, CoachView interaction,
consent-denial flow, network fallback, real LLM answer, live publication,
account adoption or deletion. Root's prior consent UI run does **not** cover this
later source until it is rebuilt. The normal combined iOS release gate remains
the integrator's task. Server copy is not live until a separately authorized
deployment; no deployment is included here.

Unrelated knowledge statements and the old `CoachShot` screenshot suite were
not audited or rewritten. That suite's canned mock response is not proof of this
offline answer, so it was deliberately not used as the verification oracle.
