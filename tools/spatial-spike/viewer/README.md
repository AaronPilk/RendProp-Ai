# Private Phase A SOG viewer

This is local spike tooling, outside the app and tour-host. It can load a bundled
`.sog` selected on the viewing device, move the camera, and export a browser draw
submission measurement. It is **not evidence that a room was captured, trained,
or tested on a physical phone**. No room, GPU training, phone FPS, or engine winner
is claimed by the included synthetic fixture.

## Run locally

Node 22+ is required. From this directory:

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm test
npm start
```

Open <http://127.0.0.1:8093/>. The default server listens on loopback. To view from
a phone on a trusted local Wi-Fi network, run `npm start -- --host 0.0.0.0`, open
`http://<this-computer-LAN-address>:8093/` on the phone, and choose the SOG from
the phone's Files app. Stop the server when done. Do not create a public tunnel
or publish this page or the room.

The server serves an explicit list of viewer files, the pinned PlayCanvas bundle,
and its license. It does not serve directory listings, repository files, or room
artifacts; it accepts no uploads. File selection uses `File.arrayBuffer()` and
the engine's `Asset.file.contents`. SOG decoding and WebP textures stay in the
browser. No external script, telemetry, or asset host is contacted. The engine
bundle has an SRI hash in `index.html`; dependency package integrity is pinned in
`package-lock.json`. The HTTP CSP permits only the local scripts and the blob
workers/textures used for rendering.

Input admission is limited to **64 MiB encoded SOG** (inclusive), checked from
the selected `File` before `arrayBuffer()`, then checked again against the actual
byte length and existing ZIP envelope guard. The opt-in fixture response also
has a bounded streaming reader; its HTTP length is not trusted as the actual
length. After engine decode, **1–500,000 integer splats** are admitted before a
render entity is created, matching the selected Phase A trainer's Gaussian cap.
These are local spike policy limits, **not safe-device capacity measurements**.
ZIP/WebP decoding and texture allocations happen before the engine exposes the
decoded count. A small malicious SOG can still exhaust decoder/GPU memory; use
only trusted converted artifacts, not arbitrary public uploads.

Every local selection exports `provenance: "unknown"`, `synthetic: null`, and
`realRoomVerified: false`, except reserved `SYNTHETIC-NOT-A-ROOM*` filenames or
the explicit fixture button, which export `provenance: "synthetic"` and
`synthetic: true`. A filename can warn of a synthetic fixture but cannot prove a
measured room. Renaming the fixture leaves its provenance unknown, never real.
The physical-phone checkbox attests only to the device, not the artifact.

## Real phone procedure

1. Copy the private converted SOG to the physical phone and select it in this page.
2. Visually confirm it is the correct room. Drag the canvas to look; hold the
   labeled buttons to move. WASD and Q/E also work on desktop. This free camera
   has no collision or floor lock; those are outside Phase A.
3. Enter the actual model, OS version, and browser in the device field. Check
   the physical-phone box only on a physical phone. User agent alone cannot
   establish physical hardware, so the export retains both the label and this
   explicit operator attestation.
4. Record the selected resolution. The default is one framebuffer pixel per CSS
   pixel; native device pixels are selectable. Do not compare different
   resolutions as though they were the same workload.
5. Press **Record 30 seconds**, move through the scene during the five-second
   warmup and thirty-second measurement, and keep the page visible. Repeat the
   same approximate path for any engine/device comparison. Backgrounding,
   focus loss, resize, reset, context loss, or ten seconds with no onscreen draw
   invalidates an active run.
6. Export JSON. Record the room/capture identity, training GPU and minutes,
   captured frames, PLY bytes, SOG bytes, and observed reconstruction defects
   alongside it. Those training/capture facts are not manufactured by this viewer.

The counter observes nonzero WebGL 2 instanced draws to the default framebuffer
inside PlayCanvas's render, then records at most one frame on `postrender`.
The scene contains only the SOG. Empty RAF callbacks, background time, loading,
offscreen sorting passes, and warmup do not count. Missing draws during a sample
reduce throughput. FPS is `measuredIntervals / elapsedSeconds`; the first frame
anchors the clock, so `renderedFrames = measuredIntervals + 1`.

This is **draw submission throughput**, not GPU completion time or a count of
frames physically presented by the display. Median, p95, maximum inter-frame
intervals, raw intervals, canvas/CSS sizes, device pixel ratio, engine version,
asset size/count, operator label, and user agent are included. A desktop result
remains a desktop result, even if the browser emulates a phone viewport.
`valid: true` means only a valid submission measurement; it is not a Phase A
acceptance certificate, proof of visible room pixels, or a reconstruction score.

The engine load callback currently has no timeout/cancel boundary. A stalled
decode can leave selection disabled until reload, and a context loss while a
decode is pending has no generation guard against late completion. Reload after
either condition; safe asynchronous teardown is still a gate before production
embedding. A completed measurement remains exportable after input changes and
retains its original asset context: check the exported asset, not just the scene
currently visible. This spike does not implement later Phase D joystick, floor
lock, collisions, room anchors, public publishing or privacy review/blur.

## Conversion and deterministic smoke fixture

The local CLI is pinned to `@playcanvas/splat-transform` **3.4.2**:

```sh
npm run convert -- --version
npm run convert -- -g cpu /private/path/room.ply /private/path/room.sog
```

This performs format conversion, not training. Basic SOG writing supports CPU
operation. For SH-bearing inputs, CPU k-means can be slower than GPU; no-SH
inputs do not require that clustering. `--list-gpus` reports available WebGPU
adapters; `-g 0` selects an adapter when one is already available. Do not provision
a GPU, change providers, or spend money as part of running this viewer.

To smoke-test decoding without room data, create a temporary directory and pass
its actual path to the generator. The generator refuses to overwrite a file:

```sh
mktemp -d /tmp/rendprop-spatial-smoke.XXXXXX
# Replace /tmp/YOUR-DIRECTORY with the directory returned above.
node make-synthetic-fixture.mjs /tmp/YOUR-DIRECTORY/SYNTHETIC-NOT-A-ROOM.ply
npm run convert -- -g cpu /tmp/YOUR-DIRECTORY/SYNTHETIC-NOT-A-ROOM.ply /tmp/YOUR-DIRECTORY/SYNTHETIC-NOT-A-ROOM.sog
npm start -- --fixture /tmp/YOUR-DIRECTORY/SYNTHETIC-NOT-A-ROOM.sog
```

Open <http://127.0.0.1:8093/?fixture=1> and click **Load synthetic test only**.
This opt-in server route accepts only a fixture filename beginning with
`SYNTHETIC-NOT-A-ROOM`. The generated colored sphere contains 2,048 Gaussians
with no SH bands. Its conversion success and frame rate say nothing about
real-room quality or phone performance.

Before trusting the normal test output, run `npm run negative-control`. It must
exit nonzero: it deliberately asserts that an empty animation loop generated
valid FPS. Then `npm test` must pass. These tests cover counter math, the actual
production `loadFile` path with a stubbed engine, and the input-policy helpers.
They assert pre-read rejection, entity admission, cleanup and conservative
provenance; they do not exercise the real SOG decoder or WebGL. The new loader
tests were run against the unchanged loader first: 1 positive case passed and
6 intended rejections/provenance checks failed (exit 1). Browser verification
must separately prove that the synthetic SOG is
visible, actual render counts increase, movement changes the camera, and a
malformed file is refused. `window.spatialSpike.snapshot()` provides read-only
diagnostics for that verification; it cannot force a successful result.

## Versions, licenses, and engine decision

| Component | Pin | License | Purpose |
| --- | --- | --- | --- |
| PlayCanvas | 2.22.1 | MIT | Local WebGL 2 SOG viewer |
| SplatTransform | 3.4.2 | MIT | Local PLY to SOG conversion |
| Spark (evaluated in documentation, not installed) | 2.1.0 | MIT | Alternative Three.js renderer |

PlayCanvas is a provisional first viewer because its SOG implementation is
first-party, includes bundled SOG parsing, and is self-hostable as one engine
bundle. Spark 2.1.0 also supports SOG v2 and mobile controls; its official example
pins Three.js 0.180.0. No performance preference is established until both render
the same real room on representative physical phones. Streamed SOG/LOD and
Spark's RAD streaming are outside this one-room spike.

Primary sources checked 2026-09-10:

- [SOG format specification](https://developer.playcanvas.com/user-manual/gaussian-splatting/formats/sog/)
- [PlayCanvas Engine API example](https://developer.playcanvas.com/user-manual/gaussian-splatting/building/your-first-app/engine/)
- [PlayCanvas 2.22.1 SOG bundle parser](https://github.com/playcanvas/engine/blob/v2.22.1/src/framework/parsers/sog-bundle.js)
- [PlayCanvas 2.22.1 render lifecycle](https://github.com/playcanvas/engine/blob/v2.22.1/src/framework/app-base.js)
- [PlayCanvas 2.22.1 MIT license](https://github.com/playcanvas/engine/blob/v2.22.1/LICENSE)
- [SplatTransform CLI and CPU/GPU selection](https://developer.playcanvas.com/user-manual/splat-transform/)
- [SplatTransform backend GPU requirements](https://developer.playcanvas.com/user-manual/splat-transform/docker/)
- [SplatTransform 3.4.2 release](https://github.com/playcanvas/splat-transform/releases/tag/v3.4.2)
- [SplatTransform 3.4.2 MIT license](https://github.com/playcanvas/splat-transform/blob/v3.4.2/LICENSE)
- [Spark 2.1.0 release and SOG support history](https://github.com/sparkjsdev/spark/releases)
- [Spark pinned getting-started example](https://sparkjs.dev/docs/)
- [Spark SplatMesh formats and direct bytes](https://sparkjs.dev/docs/splat-mesh/)
- [Spark mobile controls](https://sparkjs.dev/docs/controls/)
- [Spark 2.1.0 MIT license](https://github.com/sparkjsdev/spark/blob/v2.1.0/LICENSE)
