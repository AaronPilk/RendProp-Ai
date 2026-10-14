# Private property-video CPU renderer

This dedicated Worker controls two fixed Durable Object CPU slots. Supabase
`property-video-worker` owns jobs, current account/library/source permissions,
provider dispatch, cost settlement and final output registration. This service
does **not** publish a property site or issue a provider request.

The controller advances `/tick` with `slot-0` / `slot-1`, sleeps between provider
checks, and starts a `standard-3` container only for extracting three actual
frames or composing a ready batch. CPU output is retained in the private
container until `/outputs` admits its measured storage size and supplies the
exact master/poster PUT capabilities. After upload, the measured `/finish`
receipt is persisted before the fenced backend callback. The CPU is destroyed
before callback retries. An interrupted lease takes `/failure`; it never
fabricates success or retries a billable supplier POST.

## Media and rendering

- No provider, Supabase administrator or R2 account credential enters the
  container. Its random token only authenticates the private DO-to-CPU port.
- Internet is disabled. The controller's HTTPS intercept permits only the exact
  signed GET/PUT URL, method, expiry and byte count supplied by the authority.
  Redirects, alternate paths/hosts and forwarded Authorization are refused.
- 1..100 immutable ordered sources; one normalizer / two transition decoders at
  once. Temporary inputs are deleted after normalization. Inputs, output sizes,
  disk admission and CPU watchdog are bounded.
- Actual 1920×1080 listing / 1080×1920 social H.264 at 30fps, CRF18, max 24Mbps VBV,
  faststart. No blurred panels or padding; inadequate actual source pixels and
  unnormalized HDR/rotation are refused instead of silently enlarged/tagged.
- Original-photo fallback is explicit provenance and a restrained3% real-photo
  push, only when the source retains sufficient pixels. It is not claimed to be
  an AI-generated drone shot.
- Cut / dissolve / slide-left whip, social title+mark, three shot-caption styles
  and timed spoken words are carried into encoded pixels. 30fps rounds native
  0.28/0.18s overlaps to 8/5 frames; the backend receives measured final duration.
  This is option parity, not a claim of pixel-identical native typography.
- Narration is retained at full speed, padded after its actual duration, never
  truncated to fit. Approved CC0 tracks start Off, loop/trim to final length,
  play at 0.18 and duck to 0.07 during narration. Output is limited below clipping.
  Exact catalog audio/license evidence SHA values are checked before mixing.
- Docker installs Liberation Sans2 under the SIL Open Font License. Its license
  remains in Debian's package documentation. No SF/Apple font is redistributed.
  Primary license: https://github.com/liberationfonts/liberation-fonts/blob/main/LICENSE

## Local gates

`npm ci --ignore-scripts && npm run verify` runs type checks, actual controller
helpers, the production DO class against explicit lifecycle/authority doubles,
  and real FFmpeg 1080 frame/audio/transition/caption tests. These doubles establish
local controller behavior, **not** a live Cloudflare Container claim.

On macOS, Homebrew FFmpeg may omit `drawtext`. Use an isolated full test encoder:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-test.txt
```

Then set `RENDER_TEST_FFMPEG` to the `imageio_ffmpeg.get_ffmpeg_exe()` path while
running the gates. Test-only macOS fonts stay local. The shipping image test must
run using Debian FFmpeg and Liberation Sans2, including the actual HTTPS CA
interceptor, streaming signed upload and API receipts.

## Root-owned activation

The checked-in service is disabled. No image or account resource was deployed.
Do not alter another account Container application. New service name:
`rendprop-property-video-render`.

1. Build the dedicated Docker image locally or through trusted CI; retain the
   image digest. Wrangler dry-run still requires a Docker-compatible CLI.
   Run the same Python suite against that exact image with `/app` on
   `PYTHONPATH`, the tests mounted read-only, and no provider credentials.
2. Set only this Worker's `EDGE_SERVICE_ROLE_KEY` and `RENDER_TRIGGER_KEY` as
   secrets. Add exact private R2 presigning hosts to `MEDIA_HOSTS`, alongside the
   Supabase host. Never place secrets in vars, test output or the container.
3. Deploy the matching backend migration/functions and validate disabled
   `/queue` / enqueue behavior. Root enables both services only after health and
   actual lease/storage registration are accepted.
4. Verify server consent/source/account revocation during work, controlled
   container interruption, uploaded-file HEAD/probe/hash, stale lease refusal,
   output registration, APNs delivery and explicit agent review/publication.
5. Run a real multi-photo job, leave the app/lock the phone after durable enqueue,
   confirm completion and notification while locked, then reopen the exact
   registered video. Do not call a local resume test a background-completion pass.
6. Measure actual 100-shot/Advanced CPU throughput before promising a finish
   time. The current watchdog is 20min; signatures/leases must cover the phase or
   be safely renewed. No synthetic-color test establishes hosted throughput.

Current direct API/config references retrieved 2026-10-14:
https://developers.cloudflare.com/containers/api/durable-object-container/
https://developers.cloudflare.com/containers/configuration/wrangler/
https://developers.cloudflare.com/containers/platform/limits/
The `durable_object` policy does not accept `max_instances`; the closed Worker
only addresses the two fixed CPU atoms instead. It stops idle containers; there
is no always-on fleet minimum.

Large selected masters use a separate `prepare_image` lease on the same two CPU slots. Pillow12.3.0 decodes only single-frame JPEG/PNG/WebP≤50MiB/100MP, bakes EXIF orientation, converts validated embedded ICC to sRGB, removes private EXIF, flattens any transparency onwhite, and produces a q97 JPEG≤2048px/8MiB. Exact original bytes and exportmaster remain untouched. Edge records master→derivative lineage and admits measured output before a single signed PUT; no browser-uploadedalias is accepted as proof. Malformed profiles/animation/expired capabilities fail with private workingcopy cleanup.

Install production Python dependency from `requirements.txt` in an isolated venv before local tests, or use the exact Docker image.
