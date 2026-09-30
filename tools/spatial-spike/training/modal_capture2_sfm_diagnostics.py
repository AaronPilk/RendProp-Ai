#!/usr/bin/env python3
"""Bounded offline diagnostics for the capture2 SfM experiment.

This does not train, provision a provider, change primary evaluation files, or
download model weights. Its caller binds every input and caps runtime/downloads.
PLYs are the pre-final-update artifacts; official trainer metrics remain primary.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import time
from types import SimpleNamespace
import zipfile

import numpy as np

COMMIT = "937e29912570c372bed6747a5c9bf85fed877bae"
TRAINER_SHA = "79319e1cd7404e4d1ba0c425634235c39e6054f0643b904a01feea6179462c05"
PARSER_SHA = "2aa364ecfd2d7dd715ede5192fccd533982edf3be68b98008440a5aedf3b3fed"
BASELINE_PLY_SHA = "8c8e276b18f620728058dfd48e24b1dac7b32cfb05bafc900a19ce5247c0867c"
REFERENCE_ZIP_SHA = "36d3e36c185cf0495a5448fd2ee38b4798c3208c9668e5d112793666eaa5c6ae"
BASELINE_METRICS = {"psnr": 21.206584930419922, "ssim": 0.7564787864685059,
                    "lpips": 0.481100469827652}
AGGREGATE_TOLERANCES = {"psnr": .1, "ssim": .002, "lpips": .005}
# Against the saved 8-bit PNG, which includes quantization and the final update.
PER_VIEW_TOLERANCES = {"psnr": .5, "ssim": .01, "lpips": .02}
EVAL_NAMES = [f"{i:06d}.jpg" for i in range(1, 362, 8)]
TRAIN_NAMES = [f"{i:06d}.jpg" for i in range(1, 362) if i % 8 != 1]
TRAIN_DIAGNOSTIC_NAMES = [f"{i:06d}.jpg" for i in (2, 50, 98, 146, 194, 242, 290, 338)]
PROPERTIES = (["x", "y", "z"] + [f"f_dc_{i}" for i in range(3)] +
              [f"f_rest_{i}" for i in range(45)] + ["opacity"] +
              [f"scale_{i}" for i in range(3)] + [f"rot_{i}" for i in range(4)])
OUTPUT_NAMES = ("summary.json", "optimized-training-poses.json", "resolved-config.json",
                "r01-original-stats.json", "r01-localized-stats.json", "r02-localized-stats.json",
                "r01-original-worst-psnr.png", "r01-original-worst-ssim.png", "r01-original-worst-lpips.png") + tuple(
    f"{label}-{i:04d}.png" for label, count in
    (("r01-localized", 46), ("r02-localized", 46), ("r02-training", 8)) for i in range(count))


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def read_json(path, limit=4 * 1024**2):
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= limit,
            "invalid or oversized JSON input")
    return json.loads(path.read_text())


def save_json(path, value):
    # Never overwrite a partial/frozen earlier diagnostic.
    with Path(path).open("x") as stream:
        json.dump(value, stream, indent=2, allow_nan=False)
        stream.write("\n")


def load_ply(path):
    """Strict gsplat 1.5.3 float32 export decoder, with no Gaussian filtering."""
    path = Path(path)
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 120 * 1024**2,
            "invalid or oversized PLY")
    with path.open("rb") as stream:
        lines = []
        for _ in range(80):
            line = stream.readline(256)
            require(line.endswith(b"\n"), "truncated or oversized PLY header line")
            lines.append(line.decode("ascii").rstrip("\n"))
            if lines[-1] == "end_header":
                break
        require(lines[:2] == ["ply", "format binary_little_endian 1.0"], "unsupported PLY encoding")
        require(len(lines) == len(PROPERTIES) + 4 and lines[-1] == "end_header",
                "unexpected PLY header")
        require(lines[2].startswith("element vertex "), "missing vertex count")
        count = int(lines[2].split()[-1])
        require(0 < count <= 500000, "Gaussian cap exceeded or empty PLY")
        require(lines[3:-1] == [f"property float {name}" for name in PROPERTIES],
                "PLY property order/type differs from pinned exporter")
        body = stream.read()
    require(len(body) == count * len(PROPERTIES) * 4, "PLY body length differs from declared count")
    rows = np.frombuffer(body, dtype="<f4").reshape(count, len(PROPERTIES))
    require(np.isfinite(rows).all(), "nonfinite PLY values; refusing to filter")
    return {"means": rows[:, :3].copy(), "sh0": rows[:, 3:6].reshape(count, 1, 3).copy(),
            "shN": rows[:, 6:51].reshape(count, 3, 15).transpose(0, 2, 1).copy(),
            "opacities": rows[:, 51].copy(), "scales": rows[:, 52:55].copy(),
            "quats": rows[:, 55:59].copy()}


def rigid_pose(value):
    matrix = np.asarray(value, dtype=np.float64)
    require(matrix.shape == (4, 4) and np.isfinite(matrix).all(), "invalid pose shape/values")
    require(np.allclose(matrix[3], [0, 0, 0, 1], atol=1e-7, rtol=0) and
            np.allclose(matrix[:3, :3].T @ matrix[:3, :3], np.eye(3), atol=1e-5, rtol=0) and
            abs(np.linalg.det(matrix[:3, :3]) - 1) <= 1e-5, "pose is not a proper rigid transform")
    return matrix


def validate_pose_sidecar(value, original_poses, intrinsics):
    require(value.get("schema_version") == 1 and
            value.get("coordinate_system") == "ARKit-world/OpenCV-camera" and
            value.get("evaluation_images") == EVAL_NAMES, "evaluation sidecar coordinate system/cohort changed")
    entries = value.get("poses", [])
    require(len(entries) == 46 and [row.get("image_name") for row in entries] == EVAL_NAMES,
            "evaluation sidecar dropped, duplicated or reordered a view")
    result = []
    for row, original, K in zip(entries, original_poses, intrinsics):
        require(row.get("status") == "passed" and row.get("recomputed_final_inliers", 0) >= 20,
                "held-out PnP localization did not pass")
        candidate = rigid_pose(row["camtoworld"])
        recorded = rigid_pose(row["original_camtoworld"])
        require(np.allclose(recorded, original, atol=1e-6, rtol=0), "original held-out pose changed")
        recorded_K = np.asarray(row["K"], dtype=np.float64)
        require(recorded_K.shape == (3, 3) and np.isfinite(recorded_K).all() and
                np.allclose(recorded_K, K, atol=1e-4, rtol=0), "held-out calibration changed")
        result.append(candidate)
    return np.asarray(result)


def compare_import(aggregate, per_view):
    require(set(aggregate) == set(BASELINE_METRICS) and len(per_view) == 46,
            "missing import compatibility metrics")
    deltas = {key: aggregate[key] - BASELINE_METRICS[key] for key in BASELINE_METRICS}
    worst = {key: max(per_view, key=lambda row: abs(row["delta_vs_saved_png"][key]))
             for key in BASELINE_METRICS}
    require(all(np.isfinite(list(row["delta_vs_saved_png"].values())).all() for row in per_view)
            and np.isfinite(list(deltas.values())).all(), "nonfinite import comparison")
    return {"passed": all(abs(deltas[key]) <= AGGREGATE_TOLERANCES[key] and
                           abs(worst[key]["delta_vs_saved_png"][key]) <= PER_VIEW_TOLERANCES[key]
                           for key in deltas),
            "signed_aggregate_delta_vs_official_float_metrics": deltas,
            "aggregate_tolerances": AGGREGATE_TOLERANCES,
            "per_view_tolerances_vs_quantized_saved_png": PER_VIEW_TOLERANCES,
            "worst_view_for_each_metric": worst}


def main(args):
    started = time.monotonic()
    output = Path(args.output)
    require(not output.exists(), "diagnostic output already exists")
    output.mkdir(parents=True, mode=0o700)
    upstream = Path("/opt/gsplat-phase-a")
    require(subprocess.check_output(["git", "-C", str(upstream), "rev-parse", "HEAD"], text=True).strip()
            == COMMIT, "unexpected gsplat revision")
    require(not subprocess.check_output(["git", "-C", str(upstream), "diff", "--name-only", "HEAD"]),
            "modified tracked gsplat source")
    require(digest(upstream / "examples/simple_trainer.py") == TRAINER_SHA and
            digest(upstream / "examples/datasets/colmap.py") == PARSER_SHA, "pinned renderer/parser changed")
    require(digest(args.baseline_ply) == BASELINE_PLY_SHA and
            digest(args.baseline_renders) == REFERENCE_ZIP_SHA, "frozen baseline changed")
    sys.path.insert(0, str(upstream / "examples"))
    import torch
    import imageio.v2 as imageio
    from PIL import Image
    from datasets.colmap import Parser, Dataset
    from simple_trainer import Config, Runner
    from gsplat.strategy import MCMCStrategy
    from utils import CameraOptModule
    from torchmetrics.image import PeakSignalNoiseRatio, StructuralSimilarityIndexMeasure
    from torchmetrics.image.lpip import LearnedPerceptualImagePatchSimilarity
    require(torch.cuda.is_available(), "CUDA renderer unavailable")
    torch.set_num_threads(4)
    torch.manual_seed(42)
    np.random.seed(42)
    dataset = Path(args.dataset)
    parser = Parser(str(dataset), factor=1, normalize=False, test_every=8)
    trainset, valset = Dataset(parser, split="train"), Dataset(parser, split="val")
    require([parser.image_names[i] for i in trainset.indices] == TRAIN_NAMES and
            [parser.image_names[i] for i in valset.indices] == EVAL_NAMES, "trainer split changed")
    original_poses = parser.camtoworlds[valset.indices]
    intrinsics = [parser.Ks_dict[parser.camera_ids[i]] for i in valset.indices]
    localized = validate_pose_sidecar(read_json(args.evaluation_poses), original_poses, intrinsics)
    result_dir = Path(args.candidate_ply).parent.parent
    run_path = result_dir / "run.json"
    run = read_json(run_path)
    require(run.get("status") == "trained" and run.get("max_steps") == 30000 and
            run.get("max_gaussians") == 500000 and run.get("pose_optimization") is True and
            run.get("world_normalization") is False and run.get("gsplat_commit") == COMMIT,
            "candidate training recipe differs")
    config_path = result_dir / "cfg.yml"
    require(config_path.stat().st_size <= 1024**2, "oversized resolved config")
    config_text = config_path.read_text()
    # Preserve upstream YAML verbatim, never deserialize its Python object tags.
    cfg = Config(strategy=MCMCStrategy(cap_max=500000), packed=True, pose_opt=True,
                 normalize_world_space=False, data_factor=1, test_every=8,
                 disable_viewer=True, disable_video=True)
    render_config = {key: getattr(cfg, key) for key in
        ("packed", "sparse_grad", "antialiased", "app_opt", "camera_model", "with_ut", "with_eval3d",
         "near_plane", "far_plane", "sh_degree", "use_bilateral_grid", "lpips_net")}
    require(render_config == {"packed": True, "sparse_grad": False, "antialiased": False,
        "app_opt": False, "camera_model": "pinhole", "with_ut": False, "with_eval3d": False,
        "near_plane": .01, "far_plane": 1e10, "sh_degree": 3, "use_bilateral_grid": False, "lpips_net": "alex"},
        "pinned renderer defaults changed")
    # compose creates syntax nodes only; it does not instantiate Python objects.
    import yaml
    config_node = yaml.compose(config_text, Loader=yaml.SafeLoader)
    require(isinstance(config_node, yaml.MappingNode), "invalid config root")
    scalar_config = {key.value: val for key, val in config_node.value}
    for key, expected in {**render_config, "data_factor": 1, "test_every": 8,
                          "normalize_world_space": False, "pose_opt": True}.items():
        node = scalar_config.get(key)
        require(isinstance(node, yaml.ScalarNode) and
                yaml.safe_load(node.value) == expected, f"actual renderer/training setting differs: {key}")
    save_json(output / "resolved-config.json", {"upstream_yaml_text": config_text,
        "upstream_yaml_sha256": digest(config_path), "render_config": render_config,
        "training_run": run, "training_run_sha256": digest(run_path)})

    candidate_arrays = load_ply(args.candidate_ply)
    checkpoint_path = result_dir / "ckpts/ckpt_29999_rank0.pt"
    require(checkpoint_path.is_file() and not checkpoint_path.is_symlink() and
            checkpoint_path.stat().st_size < 256 * 1024**2, "invalid checkpoint bounds")
    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=True)
    require(checkpoint["step"] == 29999 and set(checkpoint["splats"]) == set(candidate_arrays),
            "checkpoint step or fields changed")
    for key, array in candidate_arrays.items():
        tensor = checkpoint["splats"][key]
        require(tensor.dtype == torch.float32 and np.array_equal(tensor.numpy(), array),
                f"checkpoint versus decoded PLY mismatch: {key}")
    adjust = CameraOptModule(315)
    adjust.load_state_dict(checkpoint["pose_adjust"], strict=True)
    require(tuple(adjust.embeds.weight.shape) == (315, 9) and
            torch.isfinite(adjust.embeds.weight).all().item(), "invalid optimized pose embeddings")
    with torch.no_grad():
        optimized = adjust(torch.tensor(parser.camtoworlds[trainset.indices], dtype=torch.float32),
                           torch.arange(315)).numpy()
    pose_rows = []
    for index, (name, before, after) in enumerate(zip(TRAIN_NAMES, parser.camtoworlds[trainset.indices], optimized)):
        rigid_pose(after)
        angle = np.degrees(np.arccos(np.clip((np.trace(before[:3, :3].T @ after[:3, :3]) - 1) / 2, -1, 1)))
        pose_rows.append({"image_name": name, "split_local_embedding_id": index,
            "original_camtoworld": before.tolist(), "optimized_camtoworld": after.tolist(),
            "translation_delta_m": float(np.linalg.norm(after[:3, 3] - before[:3, 3])),
            "rotation_delta_deg": float(angle)})
    save_json(output / "optimized-training-poses.json", {"schema_version": 1,
        "coordinate_system": "ARKit-world/OpenCV-camera", "checkpoint_sha256": digest(checkpoint_path),
        "candidate_ply_sha256": digest(args.candidate_ply), "checkpoint_decoded_ply_exact": True,
        "state": "before final optimizer/MCMC update at step 29999", "poses": pose_rows,
        "training_diagnostic_images": TRAIN_DIAGNOSTIC_NAMES})
    del checkpoint, adjust

    reference = zipfile.ZipFile(args.baseline_renders)
    expected_reference = [f"val_step29999_{i:04d}.png" for i in range(46)]
    require(reference.namelist() == expected_reference and
            all(0 < row.file_size <= 20 * 1024**2 and row.compress_type == zipfile.ZIP_STORED
                for row in reference.infolist()), "baseline archive entries or bounds differ")

    def metrics():
        return {"psnr": PeakSignalNoiseRatio(data_range=1.0).cuda(),
                "ssim": StructuralSimilarityIndexMeasure(data_range=1.0).cuda(),
                "lpips": LearnedPerceptualImagePatchSimilarity(net_type="alex", normalize=True).cuda()}

    def measure(instances, predicted, truth):
        return {key: instance(predicted.permute(0, 3, 1, 2), truth.permute(0, 3, 1, 2))
                for key, instance in instances.items()}

    def renderer(arrays):
        return SimpleNamespace(splats={key: torch.from_numpy(array).cuda() for key, array in arrays.items()},
                               cfg=cfg, world_size=1)

    def render(model, data, pose):
        pixels = data["image"].cuda().unsqueeze(0) / 255.0
        require(tuple(pixels.shape) == (1, 1440, 1920, 3) and "mask" not in data,
                "native held-out canvas or mask changed")
        colors, _, _ = Runner.rasterize_splats(model,
            camtoworlds=torch.tensor(pose, dtype=torch.float32, device="cuda").unsqueeze(0),
            Ks=data["K"].cuda().unsqueeze(0), width=1920, height=1440, sh_degree=cfg.sh_degree,
            near_plane=cfg.near_plane, far_plane=cfg.far_plane)
        colors = colors.clamp(0, 1)
        require(torch.isfinite(colors).all().item(), "nonfinite rendered pixels")
        return pixels, colors

    def evaluate(label, model, poses, *, save_images, compare_reference=False):
        calculators = metrics()
        reference_calculators = metrics() if compare_reference else None
        values, rows = {key: [] for key in BASELINE_METRICS}, []
        worst_canvases = {}
        for index, name in enumerate(EVAL_NAMES):
            pixels, colors = render(model, valset[index], poses[index])
            scores = measure(calculators, colors, pixels)
            row = {"image_name": name, **{key: float(score.item()) for key, score in scores.items()}}
            for key, value in scores.items():
                values[key].append(value.detach())
            if save_images:
                canvas = (torch.cat((pixels, colors), dim=2)[0].cpu().numpy() * 255).astype(np.uint8)
                imageio.imwrite(output / f"{label}-{index:04d}.png", canvas)
            if compare_reference:
                with reference.open(expected_reference[index]) as stream:
                    with Image.open(io.BytesIO(stream.read())) as im:
                        require(im.size == (3840, 1440) and im.mode == "RGB", "saved reference canvas differs")
                        saved = np.asarray(im).copy()
                truth8 = (pixels[0].cpu().numpy() * 255).astype(np.uint8)
                require(np.array_equal(saved[:, :1920], truth8), "reference GT differs from current dataset")
                reference_pixels = torch.from_numpy(saved[:, 1920:]).cuda().unsqueeze(0) / 255.0
                original_scores = measure(reference_calculators, reference_pixels, pixels)
                row["saved_png_metrics"] = {key: float(value.item()) for key, value in original_scores.items()}
                row["delta_vs_saved_png"] = {key: row[key] - row["saved_png_metrics"][key] for key in scores}
                row["mean_absolute_pixel_delta_0_to_1"] = float((colors - reference_pixels).abs().mean().item())
                row["max_absolute_pixel_delta_0_to_1"] = float((colors - reference_pixels).abs().max().item())
                for key in scores:
                    magnitude = abs(row["delta_vs_saved_png"][key])
                    if key not in worst_canvases or magnitude > worst_canvases[key][0]:
                        # Three panels: original photo, saved baseline, PLY reload.
                        canvas = (torch.cat((pixels, reference_pixels, colors), dim=2)[0].cpu().numpy() * 255).astype(np.uint8)
                        worst_canvases[key] = (magnitude, canvas)
            rows.append(row)
            print(f"{label} {index + 1}/46", flush=True)
        aggregate = {key: float(torch.stack(value).mean().item()) for key, value in values.items()}
        require(np.isfinite(list(aggregate.values())).all(), "nonfinite aggregate metrics")
        report = {"schema_version": 1, "label": label, "evaluation_images": EVAL_NAMES,
            "aggregate": aggregate, "per_view": rows, "resolution": [1920, 1440],
            "pose_variant": "original ARKit" if compare_reference else "SfM PnP, frozen training-only geometry",
            "metric_implementation": "same pinned torchmetrics classes, defaults and float32 mean as trainer",
            "artifact_state": "pre-final-optimizer-update PLY"}
        if compare_reference:
            report["import_compatibility"] = compare_import(aggregate, rows)
            for key, (_, canvas) in worst_canvases.items():
                imageio.imwrite(output / f"r01-original-worst-{key}.png", canvas)
            report["worst_view_canvas_panels"] = ["original photo", "saved post-update baseline PNG", "pre-update PLY reload"]
        save_json(output / f"{label}-stats.json", report)
        return report

    with torch.no_grad():
        baseline = renderer(load_ply(args.baseline_ply))
        original = evaluate("r01-original", baseline, original_poses, save_images=False, compare_reference=True)
        prior = evaluate("r01-localized", baseline, localized, save_images=True)
        del baseline
        torch.cuda.empty_cache()
        candidate = renderer(candidate_arrays)
        current = evaluate("r02-localized", candidate, localized, save_images=True)
        for index, name in enumerate(TRAIN_DIAGNOSTIC_NAMES):
            train_index = TRAIN_NAMES.index(name)
            pixels, colors = render(candidate, trainset[train_index], optimized[train_index])
            canvas = (torch.cat((pixels, colors), dim=2)[0].cpu().numpy() * 255).astype(np.uint8)
            imageio.imwrite(output / f"r02-training-{index:04d}.png", canvas)
    reference.close()
    outputs = {path.name: {"sha256": digest(path), "bytes": path.stat().st_size} for path in output.iterdir()}
    require(set(outputs) == set(OUTPUT_NAMES) - {"summary.json"}, "diagnostic output set differs")
    compatible = original["import_compatibility"]["passed"]
    summary = {"schema_version": 1, "status": "passed" if compatible else "invalid-render-path-comparison",
        "quality_accepted": False, "paired_secondary_valid": compatible,
        "primary_evaluation_unchanged": True, "gsplat_commit": COMMIT,
        "baseline_ply_sha256": digest(args.baseline_ply), "candidate_ply_sha256": digest(args.candidate_ply),
        "evaluation_poses_sha256": digest(args.evaluation_poses), "baseline_renders_sha256": REFERENCE_ZIP_SHA,
        "diagnostics_source_sha256": digest(__file__), "render_config": render_config,
        "r01_original_import": original["import_compatibility"],
        "paired_secondary_aggregate": {"r01": prior["aggregate"], "r02": current["aggregate"]},
        "paired_secondary_delta_r02_minus_r01": {key: current["aggregate"][key] - prior["aggregate"][key]
                                                for key in BASELINE_METRICS},
        "caveats": ["SfM-localized evaluation is secondary and uses image-derived query poses.",
                    "Both PLY artifacts precede their final optimizer/MCMC update; official primary eval follows it.",
                    "Reference PNGs are quantized; signed per-view comparisons explicitly include that difference.",
                    "Optimized training-view renders are diagnostics, never held-out quality scores.",
                    "Passing import compatibility does not mean passing visual walkthrough quality."],
        "elapsed_seconds": time.monotonic() - started, "outputs": outputs}
    save_json(output / "summary.json", summary)
    print(json.dumps({"status": summary["status"], "secondary": summary["paired_secondary_aggregate"]}), flush=True)
    return 0 if compatible else 2


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    for name in ("baseline-ply", "candidate-ply", "dataset", "evaluation-poses", "baseline-renders", "output"):
        cli.add_argument(f"--{name}", required=True)
    sys.exit(main(cli.parse_args()))
