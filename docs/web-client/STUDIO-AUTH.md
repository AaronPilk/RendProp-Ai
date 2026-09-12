# Studio browser identity and read contracts

Implemented locally on 2026-09-12. No provider setting, Apple registration, production
data, migration, deployment, subscription or anonymous-workspace adoption was changed.
Offline test accounts exist only in `apps/studio/tests/data.test.ts`; runtime code has
no sample customer responses and no successful-connection fallback.

## Browser configuration

Provide `VITE_SUPABASE_URL` (the same project used by the native app) and
`VITE_SUPABASE_PUBLISHABLE_KEY`. Legacy `VITE_SUPABASE_ANON_KEY` is accepted for
compatibility only when the decoded configuration JWT has role `anon`. This key
inspection prevents obvious credential mistakes; it does not authenticate a user.

Both values are public, shipped in the browser bundle. A secret key, service-role
key, Apple signing key, personal access token or provider credential never belongs
in a Vite environment variable. The configuration reader rejects common secret
variable names, `sb_secret_` keys and service-role JWTs. It only accepts HTTPS
origins, with HTTP permitted on localhost for development; URL credentials,
queries, fragments and non-root paths are refused. The OAuth return address is
the actual Studio origin, not an arbitrary URL from query parameters.

```ts
import { createStudioServices, readStudioConfig } from './data';

const services = createStudioServices(
  readStudioConfig(import.meta.env, window.location.origin),
);
const unsubscribe = services.subscribe(snapshot => {
  // Snapshot contains user identity and status; it contains no tokens.
});
await services.ready();
const workspace = await services.loadWorkspace(abortController.signal);
const listings = await services.listListings(workspace.org.id, abortController.signal);
// Tear down the service only when its owning app unmounts.
unsubscribe();
services.dispose();
```

Missing or invalid configuration is an explicit unconfigured state in the UI.
Local creation and editing require no account. This adapter intentionally does
not bootstrap an anonymous remote account for local editing or adopt a workspace.
Only opening existing cross-device data requires an identified Apple account.

## Existing native Apple identity

`@supabase/supabase-js` 2.116.0 owns browser session restoration, Apple OAuth,
PKCE code exchange, auto-refresh and cross-tab Auth events. The client uses
explicit `localStorage` with project-scoped key
`rendprop-studio-auth:<Supabase host>`, `persistSession: true`,
`autoRefreshToken: true`, `flowType: 'pkce'`, and `detectSessionInUrl: true`.
Application state never persists a second bearer or refresh token. This browser
storage is accessible to scripts on the owner origin: dedicated hosting, a
strict CSP, no third-party scripts and no rendered user HTML remain release gates.

`signIn()` calls the official `signInWithOAuth({ provider: 'apple' })` path.
It does not create a second identity service, use email to merge users, or copy
native Keychain credentials. For native and web to resolve the same account,
the existing Apple provider needs a web Services ID associated with the native
App ID. Current Supabase documentation explicitly requires the **Services ID
first** in its Apple Client IDs list while retaining the native
`com.rendprop.app` audience. A native App ID listed first allows native sign-in
but causes web OAuth rejection. Supabase's callback must be registered for that
Services ID, Studio's exact origin return URL must be in Supabase's redirect
allowlist, and the Apple OAuth client secret must remain valid (Apple requires
six-month renewal). Those live settings were not read or changed by this task.

An account that still exists only as an anonymous iPhone session cannot be
recovered by signing in as an unrelated Apple user on web. Connect the existing
workspace to Apple inside the native app first. Files stored only on the phone
are not claimed to be available in the cloud.

## Identity and request fences

Snapshots distinguish session presence from `isAnonymous`. Browser snapshot
identity is display and cancellation state; server Auth validation and RLS are
the authorization authority. User-editable `user_metadata` never determines
membership, roles, entitlements or organization selection.

Each operation captures its identity revision before its first await and its
selected organization at invocation. A user change, sign out, or change in
anonymous identity increments the revision and aborts in-flight requests.
Every response is checked again before decode and use. A switch A → B → A
still rejects responses begun in the first A session. Token refresh for the
same user preserves the revision and valid work. The UI must likewise render
connected data only for the captured current identity and clear it on changes;
the transport cannot remove already-rendered image/video elements itself.

An HTTP 401 triggers at most one retry, with a single shared refresh promise
and the same selected organization. A token already replaced by auto-refresh
is reused without another refresh. Non-success responses become visible,
sanitized errors; response bodies, access tokens and signed media URLs are not
logged. Reads use `cache: 'no-store'`, `credentials: 'omit'` and `redirect: 'error'`.
Callers must pass an AbortSignal when changing workspace, listing or route.

Each GET has a 30-second total deadline, including response-body decoding and
any 401 refresh/retry wait. SDK restoration, refresh, sign-in and sign-out have
20-second deadlines. Timeouts abort the read and return a safe retry message;
the SDK retains ownership of automatic refresh. Late promise fulfillment or
rejection is consumed without resurrecting a timed-out read. Deterministic
manual-clock tests cover never-resolving fetch, JSON body, restoration, refresh,
sign-in and sign-out, plus retry after timeout and late rejection handling.

`signOut()` immediately removes the visible identity and fences requests before
calling `auth.signOut({ scope: 'local' })`. Local scope preserves the native
iPhone session; the SDK default global scope would sign out all devices. If
revocation fails, this browser stays disconnected and an explicit error reports
that server revocation was not confirmed. Signing out does not delete account
data. Existing JWT expiry behavior remains Supabase's; no claim is made that
an issued bearer instantly becomes cryptographically invalid.

## Exact read contracts

Wire DTOs use the server's literal snake_case keys; normalized application types
use camelCase. Required identifiers, role enums, dates, numeric values, money
precision, deleted rows, duplicate IDs, listing/org relationships and cross-user
responses are validated at runtime. Unknown business types stay strings, so an
industry added by the native app remains visible. No industry filter is sent.

| Read | Existing authorization and behavior |
| --- | --- |
| `GET /rest/v1/memberships?select=user_id,org_id,role,orgs!inner(id,name,space_type,deleted_at)&user_id=eq.<subject>&orgs.deleted_at=is.null` | Public project key plus current user bearer. Existing own-membership RLS and organization RLS; no service role and no write. Returned subject and joined organization must match. |
| `GET /functions/v1/me` | Existing server validates user and resolves active native workspace. An explicit selection sends `X-Org-Id`; the server checks membership. The decoded user and organization must match the active identity and membership list. Effective `plan` is displayed separately from `plan_raw`. |
| `GET /functions/v1/listings` | Existing route returns all RLS-visible organizations and does not currently apply `X-Org-Id` to its query. Every row must belong to the loaded membership set, then the adapter selects the requested organization. A row from an unjoined organization fails the entire response. This endpoint has no pagination contract, so default Data API row limits remain a large-account release concern. |
| `GET /functions/v1/studio/media?listing_id=<uuid>&org_id=<uuid>` | Additive Studio read route implemented on this branch. Client sends `X-Org-Id` as well. Server must validate user, current membership and a live listing in that organization before signing any object URL. |

The original backend had no general authenticated private-media read endpoint.
Public tours and AI-provider/internal presign helpers were not substituted for
one. The Studio media route contract is:

```ts
type ListingMediaDTO = {
  org_id: string;
  listing_id: string;
  photos: Array<{
    id: string; listing_id: string; url: string; expires_at: string;
    caption: string | null; is_staged: boolean; sort: number;
  }>;
  videos: Array<{
    id: string; listing_id: string; url: string; expires_at: string;
    kind: 'video'; created_at: string; duration_s: number | null;
  }>;
  next_offset: number | null;
  unavailable_count: number;
};
```

The server accepts listing identity, never an arbitrary client storage key.
Only supported, completed objects are signed. Every item must match the
requested listing; top-level listing and organization must match the request.
The browser validates the existing path-style R2 signer contract: an HTTPS
account endpoint, canonical uploads/renders key scoped to the requested org and
listing, unique SigV4 parameters, and a signed lifetime no longer than 600 seconds.
It rejects foreign hosts/tenant paths, expired signatures even when the DTO
claims a later expiry, malformed dates, duplicate parameters, credentials and
bearer-token query parameters. This is structural validation, not cryptographic
signature verification; R2 verifies the signature. Staging disclosure is retained. Signed URLs stay in memory,
are short-lived read capabilities, and must be renewed by fetching the route
again. R2 requests never receive the user's Supabase Authorization header.
Browser playback/import needs working origin CORS and a no-referrer policy;
native URLSession playback is not proof of browser access.

The request adapter verifies the bearer with Auth, checks account deletion,
reads current membership, then checks the live org and live listing through the
request-local RLS client. The handler repeats authorization after reading and
signing but before returning the page, so removal/deletion observed during the
request cannot release a stale successful response. This is not an atomic
transaction or instant revocation: a capability already issued remains usable
until its short expiry, and already downloaded bytes cannot be recalled.

`Cache-Control: private, no-store` on the JSON response and `cache: no-store` on
the editor's bounded download do not govern direct `<img>`/`<video>` responses.
The shared `presignGet(bucket, key, expiresIn)` currently has no response-header
override option. No cache parameter is appended after signing (that would
invalidate SigV4), and shared R2 behavior was not changed. Before enabling the
connected library, verify actual private R2 GET/Range cache headers, expiry and
CORS. Do not describe media browser-cache removal as proven by static headers.

`listMedia(orgId, listingId, signal?, offset = 0)` reads one page. Server offsets
advance by 50 database rows per source. Each response permits at most 100 photos
and 100 videos; malformed/non-advancing cursors fail validation. The library's
Load more action preserves subject, workspace and listing fences, deduplicates
by item ID, and reports the count of unavailable items across loaded pages.
Refresh discards existing pages and renews links from the first page. Rendered
media, imported files, editor drafts and content plans are also fenced before
React commits; an account change cannot render the preceding account's data
while waiting for cleanup effects. The editor mounts only after the matching
storage scope is restored, preventing its empty initial draft from overwriting
a saved edit.

Each of the three RLS queries orders by ID and requests an inclusive 51-row
range: 50 usable rows plus one lookahead, with the same offset for each source.
Null/failed query results, oversized pages and cross-listing rows (including the
lookahead) fail rather than appearing as an empty or truncated successful library.
The request AbortSignal is attached to these queries. Offset paging is not a
database snapshot: concurrent media insertion/removal can shift later pages;
refresh from offset zero to reconcile changes. No snapshot cursor is claimed.

Offline API-hardening verification on 2026-09-12:

```sh
deno test --cached-only --deny-net --deny-run --deny-write \
  services/supabase/functions/studio/handler.test.ts \
  services/supabase/functions/studio/repository.test.ts
deno check --deny-import --frozen services/supabase/functions/studio/index.ts
cd apps/studio
node --import tsx --test tests/data.test.ts
npm run typecheck
```

Observed: 29 route/real-query-adapter tests passed, 24 browser-data tests passed,
zero failures or skipped tests; both type checks passed. Tests use isolated
synthetic rows, Auth and query doubles; they do not prove production RLS or
provider configuration. No dist rebuild, deployment, provider change or
production mutation was performed for this hardening pass.

## Verification and remaining live gates

Run `cd apps/studio && npm test` for the offline application tests. The data suite
asserts public environment validation, literal DTO decoding, effective plan
preservation, membership/tenant mismatch rejection, industry preservation,
Apple provider and local logout arguments, anonymous/identified distinction,
401 single-flight retry, account-switch races, late session initialization,
navigation abort, stale response rejection, and private-media URL validation.
No test calls production Auth, Apple, Data API or a paid provider.

The repeatable workspace browser runner uses the pinned `@playwright/test`
package and fresh isolated contexts. It blocks all external network requests
and rejects the Vite HMR client. With a built preview already listening:

```sh
cd apps/studio
node tests/browser-workspace.mjs --base-url=http://127.0.0.1:4179
```

For CI, install the matching Chromium once with `npx playwright install chromium`,
then let the runner build and own a preview on an unused port:

```sh
node tests/browser-workspace.mjs --start-preview --base-url=http://127.0.0.1:4189
```

`STUDIO_BROWSER_EXECUTABLE` optionally selects an already-installed Chromium
or Chrome executable. The runner saves screenshots, the actual downloaded
calendar file and `receipt.json` in an OS temporary directory outside app code.
Its receipt explicitly distinguishes local browser behavior from untested
live Apple authentication; failure exits nonzero. Verification includes every
page at desktop and 375px widths, navigation names/targets, modal keyboard
containment/Escape/focus restoration, planner persistence and calendar bytes,
editor draft restoration, and full-hash rejection of altered media with the
same filename, size, dimensions and displayed pixels. Corrupted and unreadable
draft storage is independently restored and write-locked; retry is tested with
both cancelled and accepted confirmation, including a repaired draft with a
different identity and clip count.

Executed against the final frozen production preview on 2026-09-12, after the
timeout, planner, mobile-label and draft-recovery changes:

```sh
STUDIO_BROWSER_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
  node tests/browser-workspace.mjs --base-url=http://127.0.0.1:4179
```

```json
{
  "status": "passed",
  "finishedAt": "2026-09-12T16:22:03.694Z",
  "browserVersion": "152.0.7977.83",
  "builtEntrySha256": "95d81d1cb69bb64d237e6cd4dbc884287b0e314d4f9d49b07aa988f8506fef05",
  "pageViewportCombinations": 10,
  "consoleErrors": 0,
  "externalRequests": 0,
  "authVerification": "Not run; no provider settings changed"
}
```

The run also exercised planner edits preserving item identity, channel filters,
cancelled/confirmed local removal, refusal of the nonexistent New York
`2026-03-08 02:30`, and explicit selection of the second repeated
`2026-11-01 01:30` (persisted as `06:30Z`). Malformed planner content did not
prevent restoration or saving of a valid editor draft; malformed editor content
and a throwing `getItem` could not be overwritten by empty or temporary edits.
Cancelling retry retained temporary edits. Accepting retry restored a repaired
draft with a different ID and two clips, and the next save retained that repaired
identity. Mobile and planner screenshots were visually inspected after the run.
Its full receipt and images are at
`/var/folders/j3/n4p7jg5x5lv35xgcv9hw9yx80000gn/T/rendprop-workspace-browser-fwxA6G/`.
A durable copy of the receipt is included at
[`evidence/2026-09-12/workspace-browser.json`](evidence/2026-09-12/workspace-browser.json).
The `--start-preview` orchestration option is implemented but was not exercised
in this final coordinated run, which deliberately used the already-frozen build.

Final config review also caught the unused-key-alias path: a valid preferred
publishable key could mask a forbidden value in the other Vite key field. Both
fields now fail closed even if the unused field is empty. The data suite passed
24/24; the actual Vite CLI, given only synthetic keys, exited 1 before emitting
files and left all existing dist hashes unchanged. No actual credential was used
or printed by that negative control.

The Studio preview subsequently deployed in **unconfigured local mode**. It does
not enable or prove this Apple account flow. See STUDIO-STATUS for the separate
live editor/asset receipts and the Cloudflare-managed robots exception.

Before claiming a connected production browser, verify the configured Apple
round trip reaches the same Supabase subject and existing listings as the iPhone;
restore after reload; refresh and sign-out across two real browser tabs; token
expiry, account switching, membership removal and network failure; real
low-privilege Data API/RLS behavior; Studio endpoint deployment/CORS; and
private-media expiry/playback/import. Offline mocks prove the adapter's state
machine and contracts, not those external settings. Native StoreKit, server
entitlements, adoption, account deletion, analytics and provider routing are
outside this browser read implementation.

Documentation checked 2026-09-12: [Supabase changelog](https://supabase.com/changelog),
[Apple sign-in](https://supabase.com/docs/guides/auth/social-login/auth-apple),
[OAuth/PKCE](https://supabase.com/docs/reference/javascript/auth-signinwithoauth),
[Auth state events](https://supabase.com/docs/reference/javascript/auth-onauthstatechange),
and [local sign out](https://supabase.com/docs/reference/javascript/auth-signout).
The reviewed changelog adds no relevant hosted Apple-browser breaking migration;
Node 22+ and TypeScript 5+ satisfy its current library compatibility notices.
