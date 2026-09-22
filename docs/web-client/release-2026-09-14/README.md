# Studio account connection release — September 14, 2026

The live homepage now has Studio navigation, footer links and an Open Studio
button. `/studio` redirects to `https://studio.rendprop.com/`. This release uses
the latest native/product baseline `8d32f85`, preserving its invite links, pricing,
attribution, sitemap and existing tour routes. It imports the existing Studio
implementation from `a9811c6` and fixes the account-read issues before deployment.

## Deployed account connection

- Apple Services ID `com.rendprop.studio` is associated with primary App ID
  `5F5C5G25Y6.com.rendprop.app`, with Studio and Supabase domains registered and
  `https://ymgqpbnjpztwjsyvceld.supabase.co/auth/v1/callback` as its return URL.
- Supabase Apple client IDs put the web ID first and preserve the native ID.
  Existing redirects, native/anonymous settings and site URL are preserved.
- Existing key `YRH7FM6336` was already enabled for Sign in with Apple for the
  correct native app; no new signing key was created and no key was revoked.
- Studio includes only the same project's public URL and publishable key.
- Only the new `studio` Edge Function was deployed, with JWT verification enabled.
  It checks current user, workspace membership, deletion state and listing access
  before issuing short-lived signed private-media reads. No migration was needed.
- Private upload/render buckets allow GET/HEAD and Range from the exact Studio
  origin. This CORS policy does not make their objects public.

Connected Studio loads the existing iPhone workspace, spaces, plan and cloud
photos/footage. The library refresh button reloads cloud data. A workspace that
still belongs to an anonymous iPhone session must be linked to Apple in the app
first. Files stored only on the phone cannot be recovered by a browser login.
Browser edits, original-file bindings and content plans still remain local;
this release does not add cloud edit writes, uploads or social publishing.

## Correctness fixes and verification

Listing and membership reads now use explicit RLS queries with scoped filters,
deterministic ordering, exact counts and bounded pagination. This avoids the old
all-workspace response cap falsely hiding a selected workspace. Requests reject
incomplete counts, duplicate rows and oversized metadata. Refresh promises cannot
cross identities. Degraded entitlements display as temporarily unavailable.

Full tour-host predeploy passed; Studio passed 166 unit tests, 30 Deno backend
tests, type checks, six connected-browser fixture checks and the deliberate
refresh-regression control. These fixtures are isolated from real accounts.
`deployed-assets.json` proves the live Studio entry and assets match the build,
including response policy and the SPA deep route. `deployment.json` records
actual production versions and the still-required owner-login check.

Live browser verification confirmed the homepage link opens Studio and Continue
with Apple reaches Apple's Rendprop sign-in page. The owner was asked to complete
Apple sign-in with the account used by the iPhone app. Until that finishes, an
actual same-account workspace/media round trip is not claimed as verified.

## OAuth maintenance

The Apple OAuth client secret expires March 13, 2027; renew before February 27,
2027. The existing private key stays outside Git at the owner's secure key path.
Do not revoke it during renewal: it also supports the existing app's push service.
Use `apps/studio/scripts/configure-apple-web.mjs` with the key-file, key-id and
Supabase token-file paths. Default execution is a read-only preview; `--apply`
renews the secret and preserves the existing native audiences/redirects. It prints
only non-secret metadata. Never copy the private key or OAuth secret into Vite
configuration, source, receipts or command arguments.

## Deployment recovery

`deployment.json` records both previous Worker versions. The homepage and Studio
are separate Workers; roll back only the affected Worker if needed. Preserve the
new additive backend and existing native auth audience. Native app builds, App
Store submission and other Edge Functions were not changed by this release.
