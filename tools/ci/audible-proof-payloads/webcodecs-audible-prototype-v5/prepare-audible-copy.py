#!/usr/bin/env python3
"""Prepare an external, disposable 1c archive for the audible proof.

Static preparation only. It never builds, opens a browser, encodes, downloads,
or modifies the shipping checkout. The prior frozen video loop is retained.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import runpy
from pathlib import Path

HERE = Path(__file__).resolve().parent
PRIOR = HERE.parent / "webcodecs-narrated-prototype-v2/prepare-disposable-copy.py"
PRIOR_SHA = "8468b413d7beb7eae24703cc3c6ae65d28a6671d253af8a9bfd66b7a809428b1"
SHIPPING_SHA = "1c561d7b91d9b75bd7ba29aa081fcba959089fee"
SOURCE = {
    "experimental-webcodecs-audible.ts": "apps/studio/src/editor/experimental-webcodecs.ts",
    "audible-pcm.ts": "apps/studio/src/editor/audible-pcm.ts",
    "audible-pcm-worklet.js": "apps/studio/src/editor/audible-pcm-worklet.js",
    "audible-proof-fixture.html": "apps/studio/tests/audible-proof-fixture.html",
    "audible-proof-fixture.ts": "apps/studio/tests/audible-proof-fixture.ts",
    "audible-proof-browser.mjs": "apps/studio/tests/audible-proof-browser.mjs",
}


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkout", type=Path, required=True,
                        help="Disposable exact-1c source archive, never the active checkout")
    parser.add_argument("--dependency-root", type=Path, required=True,
                        help="External pinned Mediabunny install root")
    parser.add_argument("--receipt", type=Path, required=True,
                        help="External manifest JSON path")
    parser.add_argument("--validate-only", action="store_true")
    args = parser.parse_args()
    checkout = args.checkout.resolve()
    dependency = args.dependency_root.resolve()
    receipt = args.receipt.resolve()
    active = Path("/Volumes/Rendprop Files/Builds/Active/client-native-speed-20261111/source").resolve()
    if checkout == active or checkout.is_relative_to(active) or active.is_relative_to(checkout):
        raise RuntimeError("Refusing to write the active release checkout")
    if checkout == HERE or checkout.is_relative_to(HERE) or HERE.is_relative_to(checkout):
        raise RuntimeError("Proof payload and disposable checkout must be separate")
    if receipt.is_relative_to(checkout):
        raise RuntimeError("Receipt must remain outside the disposable checkout")
    if sha(PRIOR) != PRIOR_SHA:
        raise RuntimeError("Frozen prior pin verifier changed")
    prior = runpy.run_path(str(PRIOR))
    for relative, expected in prior["PINNED"].items():
        if sha(checkout / relative) != expected:
            raise RuntimeError(f"Shipping input mismatch: {relative}")
    package = dependency / "node_modules/mediabunny"
    entry = package / "dist/modules/src/index.js"
    lock = dependency / "package-lock.json"
    lock_data = json.loads(lock.read_text())["packages"]["node_modules/mediabunny"]
    if lock_data.get("version") != "1.65.2" or \
            lock_data.get("integrity") != prior["EXPECTED_INTEGRITY"] or \
            sha(lock) != prior["EXPECTED_LOCK_SHA256"] or \
            sha(entry) != prior["EXPECTED_ENTRY_SHA256"] or \
            prior["tree_digest"](package) != prior["EXPECTED_TREE_SHA256"]:
        raise RuntimeError("Pinned external Mediabunny package changed")
    if sha(HERE.parent / "webcodecs-narrated-prototype-v2/experimental-webcodecs.ts") != \
            "773e6860f48963746f4233c240292dca63092e288493c6bc43fbbb9c51b437a3":
        raise RuntimeError("Frozen narrated video-loop source changed")
    manifest = json.loads((HERE / "payload-hashes.json").read_text())
    for name in [*SOURCE, "design.md", "README.md", "derive-audible-exporter.py",
                 "prepare-audible-copy.py"]:
        if sha(HERE / name) != manifest["payloadSha256"].get(name):
            raise RuntimeError(f"Audible payload changed: {name}")
    outputs = {target: sha(HERE / name) for name, target in SOURCE.items()}
    for target in outputs:
        if (checkout / target).exists():
            raise RuntimeError(f"Refusing to overwrite existing path: {target}")
    if args.validate_only:
        print(json.dumps({"status": "validated-without-writes", "shippingCommit": SHIPPING_SHA,
                          "shippingPins": len(prior["PINNED"]), "outputsSha256": outputs}, indent=2))
        return
    for name, target in SOURCE.items():
        destination = checkout / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes((HERE / name).read_bytes())
        if sha(destination) != outputs[target]:
            raise RuntimeError(f"Prepared output changed: {target}")
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps({
        "kind": "audible-original-webcodecs-disposable-preparation",
        "status": "prepared-only", "shippingCommit": SHIPPING_SHA,
        "shippingPinsSha256": prior["PINNED"], "externalDependency": {
            "name": "mediabunny", "version": "1.65.2",
            "integrity": prior["EXPECTED_INTEGRITY"],
            "packageLockSha256": sha(lock), "entrySha256": sha(entry),
            "packageTreeSha256": prior["tree_digest"](package), "entry": str(entry),
        },
        "payloadSha256": manifest["payloadSha256"], "outputsSha256": outputs,
        "runtimeExecuted": False,
    }, indent=2) + "\n")
    print(json.dumps({"status": "prepared-only", "outputs": len(outputs),
                      "receipt": str(receipt)}))


if __name__ == "__main__":
    main()
