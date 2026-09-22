#!/usr/bin/env python3
"""Bounded local export assembly, validation and provenance; never reconstruction.

Only explicit local paths are read. No subprocess, GPU, provider or network code.
Keep stdout/provenance private: filenames, hashes and session IDs identify media.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys

import prepare_capture as adapter
from estimate_growth import estimate_growth

# Match NativeRasterWriter/CaptureRasterLimits. The total cap is an additional
# conservative handoff limit, not a claim about native capture quality or RAM.
MANIFEST_LIMIT = 256 * 1024
SIDECAR_LIMIT = 16 * 1024 * 1024
JPEG_LIMIT = 64 * 1024 * 1024
TOTAL_LIMIT = 2 * 1024**3
DISK_RESERVE = 2 * 1024**3


def bounded_file(path, limit, keep=False, sink=None):
    """Read regular files in bounded chunks; refuse final-component symlinks."""
    adapter.require(stat.S_ISREG(path.lstat().st_mode), f"not a regular file: {path.name}")
    digest, size, chunks = hashlib.sha256(), 0, []
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        adapter.require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "file type changed")
        while chunk := stream.read(min(1024 * 1024, limit + 1 - size)):
            size += len(chunk)
            adapter.require(size <= limit, f"file exceeds {limit}-byte limit: {path.name}")
            digest.update(chunk)
            if sink is not None:
                sink.write(chunk)
            if keep:
                chunks.append(chunk)
    return {"bytes": size, "sha256": digest.hexdigest()}, b"".join(chunks)


def bounded_json(path, limit):
    info, data = bounded_file(path, limit, keep=True)
    def reject(value):
        raise adapter.CaptureError(f"non-finite JSON constant: {value}")
    value = json.loads(data, object_pairs_hook=adapter.unique_object, parse_constant=reject)
    adapter.require(type(value) is dict, "JSON object required")
    return info, value


def directory(path, expected):
    adapter.require(stat.S_ISDIR(path.lstat().st_mode), f"not a real directory: {path.name}")
    # Bounded traversal: stop at the first extra entry; never recursively inspect
    # an unexpected directory, unrelated Downloads file, or symlink target.
    remaining = set(expected)
    with os.scandir(path) as entries:
        for entry in entries:
            adapter.require(entry.name in remaining, f"unexpected entry in {path.name}")
            remaining.remove(entry.name)
    adapter.require(not remaining, f"missing declared entries in {path.name}")


def inventory(manifest_path, frames_dir, images_dir, root=None):
    """Transport preflight; actual geometry and JPEG decoding remain in adapter."""
    if root is not None:
        directory(root, {"manifest.json", "frames", "images"})
    info, manifest = bounded_json(manifest_path, MANIFEST_LIMIT)
    for key, expected in adapter.CONVENTIONS.items():
        adapter.require(type(manifest.get(key)) is type(expected) and manifest[key] == expected,
                        f"manifest {key} violates capture contract")
    sidecars = manifest.get("frames")
    adapter.require(type(sidecars) is list and 20 <= len(sidecars) <= 400,
                    "complete capture requires 20–400 frames")
    expected = [f"frames/{i:06d}.json" for i in range(1, len(sidecars) + 1)]
    adapter.require(sidecars == expected, "manifest must list contiguous native frame paths")
    directory(frames_dir, {Path(name).name for name in expected})
    directory(images_dir, {f"{i:06d}.jpg" for i in range(1, len(sidecars) + 1)})
    files, sources = {"manifest.json": info}, {"manifest.json": manifest_path}
    observations, image_bytes = 0, 0
    for i, relative in enumerate(sidecars, 1):
        source = frames_dir / Path(relative).name
        files[relative], frame = bounded_json(source, SIDECAR_LIMIT)
        sources[relative] = source
        adapter.require(type(frame.get("schema_version")) is int and frame["schema_version"] == 1,
                        "sidecar schema_version must be 1")
        adapter.require(isinstance(manifest.get("session_id"), str)
                        and frame.get("session_id") == manifest["session_id"],
                        "mixed ARSession coordinate epochs")
        image = f"images/{i:06d}.jpg"
        adapter.require(frame.get("image") == image, "non-native image pairing")
        resolution = frame.get("image_resolution")
        adapter.require(type(resolution) is dict, "image_resolution object required")
        width, height = resolution.get("width"), resolution.get("height")
        adapter.require(all(type(n) is int and 1 <= n <= 8192 for n in (width, height))
                        and width * height <= 16777216, "native raster limit exceeded")
        points = frame.get("raw_feature_points")
        adapter.require(type(points) is list and len(points) <= 50000,
                        "raw_feature_points array must contain at most 50,000 entries")
        observations += len(points)
        sources[image] = images_dir / Path(image).name
        files[image], _ = bounded_file(sources[image], JPEG_LIMIT)
        image_bytes += files[image]["bytes"]
        adapter.require(sum(f["bytes"] for f in files.values()) <= TOTAL_LIMIT,
                        "capture exceeds conservative 2 GiB local handoff limit")
    adapter.require(type(manifest.get("feature_point_observations")) is int
                    and manifest["feature_point_observations"] == observations,
                    "manifest feature_point_observations does not match sidecars")
    # Native exports declare this field but native validation does not total it.
    # Handoff checks it as an additional transfer-integrity diagnostic.
    adapter.require(type(manifest.get("image_bytes")) is int
                    and manifest["image_bytes"] == image_bytes,
                    "manifest image_bytes does not match JPEG files")
    encoded = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    return {"files": files, "source_tree_sha256": hashlib.sha256(encoded).hexdigest(),
            "file_count": len(files), "total_bytes": sum(f["bytes"] for f in files.values()),
            "image_bytes": image_bytes}, sources


def root_inventory(root):
    return inventory(root / "manifest.json", root / "frames", root / "images", root)[0]


def new_output(path, source_paths, required_bytes):
    adapter.require(not path.exists() and not path.is_symlink(), "output already exists")
    adapter.require(path.parent.is_dir(), "output parent must already exist")
    resolved = path.resolve()
    adapter.require(all(not resolved.is_relative_to(source.resolve()) for source in source_paths),
                    "output must be outside source directories")
    adapter.require(shutil.disk_usage(path.parent).free >= required_bytes + DISK_RESERVE,
                    "insufficient disk space; preserve at least 2 GiB free")


def assemble_capture(manifest, frames, images, output):
    before, sources = inventory(manifest, frames, images)
    # Even a new sibling of frames/images would add an unexpected entry to the
    # original capture. Protect the manifest's WHOLE parent, including aliases.
    new_output(output, [frames, images, manifest.parent], before["total_bytes"])
    output.mkdir(mode=0o700)
    (output / "frames").mkdir(mode=0o700)
    (output / "images").mkdir(mode=0o700)
    # A copied manifest is written LAST. No raw JSON is rewritten or normalized.
    for relative in [p for p in sources if p != "manifest.json"] + ["manifest.json"]:
        with (output / relative).open("xb") as target:
            os.chmod(output / relative, 0o600)
            copied, _ = bounded_file(sources[relative], before["files"][relative]["bytes"], sink=target)
            adapter.require(copied == before["files"][relative], "source changed during bounded copy")
    after, _ = inventory(manifest, frames, images)
    adapter.require(before == after == root_inventory(output),
                    "source/copy changed during assembly; partial output preserved, not approved")
    return output


@contextmanager
def private_file_creation():
    # The unchanged adapter creates its own output root. Restrict permissions
    # BEFORE mkdir/open, including partial failures, not after media is written.
    # umask is process-wide: this is a single-threaded CLI, not a concurrent API.
    previous = os.umask(0o077)
    try:
        yield
    finally:
        os.umask(previous)


def inspect_capture(root, dataset=None):
    before = root_inventory(root)
    capture = adapter.load_capture(root)  # Use unchanged geometry/quality guards.
    adapter.require(before == root_inventory(root), "capture changed during validation")
    report = {"format": "rendprop-local-capture-handoff", "schema_version": 1,
              "status": "validated_capture_not_reconstruction", "source": before,
              "adapter": adapter.summary(capture), "gsplat_commit": adapter.GSPLAT_COMMIT,
              "raw_pose_and_calibration_modified": False, "dataset_prepared": False,
              "gpu_training_performed": False, "reconstructed_room_verified": False,
              "phone_viewer_verified": False,
              "integrity_scope": "local before/after byte hashes, not authentication or an atomic filesystem snapshot",
              "not_proved": ["pose accuracy", "lens distortion", "coverage", "reconstruction quality",
                             "surface measurements", "GPU runtime/cost", "phone FPS"]}
    seed_count = len(capture["seeds"])
    report["growth_plan"] = (estimate_growth(seed_count) if seed_count <= 500000 else
                             {"status": "blocked", "reason": "initial seeds exceed runner cap; do not truncate silently"})
    if dataset is not None:
        adapter.require(seed_count <= 500000, "seed count exceeds pinned runner cap; do not truncate silently")
        # points3D records are 51 bytes; include generous camera/report overhead.
        needed = before["image_bytes"] + 51 * seed_count + 200 * len(capture["frames"]) + 1024 * 1024
        new_output(dataset, [root], needed)
        with private_file_creation():
            adapter.write_dataset(capture, dataset)
            adapter.require(before == root_inventory(root),
                            "source changed during preparation; dataset not handoff-approved")
            report["dataset_prepared"] = True
            report["adapter_report_sha256"] = bounded_file(dataset / "adapter-report.json", MANIFEST_LIMIT)[0]["sha256"]
            # This is this wrapper's completion marker, separate from the adapter's.
            # run_training currently verifies adapter-report, not this extra report.
            with (dataset / "capture-provenance.json").open("x") as stream:
                json.dump(report, stream, indent=2, allow_nan=False)
                stream.write("\n")
    return report


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise adapter.CaptureError(message)


def main(argv=None):
    parser = Parser(description=__doc__, allow_abbrev=False)
    commands = parser.add_subparsers(dest="command", required=True, parser_class=Parser)
    inspect = commands.add_parser("inspect", allow_abbrev=False)
    inspect.add_argument("capture", type=Path)
    inspect.add_argument("--dataset", type=Path, help="new local dataset; never trains")
    assemble = commands.add_parser("assemble", allow_abbrev=False)
    for name in ("manifest", "frames", "images", "output"):
        assemble.add_argument(f"--{name}", type=Path, required=True)
    try:
        args = parser.parse_args(argv)
        if args.command == "assemble":
            root = assemble_capture(args.manifest, args.frames, args.images, args.output)
            report = inspect_capture(root)
        else:
            report = inspect_capture(args.capture, args.dataset)
        print(json.dumps(report, indent=2, allow_nan=False))
        return 0
    except (adapter.CaptureError, OSError, ValueError, RecursionError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
