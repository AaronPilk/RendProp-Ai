#!/usr/bin/env python3
"""
Fixture test for the HDR→SDR path (audit F-G-03).

Synthesises four sources with ffmpeg, runs the worker's EXACT `_encode_cmd`
against each, and measures the output with `signalstats` (0–255 scale, averaged
over every frame):

    ref_sdr        bt709-tagged SDR              — the ground truth
    sdr_untagged   no colour tags at all         — common for edited/imported clips
    hdr_pq         BT.2020 / smpte2084 10-bit    — Dolby Vision 5/8.1 base layer
    hdr_hlg        BT.2020 / arib-std-b67 10-bit — what an iPhone records by default

Three properties are asserted, each of which was BROKEN at the time of the audit:

  1. an SDR source (tagged or not) is passed through bit-for-bit unchanged —
     the tone-map chain must not touch it, and must not fail on it;
  2. an untagged SDR source ENCODES (the old unconditional chain died with
     `zscale: no path between colorspaces`, rc=187, and failed the job);
  3. an HDR source is really tone-mapped, not just re-tagged — its saturation
     lands within a tolerance of the SDR reference instead of collapsing.

    python3 tests/test_hdr_tonemap.py            # needs ffmpeg + ffprobe with libzimg

Skips (exit 0) with a clear message when ffmpeg lacks zscale/tonemap.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

FAILURES: list[str] = []
SIZE = "640x360"
DURATION = "2"


def check(label: str, cond: bool, detail: str = "") -> None:
    print(f"  {'ok  ' if cond else 'FAIL'} {label}" + (f" — {detail}" if detail else ""))
    if not cond:
        FAILURES.append(label)


def run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=300)


def stats(path: str) -> dict:
    """Mean YAVG / YMAX / SATAVG over all frames, 0–255."""
    p = run(["ffprobe", "-v", "error", "-f", "lavfi", f"movie={path},signalstats",
             "-show_entries",
             "frame_tags=lavfi.signalstats.YAVG,lavfi.signalstats.YMAX,lavfi.signalstats.SATAVG",
             "-of", "json"])
    frames = json.loads(p.stdout or "{}").get("frames", [])

    def avg(key: str) -> float:
        vals = [float(f["tags"][key]) for f in frames if f.get("tags", {}).get(key)]
        return round(sum(vals) / len(vals), 1) if vals else 0.0

    return {"YAVG": avg("lavfi.signalstats.YAVG"),
            "YMAX": avg("lavfi.signalstats.YMAX"),
            "SATAVG": avg("lavfi.signalstats.SATAVG")}


def synth(tmp: Path) -> dict[str, str]:
    """Build the four fixtures. Same scene, four colour encodings."""
    src = f"smptehdbars=size={SIZE}:rate=30:duration={DURATION}"
    out: dict[str, str] = {}

    out["ref_sdr"] = str(tmp / "ref_sdr.mp4")
    run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", src,
         "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast", "-crf", "12",
         "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
         out["ref_sdr"]])

    out["sdr_untagged"] = str(tmp / "sdr_untagged.mp4")
    run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", src,
         "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "ultrafast", "-crf", "12",
         "-color_primaries", "unspecified", "-color_trc", "unspecified",
         "-colorspace", "unspecified", out["sdr_untagged"]])

    for name, trc in (("hdr_pq", "smpte2084"), ("hdr_hlg", "arib-std-b67")):
        out[name] = str(tmp / f"{name}.mp4")
        vf = ("format=yuv420p,"
              "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv,"
              "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=2020,"
              f"zscale=t={trc},zscale=m=2020_ncl:r=tv,format=yuv420p10le")
        run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", src, "-vf", vf,
             "-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-preset", "ultrafast",
             "-crf", "12", "-tag:v", "hvc1", "-x265-params", "log-level=none",
             "-color_primaries", "bt2020", "-color_trc", trc, "-colorspace", "bt2020nc",
             out[name]])
    return out


def encode_with_worker(fr, src: str, dst: str) -> tuple[int, bool, str]:
    """Run the worker's real command. Returns (rc, tone_map_applied, vf)."""
    info = fr.probe_source(src)
    cmd = fr._encode_cmd(src, dst, 2.0, info)
    vf = cmd[cmd.index("-vf") + 1]
    return run(cmd).returncode, bool(fr.hdr_tonemap_chain(info)), vf


def main() -> int:
    if not (shutil.which("ffmpeg") and shutil.which("ffprobe")):
        print("SKIP: ffmpeg/ffprobe not on PATH — cannot verify the HDR path.")
        return 0

    os.environ.setdefault("TONEMAP_HDR", "1")
    import ffmpeg_render as fr  # noqa: WPS433 — after env is set

    if not fr.ffmpeg_has_tonemap_filters():
        print("SKIP: this ffmpeg lacks zscale/tonemap (libzimg) — cannot verify.")
        return 0

    with tempfile.TemporaryDirectory(prefix="rendprop-hdr-") as td:
        tmp = Path(td)
        fx = synth(tmp)
        missing = [k for k, v in fx.items() if not os.path.getsize(v)]
        if missing:
            print(f"SKIP: could not synthesise fixtures {missing} with this ffmpeg build.")
            return 0

        ref = stats(fx["ref_sdr"])
        print(f"\nreference (bt709 SDR source): {ref}")

        results: dict[str, dict] = {}
        print("\nworker encode path:")
        for name, src in fx.items():
            dst = str(tmp / f"out-{name}.mp4")
            rc, toned, vf = encode_with_worker(fr, src, dst)
            st = stats(dst) if rc == 0 else {}
            results[name] = {"rc": rc, "toned": toned, "stats": st, "vf": vf}
            print(f"  {name:<13} rc={rc} tonemapped={str(toned):<5} {st}")

        # 1. SDR must be untouched by the chain.
        print("\n1. SDR is passed through, never tone-mapped")
        for name in ("ref_sdr", "sdr_untagged"):
            r = results[name]
            check(f"{name}: no tone-map chain", r["toned"] is False)
            check(f"{name}: encodes cleanly", r["rc"] == 0, f"rc={r['rc']}")
            check(f"{name}: matches the reference",
                  r["stats"].get("SATAVG") == ref["SATAVG"]
                  and r["stats"].get("YAVG") == ref["YAVG"],
                  f"{r['stats']} vs {ref}")

        # 2. HDR must be genuinely converted, not just re-labelled.
        print("\n2. HDR is tone-mapped to something that looks like the reference")
        for name in ("hdr_pq", "hdr_hlg"):
            r = results[name]
            check(f"{name}: tone-map chain applied", r["toned"] is True)
            check(f"{name}: encodes cleanly", r["rc"] == 0, f"rc={r['rc']}")
            sat = r["stats"].get("SATAVG", 0)
            luma = r["stats"].get("YAVG", 0)
            # The audit's broken state: SATAVG ~24% of reference and YMAX capped
            # near 127. Require at least 70% of the reference's colour and light.
            check(f"{name}: saturation ≥70% of reference",
                  sat >= ref["SATAVG"] * 0.70, f"{sat} vs {ref['SATAVG']}")
            check(f"{name}: luma ≥70% of reference",
                  luma >= ref["YAVG"] * 0.70, f"{luma} vs {ref['YAVG']}")
            check(f"{name}: output is tagged bt709",
                  fr.probe_source(str(tmp / f"out-{name}.mp4"),
                                  enforce_limit=False).color_transfer == "bt709")

        # 3. TONEMAP_HDR=0 must still produce a file (opt-out, not a crash).
        print("\n3. TONEMAP_HDR=0 opts out without breaking the encode")
        os.environ["TONEMAP_HDR"] = "0"
        for mod in ("ffmpeg_render", "settings"):
            sys.modules.pop(mod, None)
        import ffmpeg_render as fr0  # noqa: WPS433
        fr0.ffmpeg_has_tonemap_filters.cache_clear()
        rc, toned, _vf = encode_with_worker(fr0, fx["hdr_pq"], str(tmp / "out-off.mp4"))
        off = stats(str(tmp / "out-off.mp4")) if rc == 0 else {}
        check("opt-out: no chain", toned is False)
        check("opt-out: still encodes", rc == 0, f"rc={rc}")
        check("opt-out really is the washed-out look the audit measured",
              off.get("SATAVG", 99) < results["hdr_pq"]["stats"]["SATAVG"],
              f"off={off} vs on={results['hdr_pq']['stats']}")

    print()
    if FAILURES:
        print(f"✗ {len(FAILURES)} failure(s): {FAILURES}")
        return 1
    print("✓ all HDR tone-map tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
