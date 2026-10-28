# Complete first-listing guide

This is the source package for the offline training film bundled in the iOS
app as `RendpropQuickStart.mp4`. It replaces the 118-second introduction with
38 narrated scenes in eight chapters. The guide starts with navigation and
one real listing, then teaches photos and reviewed AI edits, listing video,
optional aerial/recorded walkthroughs, property-site publishing and sharing,
Leads, Activity recovery, Account, plans, credits and Team. It treats floor
plans and 3D capture as later features.

## Source and visuals

- `scenes.json`: exact narration and on-screen directions, in playback order.
- `screens/`: eight small labeled excerpts from the previously bundled app
  guide. These illustrate stable, visible controls such as the toolbox,
  listing details, Photos, saved edit review, export, music and walkthrough.
- The rendering script draws current-flow diagrams for numbered video photo
  selection, framing, Activity, credits, purchases and website designs.
  Diagrams say **illustrative** in-frame; they are not claimed to be a device
  capture. The two luxury designs follow the current source material and
  physical-iPhone Safari review, not the stale paid-site sample screenshot.
- `captions.vtt` and `timeline.json`: generated timed sidecars. The app's
  Video Guide transcript disclosure uses the complete bundled `.txt`
  narration and directions; the MP4 also carries eight chapter markers.

The script uses system fonts, the checked-in brand photographs, macOS
Samantha speech, Pillow and ffmpeg. It makes **no provider or paid API calls**.
Use an external work directory for intermediate PCM, AIFF and slide files:

```sh
python3 -m pip install --target /path/to/external/pydeps Pillow==12.3.0
PYTHONPATH=/path/to/external/pydeps TMPDIR=/path/to/external/work \
  python3 tools/video/build_quick_start.py \
  --work-dir /path/to/external/work --render
python3 apps/ios/tests/run-quick-start-video.py \
  --evidence-dir /path/to/external/qa
```

The render produces the MP4 and `.txt` in `apps/ios/Rendprop/Resources`,
plus sidecars here. The QA check verifies actual picture and audio decoding,
eight chapter timestamps, scene/transcript/caption alignment and native media
formats. An iOS build separately verifies the resources are bundled. Playback
and instructional judgment on the owner phone remain a device acceptance
step; source and simulator validation do not stand in for that review.
