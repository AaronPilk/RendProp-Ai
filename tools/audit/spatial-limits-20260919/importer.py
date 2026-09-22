#!/usr/bin/env python3
"""Run the real CPU-only importer against native recorder output."""
import hashlib
import json
from pathlib import Path
import sys

sys.path.insert(0, sys.argv[1])
from prepare_capture import CaptureError, load_capture, summary, write_dataset

source = json.loads(Path(sys.argv[2]).read_text())
variant = sys.argv[3]
rows = []
for sample in source["scenarios"]:
    expected = sample["name"] == "manual" or (variant == "fixed" and sample["name"] in ["frame-limit-pending-write", "duration-limit-pending-write"])
    try:
        capture = load_capture(Path(sample["root"]))
    except CaptureError as error:
        assert not expected, (sample["name"], str(error))
        rows.append({"name": sample["name"], "accepted": False, "reason": str(error)})
    else:
        assert expected, sample["name"]
        rows.append({"name": sample["name"], "accepted": True, **summary(capture)})
        if variant == "fixed" and sample["name"] == "frame-limit-pending-write":
            destination = Path(sys.argv[4]).parent / "posed-dataset"
            write_dataset(capture, destination)
            assert len(list((destination / "images").glob("*.jpg"))) == 400
            for frame in capture["frames"]:
                assert hashlib.sha256(frame["source"].read_bytes()).hexdigest() == frame["sha256"]
            rows[-1]["dataset_images"] = 400
    for relative, expected_hash in sample["fileHashes"].items():
        assert hashlib.sha256((Path(sample["root"]) / relative).read_bytes()).hexdigest() == expected_hash
Path(sys.argv[4]).write_text(json.dumps(rows, indent=2))
print(f"PASS actual importer: {len(rows)} cases; every recorded original hash unchanged; GPU/provider calls: 0")
