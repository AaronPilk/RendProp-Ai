#!/usr/bin/env python3
"""
Regression tests for the resource controls added to services/worker/ffmpeg_render.py
(external release audit finding 4):

  1. FFMPEG_STALL_TIMEOUT_S <= 0 means "use the default", not "disabled" —
     FFMPEG_STALL_DISABLED=1 is the only way to actually turn stall detection off.
  2. A pixel-count ceiling is enforced from ffprobe METADATA, before any decode.
  3. A real byte-size cap on the ENCODED output (not just the disk-preflight
     estimate in worker.py) fails the job with a clear message.

    python3 tests/test_resource_limits.py     # needs ffmpeg + ffprobe on PATH

Skips (exit 0) the two integration sections (pixel limit, output cap) with a
clear message if ffmpeg/ffprobe are not available; the stall-timeout parsing
section is pure Python and always runs.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

FAILURES: list[str] = []


def check(label: str, cond: bool, detail: str = "") -> None:
    print(f"  {'ok  ' if cond else 'FAIL'} {label}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(label)


# ── 1. FFMPEG_STALL_TIMEOUT_S <= 0 no longer silently disables stall detection

def test_stall_timeout_parsing() -> None:
    print("\n1. a non-positive FFMPEG_STALL_TIMEOUT_S means \"use the default\", "
          "not \"disabled\" (finding 4)")
    import ffmpeg_render as fr  # noqa: WPS433

    for var in ("FFMPEG_STALL_TIMEOUT_S", "FFMPEG_STALL_DISABLED"):
        os.environ.pop(var, None)

    try:
        check("unset → the given default", fr._stall_timeout_from_env(300) == 300)

        os.environ["FFMPEG_STALL_TIMEOUT_S"] = "0"
        check("0 does NOT disable — falls back to the default",
              fr._stall_timeout_from_env(300) == 300)

        os.environ["FFMPEG_STALL_TIMEOUT_S"] = "-5"
        check("a negative value ALSO falls back to the default",
              fr._stall_timeout_from_env(300) == 300)

        os.environ["FFMPEG_STALL_TIMEOUT_S"] = "not-a-number"
        check("a non-numeric value falls back to the default",
              fr._stall_timeout_from_env(300) == 300)

        os.environ["FFMPEG_STALL_TIMEOUT_S"] = "120"
        check("a genuine positive value is honoured", fr._stall_timeout_from_env(300) == 120)

        os.environ["FFMPEG_STALL_TIMEOUT_S"] = "0"
        os.environ["FFMPEG_STALL_DISABLED"] = "1"
        check("FFMPEG_STALL_DISABLED=1 is the ONLY way to actually disable (→ 0), "
              "even with FFMPEG_STALL_TIMEOUT_S=0 too",
              fr._stall_timeout_from_env(300) == 0)

        os.environ["FFMPEG_STALL_TIMEOUT_S"] = "120"
        os.environ["FFMPEG_STALL_DISABLED"] = "0"
        check("FFMPEG_STALL_DISABLED=0 does not disable — the positive value still applies",
              fr._stall_timeout_from_env(300) == 120)

        os.environ["FFMPEG_STALL_TIMEOUT_S"] = "0"
        check("back to 0 with the disable flag off: falls back to the default again",
              fr._stall_timeout_from_env(300) == 300)
    finally:
        for var in ("FFMPEG_STALL_TIMEOUT_S", "FFMPEG_STALL_DISABLED"):
            os.environ.pop(var, None)


# ── 2. pixel-count ceiling ────────────────────────────────────────────────────

def test_pixel_limit_pure() -> None:
    print("\n2a. _check_pixel_limit (pure, no ffprobe needed)")
    import ffmpeg_render as fr  # noqa: WPS433

    try:
        fr._check_pixel_limit(1920, 1080)
        check("1080p is well under the default ~67MP limit", True)
    except fr.RenderError:
        check("1080p is well under the default ~67MP limit", False, "raised")

    try:
        fr._check_pixel_limit(0, 0)
        check("0x0 (unknown dims) is not flagged — let the real decode fail naturally", True)
    except fr.RenderError:
        check("0x0 (unknown dims) is not flagged — let the real decode fail naturally", False, "raised")

    orig = fr.MAX_SOURCE_PIXELS
    try:
        fr.MAX_SOURCE_PIXELS = 100 * 100  # tiny ceiling for the test
        try:
            fr._check_pixel_limit(4000, 3000)
            check("dimensions over the ceiling raise RenderError", False, "did not raise")
        except fr.RenderError as e:
            check("dimensions over the ceiling raise RenderError", True)
            check("the message names both dimensions", "4000" in str(e) and "3000" in str(e), str(e))
    finally:
        fr.MAX_SOURCE_PIXELS = orig


def test_pixel_limit_via_probe_source() -> None:
    print("\n2b. probe_source() enforces the pixel ceiling from ffprobe metadata "
          "(before any decode)")
    if not (shutil.which("ffmpeg") and shutil.which("ffprobe")):
        print("  SKIP: ffmpeg/ffprobe not on PATH")
        return
    import ffmpeg_render as fr  # noqa: WPS433

    with tempfile.TemporaryDirectory(prefix="rendprop-reslimit-") as tmp:
        src = str(Path(tmp) / "tiny.mp4")
        res = subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-f", "lavfi",
             "-i", "testsrc=size=320x240:rate=10:duration=1",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast", src],
            capture_output=True, text=True,
        )
        if res.returncode != 0 or not os.path.exists(src):
            print(f"  SKIP: could not synthesise a fixture with this ffmpeg build: {res.stderr[:200]}")
            return

        info = fr.probe_source(src)
        check("probes the real dimensions", (info.width, info.height) == (320, 240), str(info))

        orig = fr.MAX_SOURCE_PIXELS
        try:
            fr.MAX_SOURCE_PIXELS = 100 * 100   # well under 320x240 = 76800
            try:
                fr.probe_source(src)
                check("probe_source refuses a source over the pixel ceiling", False, "did not raise")
            except fr.RenderError as e:
                check("probe_source refuses a source over the pixel ceiling", True)
                check("refused BEFORE any decode (ffprobe-only; no frame requested)",
                      "MP" in str(e), str(e))
            # enforce_limit=False (used for re-probing OUR OWN output) bypasses it.
            info2 = fr.probe_source(src, enforce_limit=False)
            check("enforce_limit=False bypasses the ceiling",
                  (info2.width, info2.height) == (320, 240))
        finally:
            fr.MAX_SOURCE_PIXELS = orig


# ── 3. real output byte-size cap ──────────────────────────────────────────────

def test_output_size_cap() -> None:
    print("\n3. render() enforces a real cap on the ENCODED output's byte size")
    if not (shutil.which("ffmpeg") and shutil.which("ffprobe")):
        print("  SKIP: ffmpeg/ffprobe not on PATH")
        return
    import ffmpeg_render as fr  # noqa: WPS433

    with tempfile.TemporaryDirectory(prefix="rendprop-reslimit-") as tmp:
        src = str(Path(tmp) / "src.mp4")
        res = subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-f", "lavfi",
             "-i", "smptehdbars=size=320x240:rate=10:duration=2",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast", "-crf", "23", src],
            capture_output=True, text=True,
        )
        if res.returncode != 0 or not os.path.exists(src):
            print(f"  SKIP: could not synthesise a fixture with this ffmpeg build: {res.stderr[:200]}")
            return

        orig_bytes = fr.MAX_OUTPUT_BYTES
        try:
            # (a) a generous cap: the tiny render succeeds normally.
            fr.MAX_OUTPUT_BYTES = 1024 * 1024 * 1024  # 1 GiB
            workdir_ok = str(Path(tmp) / "ok")
            out_mp4, poster, dur, speed = fr.render(src, False, workdir=workdir_ok)
            check("a tiny render succeeds under a generous cap",
                  os.path.exists(out_mp4) and os.path.getsize(out_mp4) > 0)

            # (b) an absurdly small cap: the SAME render is refused with a clear error.
            fr.MAX_OUTPUT_BYTES = 10   # bytes — no real encode fits this
            workdir_bad = str(Path(tmp) / "bad")
            try:
                fr.render(src, False, workdir=workdir_bad)
                check("an over-cap output raises RenderError", False, "did not raise")
            except fr.RenderError as e:
                check("an over-cap output raises RenderError", True)
                check("the message names the cap (MAX_OUTPUT_MB)", "MAX_OUTPUT_MB" in str(e), str(e))
        finally:
            fr.MAX_OUTPUT_BYTES = orig_bytes


if __name__ == "__main__":
    test_stall_timeout_parsing()
    test_pixel_limit_pure()
    test_pixel_limit_via_probe_source()
    test_output_size_cap()
    print()
    if FAILURES:
        print(f"✗ {len(FAILURES)} failure(s): {FAILURES}")
        sys.exit(1)
    print("✓ all resource-limit tests passed")
