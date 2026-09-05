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
| Free trial | `POST /v1/subscriptionIntroductoryOffers` | `offerMode: FREE_TRIAL`, `duration: ONE_WEEK`, `numberOfPeriods: 1`, **`territory` relationship required** — one offer per territory |
| Un-price | `DELETE /v1/subscriptionPrices/{id}` | `subscriptions unprice` only. 204 on success |

> ### Order matters: availability → price → introductory offer, per territory
>
> This is the single most important thing learned from the live runs, and all
> three steps are per-territory.
>
> 1. **Availability first.** The price POST failed with
>    `ENTITY_ERROR.RELATIONSHIP.INVALID` pointed at the price point id. A
>    follow-up probe proved the cause was ordering, not the request shape: the
>    *identical* request succeeded once `POST /v1/subscriptionAvailabilities` had
>    run. `GET /v1/subscriptions/{id}/subscriptionAvailability` returns **404** —
>    not an empty object — before availability exists, which is what "not set"
>    looks like.
> 2. **Then the price**, for each territory the product is actually available in
>    (`asc.py` reads that back rather than assuming the launch list).
> 3. **Then the introductory offer, with an explicit `territory`.** Live
>    2026-09-05: without it, `ENTITY_ERROR.RELATIONSHIP.REQUIRED` — "You must
>    provide a value for the relationship 'territory'". The relationship is
>    *optional in the spec* and required in practice, so `asc.py` creates one
>    offer per territory the product sells in and skips territories that already
>    have one.

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
  `subscriptionAvailabilities` has POST and GET but **no PATCH and no DELETE**
  (and the POST is marked `deprecated` in spec v4.4.1, while remaining the only
  write there is). `asc.py` re-POSTs in case that behaves as an upsert; if Apple
  refuses, it warns loudly with the exact UI path and carries on rather than
  aborting. Whether the re-POST works is still **UNVERIFIED** — as of the
  2026-09-05 runs all six products read back as USA-only, so the path has not had
  to fire. The same re-POST, with an **empty** territory list, is what
  `subscriptions unprice` falls back on to take a product off sale.

The app's own territories are set with `POST /v2/appAvailabilities`, in
`metadata apply`. The request body is the fiddliest one this tool sends, so it is
worth spelling out. Per `AppAvailabilityV2CreateRequest` in spec v4.4.1:

```jsonc
{
  "data": {
    "type": "appAvailabilities",
    "attributes": { "availableInNewTerritories": false },
    "relationships": {
      "app": { "data": { "type": "apps", "id": "<app id>" } },
      "territoryAvailabilities": {
        "data": [ { "type": "territoryAvailabilities", "id": "USA" } ]   // <- id REQUIRED
      }
    }
  },
  "included": [                                     // TerritoryAvailabilityInlineCreate
    {
      "type": "territoryAvailabilities",            // only `type` is required
      "id": "USA",                                  // client-supplied temporary handle
      "attributes": { "available": true },
      "relationships": { "territory": { "data": { "type": "territories", "id": "USA" } } }
    }
  ]
}
```

The two halves are linked by an id the **client** invents:
`relationships.territoryAvailabilities.data[]` requires both `id` and `type`,
while `included[]` (`TerritoryAvailabilityInlineCreate`) requires only `type` —
so the id there exists purely to be matched. The spec ships **no example** for
this request, and the live attempt returned
**409 `ENTITY_ERROR.INCLUDED.INVALID_ID`**, which is exactly the id-matching
failing. `asc.py` therefore sends the territory id as the handle, and if Apple
returns `INCLUDED.INVALID_ID` retries once with `territoryAvailability-<t>`,
which cannot be confused with an existing resource id. If both fail it warns with
the UI path and carries on — a territory list is one click in the UI.

> Apple titles this endpoint **"Create an app pre-order"**, which is alarming
> until you read the schema: `releaseDate` and `preOrderEnabled` are *optional*
> attributes of `TerritoryAvailabilityInlineCreate` and `asc.py` sends neither.
> Only `available: true` is sent, so this sets territories and nothing else. A
> test asserts that no other attribute is ever included.

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
> **Price point caveat — and the guard that now enforces it.** `asc.py` asks
> Apple which USD price points that specific subscription offers and matches the
> target exactly. If Apple does not offer the exact amount it takes the nearest
> **only if that is within `PRICE_TOLERANCE` (2 %)**, with a loud warning naming
> both amounts. Further away than that, **no price is created at all**.
>
> This guard exists because of a real loss. On the live run of 2026-09-05 there
> was no guard: Apple's USD points for a *yearly* subscription stop at
> **USD 1000.00**, so `com.rendprop.app.team.annual` (target USD 2490.00) was
> priced at USD 1000.00 and the POST returned **201**. The product became
> genuinely sellable at 40 % of its intended price. An unpriced subscription
> cannot be sold; a wrongly priced one can, so refusing is the safe outcome.
>
> Consequences, all automated:
>
> * Refused products are listed under `UNPRICED` in the run summary.
> * `asc.py status` prints **every product's actual amount** and raises a
>   `WRONG PRICE` block, plus a non-zero exit, for any that disagrees with
>   `docs/LAUNCH-CONTRACT.md`. It reads the amount from the price point via
>   `include=subscriptionPricePoint` — the amount is not an attribute of the
>   price itself.
> * `asc.py subscriptions unprice <productId>` takes a wrongly priced product off
>   sale: `DELETE /v1/subscriptionPrices/{id}` first, then a re-POST of
>   `subscriptionAvailabilities` with an **empty** `availableTerritories` array
>   (legal — `SubscriptionAvailabilityCreateRequest` sets no `minItems`), then
>   the exact UI path.
> * `--skip-product <productId>`, repeatable, excludes a product from
>   `subscriptions apply`, `review apply` and `review submit` entirely.
>
> **The fix is to ask Apple for higher price points.** Every app gets 800; the
> Account Holder can request 100 more, up to USD 10,000, at
> <https://developer.apple.com/contact/request/app-store-higher-price-points/>
> (linked from Apple's
> [Set a price](https://developer.apple.com/help/app-store-connect/manage-app-pricing/set-a-price/)
> help page). In the UI they appear under **Pricing and Availability → Price
> Schedule → Add Pricing → See Additional Prices**. Once granted, re-run
> `subscriptions apply` and the guard passes.

**Sandbox lag.** Apple's own note on the subscription endpoints: metadata changes
made through the API can take **up to 1 hour** to appear in the sandbox.

### Listing — `asc.py metadata apply`

| Step | Call | Fields |
|---|---|---|
| App info | `GET /v1/apps/{id}/appInfos` → pick the editable one | — |
| Name/subtitle/privacy | `POST`/`PATCH /v1/appInfoLocalizations` | `name`, `subtitle`, `privacyPolicyUrl`, `locale` |
| Categories | `PATCH /v1/appInfos/{id}` | relationships `primaryCategory` → `BUSINESS`, `secondaryCategory` → `PHOTO_AND_VIDEO` |
| Age rating | `GET` then `PATCH /v1/ageRatingDeclarations/{id}` | exactly the attributes the GET returns, each set to its none/false value |
| Version | `POST /v1/appStoreVersions` | `platform: IOS`, `versionString: "1.0"`, `copyright`, `releaseType: MANUAL` |
| Listing copy | `POST`/`PATCH /v1/appStoreVersionLocalizations` | `description`, `keywords`, `promotionalText`, `supportUrl`, `marketingUrl` — and `whatsNew` **only if the app has a released version** |

> ### "What's New" does not exist on a first version
>
> Live 2026-09-05, on the app's first and only `appStoreVersion`
> (`PREPARE_FOR_SUBMISSION`, never released):
>
> ```
> PATCH /v1/appStoreVersionLocalizations/{id} -> 409
> [STATE_ERROR] The request cannot be fulfilled because of the state of another resource.
>     Attribute 'whatsNew' cannot be edited at this time.
>     at /data/attributes/whatsNew
> ```
>
> "What's New" describes what changed *since the previous release*, so on a first
> release there is nothing for it to say and App Store Connect will not take it.
> Two defences, because losing the whole listing to one rejected attribute would
> be absurd:
>
> 1. **Do not send it.** `app_has_previous_release()` lists the app's versions and
>    looks for one in a genuinely-released state — `READY_FOR_SALE`,
>    `PREORDER_READY_FOR_SALE`, `REPLACED_WITH_NEW_VERSION`, `REMOVED_FROM_SALE`,
>    `DEVELOPER_REMOVED_FROM_SALE`, `PENDING_DEVELOPER_RELEASE`,
>    `PENDING_APPLE_RELEASE` (from `AppStoreVersionState` / `AppVersionState`).
>    `ACCEPTED` and the other approval states are deliberately excluded: approved
>    is not released. The version being edited is excluded too — it cannot be its
>    own predecessor.
> 2. **Recover if it is rejected anyway.** On that exact 409 the request is sent
>    once more without `whatsNew`, so `description`, `keywords`, `marketingUrl`,
>    `promotionalText` and `supportUrl` all still land. Any other error is
>    re-raised untouched.
>
> `release_notes.txt` stays in the repo and starts being used at version 1.1.

> ### Age rating: PATCH what Apple asks for, not what you guessed
>
> Live 2026-09-05: a PATCH carrying 22 attributes chosen up-front returned
> **409 `ENTITY_ERROR.ATTRIBUTE.REQUIRED`**. The declaration's attribute set is
> not fixed — Apple keeps adding questions (`advertising`, `ageAssurance`,
> `lootBox`, `messagingAndChat`, `parentalControls`, `userGeneratedContent`,
> `socialMediaAgeRestricted`, `koreaAgeRatingOverride`, `ageRatingOverrideV2`…),
> and which ones are required varies. So `asc.py`:
>
> * **GETs the declaration first** and PATCHes exactly the attribute keys Apple
>   returned, each set to its "nothing applies" value from
>   `AgeRatingDeclarationUpdateRequest`: `false` for the 11 booleans, `"NONE"` for
>   the 13 frequency enums (`NONE | INFREQUENT_OR_MILD | FREQUENT_OR_INTENSE |
>   INFREQUENT | FREQUENT`), and `"NONE"` for `ageRatingOverride`,
>   `ageRatingOverrideV2` and `koreaAgeRatingOverride`, whose enums differ from
>   each other but all include `NONE`.
> * **Never sends `kidsAgeBand`** (it would put the app in the Kids category) or
>   `developerAgeRatingInfoUrl`.
> * On `ATTRIBUTE.REQUIRED`, **prints Apple's `detail` and `source.pointer`
>   verbatim**, then retries once having answered exactly the attributes those
>   pointers name. An attribute with no known safe value is reported, never
>   guessed.
> * Never fails the run — a rejected age rating prints the UI path instead.
>
> A test asserts that every attribute of `AgeRatingDeclarationUpdateRequest` in
> spec v4.4.1 is classified as boolean, frequency, override or skip, so a new
> Apple question shows up as a test failure rather than a live 409.

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

### 5b. Team Yearly's price — **blocker for that one product**

`com.rendprop.app.team.annual` is on sale at **USD 1000.00** instead of
USD 2490.00, because Apple's yearly USD price points stop at 1000.00 and the
2026-09-05 run had no guard. Do these in order:

1. Take it off sale:

   ```bash
   python3 tools/asc/asc.py subscriptions unprice com.rendprop.app.team.annual
   ```

   Read the output — if the API refuses both the delete and the empty
   availability, it prints the exact place to click.

2. Request the higher price points (Account Holder only), which adds 100 points
   up to USD 10,000:
   <https://developer.apple.com/contact/request/app-store-higher-price-points/>

3. Until that is granted, keep the product out of every run:

   ```bash
   python3 tools/asc/asc.py subscriptions apply --skip-product com.rendprop.app.team.annual
   python3 tools/asc/asc.py review apply        --skip-product com.rendprop.app.team.annual
   python3 tools/asc/asc.py review submit       --skip-product com.rendprop.app.team.annual
   ```

4. Once granted, drop the flag and re-run `subscriptions apply`. Confirm with
   `asc.py status`, which prints every product's actual amount and shouts
   `WRONG PRICE` if any of them disagrees with `docs/LAUNCH-CONTRACT.md`.

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
and shows each product's state, territories, **price amount**, trial and review
screenshot. It exits non-zero if any price disagrees with
`docs/LAUNCH-CONTRACT.md`, so read the `WRONG PRICE` block if one appears.

Optionally send the subscriptions on their own:

```bash
python3 tools/asc/asc.py review submit --skip-product com.rendprop.app.team.annual
```

(`--dry-run` shows what it would submit. Drop `--skip-product` once Team Yearly
has a correct price — see step 5b.)

Then the app version itself: **your app → the 1.0 version → Add for Review →
Submit to App Review**. On a first release the subscriptions are reviewed
together with the app, so confirm the ones you intend to ship appear in the
submission — and that Team Yearly does **not**, until it is priced correctly.

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
* **Introductory offer territory scope.** ~~Optional, so omitted.~~ **Settled
  live 2026-09-05**: omitting `territory` returns
  `ENTITY_ERROR.RELATIONSHIP.REQUIRED`. `asc.py` now creates one offer per
  territory the product sells in (USA only at launch).
* **Age rating attribute set.** Verified against
  `AgeRatingDeclarationUpdateRequest` in spec v4.4.1, and no longer a fixed list
  — the PATCH is driven by what the GET returns. See the age-rating box above.
* **Deleting a price that is already in effect.** `DELETE
  /v1/subscriptionPrices/{id}` exists (204), but Apple documents the POST as
  scheduling a price *change*, and does not say whether an in-effect price can be
  removed. **UNVERIFIED** — `subscriptions unprice` tries it and falls back to an
  empty `availableTerritories`, then to the UI path.
* **The `appAvailabilities` inline-create id.** The spec requires an id on the
  relationship reference and makes it optional on the `included` object, but
  ships no example, and the live attempt returned `INCLUDED.INVALID_ID`. Which
  handle Apple actually accepts is **UNVERIFIED**; `asc.py` tries the territory
  id, then a distinct handle, then prints the UI path.
* **Live API behaviour.** Four live runs have now happened (2026-09-05). What
  they proved is recorded inline above: availability before price, per-territory
  introductory offers, the yearly USD 1000.00 price ceiling, the `whatsNew`
  STATE_ERROR, the age-rating `ATTRIBUTE.REQUIRED`, and the `appAvailabilities`
  `INCLUDED.INVALID_ID`. Every one of them is reproduced by the fake API in
  `tools/asc/test_asc.py`. Everything is idempotent, so a mid-run failure is safe
  to retry.

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
