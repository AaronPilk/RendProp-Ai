#!/usr/bin/env python3
"""Prepare/run ONE isolated partial WebCodecs fixture. Never required release CI."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tarfile

SHIPPING_SHA = "1c561d7b91d9b75bd7ba29aa081fcba959089fee"
FROZEN = {
    "experimental-webcodecs.ts": "773e6860f48963746f4233c240292dca63092e288493c6bc43fbbb9c51b437a3",
    "prepare-disposable-copy.py": "8468b413d7beb7eae24703cc3c6ae65d28a6671d253af8a9bfd66b7a809428b1",
    "dependencies/package-lock.json": "8877584e305eacab211161e8eb8564cbfcf32ef14c23864cbd5a61794020061b",
}
VERSIONS = {
    "node": "v24.22.2",
    "browser": "Google Chrome for Testing 153.0.8010.12",
    "ffmpeg": "ffmpeg version 9.0.2 Copyright (c) 2000-2026 the FFmpeg developers",
    "ffprobe": "ffprobe version 9.0.2 Copyright (c) 2007-2026 the FFmpeg developers",
}


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def utc() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def write_json(path: Path, value: dict, exclusive: bool = False) -> None:
    with path.open("x" if exclusive else "w") as out:
        json.dump(value, out, indent=2)
        out.write("\n")
    path.chmod(0o600)


def load_generator(payload: Path):
    for relative, expected in FROZEN.items():
        if sha(payload / relative) != expected:
            raise RuntimeError(f"Frozen payload mismatch: {relative}")
    spec = importlib.util.spec_from_file_location("frozen_webcodecs_prepare", payload / "prepare-disposable-copy.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if module.SHIPPING_SHA != SHIPPING_SHA:
        raise RuntimeError("Generator source commit differs")
    return module


def shipping_check(root: Path, pins: dict) -> dict:
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    if head != SHIPPING_SHA:
        raise RuntimeError("Shipping checkout HEAD differs")
    subprocess.run(["git", "diff", "--quiet", "HEAD", "--"], cwd=root, check=True)
    hashes = {name: sha(root / name) for name in pins}
    if hashes != pins:
        raise RuntimeError("Shipping source input changed")
    return hashes


def assert_separate(base: Path, shipping: Path, payload: Path) -> None:
    if any(base == other or base.is_relative_to(other) or other.is_relative_to(base)
           for other in (shipping, payload)):
        raise RuntimeError("Evidence base must be separate from both source checkouts")


def prepare(args) -> None:
    payload = Path(__file__).resolve().parent
    shipping = args.shipping_root.resolve(strict=True)
    base = args.base_dir.resolve(strict=True)
    assert_separate(base, shipping, payload)
    module = load_generator(payload)
    source = base / "source"
    if source.exists() or (base / "preparation-journal.json").exists():
        raise RuntimeError("This isolated preparation already exists; never overwrite it")
    shipping_hashes = shipping_check(shipping, module.PINNED)
    journal_path = base / "preparation-journal.json"
    journal = {"schema": "rendprop-hosted-webcodecs-preparation-v1", "status": "preparing",
               "startedAtUTC": utc(), "partialSuite": True, "shippingCommit": SHIPPING_SHA,
               "shippingRoot": str(shipping), "baseDir": str(base),
               "shippingHashesBefore": shipping_hashes,
               "payloadHashes": {path.relative_to(payload).as_posix(): sha(path)
                                  for path in sorted(payload.rglob("*"))
                                  if path.is_file() and "__pycache__" not in path.parts}}
    write_json(journal_path, journal, exclusive=True)
    archive = base / "shipping-source.tar"
    try:
        # Archive the immutable shipping commit before any prototype transform.
        subprocess.run(["git", "archive", "--format=tar", "--output", str(archive), SHIPPING_SHA],
                       cwd=shipping, check=True, timeout=90)
        source.mkdir(mode=0o700)
        with tarfile.open(archive) as bundle:
            bundle.extractall(source, filter="data")
        archive.unlink()
        studio = source / "apps/studio"
        locked_modules = shipping / "apps/studio/node_modules"
        if not locked_modules.is_dir():
            raise RuntimeError("Locked Studio dependencies were not installed")
        (studio / "node_modules").symlink_to(locked_modules, target_is_directory=True)
        manifest = base / "prepared-manifest.json"
        subprocess.run([shutil.which("python3") or "python3", str(payload / "prepare-disposable-copy.py"),
                        "--checkout", str(source), "--dependency-root", str(base / "dependencies"),
                        "--receipt", str(manifest)], check=True, timeout=60)
        journal.update(status="prepared-not-run", manifestSha256=sha(manifest),
                       shippingHashesAfter=shipping_check(shipping, module.PINNED))
    except BaseException as error:
        journal.update(status="preparation-failed", errorClass=type(error).__name__, error=str(error)[:500])
        raise
    finally:
        if archive.exists():
            archive.unlink()
        journal["finishedAtUTC"] = utc()
        write_json(journal_path, journal)
    print(json.dumps({"status": journal["status"], "source": str(source), "manifest": str(manifest)}))


def process_table() -> dict:
    """No arguments/environments: retain only identity, ancestry and executable."""
    raw = subprocess.check_output(["ps", "-axo", "pid=,ppid=,lstart=,comm="], text=True, timeout=5)
    rows = {}
    for line in raw.splitlines():
        parts = line.split(None, 7)
        if len(parts) == 8:
            rows[int(parts[0])] = {"ppid": int(parts[1]), "identity": " ".join(parts[2:])}
    return rows


def descendant_identities(table: dict, root_pid: int) -> dict:
    selected = {root_pid}
    while True:
        added = {pid for pid, row in table.items() if row["ppid"] in selected} - selected
        if not added:
            break
        selected.update(added)
    return {pid: table[pid]["identity"] for pid in selected if pid in table}


def stop_owned_tree(child, journal: dict) -> None:
    # Playwright may create a separate Chromium process group. Capture owned
    # descendants before stopping Node, then verify identity again before signals.
    identities = descendant_identities(process_table(), child.pid)
    journal["timeoutOwnedPids"] = sorted(identities)
    def send(sig):
        current = process_table()
        for pid, identity in identities.items():
            if pid in current and current[pid]["identity"] == identity:
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass
    send(signal.SIGTERM)
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    send(signal.SIGKILL)
    child.wait(timeout=5)


def check_receipt(receipt: dict) -> None:
    if receipt.get("status") != "prototype-case-passed" or receipt.get("partialSuite") is not True:
        raise RuntimeError("No complete partial prototype pass")
    if receipt.get("sourceBoundAtEnd") is not True or receipt.get("externalRequests") != [] or receipt.get("errors") != []:
        raise RuntimeError("Source binding or isolated fixture failed")
    if receipt.get("audioOutput", {}).get("mode") != "default-device":
        raise RuntimeError("The native default audio output was not retained")
    if receipt.get("dependencyTreeBefore") != receipt.get("dependencyTreeAfter") or not receipt.get("dependencyTreeBefore"):
        raise RuntimeError("External dependency tree binding failed")
    proof = receipt.get("webCodecs", {})
    if proof.get("requested") != 90 or len(proof.get("encoded", [])) != 90 or proof.get("finalized") is not True or proof.get("failed") is not False:
        raise RuntimeError("Actual requested/encoded frame evidence incomplete")
    if len(receipt.get("frameTimes", [])) != 90 or receipt.get("proofDownloads") != 1 or receipt.get("mutedSourceConfirmed") is not True:
        raise RuntimeError("Decoded frame, download, or explicit muted scope missing")


def run(args) -> None:
    payload = Path(__file__).resolve().parent
    module = load_generator(payload)
    shipping = args.shipping_root.resolve(strict=True)
    base = args.base_dir.resolve(strict=True)
    assert_separate(base, shipping, payload)
    shipping_check(shipping, module.PINNED)
    manifest_path = base / "prepared-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest["shippingCommit"] != SHIPPING_SHA:
        raise RuntimeError("Prepared commit mismatch")
    source = base / "source"
    for name, digest in manifest["preparedSha256"].items():
        if sha(source / name) != digest:
            raise RuntimeError(f"Prepared source changed: {name}")
    if Path(manifest["externalDependency"]["entry"]).resolve() != (base / "dependencies/node_modules/mediabunny/dist/modules/src/index.js").resolve():
        raise RuntimeError("Prepared dependency alias differs")
    if os.environ.get("GITHUB_RUN_ATTEMPT") != "1":
        raise RuntimeError("Only the original manually dispatched run is authorized")
    run_dir = base / "run-1"
    run_dir.mkdir(mode=0o700)  # Exclusive latch; no automatic/local retry.
    artifacts = run_dir / "artifacts"
    artifacts.mkdir(mode=0o700)
    journal_path = run_dir / "journal.json"
    journal = {"schema": "rendprop-one-hosted-webcodecs-proof-v1", "startedAtUTC": utc(),
               "status": "preflight", "shippingCommit": SHIPPING_SHA, "partialSuite": True,
               "attemptsAuthorized": 1, "audioOutputMode": "default-device",
               "scope": "One three-second narrated, muted-original synthetic prototype; NOT required CI or full feature parity.",
               "runtimeVersionsRaw": {}, "runtimeVersions": {},
               "driverSha256": sha(Path(__file__).resolve()), "manifestSha256": sha(manifest_path),
               "preparationJournalSha256": sha(base / "preparation-journal.json"),
               "githubRunId": os.environ.get("GITHUB_RUN_ID"), "githubRunAttempt": os.environ.get("GITHUB_RUN_ATTEMPT")}
    write_json(journal_path, journal, exclusive=True)
    effective_exit = 1
    try:
        commands = {"node": [str(args.node), "--version"], "browser": [str(args.browser), "--version"],
                    "ffmpeg": ["ffmpeg", "-version"], "ffprobe": ["ffprobe", "-version"]}
        for label, command in commands.items():
            raw = subprocess.check_output(command, text=True, stderr=subprocess.STDOUT, timeout=10).splitlines()[0]
            journal["runtimeVersionsRaw"][label] = raw
            journal["runtimeVersions"][label] = raw.strip()
        if journal["runtimeVersions"] != VERSIONS:
            raise RuntimeError("Runtime differs from the original hosted condition")
        journal["loadBefore"] = os.getloadavg()
        journal["status"] = "running"
        write_json(journal_path, journal)
        env = dict(os.environ, STUDIO_BROWSER_EXECUTABLE=str(args.browser),
                   WEBCODECS_PROOF_MEDIABUNNY_ENTRY=manifest["externalDependency"]["entry"], TMPDIR=str(artifacts))
        with (run_dir / "run.log").open("x") as log:
            child = subprocess.Popen([str(args.node), str(source / "apps/studio/tests/webcodecs-narrated-proof-browser.mjs")],
                                     cwd=source / "apps/studio", env=env, stdout=log, stderr=subprocess.STDOUT,
                                     start_new_session=True)
            try:
                code = child.wait(timeout=150)
            except subprocess.TimeoutExpired:
                journal["childTimedOut"] = True
                stop_owned_tree(child, journal)
                raise RuntimeError("One prototype exceeded the 150 second process limit")
        journal["childExitCode"] = code
        journal["loadAfter"] = os.getloadavg()
        journal["shippingHashesAfter"] = shipping_check(shipping, module.PINNED)
        journal["preparedHashesStillMatch"] = {name: sha(source / name) == digest
                                               for name, digest in manifest["preparedSha256"].items()}
        if not all(journal["preparedHashesStillMatch"].values()):
            raise RuntimeError("Prepared source changed during proof")
        receipts = list(artifacts.glob("rendprop-webcodecs-proof-*/receipt.json"))
        if len(receipts) != 1:
            raise RuntimeError("Expected exactly one browser proof receipt")
        receipt_path = receipts[0]
        receipt = json.loads(receipt_path.read_text())
        journal.update(receipt=str(receipt_path), receiptSha256=sha(receipt_path), receiptStatus=receipt.get("status"))
        if code == 0:
            check_receipt(receipt)
            if receipt["dependencyTreeAfter"] != module.EXPECTED_TREE_SHA256:
                raise RuntimeError("Pinned external dependency tree differs")
            effective_exit = 0
            journal["status"] = "prototype-case-passed"
        else:
            journal["status"] = "prototype-case-failed"
    except Exception as error:
        journal.update(status="prototype-error", errorClass=type(error).__name__, error=str(error)[:500])
    finally:
        journal.update(exitCode=effective_exit, finishedAtUTC=utc(), loadAtEnd=os.getloadavg())
        write_json(journal_path, journal)
    print(json.dumps({"status": journal["status"], "exitCode": effective_exit, "journal": str(journal_path)}))
    raise SystemExit(effective_exit)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("prepare", "run"))
    parser.add_argument("--shipping-root", required=True, type=Path)
    parser.add_argument("--base-dir", required=True, type=Path)
    parser.add_argument("--browser", type=Path)
    parser.add_argument("--node", type=Path, default=shutil.which("node"))
    args = parser.parse_args()
    if args.mode == "prepare":
        prepare(args)
    else:
        if not args.browser or not args.node:
            parser.error("run requires explicit --browser and an available --node")
        args.browser = args.browser.resolve(strict=True)
        args.node = Path(args.node).resolve(strict=True)
        run(args)


if __name__ == "__main__":
    main()
