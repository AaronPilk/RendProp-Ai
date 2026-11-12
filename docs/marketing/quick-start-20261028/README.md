# Complete first-listing guide

The iOS app bundles `RendpropQuickStart.mp4` and an offline transcript. This
guide has 38 narrated scenes in eight chapters and teaches a first listing in
practical order: navigation, listing details, photos and reviewed AI edits,
photo video, optional aerial opening and recorded walkthrough, property-site
publishing, Leads, Activity, plans, credits and Team. Floor plans and 3D
capture are described only as later features.

## Authentic visual source

- `scenes.json` is the exact narration and instruction order.
- `visuals.json` assigns one to three **actual app or property-site captures**
  to every scene. `captures/provenance.json` records the source device/build and
  original and checked-in SHA-256 hashes. The foreground UI is never drawn or
  simulated by the renderer. Some simulator captures contain test-fixture
  listing data; these illustrate actual controls, not a customer property.
- `captions.vtt` and `timeline.json` are generated from the duration of each
  ElevenLabs Faye audio file in the owner-selected voice. The MP4 has eight chapter
  markers. The bundled transcript is available inside the app.
- `voice/scene-XX.mp3` preserves all 38 audio masters. Its provenance
  manifest pins each file hash to the exact narration text, voice and model.

The owner rejected the earlier illustrated/Samantha cut. `build_quick_start.py`
requires the checked-in real captures and 38 checked-in ElevenLabs scene files;
it has **no system-voice fallback**. The local render does not call a provider
or spend credits.

## Rebuild

Use an external volume for audio originals and intermediate frames:

```sh
python3 -m pip install --target /external/pydeps Pillow==12.3.0
PYTHONPATH=/external/pydeps TMPDIR=/external/work \
  python3 tools/video/build_quick_start.py \
  --work-dir /external/work --render
python3 apps/ios/tests/run-quick-start-video.py \
  --evidence-dir /external/qa
```

`voice/` contains `scene-01.mp3` through `scene-38.mp3`, generated with the
selected ElevenLabs Faye v4 Turbo voice from the corresponding narration text.
The final MP4 and transcript are copied into
`apps/ios/Rendprop/Resources`. Source captures and sidecars are in this
directory. The QA check verifies capture provenance, the exact media streams,
chapter/timeline sync, picture/audio decode, and bundled asset byte identity
when supplied an app bundle. Physical-iPhone playback and instructional
judgment remain separate release checks.
