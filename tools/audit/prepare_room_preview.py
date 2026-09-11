"""Prepare a private local viewer fixture from an already-trained owner room.

No network, training, publishing, database writes, or GPU allocation. This uses
the production navigation calculation so the test starts inside the capture,
not outside an outlier-expanded splat bounding box as the generic spike does.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import uuid

REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO / "services/spatial-worker"), str(REPO / "tools/spatial-spike/training")]
from modal_provider import navigation_manifest
from prepare_capture import load_capture


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("sog", type=Path)
    parser.add_argument("validation_stats", type=Path)
    parser.add_argument("manifest_output", type=Path)
    args = parser.parse_args()
    require(not args.manifest_output.exists(), "Refusing to overwrite a preview")
    output_path = args.manifest_output.resolve()
    require(not any((parent / ".git").exists() for parent in output_path.parents),
            "Room metadata stays outside every Git worktree")
    size = args.sog.stat().st_size
    require(0 < size <= 32 * 1024 * 1024, "Production SOG byte cap")
    with args.sog.open("rb") as source:
        data = source.read(32 * 1024 * 1024 + 1)
    require(len(data) == size, "Model changed while reading")
    require(data[:4] == b"PK\x03\x04", "Bundled SOG required")
    stats = json.loads(args.validation_stats.read_text())
    count = stats["num_GS"]
    require(type(count) is int and 0 < count <= 500000, "Production splat cap")
    capture = load_capture(args.capture)
    manifest = {
        **navigation_manifest(capture, "Owner room — quality test"),
        "scene_id": str(uuid.uuid4()), "artifact_revision": str(uuid.uuid4()),
        "bytes": size, "sha256": hashlib.sha256(data).hexdigest(),
        "gaussian_count": count, "provenance": "captured", "privacy_reviewed": False,
    }
    fd = os.open(args.manifest_output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump(manifest, output, indent=2)
        output.write("\n")
    print(json.dumps({"scene_id": manifest["scene_id"], "bytes": size,
                      "sha256": manifest["sha256"], "gaussian_count": count,
                      "manifest_output": str(args.manifest_output)}))


if __name__ == "__main__":
    main()
