# Exact 1.0.5 App Store copy reconciliation

`catalog_copy.py` targets Rendprop app `6808982413` and iOS version `1.0.5`. Its default mode reconciles the four base monthly subscription localizations, the en-US listing and source App Review notes. `--include-team-seats` explicitly adds Team 4–9 localizations and selects the conditional Team description and notes. It does not change products, prices, offers, territories, builds, screenshots, review staging or release state.

```sh
python3 tools/asc/catalog_copy.py plan
```

`plan` uses authenticated GET requests only. It checks the exact non-preserved U.S. price for each selected product, the seven-day trial for the four base subscriptions, and that the App Review Information record already has `demoAccountRequired=true`. The current Max, Ultra and Team target prices are scheduled for **30 October 2026**; the script does not make them effective sooner or change existing subscriber treatment. A Team 4–9 plan additionally requires the native allowlist to be open and every selected variant to have **no** introductory offer, matching the paid-Team-owner-only route. At the 28 October readback, all six variants still had one-week offers, so the Team plan must fail until that conflict is resolved.

The default source copy states that the 100-credit pack, per-property luxury design and Team 4–9 are gated, even though product records exist. Before applying any copy, verify the deployed funded `credit_monthly_catalog` and combined serving policy, genuine purchase routes on the exact iPhone build, and the secure reviewer-account setup. The App Review Information login must be provisioned and rehearsed separately; this script reads the flag but never prints or writes credentials.

For a Team 4–9 candidate, prepare the native and funded server paths, resolve the introductory offers, capture a distinct genuine review screenshot for each variant, then inspect the conditional wording in `description_team_seats.txt` and `review_notes_team_seats.txt` against the actual Sandbox device route. Keep the public gate off until Apple approves the submitted tiers. The Team copy path is explicit:

```sh
python3 tools/asc/catalog_copy.py plan --include-team-seats
python3 tools/asc/catalog_copy.py apply \
  --include-team-seats \
  --confirm-app-id 6808982413 \
  --confirm-version-id <read-back-version-id> \
  --confirm-credit-activation \
  --confirm-team-seat-activation
```

Without Team activation, omit both Team flags and use the default files. `asc.py metadata apply` always reads `description.txt`; use the narrow copy helper when a verified Team variant description is required. `asc.py review apply --include-team-seats` reads the Team review notes and requires product-specific subscription review screenshots. If a second expired-subscription demo account is added to private App Review Notes in the UI, do so **after** the last copy helper run: this script replaces that Notes field with the tracked text when run again.

An uncertain PATCH result stops before the next resource; inspect the App Store Connect readback before retrying. A current genuine paywall capture and each additional Team review image are separate release requirements. See [the capture guide](../../docs/appstore/iap-review/README.md) and [metadata readiness](../../docs/appstore/submission-metadata-readiness-20261028.md).
