# gear.json — the "Gear we recommend" catalog (Amazon Associates)

[gear.json](gear.json) in this folder is served as-is at **https://rendprop.com/gear.json**
by Workers Static Assets (`wrangler.toml` → `[assets] directory = "./public"`).
The iOS app fetches it on launch, caches it on the phone, and shows the Gear
section only when the file says so. No Worker code reads it.

This README is **not** published: `public/.assetsignore` excludes it from the
asset upload. Treat other files in `public/` as publishable assets; the exclusions are listed in
[.assetsignore](.assetsignore).

## The section stays hidden until three things are true

The app shows Gear (Settings → "Gear we recommend", a Home tile, the list
itself) only when **all** of these hold in the live `gear.json`:

1. `"enabled": true`
2. `"associates_tag"` is your Amazon Associates tracking ID (`rendprop-20` style)
3. at least one item has a valid 10-character `"asin"` and non-empty category

Items with an empty `asin` are never shown, so you can fill the catalog in
gradually. The checked-in catalog, reviewed on 24 September 2026, still has
`enabled: false`, an empty tag and empty ASINs. This describes repository defaults,
not a fresh read of live catalog or Associates approval state.

**Do not set `enabled: true` until the app has been approved in Associates
Central** — see [the gear-store workflow](../../../../docs/GEAR-STORE.md) for the approval order. Amazon's mobile app
approval is per app, after it is live and free in the App Store.

## How to fill it in

You need one Associates tracking ID (the "tag") and one ASIN per product.

### The tag

Associates Central → the account menu (top right) → **Manage Your Tracking IDs**.
The default one looks like `yourname-20`. Use it, or create one such as
`rendprop-20` so the app's clicks show up on their own. Put it in
`"associates_tag"`.

### An ASIN per item

1. In Associates Central, use **SiteStripe** (the bar across the top of any
   amazon.com page while you are signed in) → **Get Link** → **Text**, or just
   open the product page you want to recommend.
2. The ASIN is the 10-character code in the product URL right after `/dp/`:
   `https://www.amazon.com/dp/B0XXXXXXXX/…` → `B0XXXXXXXX`. Letters and digits
   only, always 10 characters. (SiteStripe's short `amzn.to` link also resolves
   to a `/dp/ASIN` URL.)
3. Paste it into that item's `"asin"`.

The app builds the link itself as
`https://www.amazon.com/dp/<ASIN>?tag=<associates_tag>` and opens it with
the system (Safari or the Amazon app). An ASIN that is not exactly 10 letters
and digits is treated as empty and the item stays hidden.

### Turn it on

Set `"enabled": true`, keep `"version": 1`, save, then redeploy the Worker:

```bash
cd services/edge/tour-host
npm ci
npm run deploy      # predeploy runs typecheck, all Worker tests and asset checks
```

The app tries on first access each launch, then throttles automatic refresh
attempts for six hours. Pull-to-refresh requests a new copy immediately. Failed
requests keep the last good disk copy; a refresh interval is not a delivery
guarantee while the phone is offline.

## Editing the catalog

- **Categories** — `id`, `title`, and `why`: one plain sentence on why this
  kind of gear matters for filming a walkthrough. The app shows a category
  only when it has at least one visible item.
- **Items** — `id` (stable slug; it is the only thing analytics records),
  `category` (must match a category `id`), `name`, `blurb` (what the gear does
  for a walkthrough — not a review, not a price), `asin`, and `for`.
- **`for`** — which business types see the item: any of `real_estate`,
  `venue`, `restaurant`, `retail`, `fitness`, `other`. An empty list means
  everyone.
- **`disclosure`** — the sentence Amazon's Operating Agreement requires. Leave
  it as it is unless Amazon changes the wording.
- **`version`** — leave at `1`. The app ignores a catalog with any other value.

Keep the file valid JSON (a trailing comma is enough to hide the whole
section). From `services/edge/tour-host`, check syntax before deploying:

```bash
node -e 'JSON.parse(require("fs").readFileSync("public/gear.json","utf8")); console.log("gear.json ok")'
```

The app-side parser, visibility rules and refresh/cache behavior live in
[GearStore.swift](../../../../apps/ios/Rendprop/Gear/GearStore.swift). This catalog
is independent of [Studio creation](../../../../apps/studio/README.md); updating
README files does not enable affiliate links or publish a catalog change.

## What the app never does with this file

- It never shows a price, a rating or a stock status — there is no field for
  one, and Amazon's rules forbid making those up.
- It never renders Amazon inside the app; links open in Safari or the Amazon
  app.
- It never gates any of this behind sign-in or a paid plan.
