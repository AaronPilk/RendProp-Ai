# Public legal update — 7 October 2026

Delivered from tested source `fe0a59c`: one production tour-host deployment
selected Worker `d9232ced-c945-49f6-9ae0-30f958dbfe0d` at 100%. Eight actual
Cloudflare metadata/content GETs recorded the same sole version before and after
readback. The downloaded module is byte-identical to the reviewed bundle.
Four ordinary public GETs passed at 05:00:09 UTC.

Only the public Terms and Privacy runtime changed from the preceding `5eeb783`
Worker. Terms explain that an eligible Apple trial requires a funded offer,
usage can run out early without moving Apple's renewal date, and cancellation
or interruption does not reset the reservation. Privacy explains the retained
account-related eligibility/usage record and that it contains no media or
email-address text. This legal publication does not fund or activate an offer.

## Actual public checks

| Served response | Result |
|---|---|
| `/terms` | 200; authored document bytes match |
| `/privacy` | 200; authored document bytes match |
| Previously read public listing | 200; application script and leading cover identity unchanged; listing-inquiry action present |
| `/assets/site.js` | 200; actual JavaScript bytes match committed source |

The four responses totaled 178,326 bytes. No page scripts, video requests,
lead forms or beacons were executed. No retry, redirect or cache bypass was used.
The complete Terms/Privacy responses contain the same known Cloudflare platform
fragment as the retained baseline, with its opaque ray/time values allowed to
vary. Removing only that validated fragment produces the exact authored HTML;
whole-response byte equality is not claimed.

## Route identity reconciliation

The first actual readback failed its complete route-row comparison because both
Cloudflare route IDs were replaced. That failure is preserved. A separate offline
reconciliation verified the same exact two apex/www routes, Worker target and
fail-open setting, comparing every typed route field except the generated IDs.
Independent review confirmed the reconciliation and checksum-bound public-reader
gate before the four public GETs. No additional metadata requests or deployment
were needed to reconcile the difference.

The complete runtime configuration, bindings, asset headers, variables, secrets
and workers.dev state are unchanged; only the intended version tag/message
changed. The actual source binding covers all 91 staged committed files. Eight
preflight GETs preceded the one deployment, separate from the eight readback GETs.
Historical deployment-tool and verifier repairs are retained privately.

## Delivery boundaries

All twelve jobs in the actual
[CI run for `fe0a59c`](https://github.com/AaronPilk/RendProp-Ai/actions/runs/37565928915)
passed. The [reel-server rollout](AGENT-REEL-ROLLOUT-20261007.md) records its
separate one-function delivery. Documentation child `0842c9f` encountered a
secret-scan false positive on a retained receipt checksum. Commit `75e1dcd` adds
only that exact historical finding fingerprint; the same scanner still rejected
a credential-format negative control, and the actual hosted Secret scan passed.
No broad scanner exception or rewritten history was introduced.

Internal [TestFlight 46](TESTFLIGHT-46-AND-DORMANT-TRIAL-ROLLOUT-20261006.md)
remains the available native build; this server/legal update creates no new
archive. No price, SKU, provider route, financial schedule, trial pool, media
flag, R2 public-domain switch or public App Review submission was performed.

The [phone checklist](PHONE-ACCEPTANCE-TESTFLIGHT46-20261006.md),
[pricing decision sheet](PRICING-DECISIONS-20261007.md) and
[protected-media handoff](MEDIA-PRIVATE-DELIVERY-20261006.md) remain open gates.
Trials remain OFF and build-46 new ordinary purchases remain closed. The existing
public build 42 is not retroactively protected by build 46's purchase guard.
