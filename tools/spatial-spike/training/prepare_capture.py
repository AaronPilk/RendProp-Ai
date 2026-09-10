#!/usr/bin/env python3
"""Validate one local ARKit capture and export a posed gsplat binary dataset.

No COLMAP executable, reconstruction, pose fitting, cloud API or GPU is used.
The point cloud is an initialization hint measured/estimated by ARKit, not a
claim that camera poses themselves constitute a reconstructed surface.
"""

import argparse
import hashlib
import io
import json
import math
from pathlib import Path, PurePosixPath
import struct
import sys
import uuid


GSPLAT_COMMIT = "937e29912570c372bed6747a5c9bf85fed877bae"
PYCOLMAP_COMMIT = "cc7ea4b7301720ac29287dbe450952511b32125e"
CONVENTIONS = {
    "schema_version": 1,
    "format": "rendprop-arkit-capture",
    "image_orientation": "sensor-native-exif-1",
    "coordinate_system": "arkit-right-handed-y-up-camera-minus-z-forward",
    "matrix_layout": "row-major",
    "pose_type": "camera-to-world",
    "units": "metres",
    "world_alignment": "gravity",
    "status": "complete",
}


class CaptureError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise CaptureError(message)


def finite_number(value, label):
    require(type(value) in (int, float) and math.isfinite(value), f"{label}: finite number required")
    return float(value)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path):
    def reject_constant(value):
        raise CaptureError(f"non-finite JSON value: {value}")
    try:
        result = json.loads(path.read_text(), object_pairs_hook=unique_object,
                            parse_constant=reject_constant)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise CaptureError(f"cannot read JSON {path}: {exc}") from exc
    require(isinstance(result, dict), f"{path}: expected JSON object")
    return result


def capture_file(root, relative, suffix):
    require(isinstance(relative, str) and relative, "capture path must be a nonempty string")
    path = PurePosixPath(relative)
    require(not path.is_absolute() and ".." not in path.parts and "\\" not in relative,
            f"unsafe capture path: {relative}")
    require(path.suffix.lower() == suffix, f"expected {suffix} file: {relative}")
    resolved = (root / relative).resolve()
    require(resolved.is_relative_to(root) and resolved.is_file(), f"missing/outside capture file: {relative}")
    return resolved


def matrix(value, size, label):
    require(isinstance(value, list) and len(value) == size, f"{label}: expected {size} rows")
    require(all(isinstance(row, list) and len(row) == size for row in value),
            f"{label}: expected {size} columns")
    return [[finite_number(x, label) for x in row] for row in value]


def validate_pose(value):
    pose = matrix(value, 4, "camera_to_world")
    require(all(abs(pose[3][i] - [0, 0, 0, 1][i]) < 1e-6 for i in range(4)),
            "camera_to_world: invalid homogeneous row (possibly transposed)")
    rotation = [row[:3] for row in pose[:3]]
    for i in range(3):
        for j in range(3):
            dot = sum(rotation[k][i] * rotation[k][j] for k in range(3))
            require(abs(dot - (1 if i == j else 0)) < 1e-3, "camera_to_world: non-rigid rotation")
    a, b, c = rotation
    determinant = (a[0] * (b[1]*c[2] - b[2]*c[1]) -
                   a[1] * (b[0]*c[2] - b[2]*c[0]) +
                   a[2] * (b[0]*c[1] - b[1]*c[0]))
    require(abs(determinant - 1) < 1e-3, "camera_to_world: reflected rotation")
    return pose


def world_to_cv(pose):
    """Inverse(T_arkit @ diag(1,-1,-1,1)); do not flip the world axes."""
    signs = (1, -1, -1)
    rotation = [[signs[r] * pose[c][r] for c in range(3)] for r in range(3)]
    translation = [-sum(rotation[r][c] * pose[c][3] for c in range(3)) for r in range(3)]
    return rotation, translation


def rotation_quaternion(r):
    """Hamilton scalar-first quaternion, including stable 180-degree branches."""
    trace = r[0][0] + r[1][1] + r[2][2]
    if trace > 0:
        s = 2 * math.sqrt(trace + 1)
        q = [s / 4, (r[2][1]-r[1][2])/s, (r[0][2]-r[2][0])/s, (r[1][0]-r[0][1])/s]
    else:
        i = max(range(3), key=lambda k: r[k][k])
        j, k = (i + 1) % 3, (i + 2) % 3
        s = 2 * math.sqrt(1 + r[i][i] - r[j][j] - r[k][k])
        q = [0.0] * 4
        q[0] = (r[k][j] - r[j][k]) / s
        q[i+1], q[j+1], q[k+1] = s/4, (r[j][i]+r[i][j])/s, (r[k][i]+r[i][k])/s
    norm = math.sqrt(sum(x*x for x in q))
    return [x/norm for x in q]


def project(position, pose, intrinsics):
    rotation, translation = world_to_cv(pose)
    x, y, z = [sum(rotation[r][c] * position[c] for c in range(3)) + translation[r] for r in range(3)]
    if z <= 0:
        return None
    return (intrinsics[0][0] * x/z + intrinsics[0][2],
            intrinsics[1][1] * y/z + intrinsics[1][2])


def jpeg_pixels(path, width, height):
    # Geometry/serialization stay stdlib-only. Pillow decodes actual JPEG bytes;
    # trusting filename/sidecar dimensions would miss the orientation failure.
    try:
        from PIL import Image
    except ImportError as exc:
        raise CaptureError("Pillow is required: python -m pip install -r requirements-adapter.txt") from exc
    content = path.read_bytes()
    try:
        with Image.open(io.BytesIO(content)) as image:
            require(image.format == "JPEG", f"not JPEG bytes: {path.name}")
            require(image.size == (width, height), f"JPEG/metadata dimensions mismatch: {path.name}")
            require(image.getexif().get(274) == 1, f"JPEG must explicitly use EXIF orientation 1: {path.name}")
            image.load()  # Truncated image bytes must fail, not pass a header check.
            rgb = image.convert("RGB")
    except (OSError, ValueError) as exc:
        raise CaptureError(f"invalid JPEG {path.name}: {exc}") from exc
    return rgb, hashlib.sha256(content).hexdigest()


def load_capture(root, min_frames=20, min_points=100):
    require(min_frames >= 2 and min_points >= 4, "minimums must be at least 2 frames and 4 points")
    root = Path(root).resolve()
    manifest = read_json(root / "manifest.json")
    for key, expected in CONVENTIONS.items():
        require(type(manifest.get(key)) is type(expected) and manifest.get(key) == expected,
                f"manifest {key} must equal {expected!r}")
    session_id = manifest.get("session_id")
    try:
        require(isinstance(session_id, str), "session_id must be a UUID string")
        uuid.UUID(session_id)
    except (ValueError, AttributeError) as exc:
        raise CaptureError("session_id must be a UUID string") from exc
    sidecars = manifest.get("frames")
    require(isinstance(sidecars, list) and min_frames <= len(sidecars) <= 400,
            f"capture requires {min_frames}–400 frames")
    require(all(isinstance(p, str) for p in sidecars) and len(set(sidecars)) == len(sidecars),
            "duplicate or invalid frame sidecars")
    frames, seeds, used_images, seen_sidecars = [], {}, set(), set()
    previous_time, raster_size, observed = -1.0, None, 0
    for sidecar in sidecars:
        path = capture_file(root, sidecar, ".json")
        require(path not in seen_sidecars, "duplicate resolved sidecar path")
        seen_sidecars.add(path)
        metadata = read_json(path)
        require(type(metadata.get("schema_version")) is int and metadata["schema_version"] == 1,
                "sidecar schema_version must be 1")
        require(metadata.get("session_id") == session_id, "mixed ARSession coordinate epochs")
        require(metadata.get("tracking_state") == {"state": "normal", "reason": None},
                "all saved frames must have normal tracking state")
        timestamp = finite_number(metadata.get("timestamp"), "timestamp")
        require(timestamp > previous_time and timestamp >= 0, "timestamps must strictly increase")
        previous_time = timestamp
        pose = validate_pose(metadata.get("camera_to_world"))
        resolution = metadata.get("image_resolution")
        require(isinstance(resolution, dict), "image_resolution object required")
        width, height = resolution.get("width"), resolution.get("height")
        require(all(type(v) is int and 1 <= v <= 16384 for v in (width, height)) and width*height <= 50000000,
                "invalid image dimensions")
        require(raster_size is None or raster_size == (width, height), "variable raster size unsupported by pinned parser")
        raster_size = (width, height)
        k = matrix(metadata.get("intrinsics"), 3, "intrinsics")
        require(k[0][0] > 0 and k[1][1] > 0 and 0 <= k[0][2] < width and 0 <= k[1][2] < height,
                "invalid focal length/principal point")
        require(all(abs(k[r][c] - expected) < 1e-6 for r, c, expected in
                    ((0, 1, 0), (1, 0, 0), (2, 0, 0), (2, 1, 0), (2, 2, 1))),
                "intrinsics must be an unrotated pinhole matrix")
        image_path = capture_file(root, metadata.get("image"), ".jpg")
        require(image_path not in used_images, "duplicate JPEG reference")
        used_images.add(image_path)
        rgb, image_hash = jpeg_pixels(image_path, width, height)
        points = metadata.get("raw_feature_points")
        require(isinstance(points, list), "raw_feature_points array required (poses alone provide no seeds)")
        require(len(points) <= 50000, "more than 50,000 feature points in one frame; refusing without truncation")
        ids_in_frame = set()
        for point in points:
            require(isinstance(point, dict), "invalid feature point")
            identifier = point.get("id")
            require(isinstance(identifier, str) and identifier.isascii() and identifier.isdecimal()
                    and str(int(identifier)) == identifier and int(identifier) < 2**64,
                    "feature point id must be a canonical UInt64 decimal string")
            require(identifier not in ids_in_frame, "duplicate feature id within one frame")
            ids_in_frame.add(identifier)
            position = point.get("position")
            require(isinstance(position, list) and len(position) == 3, "feature point position must have 3 values")
            position = [finite_number(value, "feature point") for value in position]
            observed += 1
            uv = project(position, pose, k)
            if uv is not None and 0 <= uv[0] < width and 0 <= uv[1] < height:
                # Latest visible estimate and its same-frame pixel remain paired.
                # These are projected color samples, NOT measured 2D feature tracks.
                seeds[identifier] = {"position": position, "rgb": rgb.getpixel((int(uv[0]), int(uv[1])))}
        frames.append({"pose": pose, "intrinsics": k, "width": width, "height": height,
                       "source": image_path, "sha256": image_hash, "timestamp": timestamp})
    require(type(manifest.get("feature_point_observations")) is int
            and manifest["feature_point_observations"] == observed,
            "manifest feature_point_observations does not match sidecars")
    # Coincident points make the upstream nearest-neighbor scale initialization
    # degenerate. Preserve one estimate per micrometre cell, record the reduction.
    distinct = {}
    for identifier in sorted(seeds, key=int):
        seed = seeds[identifier]
        cell = tuple(round(v, 6) for v in seed["position"])
        distinct.setdefault(cell, {"source_id": identifier, **seed})
    require(len(distinct) >= min_points,
            f"only {len(distinct)} distinct visible ARKit seeds; need {min_points}; poses alone are insufficient")
    locations = [[frame["pose"][axis][3] for axis in range(3)] for frame in frames]
    center = [sum(p[i] for p in locations) / len(locations) for i in range(3)]
    radius = max(math.dist(p, center) for p in locations)
    require(radius >= 0.05, "camera translation radius below 5 cm; pure rotation cannot initialize scene scale")
    return {"root": root, "session_id": session_id, "frames": frames,
            "seeds": list(distinct.values()), "camera_radius_m": radius,
            "point_observations": observed, "visible_point_ids": len(seeds)}


def summary(capture):
    return {"session_id": capture["session_id"], "frames": len(capture["frames"]),
            "initial_points": len(capture["seeds"]), "camera_radius_m": capture["camera_radius_m"],
            "point_observations": capture["point_observations"],
            "visible_point_ids": capture["visible_point_ids"], "gpu_training_performed": False}


def write_dataset(capture, output):
    output = Path(output).resolve()
    require(not output.exists(), "output already exists; choose a new directory")
    require(not output.is_relative_to(capture["root"]), "output must be outside the capture directory")
    output.mkdir(parents=True)
    image_dir, sparse_dir = output / "images", output / "sparse" / "0"
    image_dir.mkdir()
    sparse_dir.mkdir(parents=True)
    frames, seeds = capture["frames"], capture["seeds"]
    for index, frame in enumerate(frames, start=1):
        content = frame["source"].read_bytes()
        require(hashlib.sha256(content).hexdigest() == frame["sha256"], "JPEG changed after validation")
        with (image_dir / f"{index:06d}.jpg").open("xb") as stream:
            stream.write(content)
    with (sparse_dir / "cameras.bin").open("xb") as stream:
        stream.write(struct.pack("<Q", len(frames)))
        for index, frame in enumerate(frames, start=1):
            k = frame["intrinsics"]
            # PINHOLE model id 1; one camera per frame preserves per-frame K.
            stream.write(struct.pack("<IiQQ4d", index, 1, frame["width"], frame["height"],
                                     k[0][0], k[1][1], k[0][2], k[1][2]))
    with (sparse_dir / "images.bin").open("xb") as stream:
        stream.write(struct.pack("<Q", len(frames)))
        for index, frame in enumerate(frames, start=1):
            rotation, translation = world_to_cv(frame["pose"])
            stream.write(struct.pack("<I4d3dI", index, *rotation_quaternion(rotation), *translation, index))
            stream.write(f"{index:06d}.jpg".encode() + b"\x00")
            stream.write(struct.pack("<Q", 0))  # No invented feature observations.
    with (sparse_dir / "points3D.bin").open("xb") as stream:
        stream.write(struct.pack("<Q", len(seeds)))
        for index, seed in enumerate(seeds, start=1):
            # ERROR=0 is an unused format placeholder; no BA residual was measured.
            stream.write(struct.pack("<Q3d3BdQ", index, *seed["position"], *seed["rgb"], 0.0, 0))
    report = {"format": "rendprop-posed-gsplat-dataset", "schema_version": 1,
              "gsplat_commit": GSPLAT_COMMIT, **summary(capture),
              "world_space": "unchanged ARKit world in metres, y up",
              "camera_conversion": "c2w_cv = c2w_arkit @ diag(1,-1,-1,1)",
              "initialization": "ARKit rawFeaturePoints; not COLMAP/SfM; no measured 2D feature tracks",
              "reprojection_error_measured": False,
              "image_sha256": {f"{i:06d}.jpg": f["sha256"] for i, f in enumerate(frames, start=1)},
              "model_sha256": {name: hashlib.sha256((sparse_dir / name).read_bytes()).hexdigest()
                               for name in ("cameras.bin", "images.bin", "points3D.bin")}}
    # Last file is the completion marker; a partial export never has one.
    with (output / "adapter-report.json").open("x") as stream:
        json.dump(report, stream, indent=2, allow_nan=False)
        stream.write("\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--output", type=Path, help="new local directory; omit to validate only")
    args = parser.parse_args()
    try:
        capture = load_capture(args.capture)
        report = write_dataset(capture, args.output) if args.output else summary(capture)
        print(json.dumps(report, indent=2, allow_nan=False))
        return 0
    except (CaptureError, OSError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
