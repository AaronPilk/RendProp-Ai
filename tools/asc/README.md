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
| 2 | `asc.py subscriptions apply` | Subscription group, six products, en-US names and descriptions, USD prices, all-territory availability, 1-week free trials, and the App Store Server Notification URLs. |
| 3 | `asc.py metadata apply` | App name, subtitle, categories, age rating, privacy policy URL, then the version's description, keywords, promotional text, release notes, support and marketing URLs. |
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
python3 tools/asc/asc.py status
python3 tools/asc/asc.py status --json            # machine-readable
```

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
| `docs/appstore/metadata/en-US/release_notes.txt` | What's New (≤4000) |
| `docs/appstore/metadata/en-US/support_url.txt` | support URL |
| `docs/appstore/metadata/en-US/marketing_url.txt` | marketing URL (optional) |
| `docs/appstore/metadata/en-US/privacy_url.txt` | privacy policy URL (optional) |
| `docs/appstore/metadata/en-US/copyright.txt` | copyright line (optional) |
| `docs/appstore/screenshots/6.9/*.png` | screenshots, uploaded in filename order |
| `docs/appstore/iap-review/paywall.png` | the review screenshot on each subscription |
| `docs/appstore/review-notes.md` | App Review notes (≤4000) |

Length limits are checked **before** anything is sent, and a file that is too
long stops the run with a message naming the file and the overage. Screenshots
are checked for the exact 1320×2868 size before upload.

The product ids, prices, tiers and trial are hard-coded in `asc.py` and match
`docs/LAUNCH-CONTRACT.md`. Changing a price means editing `SUBSCRIPTIONS` there.

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

* Create the subscription group, the six products, their localizations, prices,
  availability and introductory offers.
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
| **Press Submit for Review** | Deliberately not automated. | The version page → Add for Review |

The full list, with the remaining manual steps in order, is in
[`docs/appstore/ASC-API-PLAN.md`](../../docs/appstore/ASC-API-PLAN.md).

---

## Tests

```bash
python3 -m unittest discover -s tools/asc -t tools/asc -v
```

60 tests, no network, no credentials needed. They cover:

* **JWT** — header and payload exactly as Apple specifies, the 20-minute lifetime
  ceiling, and a real signature check: a throwaway P-256 key is generated with
  `openssl ecparam -genkey -name prime256v1`, `asc.py` signs a token with it, the
  raw `r||s` signature is converted back to DER, and `openssl dgst -verify`
  confirms it. A tampered payload is confirmed to fail.
* **DER parsing** — round-trips, sign padding, short and long form lengths,
  short integers, and malformed input.
* **Price points** — exact match, nearest-with-a-loud-warning, tie-breaking, and
  that all six Rendprop prices resolve exactly against a normal ladder.
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
that product and the nearest one was used. This is loud on purpose. Check it
against `docs/LAUNCH-CONTRACT.md`; the annual tiers are the likely ones to differ
because Apple's high annual points are sparse. Fix it by hand in **Monetization →
Subscriptions** if the substitute is wrong.

**Subscription metadata not showing up in the sandbox** — Apple's own note:
product metadata changes can take up to an hour to reach the sandbox.
