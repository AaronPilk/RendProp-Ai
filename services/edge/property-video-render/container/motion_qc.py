"""Temporal motion QC: what a viewer sees in the final property-video frame.

Profile temporal-motion-v1 is read-only. It measures walking-cadence bob,
shake, horizon roll, travel and duplicated frames in pixels of the final
1920x1080 (or 1080x1920) frame, after the same scale + centre crop the composer
applies, never on the provider's uncropped frame. Motion per frame step comes
from phase correlation on a grid of tiles at half output resolution and a
robust similarity fit (translation, rotation, scale) about the frame centre.

The existing drift QC looks at three stills, so it cannot see any of this.
No customer/media path is interpolated into a filter expression.
"""
from __future__ import annotations

import json
import math
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

PROFILE = "temporal-motion-v1"
ANALYSIS_DOWNSCALE = 2      # analyse at half output resolution
TILE = 128                  # analysis pixels per tile side (256 final pixels)
WHITEN = .6                 # partial phase whitening; measured 0.03-0.05 px tile error
SMOOTH_SECONDS = .25        # camera path low-pass; faster motion is bob/shake
MIN_TILE_STD = 4.0
MIN_PEAK_RATIO = 15.0
MIN_INLIERS = 6
DUPLICATE_MAD = .25         # mean absolute grey difference of an exact repeat

# Limits for a FINISHED shot, in final-frame pixels and degrees. The 13 AI
# shots of rejected job c40f4860 measure 1.3-12.8 px of 3 Hz bob with this
# module; gimbal/slider reference listings measured 0.1-0.3 px (in-browser, a
# comparable band). These are new checks; nothing existing is relaxed.
FINISHED_LIMITS = {
    "bob_pp_px": 1.2,          # vertical bob, 2-98 percentile span
    "sway_pp_px": 1.2,         # horizontal sway
    "cadence_acf": .4,         # walking rhythm: periodic 1.5-6 Hz motion...
    "cadence_min_pp_px": .6,   # ...only counts when it is also visible
    "roll_wobble_pp_deg": .08,
    "roll_drift_deg": 1.0,     # horizon tilt accumulated over the shot
    "duplicate_ratio": .01,
    "zoom_pct": 40.0,          # beyond this a push-in reads as walking into the room
    "pan_pct": 20.0,
    "invalid_ratio": .1,
}


class MotionError(Exception):
    pass


def framing(aspect):
    if aspect not in {"16:9", "9:16"}:
        raise MotionError("closed_aspect_required")
    return (1920, 1080) if aspect == "16:9" else (1080, 1920)


def probe_stream(path: Path):
    out = subprocess.run([shutil.which("ffprobe"), "-v", "error", "-select_streams", "v:0", "-count_packets",
                          "-show_entries", "stream=width,height,r_frame_rate,avg_frame_rate,nb_read_packets",
                          "-of", "json", str(path)], check=True, capture_output=True, timeout=60).stdout
    streams = json.loads(out).get("streams", [])
    if len(streams) != 1:
        raise MotionError("one_video_stream_required")
    return streams[0]


def native_fps(stream) -> float:
    num, den = (int(v) for v in stream["avg_frame_rate"].split("/"))
    if not den or not num:
        num, den = (int(v) for v in stream["r_frame_rate"].split("/"))
    if not den or not num:
        raise MotionError("frame_rate_unknown")
    return num / den


def framed_gray_frames(path: Path, width: int, height: int, max_frames: int | None = None):
    """Yields the final framing at half resolution as uint8 grey frames."""
    w, h = width // ANALYSIS_DOWNSCALE, height // ANALYSIS_DOWNSCALE
    filters = (f"scale={width}:{height}:force_original_aspect_ratio=increase,crop={width}:{height},"
               f"scale={w}:{h}:flags=area,format=gray")
    args = [shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-i", str(path),
            "-map", "0:v:0", "-an", "-vf", filters]
    if max_frames:
        args += ["-frames:v", str(max_frames)]
    args += ["-f", "rawvideo", "-pix_fmt", "gray", "-"]
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    size = w * h
    try:
        while True:
            data = process.stdout.read(size)
            if len(data) < size:
                break
            yield np.frombuffer(data, np.uint8).reshape(h, w)
    finally:
        process.stdout.close()
        error = process.stderr.read()
        process.stderr.close()
        if process.wait(timeout=120) != 0:
            raise MotionError("decode_failed: " + error.decode(errors="replace")[:200])


def tile_centres(height, width):
    nx, ny = max(2, round(width / 160)), max(2, round(height / 160))
    margin = TILE // 2 + 8
    xs, ys = np.linspace(margin, width - margin, nx), np.linspace(margin, height - margin, ny)
    return np.array([(int(round(x)), int(round(y))) for y in ys for x in xs])


_WINDOW = np.outer(np.hanning(TILE), np.hanning(TILE)).astype(np.float64)


def _tiles(frame, centres):
    half = TILE // 2
    return np.stack([frame[y - half:y + half, x - half:x + half] for x, y in centres]).astype(np.float64)


def _subpixel(m, z, p):
    """Gaussian peak interpolation, parabolic where a neighbour is not positive."""
    gaussian = (m > 0) & (z > 0) & (p > 0)
    lm, lz, lp = (np.log(np.where(gaussian, v, 1.0)) for v in (m, z, p))
    dg = lm - 2 * lz + lp
    dp = m - 2 * z + p
    g = np.where(np.abs(dg) > 1e-12, .5 * (lm - lp) / np.where(np.abs(dg) > 1e-12, dg, 1), 0.0)
    q = np.where(np.abs(dp) > 1e-12, .5 * (m - p) / np.where(np.abs(dp) > 1e-12, dp, 1), 0.0)
    return np.clip(np.where(gaussian, g, q), -1, 1)


_KY = np.fft.fftfreq(TILE)[:, None]
_KX = np.fft.rfftfreq(TILE)[None, :]


def _peak(corr):
    n = corr.shape[0]
    rows = np.arange(n)
    py, px = np.divmod(corr.reshape(n, -1).argmax(axis=1), TILE)
    peak = corr[rows, py, px]
    dy = py + _subpixel(corr[rows, (py - 1) % TILE, px], peak, corr[rows, (py + 1) % TILE, px])
    dx = px + _subpixel(corr[rows, py, (px - 1) % TILE], peak, corr[rows, py, (px + 1) % TILE])
    return np.where(dx > TILE / 2, dx - TILE, dx), np.where(dy > TILE / 2, dy - TILE, dy), peak


def tile_shifts(a, b, refinements=2):
    """Content displacement of each tile from frame a to frame b, and confidence.

    Peak interpolation pulls sub-pixel shifts toward whole pixels (a 0.03 deg
    per frame roll read ~22% low), so the estimate is refined by re-centring
    the cross-power spectrum on it and measuring what remains.
    """
    std = np.minimum(a.std(axis=(1, 2)), b.std(axis=(1, 2)))
    a = (a - a.mean(axis=(1, 2), keepdims=True)) * _WINDOW
    b = (b - b.mean(axis=(1, 2), keepdims=True)) * _WINDOW
    cross = np.fft.rfft2(b) * np.conj(np.fft.rfft2(a))
    cross /= np.abs(cross) ** WHITEN + 1e-9
    corr = np.fft.irfft2(cross, s=(TILE, TILE))
    n = corr.shape[0]
    dx, dy, peak = _peak(corr)
    for _ in range(refinements):
        ramp = np.exp(2j * np.pi * (_KX[None] * dx[:, None, None] + _KY[None] * dy[:, None, None]))
        rx, ry, _ = _peak(np.fft.irfft2(cross * ramp, s=(TILE, TILE)))
        dx, dy = dx + rx, dy + ry
    # Peak-to-mean ratio: real interior tiles measure 27-238, unrelated noise 7-10.
    ratio = peak / (np.abs(corr).reshape(n, -1).mean(axis=1) + 1e-12)
    ok = (std >= MIN_TILE_STD) & (ratio >= MIN_PEAK_RATIO)
    return np.stack([dx, dy], 1), ok


def fit_similarity(vectors, positions, ok):
    """v = t + a*p + b*perp(p) about the frame centre. Returns (tx, ty, a, b, inliers)."""
    index = np.flatnonzero(ok)
    solution = None
    for _ in range(4):
        if index.size < MIN_INLIERS:
            return None
        p, v = positions[index], vectors[index]
        design = np.zeros((2 * index.size, 4))
        design[0::2, 0] = 1; design[0::2, 2] = p[:, 0]; design[0::2, 3] = -p[:, 1]
        design[1::2, 1] = 1; design[1::2, 2] = p[:, 1]; design[1::2, 3] = p[:, 0]
        target = v.reshape(-1)
        solution = np.linalg.lstsq(design, target, rcond=None)[0]
        residual = np.hypot(*(design @ solution - target).reshape(-1, 2).T)
        keep = residual <= max(.35, 3 * float(np.median(residual)))
        if keep.all():
            break
        index = index[keep]
    if index.size < MIN_INLIERS:
        return None
    return (*solution, int(index.size))


def measure_steps(path: Path, aspect="16:9", max_frames=None):
    """Per frame step: content motion in FINAL pixels (dx, dy), rotation rad, scale-1."""
    width, height = framing(aspect)
    steps, previous, centres, positions, previous_tiles = [], None, None, None, None
    for frame in framed_gray_frames(path, width, height, max_frames):
        if previous is None:
            h, w = frame.shape
            centres = tile_centres(h, w)
            positions = centres.astype(np.float64) - np.array([w / 2, h / 2])
            previous, previous_tiles = frame, _tiles(frame, centres)
            continue
        tiles = _tiles(frame, centres)
        vectors, ok = tile_shifts(previous_tiles, tiles)
        fit = fit_similarity(vectors, positions, ok)
        mad = float(np.abs(frame.astype(np.int16) - previous.astype(np.int16)).mean())
        if fit is None:
            steps.append({"valid": False, "mad": mad})
        else:
            tx, ty, a, b, inliers = fit
            steps.append({"valid": True, "dx": tx * ANALYSIS_DOWNSCALE, "dy": ty * ANALYSIS_DOWNSCALE,
                          "rot": b, "scale": a, "inliers": inliers, "mad": mad})
        previous, previous_tiles = frame, tiles
    if len(steps) < 8:
        raise MotionError("too_few_frames")
    return steps


def gaussian_smooth(series, sigma):
    """Low-pass with point-reflected ends, so a steady glide is kept as is."""
    values = np.asarray(series, dtype=np.float64)
    if sigma <= 0 or values.size < 3:
        return values.copy()
    radius = int(math.ceil(3 * sigma))
    kernel = np.exp(-.5 * (np.arange(-radius, radius + 1) / sigma) ** 2)
    kernel /= kernel.sum()
    pad = min(radius, values.size - 1)
    left = 2 * values[0] - values[pad:0:-1]
    right = 2 * values[-1] - values[-2:-pad - 2:-1]
    padded = np.concatenate([left, values, right])
    if pad < radius:  # very short clip: extend flat
        padded = np.concatenate([np.full(radius - pad, padded[0]), padded, np.full(radius - pad, padded[-1])])
    return np.convolve(padded, kernel, mode="valid")


def camera_path(steps):
    """Exact composition of per-step similarities about the centre: log-scale, angle, translation."""
    n = len(steps)
    valid = np.array([s["valid"] for s in steps])
    keys = ("dx", "dy", "rot", "scale")
    series = {}
    for key in keys:
        raw = np.array([s.get(key, np.nan) if s["valid"] else np.nan for s in steps], dtype=np.float64)
        if valid.any() and not valid.all():  # bridge isolated unmeasured steps
            good = np.flatnonzero(valid)
            raw[~valid] = np.interp(np.flatnonzero(~valid), good, raw[good])
        series[key] = np.nan_to_num(raw)
    log_scale, angle, tx, ty = [0.0], [0.0], [0.0], [0.0]
    for i in range(n):
        s, th = 1 + series["scale"][i], series["rot"][i]
        c, k = math.cos(th), math.sin(th)
        x, y = tx[-1], ty[-1]
        tx.append(s * (c * x - k * y) + series["dx"][i])
        ty.append(s * (k * x + c * y) + series["dy"][i])
        log_scale.append(log_scale[-1] + math.log(max(s, 1e-6)))
        angle.append(angle[-1] + th)
    return {"log_scale": np.array(log_scale), "angle": np.array(angle), "x": np.array(tx), "y": np.array(ty),
            "step_dx": series["dx"], "step_dy": series["dy"], "valid": valid}


def _span(values):
    return float(np.percentile(values, 98) - np.percentile(values, 2)) if values.size else 0.0


def _cadence(residual, fps):
    """Strongest periodic rhythm between 1.5 and 6 Hz in a residual path.

    Uses the step-to-step velocity of the high-passed path, so slow wander is
    not mistaken for rhythm, and only a local autocorrelation peak counts.
    """
    r = np.diff(residual)
    r = r - r.mean()
    energy = float((r * r).sum())
    if energy <= 1e-9:
        return 0.0, None
    low, high = max(2, int(round(fps / 6))), int(round(fps / 1.5))
    acf = {lag: float((r[:-lag] * r[lag:]).sum()) / energy for lag in range(low - 1, high + 2) if 0 < lag < r.size - 4}
    best, best_lag = 0.0, None
    for lag in range(low, high + 1):
        if lag in acf and lag - 1 in acf and lag + 1 in acf and acf[lag] >= acf[lag - 1] and acf[lag] >= acf[lag + 1] and acf[lag] > best:
            best, best_lag = acf[lag], lag
    return best, (fps / best_lag if best_lag else None)


def summarize(steps, fps, aspect="16:9"):
    width, height = framing(aspect)
    path = camera_path(steps)
    sigma = SMOOTH_SECONDS * fps
    smooth = {key: gaussian_smooth(path[key], sigma) for key in ("x", "y", "angle", "log_scale")}
    ex, ey = path["x"] - smooth["x"], path["y"] - smooth["y"]
    eth, els = path["angle"] - smooth["angle"], path["log_scale"] - smooth["log_scale"]
    cadence_y, hz_y = _cadence(ey, fps)
    cadence_x, hz_x = _cadence(ex, fps)
    cadence, cadence_hz = (cadence_y, hz_y) if cadence_y >= cadence_x else (cadence_x, hz_x)
    moving = [s for s in steps if s["valid"]]
    still = [s for s in moving if s["mad"] < DUPLICATE_MAD and math.hypot(s["dx"], s["dy"]) < .1
             and abs(s["scale"]) < 2e-4 and abs(s["rot"]) < 2e-4]
    typical_mad = float(np.median([s["mad"] for s in steps])) if steps else 0.0
    static_shot = typical_mad < DUPLICATE_MAD
    diagonal = math.hypot(width, height) / 2
    speed = (np.hypot(np.diff(smooth["x"]), np.diff(smooth["y"])) + diagonal * np.abs(np.diff(smooth["log_scale"])))
    middle = speed[int(.1 * speed.size): max(int(.1 * speed.size) + 1, int(.9 * speed.size))]
    mean_speed = float(middle.mean()) if middle.size else 0.0
    metrics = {
        "profile": PROFILE, "fps": round(fps, 4), "steps": len(steps), "frame": [width, height],
        "invalid_ratio": round(1 - len(moving) / len(steps), 4),
        "bob_pp_px": round(_span(ey), 3), "bob_rms_px": round(float(np.sqrt((ey ** 2).mean())), 3),
        "sway_pp_px": round(_span(ex), 3), "sway_rms_px": round(float(np.sqrt((ex ** 2).mean())), 3),
        "cadence_acf": round(cadence, 3), "cadence_hz": None if cadence_hz is None else round(cadence_hz, 2),
        "roll_wobble_pp_deg": round(math.degrees(_span(eth)), 4),
        "roll_drift_deg": round(math.degrees(float(smooth["angle"][-1] - smooth["angle"][0])), 3),
        "roll_span_deg": round(math.degrees(float(smooth["angle"].max() - smooth["angle"].min())), 3),
        "zoom_pump_pp_pct": round(100 * _span(els), 3),
        "zoom_pct": round(100 * (math.exp(float(path["log_scale"][-1])) - 1), 2),
        "pan_x_pct": round(100 * float(path["x"][-1]) / width, 2),
        "pan_y_pct": round(100 * float(path["y"][-1]) / height, 2),
        "speed_px_per_frame": round(mean_speed, 3),
        "speed_cv": round(float(middle.std() / mean_speed), 3) if mean_speed > .2 else 0.0,
        "duplicate_ratio": 0.0 if static_shot else round(len(still) / len(steps), 4),
        "static_shot": bool(static_shot),
    }
    return metrics, path, smooth


def verdict(metrics, limits=FINISHED_LIMITS):
    """Closed reasons a finished shot is not smooth enough to publish."""
    reasons = []
    if metrics["invalid_ratio"] > limits["invalid_ratio"]:
        reasons.append("unmeasurable")
    if metrics["bob_pp_px"] > limits["bob_pp_px"]:
        reasons.append("vertical_bob")
    if metrics["sway_pp_px"] > limits["sway_pp_px"]:
        reasons.append("lateral_sway")
    if (metrics["cadence_acf"] >= limits["cadence_acf"]
            and max(metrics["bob_pp_px"], metrics["sway_pp_px"]) > limits["cadence_min_pp_px"]):
        reasons.append("walking_cadence")
    if metrics["roll_wobble_pp_deg"] > limits["roll_wobble_pp_deg"]:
        reasons.append("roll_wobble")
    if abs(metrics["roll_drift_deg"]) > limits["roll_drift_deg"]:
        reasons.append("horizon_roll")
    if metrics["duplicate_ratio"] > limits["duplicate_ratio"]:
        reasons.append("duplicate_frames")
    if metrics["zoom_pct"] > limits["zoom_pct"] or math.hypot(metrics["pan_x_pct"], metrics["pan_y_pct"]) > limits["pan_pct"]:
        reasons.append("walk_through_travel")
    return {"profile": PROFILE, "pass": not reasons, "reasons": reasons}


def measure(path: Path, aspect="16:9", series=False, max_frames=None):
    stream = probe_stream(path)
    fps = native_fps(stream)
    steps = measure_steps(path, aspect, max_frames)
    metrics, camera, smooth = summarize(steps, fps, aspect)
    report = {"metrics": metrics, "verdict": verdict(metrics)}
    if series:
        report["series"] = {"dy": [round(float(v), 3) for v in camera["step_dy"]],
                            "dx": [round(float(v), 3) for v in camera["step_dx"]],
                            "bob_y": [round(float(v), 3) for v in camera["y"] - smooth["y"]],
                            "angle_deg": [round(math.degrees(float(v)), 4) for v in camera["angle"]]}
    return report


if __name__ == "__main__":
    arguments = sys.argv[1:]
    aspect = "9:16" if "--social" in arguments else "16:9"
    for item in [a for a in arguments if not a.startswith("--")]:
        print(json.dumps({"clip": Path(item).name, **measure(Path(item), aspect, series="--series" in arguments)}))
