#!/usr/bin/env python3
"""Verify pinned upstream parser + actual trainer CLI fields without CUDA.

Downloads only three public pinned source files into memory; never sends capture
data. Uses synthetic fixtures. This is an interface test, NOT a training run.
"""
import ast
from dataclasses import dataclass, field
import hashlib
import importlib.metadata
import json
from pathlib import Path
import sys
import tempfile
import typing
import urllib.request

import numpy as np
from pycolmap import SceneManager
import tyro

from prepare_capture import GSPLAT_COMMIT, PYCOLMAP_COMMIT, load_capture, write_dataset
from run_training import training_command
from test_prepare_capture import fixture


def main():
    direct_url = json.loads(importlib.metadata.distribution("pycolmap").read_text("direct_url.json"))
    assert direct_url["vcs_info"]["commit_id"] == PYCOLMAP_COMMIT, "wrong upstream parser revision"
    namespace = {**vars(typing), "__name__": __name__, "dataclass": dataclass, "field": field}
    hashes = {}
    for name, path in (("DefaultStrategy", "gsplat/strategy/default.py"),
                       ("MCMCStrategy", "gsplat/strategy/mcmc.py"),
                       ("Config", "examples/simple_trainer.py")):
        url = f"https://raw.githubusercontent.com/nerfstudio-project/gsplat/{GSPLAT_COMMIT}/{path}"
        with urllib.request.urlopen(url, timeout=30) as response:
            content = response.read()
        hashes[path] = hashlib.sha256(content).hexdigest()
        original = next(n for n in ast.parse(content).body if isinstance(n, ast.ClassDef) and n.name == name)
        # Preserve the real upstream annotated CLI fields, types, defaults and
        # decorators. Exclude methods/base classes to avoid importing CUDA.
        original.bases = []
        original.body = [node for node in original.body if isinstance(node, ast.AnnAssign)]
        declaration = ast.fix_missing_locations(ast.Module(body=[original], type_ignores=[]))
        exec(compile(declaration, url, "exec"), namespace)
    config = namespace["Config"](strategy=namespace["MCMCStrategy"]())
    arguments = training_command(sys.executable, "/trainer", "/dataset", "/output", 3000, 500000)[2:]
    parsed = tyro.extras.overridable_config_cli({"mcmc": ("upstream field validation", config)}, args=arguments)
    assert parsed.max_steps == 3000 and parsed.strategy.cap_max == 500000
    assert parsed.save_ply and parsed.ply_steps == [3000] and parsed.save_steps == [3000]
    assert parsed.disable_viewer and parsed.disable_video and parsed.packed
    assert not parsed.normalize_world_space and not parsed.pose_opt and parsed.init_type == "sfm"
    with tempfile.TemporaryDirectory(prefix="spatial-upstream-test-") as directory:
        root = Path(directory) / "capture"
        root.mkdir()
        fixture(root)
        output = Path(directory) / "dataset"
        capture = load_capture(root)
        write_dataset(capture, output)
        manager = SceneManager(str(output / "sparse/0"))
        manager.load_cameras()
        manager.load_images()
        manager.load_points3D()
        assert len(manager.cameras) == len(manager.images) == 20
        assert manager.points3D.shape == (100,3)
        np.testing.assert_allclose(manager.points3D[0], [-0.4,-0.4,-2])
        for index, image in manager.images.items():
            np.testing.assert_allclose(image.R(), np.diag([1,-1,-1]), atol=1e-12)
            np.testing.assert_allclose(image.tvec, [-(index-1)*0.02,0,0], atol=1e-12)
            assert image.name == f"{index:06d}.jpg" and len(image.points2D) == 0
        assert all(len(track) == 0 for track in manager.point3D_id_to_images.values())
    print(json.dumps({"status":"passed", "gsplat_commit":GSPLAT_COMMIT,
                      "pycolmap_commit":PYCOLMAP_COMMIT, "source_sha256":hashes,
                      "validated":"upstream binary parser and actual Tyro CLI fields",
                      "gpu_training_performed":False}, indent=2))


if __name__ == "__main__":
    main()
