# Native beta Profile proof

`run.py` compiles the current production personal-card, branding, selection, phone and export policies with the production models and closed Live/Mock transport slices. The positive run has 117 assertions. No network, camera, Photos picker, contact-store write or paid service is used. Temporary assets and account/workspace identities are synthetic.

```sh
python3 tools/audit/native-profile-beta-20261005/run.py --out /tmp/profile-positive
```

Fourteen altered-source controls are compiled separately and must fail their exact named assertion: `logo-late-context`, `logo-old-draft`, `portfolio-all-listings`, `share-late-context`, `share-unbound-workspace`, `personal-inviter-brand`, `personal-late-context`, `personal-old-draft`, `personal-broad-fields`, `personal-untouched-adoption`, `personal-erase-cache`, `logo-stale-brand-read`, `personal-erase-legacy`, and `logo-reload-stale-read`. Run each with `--fault NAME` and a separate `--out`. Controls deliberately alter compiled copies; they do not edit runtime sources.

The proof records hashes at capture and completion and rejects changed inputs. UI and UIKit preparation require the separate simulator proof:

```sh
python3 tools/audit/native-profile-beta-20261005/run-ui.py --out /tmp/profile-ui --simulator SIMULATOR_UUID --derived-data /tmp/profile-derived
```

This runs five actual Release SwiftUI cases: card-only OS share, explicit published-house selection, logo/phone behavior, stale client Save, accessibility-sized walkthrough, and explicit Profile Save above the phone keyboard plus account identity after a team switch (the first case covers both share flows). It requires every selected case to pass, with zero skips, and binds all runtime/UI/project/StoreKit-resource inputs at the end. The simulator host is reachable only with the exact UI-testing argument under `targetEnvironment(simulator)` and uses `MockAPIClient`.

Optional `--storekit` adds the real local StoreKitTest product/eligibility UI case. It fails closed when the local StoreKit daemon is unavailable and never uses the real App Store as a fallback. These proofs do not certify physical capture, actual storefront acceptance, hosted deployment, or delivery to a chosen share destination.
