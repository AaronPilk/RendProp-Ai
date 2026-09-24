# `tools/asc` — App Store Connect automation

Owner-operated release tooling lives here:

1. **`asc.py`** — creates Rendprop's six subscription products and fills in the
   App Store listing, using the App Store Connect REST API.
2. **`bridge-600-archive-upload.sh`** — archives the iOS app and uploads the
   build to TestFlight.
3. **`bridge-610-asc-apply.sh`** — runs the launch listing/subscription/review
   preparation sequence. This changes store state; it is not a documentation check.

The scripts run on a Mac with Python 3.9+ and `openssl` installed; archives also
need Xcode and XcodeGen. The Python utility uses the standard library only.

## Release target caution

Reviewed against repository source on 24 September 2026. `asc.py` still declares
`VERSION_STRING = "1.0"` and has **no `--version` option**. It prefers an editable
1.0 version, then falls back to another editable version; if none exists its
creation path targets 1.0. `--build` selects a build, not an App Store version.
The native source currently declares 1.0.3 (31). Reconcile version selection and
the exact intended build before using any write command for a newer release.
Do not run the broad apply bridge as routine maintenance of an already shipped app.

The latest committed [phone delivery receipt](../../docs/handoff/CLAUDE-LIVE-DELIVERY-20260922.md)
records internal TestFlight 1.0.3 (31) on 22 September. The
[24 September Studio release](../../docs/handoff/CODEX-STUDIO-LIVE-20260924.md)
did not touch iOS or App Store Connect. This README refresh performed no store
reads, uploads, metadata changes or submissions. Historical API observations
below describe the launch run and do not establish current store state.

Offline inspection that does not load credentials or call Apple:

```bash
python3 tools/asc/asc.py --help
python3 tools/asc/asc.py review --help
python3 -m unittest discover -s tools/asc -t tools/asc -v
```

`plan`, `--dry-run`, `status` and `app` still make authenticated reads; they are
not offline commands. The archive bridge also reads its key configuration even
with `--no-upload`.

---

## Before the first run

### 1. Put the API key on the Mac (never in this repo)

Create an App Store Connect API key: **App Store Connect → Users and Access →
Integrations → App Store Connect API → the blue +**. Give it the **App Manager**
role. You can download the `.p8` file exactly once.

Then put it here, along with your Issuer ID:

```
~/Rendprop AI/_bridge/.asc/
    AuthKey_XXXXXXXXXX.p8      the file you downloaded, renamed by nobody
    config                     one line:  ISSUER_ID=<the uuid on that page>
```

The key id is read from the filename, so leave the filename alone. The Issuer ID
is the UUID shown near the top of the Integrations page.

Optional, for the App Review contact fields:

```
~/Rendprop AI/_bridge/.asc/review-contact.json
    {"first_name": "...", "last_name": "...", "phone": "...", "email": "..."}
```

If that file is absent, `asc.py review apply` says so and skips those fields.

> The key, the key id and the issuer id are never printed, never logged and never
> written into the repo. `asc.py` logs only `METHOD /path -> status`.

### 2. Create the app record by hand — once

The API **cannot** create app records. Run:

```bash
python3 tools/asc/asc.py app
```

If the app does not exist yet it prints the exact values to type into App Store
Connect's **New App** form, then exits non-zero. Fill the form, then run it again.

---

## Launch preparation sequence (owner-run)

```bash
bash tools/asc/bridge-610-asc-apply.sh
```

That runs, in order, stopping at the first failure:

| # | Command | What it does |
|---|---|---|
| 1 | `asc.py app` | Finds the app record, or prints the New App form values. |
| 2 | `asc.py subscriptions apply --skip-product com.rendprop.app.team.annual` | Subscription group, six products (Team Yearly skipped, see below), en-US names and descriptions, then per product **availability → price → 1-week free trial** in that order, plus the App Store Server Notification URLs. A product Apple has no price point for is left unpriced and reported. |
| 3 | `asc.py metadata apply` | App name, subtitle, categories, age rating, privacy policy URL, content rights (no third-party content), the app's own price (Free, base territory USA), US-only app availability, then the version's description, keywords, promotional text, support and marketing URLs. "What's New" is skipped until the app has a released version. |
| 4 | `asc.py screenshots apply [--dir …] [--replace]` | Uploads the 6.9-inch set in filename order — `docs/appstore/screenshots/6.9-framed/*.png` (the composed set) when that directory has PNGs, else the raw `docs/appstore/screenshots/6.9/*.png`. `bash tools/asc/bridge-610-asc-apply.sh --replace-screenshots` passes `--replace`, which deletes every screenshot already in the set first — needed once after a re-frame, because a set holds at most 10 and the old images are still in it. |
| 5 | `asc.py review apply --skip-product com.rendprop.app.team.annual` | App Review contact + notes, and the paywall screenshot on every subscription that is sold. |
| 5b | `asc.py review stage --skip-product com.rendprop.app.team.annual` | Apple's "Add for Review" by API: one draft review submission with the selected editable version, the subscription group and the five sold subscriptions as items. Nothing is submitted. Needs App Privacy published and every subscription priced in all territories (which `subscriptions apply` now does). |
| 6 | `asc.py status --skip-product com.rendprop.app.team.annual` | One page saying where everything stands and what is still missing. Team Yearly is deliberately withdrawn (see below), so it is shown but not counted. |

`build attach` is not in the bridge: a build only exists after
`bridge-600-archive-upload.sh` has run and Apple has finished processing it.

To see what *would* happen without changing anything:

```bash
bash tools/asc/bridge-610-asc-apply.sh --dry-run
```

Most reconciliation steps read existing state and avoid duplicate records.
That is not permission to rerun the whole bridge blindly: `--replace` deletes
the selected screenshot set, metadata can alter territories/prices, and review
commands can change submission state. Inspect the plan and current release
target before resuming a partial run.

### Individual commands

```bash
python3 tools/asc/asc.py app
python3 tools/asc/asc.py subscriptions plan       # or: apply
python3 tools/asc/asc.py metadata plan            # or: apply
python3 tools/asc/asc.py screenshots apply
python3 tools/asc/asc.py screenshots apply --dir docs/appstore/screenshots/6.9-framed --replace
                                                  # the composed set; --replace rebuilds the set
python3 tools/asc/asc.py review apply
python3 tools/asc/asc.py review stage             # prepare the draft; does not submit
python3 tools/asc/asc.py review submit            # legacy per-product subscription submission
python3 tools/asc/asc.py review send --build 31 --dry-run  # inspect the draft submission only
python3 tools/asc/asc.py build attach             # newest VALID build -> selected editable version
python3 tools/asc/asc.py build attach --build 2   # a specific build number (or version)
python3 tools/asc/asc.py status
python3 tools/asc/asc.py status --skip-product com.rendprop.app.team.annual
python3 tools/asc/asc.py --json status            # machine-readable

python3 tools/asc/asc.py subscriptions unprice com.rendprop.app.team.annual
```

### Leaving one product out — `--skip-product`

`subscriptions apply`, `review apply`, `review submit` and `status` all take
`--skip-product <productId>`, repeatable. For the writing commands the named
products are not created, not priced, not localized, not given a review
screenshot and not submitted — they are left exactly as they are.

```bash
python3 tools/asc/asc.py subscriptions apply --skip-product com.rendprop.app.team.annual
python3 tools/asc/asc.py review submit      --skip-product com.rendprop.app.team.annual
python3 tools/asc/asc.py status             --skip-product com.rendprop.app.team.annual
```

For `status` a skipped product means "deliberately not sold at launch": its row
is still printed, with a trailing `WITHDRAWN (not sold at launch)` instead of
`!!`, but nothing about it goes into **WHAT IS MISSING** and it does not trigger
the `WRONG PRICE` banner. If it is mispriced, one calm `note:` line says it is
withdrawn and where to request higher price points. The exception is a skipped
product that is actually **on sale** in one or more territories: then the banner
stays and `<productId> is skipped but ON SALE in <territories> at USD <amount>`
is listed as missing — a withdrawn product that is on sale at the wrong price is
exactly what the banner exists for.

This exclusion comes from the 5 September price-point mismatch for
`com.rendprop.app.team.annual` (USD 2490.00) — see the historical price finding below. Until Apple grants higher price
points, that product should be excluded from every step rather than shipped at
the wrong price. An unknown product id is an error, not a silent no-op.

### `build attach`

Links a build to the version selected by the legacy lookup described above,
which is otherwise a click in App Store Connect. It lists the app's builds (newest first) and picks the newest one
whose `processingState` is `VALID`, or the one named with `--build` (a build
number such as `2`, or a version such as `1.0`). It refuses, with exit 1, if
the newest build is still `PROCESSING` — wait for Apple to finish processing
and try again in a few minutes — or if no build is `VALID`.

Then, in order:

1. If the build's `usesNonExemptEncryption` is still unanswered (`null`),
   `PATCH /v1/builds/{id}` sets it to `false`. `Info.plist` declares
   `ITSAppUsesNonExemptEncryption=false`: the app uses standard HTTPS only, which
   is exempt from export compliance. A build that already has an answer is left
   alone.
2. `PATCH /v1/appStoreVersions/{id}/relationships/build` with
   `{"data": {"type": "builds", "id": "<build id>"}}` — a to-one linkage, so
   `data` is one object, not a list.

If the version already has that build attached it prints
`= build N already attached` and does nothing. `--dry-run` shows the plan.

### `subscriptions unprice <productId>`

Gets a wrongly priced product off sale. It tries, in order:

1. `DELETE /v1/subscriptionPrices/{id}` for every price the product has. This is
   the only method Apple's spec gives that resource apart from the POST that
   creates one.
2. If Apple refuses, `POST /v1/subscriptionAvailabilities` with
   `availableInNewTerritories: false` and an **empty** `availableTerritories`
   list. `SubscriptionAvailabilityCreateRequest` puts no `minItems` on that
   array, so an empty one is legal, and a subscription available in no territory
   cannot be sold.
3. If that fails too, it prints the exact App Store Connect path and exits
   non-zero.

It exits non-zero whenever a human still has something to do.

`review submit` is the separate legacy per-product subscription submission;
it is never run by `review apply` or the bridge. `review send` submits the
staged draft review (including the app version) and requires `--yes` to write.
It can also require a specific attached build with `--build`. Neither submission
command belongs in a routine metadata refresh. The legacy `review submit`
path submits only products in state `READY_TO_SUBMIT`, skips anything still `MISSING_METADATA` with
an explanation, leaves already-submitted products alone, and exits non-zero if
anything was blocked.

`plan` is the same as `apply --dry-run`. Put global options **before the subcommand**: `--quiet` stops the HTTP request
log; `--key-dir <path>` selects a different key directory; `--debug` prints the exact JSON body of any request that fails — useful when
App Store Connect returns one of its vaguer validation errors. `--debug` prints
the JSON:API document only; headers, and therefore the bearer token, are never
included.

Exit codes: `0` success, `1` failure (or, for `status`, "something is still
missing"), `2` bad arguments.

---

## What it reads from the repo

| Path | Used by |
|---|---|
| `docs/appstore/metadata/en-US/name.txt` | app name (≤30 characters) |
| `docs/appstore/metadata/en-US/subtitle.txt` | subtitle (≤30) |
| `docs/appstore/metadata/en-US/description.txt` | description (≤4000) |
| `docs/appstore/metadata/en-US/keywords.txt` | keywords (**≤100 bytes**, not characters) |
| `docs/appstore/metadata/en-US/promotional_text.txt` | promotional text (≤170) |
| `docs/appstore/metadata/en-US/release_notes.txt` | What's New (≤4000) — **omitted until a prior release exists**, see below |
| `docs/appstore/metadata/en-US/support_url.txt` | support URL |
| `docs/appstore/metadata/en-US/marketing_url.txt` | marketing URL (optional) |
| `docs/appstore/metadata/en-US/privacy_url.txt` | privacy policy URL (optional) |
| `docs/appstore/metadata/en-US/copyright.txt` | copyright line (optional) |
| `docs/appstore/screenshots/6.9-framed/*.png` | the composed screenshots (`tools/screenshots/compose.py` from `docs/appstore/screenshots/plan.json`), uploaded in filename order; `--dir` picks another directory, `docs/appstore/screenshots/6.9/` is the raw fallback |
| `docs/appstore/iap-review/paywall.png` | the review screenshot on each subscription |
| `docs/appstore/metadata/en-US/review_notes.txt` | Uploaded App Review notes (≤4000); skipped if absent. The separate Markdown review guide is not read by this script. |

> **"What's New" is not written on a first release.** App Store Connect rejects
> `whatsNew` on an app's first version with 409 `STATE_ERROR`, "Attribute
> 'whatsNew' cannot be edited at this time" — there is no previous release to
> describe. `asc.py` checks whether any version has actually shipped and omits the
> field until one has; if Apple rejects it anyway, the request is retried once
> without it so the rest of the listing still lands. `release_notes.txt` stays in
> the repo and is used when a prior released version exists, rather than at a hard-coded 1.1 threshold.

Length limits are checked **before** anything is sent, and a file that is too
long stops the run with a message naming the file and the overage. Screenshots
are checked for the exact 1320×2868 size before upload.

The product ids, prices, tiers and trial are hard-coded in `asc.py` and match
`docs/LAUNCH-CONTRACT.md`. Changing a price means editing `SUBSCRIPTIONS` there.

The Support URL is read from `support_url.txt` and must be
`https://rendprop.com/support`, not the bare domain — App Review opens it and
expects a support page. `asc.py` refuses to run with the bare domain in that file.

---

## Apple's price ceiling — read this before pricing an annual tier

The 5 September 2026 account-specific launch run returned a yearly USD price
ladder ending at **$1,000**, below the configured **$2,490** Team Yearly target.
That historical observation is why the repository still excludes
`com.rendprop.app.team.annual`; it is not a fresh statement about every Apple
account's available price points.

On the live run of 2026-09-05 the tool picked the nearest point — USD 1000.00 —
and created it. That product became genuinely sellable at 40 % of its intended
price. It will not happen again:

* If the nearest point is more than **2 %** (`PRICE_TOLERANCE`) from the target,
  **no price is created**. The run prints `NOT PRICING <productId>`, lists the
  product under `UNPRICED` in the summary, and carries on with everything else.
  An unpriced subscription cannot be sold; a wrongly priced one can.
* `asc.py status` prints **each product's actual price amount** and flags any
  that does not match `docs/LAUNCH-CONTRACT.md` with a `WRONG PRICE` block, and
  exits non-zero.
* `subscriptions unprice <productId>` takes a wrongly priced product off sale.

### Requesting higher price points

The owner can inspect Apple's current higher-price-point request process:

<https://developer.apple.com/contact/request/app-store-higher-price-points/>

That link is the one Apple gives on
[Set a price](https://developer.apple.com/help/app-store-connect/manage-app-pricing/set-a-price/).
Once granted, the higher points appear in App Store Connect under
**your app → Monetization → Pricing and Availability → Price Schedule → Add
Pricing**, where you scroll to the end of the price menu and click
**See Additional Prices**. They also start coming back from
`GET /v1/subscriptions/{id}/pricePoints`, so after the request is granted:

```bash
python3 tools/asc/asc.py subscriptions apply     # prices team.annual at 2490.00
```

Until then, keep that product out of every step:

```bash
python3 tools/asc/asc.py subscriptions apply --skip-product com.rendprop.app.team.annual
python3 tools/asc/asc.py review apply           --skip-product com.rendprop.app.team.annual
python3 tools/asc/asc.py review submit          --skip-product com.rendprop.app.team.annual
python3 tools/asc/asc.py status                 --skip-product com.rendprop.app.team.annual
```

For the historical mispricing cleanup, the command was:

```bash
python3 tools/asc/asc.py subscriptions unprice com.rendprop.app.team.annual
```

On the live run the price could not be deleted (`DELETE /v1/subscriptionPrices/…`
returned 409 `STATE_ERROR`), so `unprice` withdrew the product from every
territory instead (`POST /v1/subscriptionAvailabilities` with an empty list,
201). The product still carries the USD 1000.00 price but is available nowhere,
so that launch run recorded it as unavailable for sale. A new authenticated
read is required to establish whether that remains the current store state.

---

## Uploading a build

```bash
bash tools/asc/bridge-600-archive-upload.sh
```

It runs `xcodegen generate`, then `xcodebuild archive` (Release,
`generic/platform=iOS`), then `xcodebuild -exportArchive` with
`destination: upload`, which sends the build straight to App Store Connect using
the same API key. It prints `BUILD_EXIT`, `EXPORT_EXIT` and the last 20 relevant
log lines, and it never echoes the key id or issuer id.

If `destination: upload` fails it automatically falls back to exporting an `.ipa`
and uploading it with `xcrun altool --upload-app --apiKey --apiIssuer`, copying
the key into `~/.appstoreconnect/private_keys/` (mode 600) where `altool` looks
for it.

`--no-upload` archives without uploading.

Upload completion does not prove processing or tester-group availability. The
bridge prints an estimated 5–30-minute processing window. For an owner-run
release, verify the processed build and intended version before attachment:

```bash
python3 tools/asc/asc.py build attach
```

> **Verify once on the Mac:** the `exportOptions.plist` keys were taken from
> Apple's distribution documentation, not from `xcodebuild -help`, which cannot
> be run from a Linux container. The first time you run the bridge, if the export
> step complains about a key, run `xcodebuild -help` and read the
> "Available keys for -exportOptionsPlist" section — that is the authoritative
> list. The `method` value is switched to the older `app-store` automatically on
> Xcode older than 15.3.

---

## What the API can and cannot do

The launch implementation was checked against Apple's App Store Connect
OpenAPI v4.4.1. The list below describes this tool and recorded launch
observations; it is not an exhaustive current API capability matrix. Apple's specification is available at:
<https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip>

### It can

* Create the subscription group, the six products, their localizations,
  availability, prices and introductory offers — **in that order**:
  **availability → price → introductory offer, per territory.** App Store
  Connect rejects a price for a product that has no availability yet, with a
  `RELATIONSHIP.INVALID` error that blames the price point rather than the
  missing availability; and it rejects an introductory offer with no `territory`
  relationship (`RELATIONSHIP.REQUIRED`), so one offer is created per territory
  the product actually sells in.
* Restrict both the app (`POST /v2/appAvailabilities`) and the subscriptions to
  the United States for this launch. The app request is a JSON:API inline
  create: the `included` territoryAvailabilities are linked to the relationship
  references by a `${...}` placeholder id (`${territoryAvailability-USA}`),
  Apple's convention for inline creates
  (<https://developer.apple.com/forums/thread/714696>), and carries one row for
  every territory Apple sells in (175, from `GET /v1/territories`) with
  `available` true for the USA only — Apple refuses a body that lists only the
  wanted territory (one `RELATIONSHIP.INVALID` per territory left out). Both
  rules were proven live on 2026-09-05.
* Read the categories back correctly: `GET /v1/apps/{id}/appInfos` is asked
  with `include=primaryCategory,secondaryCategory`, because without it Apple
  returns the category relationships as `links` only and set categories look
  unset.
* Attach a build to the version (`PATCH /v1/appStoreVersions/{id}/relationships/build`)
  and answer the export-compliance question on it (`PATCH /v1/builds/{id}`,
  `usesNonExemptEncryption: false`) — `build attach`.
* Remove a subscription price (`DELETE /v1/subscriptionPrices/{id}`), which is
  what `subscriptions unprice` uses.
* Submit subscriptions for review via `POST /v1/subscriptionSubmissions` — but
  only through the explicit `review submit` command.
* Set the **App Store Server Notifications V2 URLs** — both production and
  sandbox. This one is worth calling out because it is widely believed to be
  UI-only: `PATCH /v1/apps/{id}` accepts `subscriptionStatusUrl`,
  `subscriptionStatusUrlVersion`, `subscriptionStatusUrlForSandbox` and
  `subscriptionStatusUrlVersionForSandbox`. `subscriptions apply` sets all four.
* Create the 1.0 version, write every listing field, set categories and the age
  rating, upload screenshots, and set App Review details.

### Manual responsibilities and tool limits

| Thing | Why | Where you do it |
|---|---|---|
| **Create the app record** | `/v1/apps` is GET-only; there is no POST. | Apps → **+** → New App (`asc.py app` prints the values) |
| **Paid Applications agreement, banking, tax** | Nothing in the API touches agreements or payment details; only `GET /v1/financeReports` exists, and that just reads payout reports. | Business → Agreements, Tax, and Banking |
| **Privacy nutrition labels** | The spec contains no data-usage or privacy-label endpoints at all. | App Privacy → Get Started (see `docs/appstore/privacy-labels.md`) |
| **Create sandbox testers** | `/v2/sandboxTesters` is GET-only. You can list, edit and clear purchase history, but not create. | Users and Access → Sandbox → Testers |
| **Inspect a price change before applying it** | `metadata apply` now calls `ensure_app_price_free()` and can create a free app price schedule. This is automated, so do not treat metadata apply as text-only. | Read the metadata plan before any owner-run apply. |
| **Narrow an existing subscription availability** | `subscriptionAvailabilities` has POST and GET but no PATCH or DELETE. The tool re-POSTs in case that upserts; if Apple refuses it prints `FIX THIS BY HAND` and carries on. | Monetization → Subscriptions → the product → Availability |
| **Automatically decide to submit the app** | `review stage` prepares a draft; `review send --yes` can submit it. Neither should be run without an explicit owner release decision. | Reconcile the draft, target version and attached build before submission. |
| **Write "What's New" on a first version** | `PATCH /v1/appStoreVersionLocalizations/{id}` returns 409 `STATE_ERROR`, "Attribute 'whatsNew' cannot be edited at this time". There is nothing to describe until there is a previous release. `asc.py` omits it until a version has actually shipped. | Nothing to do — `release_notes.txt` is used after a prior version has shipped |
| **Invent an unavailable price point** | The historical account ladder did not include the Team Yearly target; the tool refuses substitutes more than 2% away. | Verify account-specific available points before changing the excluded-product list. |

The full list, with the remaining manual steps in order, is in
[`docs/appstore/ASC-API-PLAN.md`](../../docs/appstore/ASC-API-PLAN.md).

---

## Tests

```bash
python3 -m unittest discover -s tools/asc -t tools/asc -v
```

The documentation refresh ran **208 tests successfully** on 24 September 2026,
with no network or credentials. `test_asc.py` uses fake API state and temporary
keys; it verifies local tooling behavior, not live App Store configuration. They cover:

* **JWT** — header and payload exactly as Apple specifies, the 20-minute lifetime
  ceiling, and a real signature check: a throwaway P-256 key is generated with
  `openssl ecparam -genkey -name prime256v1`, `asc.py` signs a token with it, the
  raw `r||s` signature is converted back to DER, and `openssl dgst -verify`
  confirms it. A tampered payload is confirmed to fail.
* **DER parsing** — round-trips, sign padding, short and long form lengths,
  short integers, and malformed input.
* **Price points** — exact match, nearest-with-a-loud-warning, tie-breaking, and
  that all six Rendprop prices resolve exactly against a normal ladder.
* **The price guard** — against a ladder that stops at USD 1000.00 (the
  historical account fixture) the 2490.00 product is **not** priced, the other five still
  are, the run still succeeds, and the refusal names both amounts. A substitute
  inside the 2 % tolerance is still used.
* **`unprice`** — the DELETE path, the empty-`availableTerritories` fallback when
  Apple refuses the DELETE, and the UI path when neither works.
* **`--skip-product`** — the product is not created, not submitted, and an
  unknown id is an error.
* **`status` prices** — every amount is printed, a product priced USD 1000.00
  against a USD 2490.00 target produces a `WRONG PRICE` block and a non-zero exit,
  and the JSON report carries the amount and the verdict.
* **What's New** — an app with only a first version never sends `whatsNew`; a
  released version means it does; Apple's 409 `STATE_ERROR` is retried once
  without it and every other listing field still lands; any other error still
  raises.
* **Age rating** — only the attributes App Store Connect returns are PATCHed;
  an `ENTITY_ERROR.ATTRIBUTE.REQUIRED` has its pointer and detail printed
  verbatim and the named attributes answered on the retry; an attribute with no
  known "nothing applies" value is never guessed; and every attribute of Apple's
  `AgeRatingDeclarationUpdateRequest` is accounted for.
* **App availability** — the `${territoryAvailability-USA}` placeholder appears
  identically as the relationship reference and as the `included` id, no
  pre-order attribute is ever sent, the documented form lands against a fake
  that refuses both shapes the live run tried, and an `INCLUDED.INVALID_ID` on
  the placeholder is retried once with the bare territory id before falling
  back to the UI path.
* **Categories** — the appInfos request carries
  `include=primaryCategory,secondaryCategory`; against a fake that returns
  `links`-only relationships without it (the live shape), set categories are a
  no-op note, unset ones are still PATCHed, and `status` reports them as set.
* **`status --skip-product`** — a withdrawn, mispriced product prints its row
  with `WITHDRAWN (not sold at launch)`, one `note:` line and no `WRONG PRICE`
  banner, and adds nothing to the missing list; the same product still on sale
  keeps the banner and is listed as `skipped but ON SALE`. Without the flag
  nothing changes. The bridge passes the flag.
* **`build attach`** — picks the newest `VALID` build, passes over newer
  failed ones with a warning, refuses a newest build that is still `PROCESSING`
  (and writes nothing), refuses when nothing is `VALID`, is a no-op once
  attached, sets `usesNonExemptEncryption` only when it is unanswered, and sends
  the exact `BuildUpdateRequest` and `AppStoreVersionBuildLinkageRequest`
  bodies. `--build` picks by build number or version; `--dry-run` writes nothing.
* **Plan idempotency** — a fake in-memory App Store Connect is injected as the
  transport. The first `apply` creates 6 products with prices, localizations,
  availability and trials; the second makes **zero writes**. Partial state is
  completed rather than duplicated, wrong attributes are corrected, and a 409
  duplicate-product-id is recovered from.
* **Length validators** — every Apple limit, including that keywords are counted
  in *bytes* so 51 accented characters are rejected at 102 bytes.
* **Secret hygiene** — asserts no private key material and no hard-coded UUID
  appears in `asc.py`, and that the bearer token is sent but never logged.

---

## Troubleshooting

**"App Store Connect key directory not found"** — the `.p8` and `config` are not
in `~/Rendprop AI/_bridge/.asc`. See "Before the first run".

**HTTP 401 `NOT_AUTHORIZED`** — the key was revoked, the Issuer ID is wrong, or
the Mac's clock is off (the JWT carries `iat`/`exp`, so a badly wrong clock
invalidates every token).

**HTTP 403** — the API key's role is too low. It needs **App Manager**.

**HTTP 429** — Apple rate-limited the request. Inspect the reported limit and
current state before retrying the affected command. Reconciliation avoids many
duplicate writes, but destructive screenshot replacement and uncertain submissions
need separate review. `asc.py` reports the `X-Rate-Limit` header it saw.

**A "PRICE POINT WARNING" block** — Apple did not offer the exact USD amount for
that product. If the nearest point is within **2 %** of the target it is used and
the warning is informational. Further away than that, the tool prints
`NOT PRICING <productId>` and **creates no price at all** — see below.

**A "NOT PRICING" / "UNPRICED" block** — see **Apple's price ceiling**.

**Subscription metadata not showing up in the sandbox** — Apple's own note:
product metadata changes can take up to an hour to reach the sandbox.
