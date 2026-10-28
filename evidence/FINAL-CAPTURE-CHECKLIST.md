# Final real-app guide capture checklist

The draft contains 38 ElevenLabs Faye scenes and runs about 9m55s. Its current MP4 is a review draft, not the release asset. Capture only genuine UI from the physical TestFlight build or the exact current app simulator; never redraw a product screen or present owner-only usage as a public offer. Keep the original screenshot PNG and record build/source plus SHA-256 before making the cropped JPG used by the renderer.

| Scene | Capture required | Source and acceptance |
| --- | --- | --- |
| 03 | Sign in with Apple and the introductory flow | Exact-build simulator, signed out, no credentials or personal data. Replace the unrelated My Listings visual. |
| 08 | Recorded-walkthrough entry with record and upload choices | Exact-build physical phone or simulator. Toolbox tile alone does not teach the choice. |
| 18 | Choose the look with Wide and Tall shape choices | Build 131. Do not reuse Build 129, whose Look screen visibly contains the removed AI camera option. |
| 19 | Photo motion with **Automatic**, four available directions, and per-photo timing | Build 131, ideally two scroll positions. Verify 12% movement text; do not capture a generated result or start a paid job. |
| 26 | Tag rooms on an existing recorded walkthrough | Exact-build simulator fixture or a real nonprivate walkthrough. Toolbox tile alone does not demonstrate the chapter control. |
| 34 | Account landing page with Profile/contact card and Settings/plan | QA account or exact-build simulator, no owner contact details. Replace the Settings-only visual. |
| 35 | Public Pro/Max/Ultra/Team plan comparison and eligible trial terms | Build 131 ordinary QA account. Exclude owner Team testing entitlements/unlimited usage and purchase sheet with personal Apple ID. |
| 36 | Credits & extra usage with a visible 100-credit top-up offer | Build 131 ordinary QA account **after** the live catalog is available; do not purchase for this capture. Build 129 currently says purchases are unavailable, contradicting the narration. |
| 37 | Team workspace/seat management | Ordinary QA Team workspace or exact-build simulator fixture, no real member emails/invites. Replace the unrelated Listing contact visual. |

Existing verified captures can be reused where Build 131 leaves the shown controls unchanged: `toolbox-clean` for scenes 01, 02, 16, 24 and 38; `my-listings` for 04; `listing-edit-address` for 05; `sim-contact` for 06; the physical photo grid/versions/compare captures and simulator Studio/Share ZIP for 07, 09–15; `video-choose-photos` for 17; framing, audio, Activity and saved-video captures for 20–23; `aerial-front-photo-selection` and Activity review detail for 24–25; website-design cards, live site hero/gallery and share links for 27–30 and 38; `leads-qa-empty` for 31; Activity category captures for 32–33. The recorded aerial result is deliberately unaccepted; scene 25 should continue to teach *review before use*, not imply this result was approved. Any source that visibly changed in Build 131 must be recaptured.

For each new raw screenshot, review it first, then import its unchanged pixels and provenance. Example:

```sh
python3 tools/video/import_real_capture.py \
  --key video-look-automatic-build131 \
  --image '/absolute/path/to/actual-build131-screen.png' \
  --source 'Physical iPhone, TestFlight Build 131, 2026-10-28'
```

For an exact-build simulator capture with fixture listing data, use a source beginning `Current app simulator` and add `--fixture-content`. The importer preserves the screenshot bytes and refuses to overwrite an existing key. Assign the imported key to its scene in `visuals.json` only after checking that the screen matches the spoken instruction.

After capture, update `docs/marketing/quick-start-20261028/captures/provenance.json` and `visuals.json`, then render once. The local draft verifier currently fails because scenes 24 and 31 changed visual assignments after the last render; rendering regenerates the matching timeline and captions. Do not edit the timeline by hand to conceal stale video frames.

Render on the 128GB card to preserve signing space on the APFS volumes:

```sh
mkdir -p '/Volumes/128GB Disk/rendprop-intro-work' '/Volumes/128GB Disk/rendprop-intro-pydeps'
PIP_CACHE_DIR='/Volumes/128GB Disk/rendprop-intro-pip-cache' TMPDIR='/Volumes/128GB Disk/rendprop-intro-work' \
  python3 -m pip install --target '/Volumes/128GB Disk/rendprop-intro-pydeps' Pillow==12.3.0
PYTHONPATH='/Volumes/128GB Disk/rendprop-intro-pydeps' TMPDIR='/Volumes/128GB Disk/rendprop-intro-work' \
  python3 tools/video/build_quick_start.py --work-dir '/Volumes/128GB Disk/rendprop-intro-work' --render
python3 apps/ios/tests/run-quick-start-video.py \
  --evidence-dir '/Volumes/128GB Disk/rendprop-intro-work/qa'
```

Run these from the isolated `intro-training-20261028` checkout. After a new app archive, add `--app-bundle /path/to/Rendprop.app` to the verifier for a byte-for-byte asset check, then play the entire film on the physical iPhone and judge narration/visual alignment before committing into a release candidate.
