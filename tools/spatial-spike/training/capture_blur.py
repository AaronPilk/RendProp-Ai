#!/usr/bin/env python3
"""Capture motion-blur diagnostics: rotational smear predicted from ARKit poses.

Pure, deterministic helpers. Nothing here trains, reconstructs or contacts a
network. The predicted smear is a first-order rotational model
(fx * radians(omega * exposure)); translation blur and rolling shutter are not
modelled. Sharpness is the population variance of the signed 3x3 Laplacian
(4-neighbour, valid region) of the grayscale centre crop. Note: the 2026-09-24
diagnostic filtered with Pillow's 8-bit kernel, which clips negative responses
to 0 and copies the crop border unfiltered, so its lap_var values are lower and
biased by border brightness. This version uses maximum adjacent rotation instead
of cancellation-prone central differences; sparse samples remain uncertified.
"""

import argparse
import io
import json
import math
from pathlib import Path
import sys

from prepare_capture import (CaptureError, capture_file, finite_number, matrix, read_bytes,
                             read_json, require, validate_pose)

LAPLACIAN_KERNEL = ((0, 1, 0), (1, -4, 1), (0, 1, 0))
SMEAR_THRESHOLDS_PX = (5.0, 10.0, 20.0)
ONE_SIXTIETH = 1.0 / 60.0
DEFAULT_BLUR_POLICY = {"max_median_px": 4.0, "max_fraction_over_px": [5.0, 0.35]}
MAX_MOTION_INTERVAL_SECONDS = 0.1


def _pose_of(frame):
    pose = frame.get("camera_to_world", frame.get("pose"))
    require(pose is not None, "frame needs camera_to_world (or pose)")
    return validate_pose(pose)


def rotation_angle_deg(pose_a, pose_b):
    """Geodesic angle between two camera-to-world rotations, in degrees."""
    a, b = validate_pose(pose_a), validate_pose(pose_b)
    relative = [[sum(a[k][i] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
    cosine = (sum(relative[i][i] for i in range(3)) - 1.0) / 2.0
    axis = [relative[2][1] - relative[1][2], relative[0][2] - relative[2][0], relative[1][0] - relative[0][1]]
    return math.degrees(math.atan2(math.sqrt(sum(v*v for v in axis)) / 2.0, cosine))


def angular_speed_deg_s(frames):
    """Conservative adjacent-motion proxy; opposing directions never cancel.

    Sparse saved poses cannot certify instantaneous exposure motion. blur_rows
    reports gaps separately and prefers verifiable consecutive-frame telemetry.
    """
    require(isinstance(frames, (list, tuple)) and len(frames) >= 2, "angular speed needs at least 2 frames")
    poses = [_pose_of(frame) for frame in frames]
    times = [finite_number(frame.get("timestamp"), "timestamp") for frame in frames]
    require(all(later > earlier for earlier, later in zip(times, times[1:])), "timestamps must strictly increase")
    last = len(frames) - 1
    speeds = []
    for index in range(len(frames)):
        neighbors = [other for other in (index - 1, index + 1) if 0 <= other <= last]
        speeds.append(max(rotation_angle_deg(poses[index], poses[other]) / abs(times[other] - times[index])
                          for other in neighbors))
    return speeds


def predicted_smear_px(omega_deg_s, exposure_s, fx):
    """First-order rotational smear in pixels: fx * radians(omega * exposure)."""
    omega = finite_number(omega_deg_s, "angular speed")
    exposure = finite_number(exposure_s, "exposure")
    focal = finite_number(fx, "fx")
    require(omega >= 0 and 0 < exposure < 1 and focal > 0, "angular speed must be >= 0, exposure in (0,1), fx > 0")
    return focal * math.radians(omega * exposure)


def laplacian_variance(source, centre_crop=0.5):
    """Variance of the 3x3 Laplacian over the centre crop of the grayscale image.

    ``source`` is JPEG bytes, a path, or an already decoded PIL image. Signed
    float responses over the valid interior; no clipping, no border copy.
    """
    try:
        import numpy
        from PIL import Image
    except ImportError as exc:
        raise CaptureError("Sharpness diagnostics additionally require numpy; install requirements-adapter.txt and numpy") from exc
    fraction = finite_number(centre_crop, "centre_crop")
    require(0 < fraction <= 1, "centre_crop must be in (0, 1]")
    try:
        if isinstance(source, Image.Image):
            image = source
        elif isinstance(source, (bytes, bytearray)):
            image = Image.open(io.BytesIO(bytes(source)))
        else:
            image = Image.open(io.BytesIO(read_bytes(source)))
        image.load()
        grey = image.convert("L")
    except (OSError, ValueError) as exc:
        raise CaptureError(f"cannot decode image for sharpness: {exc}") from exc
    width, height = grey.size
    left, top = int(width * (1 - fraction) / 2), int(height * (1 - fraction) / 2)
    right, bottom = left + max(3, int(width * fraction)), top + max(3, int(height * fraction))
    right, bottom = min(right, width), min(bottom, height)
    require(right - left >= 3 and bottom - top >= 3, "image too small for a 3x3 Laplacian")
    pixels = numpy.asarray(grey.crop((left, top, right, bottom)), dtype=numpy.float64)
    response = (-4 * pixels[1:-1, 1:-1] + pixels[:-2, 1:-1] + pixels[2:, 1:-1]
                + pixels[1:-1, :-2] + pixels[1:-1, 2:])
    return float(response.var())


def percentile(values, fraction):
    """Linear-interpolated percentile (numpy default) on a copy; fraction in [0, 1]."""
    require(len(values) > 0, "percentile of an empty sequence")
    ordered = sorted(values)
    rank = fraction * (len(ordered) - 1)
    low = math.floor(rank)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (rank - low)


def pearson(xs, ys):
    """Pearson r, or None when undefined (fewer than 3 pairs or zero variance)."""
    if len(xs) < 3 or len(xs) != len(ys):
        return None
    mean_x, mean_y = sum(xs) / len(xs), sum(ys) / len(ys)
    sxx = sum((x - mean_x) ** 2 for x in xs)
    syy = sum((y - mean_y) ** 2 for y in ys)
    if sxx <= 1e-12 or syy <= 1e-12:  # Constant (to rounding) series: undefined.
        return None
    sxy = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys))
    r = sxy / math.sqrt(sxx * syy)
    return r if math.isfinite(r) else None


def blur_rows(entries):
    """Per-frame rows from entries: {source, camera_to_world|pose, timestamp,
    exposure_duration_seconds, fx[, sharpness]}. Order is capture order."""
    speeds = angular_speed_deg_s(entries)
    rows = []
    for index, (entry, omega) in enumerate(zip(entries, speeds)):
        exposure = finite_number(entry.get("exposure_duration_seconds"), "exposure_duration_seconds")
        require(0 < exposure < 1, "exposure_duration_seconds must be in (0, 1) s")
        fx = finite_number(entry.get("fx"), "fx")
        neighbors = [j for j in (index - 1, index + 1) if 0 <= j < len(entries)]
        known = all(0 < abs(entries[j]["timestamp"] - entry["timestamp"]) <= MAX_MOTION_INTERVAL_SECONDS
                    for j in neighbors)
        source = "adjacent_pose_proxy" if known else "unknown_sparse_pose_gap"
        telemetry_keys = ("motion_previous_timestamp", "motion_previous_camera_to_world",
                          "angular_speed_deg_s", "predicted_smear_px")
        if any(entry.get(key) is not None for key in telemetry_keys):
            # A recorded scalar alone cannot establish sample rate or prevent
            # gap/reversal underestimation. Bind it to the recorded pose pair.
            require(all(entry.get(key) is not None for key in telemetry_keys), "incomplete full-rate motion telemetry")
            previous_time = finite_number(entry["motion_previous_timestamp"], "motion previous timestamp")
            interval = entry["timestamp"] - previous_time
            require(previous_time >= 0 and 0 < interval <= MAX_MOTION_INTERVAL_SECONDS,
                    "motion sample gap is unavailable")
            omega = rotation_angle_deg(entry["motion_previous_camera_to_world"], _pose_of(entry)) / interval
            recorded_omega = finite_number(entry["angular_speed_deg_s"], "recorded angular speed")
            recorded_smear = finite_number(entry["predicted_smear_px"], "recorded smear")
            require(math.isclose(recorded_omega, omega, rel_tol=1e-5, abs_tol=1e-5) and
                    math.isclose(recorded_smear, predicted_smear_px(omega, exposure, fx), rel_tol=1e-5, abs_tol=1e-5),
                    "motion telemetry does not match pose, exposure and calibration")
            known, source = True, "validated_consecutive_pose_telemetry"
        row = {"index": index, "source": entry.get("source"), "timestamp": entry["timestamp"],
               "exposure_duration_seconds": exposure, "angular_speed_deg_s": omega, "fx": fx,
               "predicted_smear_px": predicted_smear_px(omega, exposure, fx),
               "motion_known": known, "motion_source": source}
        sharpness = entry.get("sharpness")
        if sharpness is not None:
            row["laplacian_variance"] = finite_number(sharpness, "sharpness")
        rows.append(row)
    return rows


def summarize(rows):
    require(len(rows) > 0, "blur summary of zero frames")
    speeds = [row["angular_speed_deg_s"] for row in rows]
    smear = [row["predicted_smear_px"] for row in rows]
    exposures = [row["exposure_duration_seconds"] for row in rows]
    histogram = {}
    for exposure in exposures:
        key = f"{exposure * 1000:.3f}"
        histogram[key] = histogram.get(key, 0) + 1
    summary = {
        "frames": len(rows),
        "angular_speed_deg_s": {"median": percentile(speeds, 0.5), "p90": percentile(speeds, 0.9),
                                "max": max(speeds)},
        "exposure_median_ms": percentile(exposures, 0.5) * 1000,
        "exposure_histogram_ms": dict(sorted(histogram.items(), key=lambda item: float(item[0]))),
        "frames_exposure_ge_1_60": sum(1 for e in exposures if e >= ONE_SIXTIETH - 1e-9),
        "predicted_smear_px": {"median": percentile(smear, 0.5), "p75": percentile(smear, 0.75),
                               "p90": percentile(smear, 0.9), "max": max(smear)},
        "frames_over_px": {f"{t:g}": sum(1 for s in smear if s > t) for t in SMEAR_THRESHOLDS_PX},
        "unknown_motion_frames": sum(row.get("motion_known") is not True for row in rows),
        "model": "rotational proxy only: max adjacent angular speed or validated consecutive-pose telemetry; sparse gaps unknown",
    }
    sharpness = [row["laplacian_variance"] for row in rows if "laplacian_variance" in row]
    if len(sharpness) == len(rows):
        summary["sharpness_laplacian_variance"] = {"median": percentile(sharpness, 0.5),
                                                   "p10": percentile(sharpness, 0.1),
                                                   "p90": percentile(sharpness, 0.9)}
        pairs = [(math.log(s), math.log(v)) for s, v in zip(smear, sharpness) if s > 0 and v > 0]
        summary["corr_log_smear_log_sharpness"] = pearson([p[0] for p in pairs], [p[1] for p in pairs])
    return summary


def validate_policy(policy):
    require(isinstance(policy, dict) and set(policy) <= {"max_median_px", "max_fraction_over_px"} and policy,
            "blur_policy keys must be max_median_px and/or max_fraction_over_px")
    result = {}
    if "max_median_px" in policy:
        value = policy["max_median_px"]
        require(type(value) in (int, float) and math.isfinite(value) and value > 0,
                "blur_policy max_median_px must be a positive number")
        result["max_median_px"] = float(value)
    if "max_fraction_over_px" in policy:
        pair = policy["max_fraction_over_px"]
        require(isinstance(pair, (list, tuple)) and len(pair) == 2 and
                all(type(v) in (int, float) and math.isfinite(v) for v in pair) and
                pair[0] > 0 and 0 <= pair[1] <= 1,
                "blur_policy max_fraction_over_px must be [threshold_px > 0, fraction in 0..1]")
        result["max_fraction_over_px"] = [float(pair[0]), float(pair[1])]
    return result


def check_policy(summary, policy):
    """Raise CaptureError('capture too blurred: ...') when the summary exceeds the policy."""
    policy = validate_policy(policy)
    failures = []
    if summary.get("unknown_motion_frames", 0):
        failures.append("motion/exposure evidence unavailable; recapture with current capture guidance")
    median = summary["predicted_smear_px"]["median"]
    if "max_median_px" in policy and median > policy["max_median_px"]:
        failures.append(f"median predicted smear {median:.2f} px > {policy['max_median_px']:g} px")
    if "max_fraction_over_px" in policy:
        threshold, limit = policy["max_fraction_over_px"]
        over = summary.get("_frames_over_threshold")
        fraction = over / summary["frames"]
        if fraction > limit:
            failures.append(f"{over}/{summary['frames']} frames ({100 * fraction:.1f}%) over {threshold:g} px "
                            f"> {100 * limit:.1f}%")
    require(not failures, "capture too blurred: " + "; ".join(failures))


def evaluate_policy(rows, policy):
    policy = validate_policy(policy)
    summary = summarize(rows)
    if "max_fraction_over_px" in policy:
        threshold = policy["max_fraction_over_px"][0]
        summary["_frames_over_threshold"] = sum(1 for row in rows if row["predicted_smear_px"] > threshold)
    try:
        check_policy(summary, policy)
    finally:
        summary.pop("_frames_over_threshold", None)
    return summary


def select_sharp_frames(rows, max_px, min_frames):
    """Diagnostic selection only: retain original eval IDs, filter training only.

    This is not export permission: the pinned trainer's positional loader
    cannot consume a thinned cohort while keeping these explicit memberships.
    """
    limit = finite_number(max_px, "sharp-only max px")
    require(limit > 0, "sharp-only max px must be positive")
    require(type(min_frames) is int and min_frames >= 1, "min_frames must be a positive integer")
    require([row.get("index") for row in rows] == list(range(len(rows))), "selection requires original ordered frame IDs")
    kept = [row for row in rows if row["index"] % 8 == 0 or
            (row.get("motion_known") is True and finite_number(row["predicted_smear_px"], "predicted smear") <= limit)]
    dropped = [row for row in rows if row not in kept]
    require(len(kept) >= min_frames,
            f"sharp-only selection keeps {len(kept)} of {len(rows)} frames under {limit:g} px; need {min_frames}")
    return kept, dropped


def capture_entries(capture_root, with_sharpness=True):
    """Read manifest + sidecars (+ JPEGs for sharpness) into blur entries; read-only."""
    root = Path(capture_root).resolve()
    manifest = read_json(root / "manifest.json")
    sidecars = manifest.get("frames")
    require(isinstance(sidecars, list) and all(isinstance(s, str) for s in sidecars) and len(sidecars) >= 2,
            "manifest frames must list at least 2 sidecars")
    entries = []
    for sidecar in sidecars:
        metadata = read_json(capture_file(root, sidecar, ".json"))
        k = matrix(metadata.get("intrinsics"), 3, "intrinsics")
        entry = {"source": sidecar, "camera_to_world": validate_pose(metadata.get("camera_to_world")),
                 "timestamp": finite_number(metadata.get("timestamp"), "timestamp"),
                 "exposure_duration_seconds": finite_number(metadata.get("exposure_duration_seconds"),
                                                            "exposure_duration_seconds"),
                 "fx": k[0][0]}
        entry.update({key: metadata.get(key) for key in ("motion_previous_timestamp", "motion_previous_camera_to_world",
                                                        "angular_speed_deg_s", "predicted_smear_px")})
        if with_sharpness:
            entry["sharpness"] = laplacian_variance(capture_file(root, metadata.get("image"), ".jpg"))
        entries.append(entry)
    return entries


def blur_report(capture_root, with_sharpness=True):
    """Per-frame rows plus summary for one capture directory. Reads only."""
    rows = blur_rows(capture_entries(capture_root, with_sharpness))
    return {"format": "rendprop-capture-blur-report", "schema_version": 1,
            "summary": summarize(rows), "rows": rows}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--no-sharpness", action="store_true", help="skip JPEG decoding; poses only")
    parser.add_argument("--rows", action="store_true", help="print per-frame rows, not only the summary")
    args = parser.parse_args(argv)
    try:
        report = blur_report(args.capture, with_sharpness=not args.no_sharpness)
        if not args.rows:
            report.pop("rows")
        print(json.dumps(report, indent=2, allow_nan=False))
        return 0
    except (CaptureError, OSError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
