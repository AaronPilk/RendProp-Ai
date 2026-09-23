#!/usr/bin/env python3
"""Freeze a new 400-view benchmark with evaluation images excluded from seeds.

Local preparation only. Original sensor JPEGs, per-frame calibration and poses
are preserved. This is a new cohort, not a comparable score for the old room.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile

import prepare_capture as adapter

PROFILE = "capture-benchmark-20260923-v1"


def training_seeds(capture, manifest, training_indexes):
    seeds = {}
    observations = 0
    for index in training_indexes:
        frame = capture["frames"][index]
        metadata = adapter.read_json(adapter.capture_file(capture["root"], manifest["frames"][index], ".json"))
        rgb, digest = adapter.jpeg_pixels(frame["source"], frame["width"], frame["height"])
        adapter.require(digest == frame["sha256"], "JPEG changed during benchmark preparation")
        for point in metadata["raw_feature_points"]:
            observations += 1
            uv = adapter.project(point["position"], frame["pose"], frame["intrinsics"])
            if uv is not None and 0 <= uv[0] < frame["width"] and 0 <= uv[1] < frame["height"]:
                seeds[point["id"]] = {"position": point["position"],
                                      "rgb": rgb.getpixel((int(uv[0]), int(uv[1]))),
                                      "source_id": point["id"]}
    distinct = {}
    for identifier in sorted(seeds, key=int):
        seed = seeds[identifier]
        distinct.setdefault(tuple(round(value, 6) for value in seed["position"]), seed)
    adapter.require(len(distinct) >= 100, "fewer than 100 visible training-only seeds")
    return list(distinct.values()), observations, len(seeds)


def prepare(root, output):
    root, output = Path(root).resolve(), Path(output).resolve()
    adapter.require(not output.exists(), "output already exists")
    adapter.require(not output.is_relative_to(root), "output must be outside the capture directory")
    manifest_path = root / "manifest.json"
    manifest_bytes = manifest_path.read_bytes()
    manifest = adapter.read_json(manifest_path)
    # Keep a hash inventory of metadata so an iCloud or concurrent replacement
    # cannot change the source between validation and training-only sampling.
    metadata_hashes = {name: hashlib.sha256(adapter.capture_file(root, name, ".json").read_bytes()).hexdigest()
                       for name in manifest["frames"]}
    capture = adapter.load_capture(root)
    adapter.require(len(capture["frames"]) == 400, "this benchmark requires exactly 400 views")
    training_indexes = [i for i in range(400) if i % 8 != 0]
    evaluation_indexes = [i for i in range(400) if i % 8 == 0]
    seeds, observations, visible_ids = training_seeds(capture, manifest, training_indexes)
    for name, digest in metadata_hashes.items():
        adapter.require(hashlib.sha256((root / name).read_bytes()).hexdigest() == digest,
                        "frame metadata changed during preparation")
    adapter.require(manifest_path.read_bytes() == manifest_bytes, "manifest changed during preparation")
    capture.update(seeds=seeds, visible_point_ids=visible_ids)
    # Publish the completed benchmark as one directory rename. The generic
    # adapter's completion marker must never be exposed at the final path
    # without the benchmark split and seed provenance attached.
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f".{output.name}-preparing-", dir=output.parent) as temporary_root:
        staged = Path(temporary_root) / "dataset"
        report = adapter.write_dataset(capture, staged)
        enrich_report(report, manifest_bytes, metadata_hashes, training_indexes, evaluation_indexes, observations)
        temporary = staged / "adapter-report.json.next"
        with temporary.open("x") as handle:
            json.dump(report, handle, indent=2, allow_nan=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(staged / "adapter-report.json")
        adapter.require(not output.exists(), "output appeared during preparation")
        staged.rename(output)
    return report


def enrich_report(report, manifest_bytes, metadata_hashes, training_indexes, evaluation_indexes, observations):
    training = [f"{i+1:06d}.jpg" for i in training_indexes]
    evaluation = [f"{i+1:06d}.jpg" for i in evaluation_indexes]
    report.update(
        benchmark_profile=PROFILE,
        training_images=training,
        evaluation_images=evaluation,
        seed_image_names=training,
        seed_colors_from_training_only=True,
        seed_geometry_from_training_observations_only=True,
        capture_point_observations=report["point_observations"],
        seed_observations=observations,
        capture_manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(),
        capture_metadata_sha256=metadata_hashes,
        benchmark_helper_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        evaluation_note="50 image-loss-heldout views; seed pixels and point observations use only the 350 training frames. ARKit VIO is shared, and heldout poses are not independently measured ground truth. Old-room PSNR/SSIM is not directly comparable.",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    report = prepare(args.capture, args.output)
    print(json.dumps({key: report[key] for key in ("benchmark_profile", "frames", "initial_points", "camera_radius_m", "seed_observations", "capture_manifest_sha256")}, indent=2))
    print("PASS: 350 training images / 50 fixed heldout images; no provider call")


if __name__ == "__main__":
    main()
