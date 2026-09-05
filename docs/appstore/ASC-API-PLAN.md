# App Store Connect API plan

What `tools/asc/asc.py` does to App Store Connect, exactly which API resources it
touches, what the API provably cannot do, and the manual steps that remain — in
the order you should do them.

Everything below was verified against **Apple's own OpenAPI specification for the
App Store Connect API, version 4.4.1**, which is a public download:

<https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip>

That file is the authority for every attribute name and enum value quoted here.
Where a claim comes from prose documentation instead, the page is linked inline.
Anything that could not be verified is marked **UNVERIFIED** and says why.

---

## 1. Authentication

ES256 JWT, signed with the `.p8` key, sent as `Authorization: Bearer <token>`.

| Part | Value |
|---|---|
| Header | `{"alg": "ES256", "kid": <key id>, "typ": "JWT"}` |
| Payload | `{"iss": <issuer id>, "iat": <now>, "exp": <now+900>, "aud": "appstoreconnect-v1"}` |
| Lifetime | `exp - iat` must be **≤ 20 minutes** for these endpoints. `asc.py` uses 15. |

Source: [Generating Tokens for API Requests](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests).

`asc.py` signs by shelling out to `openssl dgst -sha256 -sign`, which returns a
DER `SEQUENCE { INTEGER r, INTEGER s }`. JWS needs raw `r||s` as two fixed 32-byte
big-endian integers (RFC 7518 §3.4), so the DER is parsed in
`der_to_raw_signature()`. The inverse exists too, and the test suite uses it to
have `openssl dgst -verify` confirm a signature `asc.py` produced.

**Rate limits.** Every response carries `X-Rate-Limit:
user-hour-lim:3500;user-hour-rem:500;` — a rolling hour, per API key. Exceeding it
gives HTTP **429** with code `RATE_LIMIT_EXCEEDED`.
Source: [Identifying Rate Limits](https://developer.apple.com/documentation/appstoreconnectapi/identifying-rate-limits).
Because every step in `asc.py` is idempotent, the recovery from a 429 is simply
to wait and re-run.

**Errors** come back as
`{"errors": [{id, status, code, title, detail, source, links, meta}]}`
(`ErrorResponse`). `asc.py` prints the code, title, detail and JSON pointer.

**Secrets.** The key lives only in `~/Rendprop AI/_bridge/.asc/`. It is never
copied into the repo, never printed, and never logged — the request log is
`METHOD /path -> status` and nothing else.

---

## 2. What the tool creates, resource by resource

### Subscriptions — `asc.py subscriptions apply`

| Step | Call | Key attributes |
|---|---|---|
| Find the app | `GET /v1/apps?filter[bundleId]=com.rendprop.app` | — |
| Notification URLs | `PATCH /v1/apps/{id}` | `subscriptionStatusUrl`, `subscriptionStatusUrlVersion: V2`, `subscriptionStatusUrlForSandbox`, `subscriptionStatusUrlVersionForSandbox: V2` |
| Group | `POST /v1/subscriptionGroups` | `referenceName: "rendprop_plans"`, relationship `app` |
| Group name | `POST /v1/subscriptionGroupLocalizations` | `name: "Rendprop Plans"`, `locale: "en-US"` |
| Products (×6) | `POST /v1/subscriptions` | `name`, `productId`, `familySharable: false`, `subscriptionPeriod`, `reviewNote`, `groupLevel` |
| Names/descriptions | `POST /v1/subscriptionLocalizations` | `name` (≤30), `description` (≤45), `locale` |
| **Availability** | `POST /v1/subscriptionAvailabilities` | `availableInNewTerritories: false`, `availableTerritories: [USA]` |
| Price lookup | `GET /v1/subscriptions/{id}/pricePoints?filter[territory]=USA&include=territory&limit=8000` | reads `customerPrice`, verifies the territory |
| Price | `POST /v1/subscriptionPrices` | **no attributes**; relationships `subscription` + `territory` (USA) + `subscriptionPricePoint` |
| Free trial | `POST /v1/subscriptionIntroductoryOffers` | `offerMode: FREE_TRIAL`, `duration: ONE_WEEK`, `numberOfPeriods: 1`, no `territory` relationship (= every territory it sells in) |

> **Order matters: availability must exist before pricing.** On the first live
> run the price POST failed with `ENTITY_ERROR.RELATIONSHIP.INVALID` pointed at
> the price point id. A follow-up probe proved the cause was ordering, not the
> request shape: the *identical* request succeeded once
> `POST /v1/subscriptionAvailabilities` had run. `GET
> /v1/subscriptions/{id}/subscriptionAvailability` returns **404** — not an empty
> object — before availability exists, which is what "not set" looks like.

### US-only launch

Both the app and the six subscriptions ship to the **United States only**, with
`availableInNewTerritories: false` so Apple does not add new storefronts
automatically. Widening later is a deliberate decision.

Two consequences:

* **One price is the whole schedule.** With USA-only availability there is
  nothing to equalize. If a product ever *is* available more widely, `asc.py`
  fills the gaps from `GET /v1/subscriptionPricePoints/{usaPointId}/equalizations`
  and posts one price per territory, so a product is never left half-priced.
* **An availability that is already too wide cannot be narrowed by the API.**
  `subscriptionAvailabilities` has POST and GET but **no PATCH and no DELETE**.
  `asc.py` re-POSTs in case that behaves as an upsert; if Apple refuses, it warns
  loudly with the exact UI path and carries on rather than aborting. Whether the
  re-POST works is **UNVERIFIED** — no live attempt has been made. The live probe
  created `com.rendprop.app.team.monthly` with all 175 territories, so **that one
  product will hit this path** on the next run: watch for `FIX THIS BY HAND`.

The app's own territories are set with `POST /v2/appAvailabilities`
(`availableInNewTerritories: false`, plus `territoryAvailabilities` as JSON:API
inline creates in the `included` array). This runs in `metadata apply`.

The six products, matching `docs/LAUNCH-CONTRACT.md`:

| productId | reference name | period | USD | groupLevel |
|---|---|---|---|---|
| `com.rendprop.app.team.monthly` | Team Monthly | `ONE_MONTH` | 249.00 | 1 |
| `com.rendprop.app.team.annual` | Team Yearly | `ONE_YEAR` | 2490.00 | 1 |
| `com.rendprop.app.pro.monthly` | Pro Monthly | `ONE_MONTH` | 99.00 | 2 |
| `com.rendprop.app.pro.annual` | Pro Yearly | `ONE_YEAR` | 990.00 | 2 |
| `com.rendprop.app.starter.monthly` | Starter Monthly | `ONE_MONTH` | 49.00 | 3 |
| `com.rendprop.app.starter.annual` | Starter Yearly | `ONE_YEAR` | 490.00 | 3 |

`groupLevel` 1 is the highest tier; Apple uses it to decide whether a switch
between two products is an upgrade, a downgrade or a crossgrade.

**Prices are never hardcoded into the app.** The app shows
`Product.displayPrice` from StoreKit. This tool only tells Apple which price
point to charge.

> **Creating the first price — learned the hard way.** The root cause was
> ordering (see above). Two other things were tightened at the same time. The
> request no longer carries `attributes: {preserveCurrentPrice: false}` — a
> product's *first* price has no current price to preserve and no subscribers to
> preserve it for, and Apple's own UI sends neither that nor a `startDate`. And
> the `territory` relationship is now stated explicitly, since the endpoint is
> titled "Schedule a subscription price change **for a specific territory**".
>
> Price point ids are base64url of `{"s": <subscription>, "t": <territory>,
> "p": <opaque tier id>}` — confirmed live: the USD 249.00 USA point on
> subscription 6808983164 is `{"s":"6808983164","t":"USA","p":"10605"}`, so `p`
> is Apple's internal tier, **not** the amount in minor units. `asc.py` reads
> only `t`, decoding the chosen id to refuse any point that is not a USA one.
> That guard matters because a wrong-territory point is numerically invisible:
> 249.00 MXN compares equal to 249.00 USD. (`customerPrice` also comes back as
> `"249.0"`, one decimal place, which `Decimal` comparison handles.)
>
> **Price point caveat.** `asc.py` asks Apple which USD price points that specific
> subscription offers, and matches the target exactly. If Apple does not offer the
> exact amount — most likely for the annual tiers, where the high price points are
> sparse — it picks the **nearest** and prints a large, unmissable warning naming
> both amounts. It never silently substitutes a different tier. If the substitute
> is wrong, fix it in Monetization → Subscriptions.

**Sandbox lag.** Apple's own note on the subscription endpoints: metadata changes
made through the API can take **up to 1 hour** to appear in the sandbox.

### Listing — `asc.py metadata apply`

| Step | Call | Fields |
|---|---|---|
| App info | `GET /v1/apps/{id}/appInfos` → pick the editable one | — |
| Name/subtitle/privacy | `POST`/`PATCH /v1/appInfoLocalizations` | `name`, `subtitle`, `privacyPolicyUrl`, `locale` |
| Categories | `PATCH /v1/appInfos/{id}` | relationships `primaryCategory` → `BUSINESS`, `secondaryCategory` → `PHOTO_AND_VIDEO` |
| Age rating | `PATCH /v1/ageRatingDeclarations/{id}` | every content field `NONE`, every boolean `false` → 4+ |
| Version | `POST /v1/appStoreVersions` | `platform: IOS`, `versionString: "1.0"`, `copyright`, `releaseType: MANUAL` |
| Listing copy | `POST`/`PATCH /v1/appStoreVersionLocalizations` | `description`, `keywords`, `promotionalText`, `whatsNew`, `supportUrl`, `marketingUrl` |

Category ids come from `GET /v1/appCategories?filter[platforms]=IOS&exists[parent]=false`.
There is no endpoint to create a category — the ids are Apple's fixed set, and
`BUSINESS` / `PHOTO_AND_VIDEO` are the literal resource ids.

`releaseType: MANUAL` means the version does **not** go live the moment Apple
approves it — you press "Release this version". Change it in `asc.py` if you want
`AFTER_APPROVAL`.

Enforced before anything is sent:

| Field | Limit |
|---|---|
| Name | 30 characters |
| Subtitle | 30 characters |
| Promotional text | 170 characters |
| Description | 4000 characters |
| Keywords | **100 bytes** — not characters |
| What's New | 4000 characters |
| Subscription display name | 30 characters |
| Subscription description | 45 characters |

Sources: [App Information](https://developer.apple.com/help/app-store-connect/reference/app-information/)
(name, subtitle) and [Platform Version Information](https://www.developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
(promotional text, description, keywords, What's New).

### Screenshots — `asc.py screenshots apply`

`POST /v1/appScreenshotSets` with `screenshotDisplayType: APP_IPHONE_67`, then for
each file `POST /v1/appScreenshots` (`fileName`, `fileSize`) → PUT the bytes to
each `uploadOperations` entry → `PATCH /v1/appScreenshots/{id}` with
`uploaded: true` and `sourceFileChecksum` (md5). Finally
`PATCH /v1/appScreenshotSets/{id}/relationships/appScreenshots` puts the set in
filename order.

> **The 6.9-inch display type is `APP_IPHONE_67`.** This was checked directly, because
> it is the kind of thing that is easy to get wrong. The `ScreenshotDisplayType`
> enum in spec v4.4.1 has **no `APP_IPHONE_69` member** — the largest iPhone value
> is `APP_IPHONE_67`. Apple's
> [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/)
> list **1320 × 2868** under "6.9-inch displays", and that is the size this tool
> requires and uploads into the `APP_IPHONE_67` set. The API constant simply kept
> its old name when the hardware grew.

Files already present with a matching md5 are left alone, so re-running uploads
nothing. Each PNG's dimensions are read from its IHDR header and checked before
upload; a wrong size stops the run rather than being rejected by Apple later.

Uploads go to a different host than the API and must **not** carry the bearer
token — `asc.py` sends only the `requestHeaders` Apple returns.

### Review — `asc.py review apply`

`POST`/`PATCH /v1/appStoreReviewDetails` with `contactFirstName`,
`contactLastName`, `contactPhone`, `contactEmail`, `demoAccountRequired: false`
and `notes` from `docs/appstore/review-notes.md`. Then the same
reserve→upload→commit dance on `/v1/subscriptionAppStoreReviewScreenshots` to
attach `docs/appstore/iap-review/paywall.png` to **each** of the six
subscriptions — App Review routinely rejects subscriptions that lack one.

Contact details come from `~/Rendprop AI/_bridge/.asc/review-contact.json`. If it
is absent, the command says so plainly and sets everything else.

---

## 3. What the API cannot do

Each row was checked against the v4.4.1 spec by listing the paths and methods
that exist, rather than assumed.

### Creating the app record — confirmed impossible

`/v1/apps` exposes **`get` only**. `/v1/apps/{id}` exposes `get` and `patch`.
There is no `POST /v1/apps` anywhere in the spec. The app record must be created
in the UI. `asc.py app` prints the exact form values.

### Paid Applications agreement, banking and tax — confirmed impossible

Searching every path for `agreement`, `contract`, `financ`, `tax`, `bank` and
`payment` returns only:

* `/v1/betaLicenseAgreements` — the TestFlight beta licence text
* `/v1/endUserLicenseAgreements` — your app's custom EULA
* `/v1/financeReports` — **reads** payout reports

Nothing accepts an agreement or writes banking or tax details. This is entirely
manual, and it is a **hard blocker**: paid subscriptions cannot go on sale until
the Paid Applications agreement is active.

### Privacy nutrition labels — confirmed impossible

The v4.4.1 spec contains **no path** matching `dataUsage`, `privacy` or
`nutrition`. There is no endpoint of any kind for the App Privacy questionnaire.
It must be filled in the UI. The answers Rendprop needs are already written up in
`docs/appstore/privacy-labels.md`.

### Creating sandbox testers — confirmed impossible

Only three sandbox paths exist:

* `GET /v2/sandboxTesters` — list
* `PATCH /v2/sandboxTesters/{id}` — edit an existing tester
* `POST /v2/sandboxTestersClearPurchaseHistoryRequest` — clear purchase history

There is no create endpoint. Testers must be added in the UI.

### App Store Server Notifications V2 URL — **possible**, and automated

This one was expected to be UI-only and turned out not to be.
`AppUpdateRequest.Data.Attributes` includes `subscriptionStatusUrl`,
`subscriptionStatusUrlVersion`, `subscriptionStatusUrlForSandbox` and
`subscriptionStatusUrlVersionForSandbox`, with
`SubscriptionStatusUrlVersion` being the enum `V1 | V2`. So
`PATCH /v1/apps/{id}` sets all four, and `asc.py subscriptions apply` does,
pointing both production and sandbox at:

```
https://ymgqpbnjpztwjsyvceld.supabase.co/functions/v1/apple-subscriptions/notify
```

Confirm it afterwards in App Information → App Store Server Notifications, or
with `asc.py app`, which prints both URLs and their versions.

### The app's own price (Free) — possible but deliberately not automated

`POST /v1/appPriceSchedules` exists, but it requires a `baseTerritory` and a list
of `appPrices` resources built from `appPricePoints`. It is one click in the UI
and getting it wrong affects what customers are charged, so `asc.py` leaves it
alone. Do it by hand.

### Submitting for review — possible, and exposed as an explicit command

There is **no `subscriptionAppStoreReviewSubmissions` resource** — that name does
not appear anywhere in the spec. The real resources are:

| Resource | What it submits |
|---|---|
| `POST /v1/subscriptionSubmissions` | one subscription (`subscription` relationship) |
| `POST /v1/subscriptionGroupSubmissions` | a whole subscription group |
| `POST /v1/reviewSubmissions` + `POST /v1/reviewSubmissionItems` | the app version, and optionally `subscriptionVersion` / `subscriptionGroupVersion` items |

`asc.py review submit` uses `subscriptionSubmissions`, one product at a time, so
it can report per-product status. It is **never** run by `review apply` or by the
bridge — submitting is the owner's call.

A subscription can only be submitted from state `READY_TO_SUBMIT`. The states are
`MISSING_METADATA`, `READY_TO_SUBMIT`, `WAITING_FOR_REVIEW`, `IN_REVIEW`,
`DEVELOPER_ACTION_NEEDED`, `PENDING_BINARY_APPROVAL`, `APPROVED`,
`DEVELOPER_REMOVED_FROM_SALE`, `REMOVED_FROM_SALE`, `REJECTED`.
`MISSING_METADATA` means something is still absent — usually the localization,
price, availability or App Review screenshot. `review submit` skips anything not
`READY_TO_SUBMIT`, says why, leaves already-submitted products alone, and exits
non-zero if anything was blocked. Submitting the app version itself is still a
human action in the UI.

---

## 4. Your remaining manual steps, in order

Steps 1, 3 and 6 are blockers — nothing downstream works until they are done.

### 1. Create the app record — **blocker**

`python3 tools/asc/asc.py app` prints these; type them in.

**App Store Connect → Apps → the blue + → New App**

| Field | Value |
|---|---|
| Platforms | **iOS** only |
| Name | `Rendprop` — if taken, `Rendprop: AI Property Tours` |
| Primary Language | English (U.S.) |
| Bundle ID | `com.rendprop.app` |
| SKU | `rendprop-ios` |
| User Access | Full Access |

If `com.rendprop.app` is not in the Bundle ID dropdown, register it first at
**Certificates, Identifiers & Profiles → Identifiers → +  → App IDs → App**,
explicit, description "Rendprop", bundle id `com.rendprop.app`. Team `5F5C5G25Y6`.

### 2. Run the bridge

```bash
bash tools/asc/bridge-610-asc-apply.sh
```

Subscriptions, listing, screenshots and review details all get set. Read the
output; it says exactly what it changed.

### 3. Paid Applications agreement, banking and tax — **blocker**

**App Store Connect → Business** (older accounts: **Agreements, Tax, and Banking**)

1. **Paid Applications** → Request → accept the terms.
2. Add a **Bank Account** — the legal entity's account.
3. Complete the **Tax Forms** for every region you sell in; the U.S. W-9 or W-8
   is the one that gates U.S. sales.

Status must read **Active**. Until then the subscriptions cannot be sold, and
sandbox purchases may fail with obscure errors.

### 4. App privacy (nutrition labels)

**Your app → App Privacy → Get Started**

Answer using `docs/appstore/privacy-labels.md`, which was written for exactly this
form. Then **Publish**. The version cannot be submitted until this is complete.

### 5. Pricing and availability

**Your app → Pricing and Availability**

* **Price Schedule** → **Free** (the app is free; revenue is the subscriptions).
  This one is still manual — see above.
* **Availability** → `metadata apply` sets this to **United States only**. Just
  confirm it looks right.
* If the run printed `FIX THIS BY HAND` for any subscription, go to
  **Monetization → Subscriptions → that product → Availability** and deselect
  everything except the United States. `com.rendprop.app.team.monthly` is the
  likely one, because a diagnostic probe gave it all 175 territories.

### 6. Upload a build — **blocker**

```bash
bash tools/asc/bridge-600-archive-upload.sh
```

Wait 5–30 minutes for processing, then **your app → the 1.0 version → Build →
the + → pick the build**. `asc.py status` shows the build list and whether one is
attached.

Answer the **export compliance** question when prompted. Rendprop uses only
standard HTTPS, which is the exempt case.

### 7. Sandbox testers (for testing purchases before release)

**Users and Access → Sandbox → Testers → +**

Use an email address that is **not** an existing Apple ID. Then on the test
iPhone: **Settings → Developer → Sandbox Apple Account**, and sign in there —
not in the main App Store settings.

### 8. Check the notification URL landed

**Your app → App Information → App Store Server Notifications**

Production and Sandbox should both be **Version 2** and both point at the
Supabase function above. `asc.py subscriptions apply` sets this; this is just the
confirmation.

### 9. Submit

Run `python3 tools/asc/asc.py status` first — it lists anything still missing,
and shows each product's state, territories, prices, trial and review screenshot.

Optionally send the subscriptions on their own:

```bash
python3 tools/asc/asc.py review submit          # or: review submit --dry-run
```

Then the app version itself: **your app → the 1.0 version → Add for Review →
Submit to App Review**. On a first release the six subscriptions are reviewed
together with the app, so confirm they appear in the submission.

---

## 5. Anything not verified

* **`xcodebuild` exportOptions keys.** The keys in `tools/asc/exportOptions.plist`
  (`method: app-store-connect`, `destination: upload`, `signingStyle`, `teamID`,
  `manageAppVersionAndBuildNumber`, `uploadSymbols`,
  `generateAppStoreInformation`, `stripSwiftSymbols`) come from Apple's
  distribution documentation and community references. The authoritative list is
  the "Available keys for -exportOptionsPlist" section of `xcodebuild -help`,
  which can only be read on a Mac. **UNVERIFIED against that output** — check it
  once on the first run if the export step complains about a key. The
  `-authenticationKeyPath` / `-authenticationKeyID` / `-authenticationKeyIssuerID`
  flags are likewise documented only in `xcodebuild -help`; the script falls back
  to `xcrun altool --upload-app --apiKey --apiIssuer` if they do not work.
* **Introductory offer territory scope.** The `territory` relationship on
  `SubscriptionIntroductoryOfferCreateRequest` is optional, and `asc.py` omits it
  to mean "every territory". Apple's prose does not state this explicitly, so it
  is inferred from the relationship being optional. **UNVERIFIED in prose** —
  after the first apply, check one product under Monetization → Subscriptions →
  Introductory Offer and confirm it reads all countries.
* **Age rating attribute set.** Taken from `AgeRatingDeclarationUpdateRequest` in
  spec v4.4.1. `asc.py` sets the stable content fields and skips the newer
  `ageRatingOverrideV2`, `ageAssurance`, `kidsAgeBand` and
  `developerAgeRatingInfoUrl`, which are not needed for a 4+ rating. If the PATCH
  is rejected, the tool prints the exact UI path instead of failing the run.
* **Live API behaviour.** Nothing here has been run against the real App Store
  Connect API — there are no credentials in the build environment. Request shapes
  were validated against Apple's OpenAPI spec and against a fake in-memory API in
  the test suite, but the first real run is the first real run. It is idempotent,
  so a mid-run failure is safe to retry.

---

## 6. Related documents

| File | What it holds |
|---|---|
| `tools/asc/README.md` | How to run the tool; troubleshooting |
| `docs/LAUNCH-CONTRACT.md` | Plans, product ids, prices — the source of truth |
| `docs/APP-STORE-CHECKLIST.md` | The wider release checklist |
| `docs/appstore/privacy-labels.md` | Answers for the App Privacy questionnaire |
| `docs/appstore/age-rating.md` | Answers for the age-rating questionnaire |
| `docs/appstore/review-notes.md` | Notes sent to App Review |
| `docs/appstore/metadata/en-US/` | The listing copy this tool uploads |
