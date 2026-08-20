#!/usr/bin/env python3
"""
Server-side ffmpeg render — the mirror of apps/ios/Rendprop/Render/RenderEngine.swift.

Same output contract the on-device engine ships, rebuilt for the server so 4K/AI/
Stream-hosted tours look identical to the free instant path:

  • RETIME   handheld walks glide at 2×, drone clips a gentle 1.25×. Short clips
             (<12s) are sped less (≤1.5×) so they don't feel frantic — identical
             rule to RenderEngine.render(). (ffmpeg `setpts=PTS/speed`.)
  • 60 FPS   output cadence for fluid scroll-scrub (`fps=60`).
  • SCALE    ≤1280 long edge, aspect-preserved, never upscaled, even dims.
  • ALL-INTRA H.264: EVERY frame a keyframe (`-g 1 -bf 0`, x264 keyint=1) so any
             scrub position decodes exactly and instantly — the buttery scrub
             feel. Costs bitrate (~14M) but that's the whole point.
  • COLOR    tagged Rec.709 SDR so HDR/Dolby-Vision phone footage tone-maps
             instead of looking washed out. (True HDR→SDR tonemap behind
             TONEMAP_HDR — needs an ffmpeg with zscale/tonemap; see TODO.)
  • faststart moov atom up front for instant web playback.
  • Silent   the scrubbable tour has no audio track (`-an`), like RenderEngine.

Stabilization NOTE: RenderEngine's Vision-based path smoothing is on-device only.
Server-side we currently rely on the source already being reasonable and skip
stabilization (drone clips never needed it anyway). GPU stabilization
(vidstab two-pass, or a Gyroflow-grade pass) is the v3 slot — see README TODOs.

Public API:
    render(input_path, is_drone, *, workdir=None, progress=None)
        -> (output_path, poster_path, duration_s, speed_factor)
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
from collections import deque
from pathlib import Path
from typing import Callable

from settings import SETTINGS


class RenderError(RuntimeError):
    """ffmpeg/ffprobe failed, or the input is unusable."""


ProgressCB = Callable[[float], None]


# ── probing ───────────────────────────────────────────────────────────────────

def probe_duration(path: str) -> float:
    """Seconds of media, via ffprobe. Raises RenderError on failure."""
    out = subprocess.run(
        [SETTINGS.ffprobe_bin, "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nokey=1:noprint_wrappers=1", str(path)],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        raise RenderError(f"ffprobe failed for {path}: {out.stderr.strip()[:400]}")
    try:
        return float(out.stdout.strip())
    except ValueError:
        raise RenderError(f"ffprobe returned no duration for {path}")


# ── speed rule (identical to RenderEngine) ────────────────────────────────────

def speed_for(is_drone: bool, duration_s: float) -> float:
    base = 1.25 if is_drone else 2.0
    return min(base, 1.5) if duration_s < 12 else base


# ── filtergraph ───────────────────────────────────────────────────────────────

def _build_vf(speed: float) -> str:
    le = SETTINGS.encode_long_edge
    fps = SETTINGS.encode_fps
    chain = [f"setpts=PTS/{speed:.6f}", f"fps={fps}"]

    if SETTINGS.tonemap_hdr:
        # Best-effort HDR (PQ/HLG, BT.2020) → SDR Rec.709. Needs an ffmpeg built
        # with libzimg (zscale). If your build lacks it, leave TONEMAP_HDR off.
        chain += [
            "zscale=t=linear:npl=100",
            "format=gbrpf32le",
            "zscale=p=bt709",
            "tonemap=tonemap=hable:desat=0",
            "zscale=t=bt709:m=bt709:r=tv",
        ]

    # Fit inside an le×le box, aspect-preserved, never upscaled (box never exceeds
    # source dims), even dimensions. Single quotes protect the commas in min().
    chain.append(
        f"scale=w='min({le},iw)':h='min({le},ih)'"
        f":force_original_aspect_ratio=decrease:force_divisible_by=2"
    )
    chain.append("format=yuv420p")
    return ",".join(chain)


def _encode_cmd(input_path: str, output_path: str, speed: float) -> list[str]:
    br = SETTINGS.encode_bitrate
    return [
        SETTINGS.ffmpeg_bin, "-y", "-hide_banner", "-nostdin",
        "-i", str(input_path),
        "-vf", _build_vf(speed),
        "-an",                                   # silent scrubbable tour
        "-c:v", "libx264",
        "-preset", SETTINGS.encode_preset,
        "-profile:v", "high",
        "-pix_fmt", "yuv420p",
        # ALL-INTRA: keyframe every frame, no B-frames → every frame independent.
        "-g", "1", "-keyint_min", "1", "-bf", "0",
        "-x264-params", "keyint=1:min-keyint=1:scenecut=0:bframes=0:ref=1",
        "-b:v", br,                              # ~14M average (mirrors RenderEngine)
        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
        "-r", str(SETTINGS.encode_fps),
        "-movflags", "+faststart",
        "-progress", "pipe:1", "-nostats",
        str(output_path),
    ]


# ── run with progress ─────────────────────────────────────────────────────────

def _run_with_progress(cmd: list[str], expected_out_s: float, progress: ProgressCB | None) -> None:
    """Run ffmpeg, translating `-progress` output into a 0..1 callback."""
    proc = subprocess.Popen(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1
    )
    err_tail: deque[str] = deque(maxlen=40)

    def _drain_err() -> None:
        assert proc.stderr is not None
        for line in proc.stderr:
            err_tail.append(line.rstrip())

    t = threading.Thread(target=_drain_err, daemon=True)
    t.start()

    denom = max(0.05, expected_out_s) * 1_000_000.0  # microseconds
    assert proc.stdout is not None
    for line in proc.stdout:
        line = line.strip()
        if not progress:
            continue
        if line.startswith("out_time_us=") or line.startswith("out_time_ms="):
            # out_time_ms is actually microseconds in many ffmpeg builds; both keys
            # carry µs here, so the same divisor works.
            try:
                us = float(line.split("=", 1)[1])
                progress(max(0.0, min(0.999, us / denom)))
            except ValueError:
                pass
        elif line == "progress=end":
            progress(1.0)

    proc.wait()
    t.join(timeout=2)
    if proc.returncode != 0:
        raise RenderError("ffmpeg encode failed:\n" + "\n".join(err_tail))


# ── poster ────────────────────────────────────────────────────────────────────

def _extract_poster(video_path: str, poster_path: str, out_duration_s: float) -> None:
    t = min(0.6, max(0.0, out_duration_s * 0.12))
    cmd = [
        SETTINGS.ffmpeg_bin, "-y", "-hide_banner", "-nostdin",
        "-ss", f"{t:.3f}", "-i", str(video_path),
        "-frames:v", "1", "-q:v", "3", "-f", "image2", str(poster_path),
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0 or not os.path.exists(poster_path):
        raise RenderError(f"poster extraction failed: {res.stderr.strip()[:400]}")


# ── public entrypoint ─────────────────────────────────────────────────────────

def render(
    input_path: str,
    is_drone: bool,
    *,
    workdir: str | None = None,
    progress: ProgressCB | None = None,
) -> tuple[str, str, float, float]:
    """Encode a raw walkthrough into a scrubbable tour + poster.

    Returns (output_mp4_path, poster_jpg_path, duration_s, speed_factor).
    """
    workdir = workdir or os.path.dirname(os.path.abspath(input_path))
    os.makedirs(workdir, exist_ok=True)
    stem = Path(input_path).stem
    output_path = os.path.join(workdir, f"{stem}-tour.mp4")
    poster_path = os.path.join(workdir, f"{stem}-poster.jpg")

    in_duration = probe_duration(input_path)
    if not (in_duration > 0.2):
        raise RenderError(f"input too short to render ({in_duration:.3f}s)")

    speed = speed_for(is_drone, in_duration)
    expected_out_s = in_duration / speed

    _run_with_progress(_encode_cmd(input_path, output_path, speed), expected_out_s, progress)

    if not os.path.exists(output_path) or os.path.getsize(output_path) == 0:
        raise RenderError("ffmpeg produced no output file")

    out_duration = probe_duration(output_path)
    _extract_poster(output_path, poster_path, out_duration)
    return output_path, poster_path, round(out_duration, 2), round(speed, 2)


# ── manual smoke test ─────────────────────────────────────────────────────────

if __name__ == "__main__":  # pragma: no cover
    import sys

    if len(sys.argv) < 2:
        sys.exit("usage: python ffmpeg_render.py <input.mov> [--drone]")
    drone = "--drone" in sys.argv
    outp, poster, dur, spd = render(
        sys.argv[1], drone, progress=lambda p: print(f"\r  {p*100:5.1f}%", end="", flush=True)
    )
    print(f"\n→ {outp}\n→ {poster}\n  duration={dur}s speed={spd}×")
