# Property download kit

An agent can open a property's **Download listing kit**, review the available
materials, select files and download one ZIP. Unzip it and open
`START-HERE.html` for a readable index with links to the included files.

The kit contains:

- Selected saved gallery photos in their saved order, with captions.
- Each selected altered photo's paired original and saved disclosure. A photo
  missing its original or caption/disclosure is explicitly unavailable.
- Optional completed saved creative videos whose existing server projection
  confirms publishability and whose asset and disclosure can be verified.
  Videos start unselected. A generated clip's available source photo is labelled
  as a source photo; a combined edited reel never invents a single unaltered
  original video.
- Saved property facts and the property's saved creative script, when present.
  Arbitrary `details` metadata, unsaved fields, draft timelines and upload
  journals are not exported or changed.
- The latest already-published tour's marketing and unbranded links, plus two
  locally generated SVG QR codes. An unpublished property has neither links
  nor QR codes. Downloading does not publish or approve anything.

Users explicitly confirm reviewing their selection before downloading. This is
a local confirmation for this download, not a persisted approval record or an
MLS compliance certification. Changing the selection clears that confirmation.
Raw capture files, floor plans, voice-only results, unfinished provider output
and unreviewed generated videos are outside this version's scope. Existing
individual Media downloads remain available.

## Bounds and consistency

The kit has at most 40 selected items, 128 archive entries, 128 MiB per file and
256 MiB total uncompressed contents. Altered originals count toward the byte and
entry limits. Metadata is reserved within the total. Bytes are counted while
streaming; Content-Length alone is not trusted. Unsupported media or any failed
selected file stops the whole kit without emitting a partial download.

The loader uses existing read-only listing, gallery, creative-result and saved
document contracts. It verifies listing/workspace identity, pagination, saved
asset keys and original pairings. The existing strict signed-media URL decoder
is reused immediately before each download. Downloads omit credentials and
referrers, reject redirects, and use an abort signal and timeout. Account and
property changes abort work; final identity checks precede the browser download.
Opening the kit does not remount or replace the property's current form.

Archive filenames reject traversal, unsafe platform characters, reserved names
and duplicate aliases. User-facing text is escaped in HTML; private media and
upload capability URLs are omitted from exported copy. Only explicit public
tour URLs are written by the sharing feature. The ZIP uses the standard stored
method with CRC32 and UTF-8 names, preserving already-compressed media bytes.
Packing yields periodically so cancellation remains responsive.

No backend change, migration, new generation, provider request, publication,
account deletion, native change or deployment is part of this branch.

## Executed verification

- 302 Studio unit tests passed; none failed or skipped. Seven new tests cover
  archive extraction, file/byte/path limits, cancellation, original pairings,
  disclosure/copy encoding, expired/failed media and identity races.
- TypeScript, production build and built-asset checks passed.
- New actual ListingWorkflow browser fixture passed seven behavior groups:
  dirty form preservation; selected photo/original/MP4 ZIP download and exact
  bytes; opened HTML index; selection review reset; failed/cancelled download;
  property/account switch; unpublished details-only kit; 390px layout.
- Existing property workflow passed all 12 browser groups.
- Independent review passed 159 module/archive/parser assertions and nine
  browser groups, adding cancellation followed immediately by retry before the
  old response resolves, and cancellation while saved-state loading is held.
  No blocker, external request or browser exception was observed.

Fixtures contain generated images and a one-second generated H.264 video.
System `unzip` and independent Python `zipfile` verify CRC and exact extracted
contents. These checks do not claim a live account download or physical camera
capture.

Durable receipts and generated artifacts:
`/Users/pilksclaes/LocalRendpropAudits/listing-delivery-kit-20260922`.

Reproduce from `apps/studio`:

```sh
npm test
npm run build
node scripts/check-dist.mjs
STUDIO_BROWSER_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' node tests/listing-kit-browser.mjs
STUDIO_BROWSER_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' node tests/listing-workflow-browser.mjs
```
