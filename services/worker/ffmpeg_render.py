#!/usr/bin/env python3
"""
Server-side ffmpeg render — the mirror of apps/ios/Rendprop/Render/RenderEngine.swift.

Same output contract the on-device engine ships, rebuilt for the server so
AI/Stream-hosted tours look identical to the free instant path:

  • RETIME   handheld walks glide at 2×, drone clips a gentle 1.25×. Short clips
             (<12s) are sped less (≤1.5×) so they don't feel frantic — identical
             rule to RenderEngine.render(). (ffmpeg `setpts=PTS/speed`.)
  • 60 FPS   output cadence for fluid scroll-scrub (`fps=60`).
  • SCALE    ≤1280 long edge, aspect-preserved, never upscaled, even dims.
  • ALL-INTRA H.264: EVERY frame a keyframe (`-g 1 -bf 0`, x264 keyint=1) so any
             scrub position decodes exactly and instantly — the buttery scrub
             feel. Costs bitrate (~14M) but that's the whole point.
  • COLOR    the source is PROBED for HDR (PQ / HLG transfer, BT.2020 primaries).
             HDR sources get a real tone-map to Rec.709 SDR (zscale → linear →
             hable → bt709); SDR sources are passed through untouched. Output is
             tagged bt709 either way. (Audit F-G-03: re-tagging alone produced a
             grey, desaturated "HDR played as SDR" look; applying the chain to
             SDR degraded it and failed on untagged clips — so it is conditional.)
  • faststart moov atom up front for instant web playback.
  • Silent   the scrubbable tour has no audio track (`-an`), like RenderEngine.

Stabilization NOTE: RenderEngine's Vision-based path smoothing is on-device only.
Server-side we currently rely on the source already being reasonable and skip
stabilization (drone clips never needed it anyway). GPU stabilization
(vidstab two-pass, or a Gyroflow-grade pass) is the v3 slot — see README TODOs.

Public API:
    probe_source(path) -> SourceInfo
    hdr_tonemap_chain(info) -> list[str]     (shared with the AI pipeline's keyframes)
    render(input_path, is_drone, *, workdir=None, progress=None)
        -> (output_path, poster_path, duration_s, speed_factor)
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import threading
import time
from collections import deque
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Callable

from settings import SETTINGS


class RenderError(RuntimeError):
    """ffmpeg/ffprobe failed, or the input is unusable."""


ProgressCB = Callable[[float], None]


# ── resource limits (audit round 4) ──────────────────────────────────────────
# ffmpeg/ffprobe consume ATTACKER-CONTROLLED media: uploads are capped at 12 GB,
# and a crafted file can pin CPU or fill disk indefinitely. Every invocation now
# has a wall-clock timeout and is killed on breach, and sources longer than
# MAX_SOURCE_SECONDS are rejected before any transcode starts.
PROBE_TIMEOUT_S = int(os.environ.get("FFPROBE_TIMEOUT_S", "60"))
RENDER_TIMEOUT_S = int(os.environ.get("FFMPEG_TIMEOUT_S", str(90 * 60)))  # 90 min
POSTER_TIMEOUT_S = int(os.environ.get("FFMPEG_POSTER_TIMEOUT_S", "120"))
MAX_SOURCE_SECONDS = float(os.environ.get("MAX_SOURCE_SECONDS", "3600"))  # 1 h


# ── probing ───────────────────────────────────────────────────────────────────

# ffprobe → zscale option vocabularies (zimg names differ from ffmpeg's).
_ZSCALE_TRANSFER = {
    "smpte2084": "smpte2084",       # PQ (Dolby Vision profile 8.4 base layer is HLG; DV 5/8.1 are PQ)
    "arib-std-b67": "arib-std-b67",  # HLG (iPhone default HDR video)
    "bt2020-10": "2020_10",
    "bt2020-12": "2020_12",
}
_ZSCALE_PRIMARIES = {"bt2020": "2020", "bt709": "709"}
_ZSCALE_MATRIX = {"bt2020nc": "2020_ncl", "bt2020c": "2020_cl", "bt709": "709"}

HDR_TRANSFERS = frozenset({"smpte2084", "arib-std-b67"})


@dataclass(frozen=True)
class SourceInfo:
    duration_s: float
    width: int = 0
    height: int = 0
    pix_fmt: str = ""
    color_transfer: str = ""
    color_primaries: str = ""
    color_space: str = ""

    @property
    def is_hdr(self) -> bool:
        """PQ/HLG transfer, or BT.2020 primaries with a 10-bit+ pixel format."""
        if self.color_transfer in HDR_TRANSFERS:
            return True
        if self.color_primaries == "bt2020" and ("10" in self.pix_fmt or "12" in self.pix_fmt or "16" in self.pix_fmt):
            return True
        return False


def _run_ffprobe(path: str, args: list[str]) -> str:
    try:
        out = subprocess.run(
            [SETTINGS.ffprobe_bin, "-v", "error", *args, str(path)],
            capture_output=True, text=True, timeout=PROBE_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        raise RenderError(f"ffprobe timed out after {PROBE_TIMEOUT_S}s on {path}")
    except OSError as e:
        raise RenderError(f"ffprobe could not start ({SETTINGS.ffprobe_bin}): {e}")
    if out.returncode != 0:
        raise RenderError(f"ffprobe failed for {path}: {out.stderr.strip()[:400]}")
    return out.stdout


def probe_source(path: str, *, enforce_limit: bool = True) -> SourceInfo:
    """Duration + colour metadata of the first video stream. Raises RenderError."""
    raw = _run_ffprobe(path, [
        "-select_streams", "v:0",
        "-show_entries",
        "format=duration:stream=width,height,pix_fmt,color_transfer,color_primaries,color_space",
        "-of", "json",
    ])
    try:
        data = json.loads(raw or "{}")
    except ValueError:
        raise RenderError(f"ffprobe returned unparseable output for {path}")
    fmt = data.get("format") or {}
    streams = data.get("streams") or []
    stream = streams[0] if streams else {}
    try:
        seconds = float(fmt.get("duration"))
    except (TypeError, ValueError):
        raise RenderError(f"ffprobe returned no duration for {path}")
    if enforce_limit and seconds > MAX_SOURCE_SECONDS:
        raise RenderError(
            f"source is {seconds:.0f}s, longer than the {MAX_SOURCE_SECONDS:.0f}s limit — "
            "trim it before rendering"
        )

    def _s(k: str) -> str:
        v = stream.get(k)
        return str(v).strip().lower() if v not in (None, "unknown") else ""

    def _i(k: str) -> int:
        try:
            return int(stream.get(k) or 0)
        except (TypeError, ValueError):
            return 0

    return SourceInfo(
        duration_s=seconds, width=_i("width"), height=_i("height"), pix_fmt=_s("pix_fmt"),
        color_transfer=_s("color_transfer"), color_primaries=_s("color_primaries"),
        color_space=_s("color_space"),
    )


def probe_duration(path: str) -> float:
    """Seconds of media, via ffprobe (kept for callers that only need the number)."""
    return probe_source(path).duration_s


@lru_cache(maxsize=1)
def ffmpeg_has_tonemap_filters() -> bool:
    """True when this ffmpeg build has both `zscale` (libzimg) and `tonemap`."""
    try:
        out = subprocess.run([SETTINGS.ffmpeg_bin, "-hide_banner", "-filters"],
                             capture_output=True, text=True, timeout=PROBE_TIMEOUT_S)
    except (subprocess.TimeoutExpired, OSError):
        return False
    names = {line.split()[1] for line in out.stdout.splitlines() if len(line.split()) > 2}
    return "zscale" in names and "tonemap" in names


def hdr_tonemap_chain(info: SourceInfo | None) -> list[str]:
    """The HDR→SDR filter steps for THIS source, or [] when they must not run.

    Empty for SDR / untagged sources (the chain degrades SDR and errors on
    untagged input — measured in the audit), when TONEMAP_HDR=0, or when the
    ffmpeg build lacks zscale/tonemap (then the output is merely re-tagged and
    a warning is printed rather than failing the job).
    """
    if info is None or not info.is_hdr or not SETTINGS.tonemap_hdr:
        return []
    if not ffmpeg_has_tonemap_filters():
        print("    ⚠ HDR source but this ffmpeg lacks zscale/tonemap — output will look flat; "
              "install an ffmpeg built with libzimg")
        return []
    # Untagged transfer on a BT.2020 10-bit clip: assume HLG (what iPhones record).
    tin = _ZSCALE_TRANSFER.get(info.color_transfer, "arib-std-b67")
    pin = _ZSCALE_PRIMARIES.get(info.color_primaries, "2020")
    min_ = _ZSCALE_MATRIX.get(info.color_space, "2020_ncl")
    return [
        # Declare the input explicitly so partially-tagged phone clips (e.g. HLG
        # transfer with unspecified primaries) don't make zimg guess.
        f"zscale=tin={tin}:pin={pin}:min={min_}:t=linear:npl=100",
        "format=gbrpf32le",
        "zscale=p=bt709",
        "tonemap=tonemap=hable:desat=0",
        "zscale=t=bt709:m=bt709:r=tv",
    ]


# ── speed rule (identical to RenderEngine) ────────────────────────────────────

def speed_for(is_drone: bool, duration_s: float) -> float:
    base = 1.25 if is_drone else 2.0
    return min(base, 1.5) if duration_s < 12 else base


# ── filtergraph ───────────────────────────────────────────────────────────────

def _build_vf(speed: float, info: SourceInfo | None = None) -> str:
    le = SETTINGS.encode_long_edge
    fps = SETTINGS.encode_fps
    chain = [f"setpts=PTS/{speed:.6f}"]

    # Scale BEFORE fps so frames that fps= will drop aren't scaled for nothing
    # (>30 fps sources). Fit inside an le×le box, aspect-preserved, never
    # upscaled (box never exceeds source dims), even dimensions. Single quotes
    # protect the commas in min().
    chain.append(
        f"scale=w='min({le},iw)':h='min({le},ih)'"
        f":force_original_aspect_ratio=decrease:force_divisible_by=2"
    )
    chain.append(f"fps={fps}")

    # HDR → SDR, only when the probe says the source is HDR (see hdr_tonemap_chain).
    chain += hdr_tonemap_chain(info)

    chain.append("format=yuv420p")
    return ",".join(chain)


def _encode_cmd(input_path: str, output_path: str, speed: float, info: SourceInfo | None = None) -> list[str]:
    br = SETTINGS.encode_bitrate
    return [
        SETTINGS.ffmpeg_bin, "-y", "-hide_banner", "-nostdin",
        "-i", str(input_path),
        "-vf", _build_vf(speed, info),
        "-an",                                   # silent scrubbable tour
        "-c:v", "libx264",
        "-preset", SETTINGS.encode_preset,
        "-profile:v", "high",
        "-pix_fmt", "yuv420p",
        # ALL-INTRA: keyframe every frame, no B-frames → every frame independent.
        "-g", "1", "-keyint_min", "1", "-bf", "0",
        "-x264-params", "keyint=1:min-keyint=1:scenecut=0:bframes=0:ref=1",
        "-b:v", br,                              # ~14M average (mirrors RenderEngine)
        # Output really is Rec.709 SDR now (tone-mapped when the source was HDR).
        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
        "-movflags", "+faststart",
        "-progress", "pipe:1", "-nostats",
        str(output_path),
    ]


# ── run with progress ─────────────────────────────────────────────────────────

def _run_with_progress(cmd: list[str], expected_out_s: float, progress: ProgressCB | None) -> None:
    """Run ffmpeg, translating `-progress` output into a 0..1 callback.

    Hard wall-clock ceiling: the encode reads attacker-controlled media, so a
    crafted input must not be able to pin a worker forever (audit round 4). The
    ceiling is enforced by a `threading.Timer` that kills the process when it
    fires — REGARDLESS of whether ffmpeg is still emitting progress lines.
    (Audit F-G-04: the previous check only ran per stdout line, so an ffmpeg
    that blocked silently was never killed.)
    """
    started = time.monotonic()
    try:
        # Own process group so the kill reaches every process holding our pipes
        # (otherwise a lingering child could keep the stdout read blocked).
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
            start_new_session=True,
        )
    except OSError as e:
        raise RenderError(f"ffmpeg could not start ({cmd[0]}): {e}")
    err_tail: deque[str] = deque(maxlen=40)
    timed_out = threading.Event()

    def _watchdog() -> None:
        timed_out.set()
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (OSError, ProcessLookupError):
            try:
                proc.kill()
            except OSError:
                pass

    timer = threading.Timer(RENDER_TIMEOUT_S, _watchdog)
    timer.daemon = True
    timer.start()

    def _drain_err() -> None:
        assert proc.stderr is not None
        for line in proc.stderr:
            err_tail.append(line.rstrip())

    t = threading.Thread(target=_drain_err, daemon=True)
    t.start()

    denom = max(0.05, expected_out_s) * 1_000_000.0  # microseconds
    try:
        assert proc.stdout is not None
        for line in proc.stdout:
            if timed_out.is_set():
                break
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

        # Bound the final wait too — stdout can close while the process lingers.
        remaining = max(1.0, RENDER_TIMEOUT_S - (time.monotonic() - started))
        try:
            proc.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            _watchdog()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
    finally:
        timer.cancel()
        t.join(timeout=2)

    if timed_out.is_set():
        raise RenderError(
            f"ffmpeg exceeded the {RENDER_TIMEOUT_S}s render limit and was terminated"
        )
    if proc.returncode != 0:
        raise RenderError("ffmpeg encode failed:\n" + "\n".join(err_tail))


# ── poster ────────────────────────────────────────────────────────────────────

def _poster_time(out_duration_s: float) -> float:
    """~12% in, but at least 1s (skips the hand/floor at record start), and
    never past the last half-second. Tiny clips fall back to 0."""
    d = max(0.0, out_duration_s)
    return min(max(1.0, d * 0.12), max(0.0, d - 0.5))


def _extract_poster(video_path: str, poster_path: str, out_duration_s: float) -> None:
    t = _poster_time(out_duration_s)
    cmd = [
        SETTINGS.ffmpeg_bin, "-y", "-hide_banner", "-nostdin",
        "-ss", f"{t:.3f}", "-i", str(video_path),
        "-frames:v", "1", "-q:v", "3", "-f", "image2", str(poster_path),
    ]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=POSTER_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        raise RenderError(f"poster extraction timed out after {POSTER_TIMEOUT_S}s")
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

    info = probe_source(input_path)
    in_duration = info.duration_s
    if not (in_duration > 0.2):
        raise RenderError(f"input too short to render ({in_duration:.3f}s)")
    if info.is_hdr:
        tag = f"transfer={info.color_transfer or '?'} primaries={info.color_primaries or '?'} pix_fmt={info.pix_fmt or '?'}"
        if hdr_tonemap_chain(info):
            print(f"    · HDR source ({tag}) → tone-mapping to Rec.709")
        else:
            print(f"    · HDR source ({tag}) but tone-map disabled/unavailable — re-tagging only")

    speed = speed_for(is_drone, in_duration)
    expected_out_s = in_duration / speed

    _run_with_progress(_encode_cmd(input_path, output_path, speed, info), expected_out_s, progress)

    if not os.path.exists(output_path) or os.path.getsize(output_path) == 0:
        raise RenderError("ffmpeg produced no output file")

    out_duration = probe_source(output_path, enforce_limit=False).duration_s
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
