#!/usr/bin/env python3
"""Copy one genuine app screenshot into the guide with source provenance.

This imports the original pixels without resizing, redaction, retouching, or
fabricating UI. Review the source image for personal information first.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CAPTURES = ROOT / "docs/marketing/quick-start-20261028/captures"
MANIFEST = CAPTURES / "provenance.json"
ALLOWED_SOURCES = ("Physical iPhone", "Current app simulator", "Current live mobile browser")


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key", required=True, help="Unique visual key used in visuals.json")
    parser.add_argument("--image", required=True, type=Path, help="Unmodified actual app screenshot")
    parser.add_argument("--source", required=True,
                        help="Specific device/build/date, e.g. Physical iPhone, TestFlight Build 131, 2026-10-28")
    parser.add_argument("--fixture-content", action="store_true",
                        help="Declare actual simulator UI with synthetic listing/account data")
    args = parser.parse_args()

    if not args.key or not all(c.islower() or c.isdigit() or c == "-" for c in args.key):
        parser.error("--key must contain lowercase letters, digits and hyphens only")
    if not args.source.startswith(ALLOWED_SOURCES):
        parser.error("--source must identify an actual physical iPhone, current app simulator or live mobile browser")
    if not args.image.is_file() or args.image.suffix.lower() not in {".png", ".jpg", ".jpeg"}:
        parser.error("--image must be an existing PNG or JPEG screenshot")
    data = args.image.read_bytes()
    if args.image.suffix.lower() == ".png" and not data.startswith(b"\x89PNG\r\n\x1a\n"):
        parser.error("PNG content does not match extension")
    if args.image.suffix.lower() in {".jpg", ".jpeg"} and not data.startswith(b"\xff\xd8\xff"):
        parser.error("JPEG content does not match extension")
    manifest = json.loads(MANIFEST.read_text())
    if args.key in manifest:
        parser.error("Visual key already exists; choose a distinct key to preserve the previous capture")
    filename = args.key + args.image.suffix.lower()
    destination = CAPTURES / filename
    if destination.exists():
        parser.error("Capture file already exists; no existing pixels will be overwritten")

    # A copy is intentional: the exact source bytes remain inspectable. Do not
    # crop a screenshot to hide stale controls or scale it to satisfy a gate.
    shutil.copyfile(args.image, destination)
    digest = sha(destination)
    if digest != hashlib.sha256(data).hexdigest():
        destination.unlink(missing_ok=True)
        raise SystemExit("Screenshot changed while copying")
    manifest[args.key] = {
        "file": filename,
        "source": args.source,
        "original_sha256": digest,
        "capture_crop": None,
        "synthetic_fixture_content": args.fixture_content,
        "file_sha256": digest,
    }
    temporary = MANIFEST.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, indent=2) + "\n")
    os.replace(temporary, MANIFEST)
    print(json.dumps({"key": args.key, "capture": str(destination),
                      "sha256": digest, "source": args.source}, indent=2))


if __name__ == "__main__":
    main()
