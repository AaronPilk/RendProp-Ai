#!/usr/bin/env python3
"""Check the artifact, not just Xcode's success marker. Never runs the app."""
import argparse
import plistlib
from pathlib import Path

# Assertions are the gate, so optimized Python must never silently erase them.
if not __debug__:
    raise SystemExit("FAIL: run bundle verification without Python -O")


def verify(bundle: Path, build: str, lab: bool) -> None:
    info = plistlib.loads((bundle / "Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "com.rendprop.app", "wrong app identifier"
    assert info["CFBundleShortVersionString"] == "1.0", "wrong marketing version"
    assert info["CFBundleVersion"] == build, "wrong build number"
    assert info["MinimumOSVersion"] == "16.0", "shipping compatibility changed"
    assert info["UIRequiredDeviceCapabilities"] == ["arm64"], "global AR/LiDAR restriction introduced"
    assert info["NSCameraUsageDescription"], "missing camera purpose string"
    assert info["ITSAppUsesNonExemptEncryption"] is False, "encryption declaration changed"
    assert (bundle / "PrivacyInfo.xcprivacy").is_file(), "privacy manifest missing"
    assert (bundle / "Assets.car").is_file(), "asset catalog missing"
    assert (bundle / "player" / "index.html").is_file(), "bundled player missing"
    executable = bundle / info["CFBundleExecutable"]
    binary = executable.read_bytes()
    # These >16-byte literal IDs survive the checked optimized build. Short
    # Swift strings (e.g. spatial.status) may be constructed as immediate words
    # rather than contiguous data, so searching for those is not a valid gate.
    # The real UI tests still assert the controls, not just these binary markers.
    for marker in (b"settings.spatialCapture", b"spatial.lab.description"):
        assert (marker in binary) == lab, "unexpected capture-lab compilation state"
    forbidden = {".py", ".sh", ".md", ".bak", ".p8", ".pem", ".storekit"}
    for item in bundle.rglob("*"):
        if not item.is_file():
            continue
        name = item.name.lower()
        assert item.suffix.lower() not in forbidden, "non-app file bundled: " + name
        assert name != ".env" and not name.startswith(".env."), "environment file bundled"
        assert name not in ("secrets.plist", "secrets.example.plist"), "secrets resource bundled"
    print("PASS: exact Rendprop bundle, version, build, compatibility, resources and capture-lab state")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--build", required=True)
    parser.add_argument("--lab", action="store_true")
    args = parser.parse_args()
    verify(args.bundle, args.build, args.lab)
