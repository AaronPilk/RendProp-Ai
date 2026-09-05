# `tools/asc` — App Store Connect automation

Two things live here:

1. **`asc.py`** — creates Rendprop's six subscription products and fills in the
   App Store listing, using the App Store Connect REST API.
2. **`bridge-600-archive-upload.sh`** — archives the iOS app and uploads the
   build to TestFlight.

Everything runs on your Mac. Python 3.9+ and `openssl`, both of which macOS
already has. No `pip install`, no third-party libraries.

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

## The normal run

```bash
bash tools/asc/bridge-610-asc-apply.sh
```

That runs, in order, stopping at the first failure:

| # | Command | What it does |
|---|---|---|
| 1 | `asc.py app` | Finds the app record, or prints the New App form values. |
| 2 | `asc.py subscriptions apply` | Subscription group, six products, en-US names and descriptions, then per product **availability → price → 1-week free trial** in that order, plus the App Store Server Notification URLs. A product Apple has no price point for is left unpriced and reported. |
| 3 | `asc.py metadata apply` | App name, subtitle, categories, age rating, privacy policy URL, US-only app availability, then the version's description, keywords, promotional text, support and marketing URLs. "What's New" is skipped until the app has a released version. |
| 4 | `asc.py screenshots apply` | Uploads `docs/appstore/screenshots/6.9/*.png` in filename order. |
| 5 | `asc.py review apply` | App Review contact + notes, and the paywall screenshot on every subscription. |
| 6 | `asc.py status` | One page saying where everything stands and what is still missing. |

To see what *would* happen without changing anything:

```bash
bash tools/asc/bridge-610-asc-apply.sh --dry-run
```

**Every command is idempotent.** Each one reads the current state first and only
creates what is missing, so running the bridge twice is safe — the second run
prints "already correct, nothing to do". If a run dies halfway through (network,
rate limit, a typo in a metadata file), just fix the problem and run it again.

### Individual commands

```bash
python3 tools/asc/asc.py app
python3 tools/asc/asc.py subscriptions plan       # or: apply
python3 tools/asc/asc.py metadata plan            # or: apply
python3 tools/asc/asc.py screenshots apply
python3 tools/asc/asc.py review apply
python3 tools/asc/asc.py review submit            # send subscriptions to review
python3 tools/asc/asc.py status
python3 tools/asc/asc.py status --json            # machine-readable

python3 tools/asc/asc.py subscriptions unprice com.rendprop.app.team.annual
```

### Leaving one product out — `--skip-product`

`subscriptions apply`, `review apply` and `review submit` all take
`--skip-product <productId>`, repeatable. The named products are not created,
not priced, not localized, not given a review screenshot and not submitted —
they are left exactly as they are.

```bash
python3 tools/asc/asc.py subscriptions apply --skip-product com.rendprop.app.team.annual
python3 tools/asc/asc.py review submit      --skip-product com.rendprop.app.team.annual
```

This exists because `com.rendprop.app.team.annual` (USD 2490.00) has no price
point — see **Apple's price ceiling** below. Until Apple grants higher price
points, that product should be excluded from every step rather than shipped at
the wrong price. An unknown product id is an error, not a silent no-op.

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

`review submit` is deliberately separate: it is never run by `review apply` or by
the bridge, because deciding to submit is the owner's call. It submits only
products in state `READY_TO_SUBMIT`, skips anything still `MISSING_METADATA` with
an explanation, leaves already-submitted products alone, and exits non-zero if
anything was blocked.

`plan` is the same as `apply --dry-run`. Add `--quiet` to stop the HTTP request
log. Add `--key-dir <path>` to use a key somewhere other than the default. Add
`--debug` to print the exact JSON body of any request that fails — useful when
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
| `docs/appstore/metadata/en-US/release_notes.txt` | What's New (≤4000) — **unused until version 1.1**, see below |
| `docs/appstore/metadata/en-US/support_url.txt` | support URL |
| `docs/appstore/metadata/en-US/marketing_url.txt` | marketing URL (optional) |
| `docs/appstore/metadata/en-US/privacy_url.txt` | privacy policy URL (optional) |
| `docs/appstore/metadata/en-US/copyright.txt` | copyright line (optional) |
| `docs/appstore/screenshots/6.9/*.png` | screenshots, uploaded in filename order |
| `docs/appstore/iap-review/paywall.png` | the review screenshot on each subscription |
| `docs/appstore/review-notes.md` | App Review notes (≤4000) |

> **"What's New" is not written on a first release.** App Store Connect rejects
> `whatsNew` on an app's first version with 409 `STATE_ERROR`, "Attribute
> 'whatsNew' cannot be edited at this time" — there is no previous release to
> describe. `asc.py` checks whether any version has actually shipped and omits the
> field until one has; if Apple rejects it anyway, the request is retried once
> without it so the rest of the listing still lands. `release_notes.txt` stays in
> the repo and starts being used at version 1.1.

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

Apple offers **800 price points per currency**, and its USD points for a
**yearly** subscription stop at **USD 1000.00**. `com.rendprop.app.team.annual`
is meant to sell at USD 2490.00, so **no price point for it exists**.

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

Every app gets 800 price points by default. The Account Holder can request
**100 additional higher price points, up to USD 10,000**:

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
```

If the price already exists (it does, from the 2026-09-05 run):

```bash
python3 tools/asc/asc.py subscriptions unprice com.rendprop.app.team.annual
```

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

Processing takes 5–30 minutes after upload. Check with `asc.py status`.

> **Verify once on the Mac:** the `exportOptions.plist` keys were taken from
> Apple's distribution documentation, not from `xcodebuild -help`, which cannot
> be run from a Linux container. The first time you run the bridge, if the export
> step complains about a key, run `xcodebuild -help` and read the
> "Available keys for -exportOptionsPlist" section — that is the authoritative
> list. The `method` value is switched to the older `app-store` automatically on
> Xcode older than 15.3.

---

## What the API can and cannot do

Verified against Apple's own OpenAPI specification for the App Store Connect API
(v4.4.1), which you can download and grep yourself:
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
  the United States for this launch.
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

### It cannot — these stay manual

| Thing | Why | Where you do it |
|---|---|---|
| **Create the app record** | `/v1/apps` is GET-only; there is no POST. | Apps → **+** → New App (`asc.py app` prints the values) |
| **Paid Applications agreement, banking, tax** | Nothing in the API touches agreements or payment details; only `GET /v1/financeReports` exists, and that just reads payout reports. | Business → Agreements, Tax, and Banking |
| **Privacy nutrition labels** | The spec contains no data-usage or privacy-label endpoints at all. | App Privacy → Get Started (see `docs/appstore/privacy-labels.md`) |
| **Create sandbox testers** | `/v2/sandboxTesters` is GET-only. You can list, edit and clear purchase history, but not create. | Users and Access → Sandbox → Testers |
| **Set the app's price to Free** | Technically possible via `POST /v1/appPriceSchedules`, but it needs a base territory and per-territory `appPrices`, and it is one click in the UI. Not automated here on purpose. | Pricing and Availability → Price Schedule |
| **Narrow an existing subscription availability** | `subscriptionAvailabilities` has POST and GET but no PATCH or DELETE. The tool re-POSTs in case that upserts; if Apple refuses it prints `FIX THIS BY HAND` and carries on. | Monetization → Subscriptions → the product → Availability |
| **Submit the app version for review** | Deliberately not automated (subscriptions can be submitted with `review submit`). | The version page → Add for Review |
| **Write "What's New" on a first version** | `PATCH /v1/appStoreVersionLocalizations/{id}` returns 409 `STATE_ERROR`, "Attribute 'whatsNew' cannot be edited at this time". There is nothing to describe until there is a previous release. `asc.py` omits it until a version has actually shipped. | Nothing to do — `release_notes.txt` is used from version 1.1 onward |
| **Price above Apple's ceiling** | Yearly USD price points stop at USD 1000.00, so USD 2490.00 cannot be set at all. | Request higher points (link above), then re-run `subscriptions apply` |

The full list, with the remaining manual steps in order, is in
[`docs/appstore/ASC-API-PLAN.md`](../../docs/appstore/ASC-API-PLAN.md).

---

## Tests

```bash
python3 -m unittest discover -s tools/asc -t tools/asc -v
```

145 tests, no network, no credentials needed. Every live failure listed above is
reproduced by the fake API in `test_asc.py` and then proved fixed. They cover:

* **JWT** — header and payload exactly as Apple specifies, the 20-minute lifetime
  ceiling, and a real signature check: a throwaway P-256 key is generated with
  `openssl ecparam -genkey -name prime256v1`, `asc.py` signs a token with it, the
  raw `r||s` signature is converted back to DER, and `openssl dgst -verify`
  confirms it. A tampered payload is confirmed to fail.
* **DER parsing** — round-trips, sign padding, short and long form lengths,
  short integers, and malformed input.
* **Price points** — exact match, nearest-with-a-loud-warning, tie-breaking, and
  that all six Rendprop prices resolve exactly against a normal ladder.
* **The price guard** — against a ladder that stops at USD 1000.00 (Apple's real
  yearly ceiling) the 2490.00 product is **not** priced, the other five still
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
* **App availability** — the inline-create ids in `included` match the
  relationship references, no pre-order attribute is ever sent, and the live
  `ENTITY_ERROR.INCLUDED.INVALID_ID` is retried once with a distinct id before
  falling back to the UI path.
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

**HTTP 429** — the hourly rate limit. Wait and re-run; nothing is lost because
every step is idempotent. `asc.py` reports the `X-Rate-Limit` header it saw.

**A "PRICE POINT WARNING" block** — Apple did not offer the exact USD amount for
that product. If the nearest point is within **2 %** of the target it is used and
the warning is informational. Further away than that, the tool prints
`NOT PRICING <productId>` and **creates no price at all** — see below.

**A "NOT PRICING" / "UNPRICED" block** — see **Apple's price ceiling**.

**Subscription metadata not showing up in the sandbox** — Apple's own note:
product metadata changes can take up to an hour to reach the sandbox.
