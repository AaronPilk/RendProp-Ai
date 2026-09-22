# Separate saved reels for every property

Studio now saves each property's reel independently. Opening another property's
Make a reel card opens that property's saved story; returning restores the first
property's photos, timing, captions and narration. Source files are restored from
their existing upload receipts, so switching does not copy them into another
listing or upload them again.

The property selector waits for the current cloud save. Pending file uploads,
imports, exports and an undownloaded finished video keep the current editor open
with a clear next step. Only one editor and encoder is mounted at a time. Account
and workspace changes discard the old session's authority and ignore late reads.

Earlier workspace-wide account and browser edits are retained. Before creating
a property reel, Studio offers an explicit recovery choice when a compatible
earlier copy exists. Choosing a copy creates the property's new document with a
revision check; it never deletes or overwrites the earlier document or backup.
Files that never finished uploading still require their exact original bytes.

## Data contract

- `edit:<listing UUID>` documents have `kind=edit`, a matching `listing_id`, and
  the same listing ID inside their payload. The edge handler authorizes the
  listing before writing and compares the expected revision atomically.
- Existing global `edit` remains readable and writable for old clients. The new
  UI reads it for explicit recovery and never mutates it during migration.
- Existing SQL accepts these keys and already scopes reads by user, workspace
  and live listing. No migration is needed. Deploy the new `studio` edge handler
  before the frontend that writes property-scoped keys.
- Browser recovery keys include the account, workspace and property. No account
  credential, signed media URL or raw media is stored in a reel document.

## Executed verification

September 22 checks used the integrated source in `complete-product-20260922`:

| Check | Result |
| --- | --- |
| Combined Studio unit suite | 295 passed, 0 failed/skipped; includes other integrated product tests |
| TypeScript | Passed |
| New property reel browser scenarios | 7 groups: A→B→A, exact source restoration, once-only feature entry, blocked pending upload/resume, new browser, explicit legacy/browser recovery, delayed old-account response, mobile layout |
| Existing advanced editor | 13 groups, including decoded H.264/AAC output, actual dissolve/whip frames, continuous narration, phone setup, lost upload reply and competing device save |
| Media picker | 5 groups, including real 50-row paging, original identity reuse and property-scoped continuation |
| Actual App branding and navigation | 13 groups, including Home/card entry, separate property reels, source reuse, light/dark and 390px layouts |
| Scoped document edge tests | 7 passed, including mismatched key/listing rejection before writes and independent revision predicates |
| Independent browser review | Passed the existing property scenarios plus export-in-progress and undownloaded-video switch rejection, then download-and-switch success |

Durable receipts, synthetic images/video outputs and a source hash manifest are
in `/Users/pilksclaes/LocalRendpropAudits/studio-property-reels-20260922`.
Browser scenarios emitted no unexpected external requests or page errors.

These are real browser/component/export tests against isolated account/media
fixtures. They do not claim physical camera capture, a live Apple sign-in
roundtrip, paid AI output quality or production deployment.

## Reproduce

From `apps/studio`, run `npm test` and `npm run typecheck`, then:

```sh
STUDIO_BROWSER_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' node tests/property-reels-browser.mjs
STUDIO_BROWSER_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' node tests/cloud-editor-browser.mjs
STUDIO_BROWSER_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' node tests/reel-media-browser.mjs
STUDIO_BROWSER_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' node tests/brand-browser.mjs
```

The editor still supports one reel per property, 12 base clips, 128 MiB per
source, 512 MiB total sources and a three-minute edit. Finished video upload is
explicit. Native setup import preserves supported settings; it is not an
arbitrary shared AVFoundation timeline. Agent portrait file sync remains a
separate gap.

## Retained live sync verifier

`apps/studio/scripts/verify-complete-sync.mts` uses the application's actual
transport, upload, document synchronization and reel validation code. Its
`--self-test` performs nine offline allowlist/domain checks without requests.
After the backend deployment is confirmed, `--run` creates one isolated,
confirmed synthetic account and checks two independent sessions, two properties,
property-specific reel saves and conflicts, preserved legacy work, generated
PNG/MP4 upload receipts and exact signed bytes. It sends no email, invokes no
paid provider and publishes nothing. Its allowlist rejects every DELETE request.

Credentials and upload recovery journals are synchronously written before
mutations to a mode-0600 file under a mode-0700 directory outside the checkout.
The account, media and recovery files are retained after success or failure.
If a run fails, inspect its receipt and retained recovery state before another
attempt; do not rerun blindly or invoke the older cleanup verifier.

```sh
node --import tsx scripts/verify-complete-sync.mts --self-test
```
