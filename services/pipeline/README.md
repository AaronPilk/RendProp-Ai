# Rendprop Render Pipeline

Async job orchestrated as a state machine, fanned out to GPU workers (Modal primary, RunPod batch, fal.ai offload). Every step is idempotent, checkpointed, and writes to `render_step_costs`. Full spec: Master Build Prompt Parts 6, 28, 35, Appendix A/F.

## State machine

```
created → uploaded → validating → queued → ingesting → stabilizing →
interpolating → grading → [upscaling] → segmenting → [generating_hero] →
stitching → encoding → packaging → publishing → ready

Terminal: failed(step, reason) | needs_reshoot(quality) | canceled | expired | archived
```

A failed `upscaling` retries upscaling — never the whole chain. Dead-letter after N attempts. Per-job cost ceiling pauses + alerts if exceeded.

## Steps (engine per step)

| Step | Engine | Notes |
|---|---|---|
| validate/QC | ffprobe + heuristics | blur/shake/exposure score; below threshold → needs_reshoot (cheap; refund render credit) |
| ingest | ffmpeg | normalize color, fix rotation, split audio |
| stabilize | **Gyroflow** (gyro sidecar) / vidstab fallback | the #1 handheld→drone lever; drone clips skip |
| interpolate | RIFE/FILM → 60fps | Topaz for problem footage |
| grade | ffmpeg eq + hqdn3d + LUT | brand LUT per org |
| upscale (tier) | Topaz self-hosted | 4K near-$0 marginal |
| segment | chapter timestamps | room rail |
| hero gen (tier) | Seedance/Veo/Kling i2v | 8–15s, seeded from REAL frame, $5 ceiling, drop if drift |
| stitch | ffmpeg | labels are player overlays, never baked |
| encode | x264 / svt-av1 | scrub proxy + playback renditions |
| package | HLS + sprite/VTT + poster + OG | |
| publish | Cloudflare Stream + R2 | flip listing to ready, fire render.ready |

## Encode recipes (Appendix A)

```bash
# Scrub proxy — instant seek, mobile/webview-safe (540–720p, all-intra-ish)
ffmpeg -i graded.mp4 -vf scale=-2:720 -c:v libx264 -profile:v high -pix_fmt yuv420p \
  -g 3 -keyint_min 3 -sc_threshold 0 -crf 28 -an -movflags +faststart proxy_720.mp4

# Playback 1080p (H.264 fallback; AV1 via svt-av1 preferred where supported)
ffmpeg -i stitched.mp4 -vf scale=-2:1080 -c:v libx264 -profile:v high -pix_fmt yuv420p \
  -g 12 -keyint_min 12 -sc_threshold 0 -crf 21 -movflags +faststart playback_1080.mp4

# Stabilize without gyro (2-pass vidstab)
ffmpeg -i in.mp4 -vf vidstabdetect=shakiness=8:accuracy=15 -f null -
ffmpeg -i in.mp4 -vf vidstabtransform=smoothing=30:input=transforms.trf,unsharp=5:5:0.8 out.mp4

# Grade/denoise starting point
-vf hqdn3d,eq=brightness=0.02:contrast=1.06:saturation=1.08:gamma=0.98
```

## Anti-patterns (Part 38)

Never full-length generative. Never a single monolithic 4K MP4. Never bake room labels into the video. Never skip the gyro sidecar path.
