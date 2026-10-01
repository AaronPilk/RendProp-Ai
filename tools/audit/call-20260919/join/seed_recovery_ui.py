#!/usr/bin/env python3
"""Seed synthetic fixtures ONLY into a newly-created isolated QA simulator.

Refuses an existing Recordings or TakeRecovery directory. Run after installing
the simulator app and before its first capture. Never points at a real device.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--simulator", required=True)
args = parser.parse_args()
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"]))
device = next((d for group in devices["devices"].values() for d in group if d["udid"] == args.simulator), None)
if not device or not device["name"].startswith("Rendprop Capture Recovery Audit "):
    raise SystemExit("Requires a newly-created Rendprop Capture Recovery Audit simulator")
container = pathlib.Path(subprocess.check_output([
    "xcrun", "simctl", "get_app_container", args.simulator, "com.rendprop.app", "data"
], text=True).strip())
documents = container / "Documents"
recordings = documents / "Recordings"
recovery = documents / "TakeRecovery"
if recordings.exists() or recovery.exists():
    raise SystemExit("Refusing existing capture directories; create a new isolated simulator")
recordings.mkdir(parents=True)
recovery.mkdir()
pieces = ["walkthrough-ui-part-1.mov", "walkthrough-ui-part-2.mov"]
for name, color in [(pieces[0], "blue"), (pieces[1], "green"), ("walkthrough-legacy-ui.mov", "red")]:
    subprocess.run(["/opt/homebrew/bin/ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                    "-i", f"color=c={color}:s=320x240:r=30:d=0.3", "-an", "-c:v", "libx264",
                    "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709",
                    "-colorspace", "bt709", str(recordings / name)], check=True)
take_id = str(uuid.UUID("5d8bcccf-9859-46f0-b979-7519a846bdc9")).upper()
journal = {
    "id": take_id, "createdAt": 811641600,
    "piecePaths": ["Recordings/" + name for name in pieces],
    "tags": [{"id": str(uuid.uuid4()).upper(), "name": "Synthetic kitchen", "tMs": 100}],
    "people": [{"startS": 0.1, "endS": 0.4}],
    "seconds": 0.6, "fps": 30, "width": 320, "height": 240,
}
(recovery / (take_id + ".json")).write_text(json.dumps(journal))
receipt = {
    "simulator": device, "documents": str(documents), "journal": journal,
    "files": [{"path": str(p), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
              for p in sorted(recordings.iterdir())],
}
receipt_dir = pathlib.Path(tempfile.mkdtemp(prefix="rendprop-recovery-ui-seed-"))
(receipt_dir / "receipt.json").write_text(json.dumps(receipt, indent=2))
print(receipt_dir / "receipt.json")
