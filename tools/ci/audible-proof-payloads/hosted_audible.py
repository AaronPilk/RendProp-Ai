#!/usr/bin/env python3
"""ONE hosted audible fixture plus fault controls; partial evidence, never required CI."""
from __future__ import annotations
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import runpy
import shutil
import signal
import subprocess
import tarfile
from types import SimpleNamespace

SHIPPING_SHA = "1c561d7b91d9b75bd7ba29aa081fcba959089fee"
SHIPPING_TREE = "786b394ac6670007d96918372af2ee33aaaf3215"
ARCHIVE_SHA = "322ddba3e7efcb8e5e982a6f77d8c25f96ffb40e75c9c8581b061788895b0649"
ARCHIVE_BYTES = 201492480
SOURCE_FILES = 3340
SOURCE_AGGREGATE = "d66a01ab8689ac9907b75ea8b678e5e59506406a4e933b89375b64d21daee88b"
MODE_AGGREGATE = "7060984f4f3d27683c2b8a01d765b8a51ea123251d19c288537e1db7b09c4df9"
V5 = "webcodecs-audible-prototype-v5"
PRIOR = "webcodecs-narrated-prototype-v2"
FROZEN = {
    V5 + "/payload-hashes.json": "aab36c47db0ef066fa66d009dedaa8e6866e84b97f33bd1ec9afd66f5be347b4",
    PRIOR + "/prepare-disposable-copy.py": "8468b413d7beb7eae24703cc3c6ae65d28a6671d253af8a9bfd66b7a809428b1",
    PRIOR + "/experimental-webcodecs.ts": "773e6860f48963746f4233c240292dca63092e288493c6bc43fbbb9c51b437a3",
    "dependencies/package-lock.json": "8877584e305eacab211161e8eb8564cbfcf32ef14c23864cbd5a61794020061b",
}
VERSIONS = {
    "node": "v24.22.2",
    "browser": "Google Chrome for Testing 153.0.8010.12",
    "ffmpeg": "ffmpeg version 9.0.2 Copyright (c) 2000-2026 the FFmpeg developers",
    "ffprobe": "ffprobe version 9.0.2 Copyright (c) 2007-2026 the FFmpeg developers",
}
CASES = ["audible-original", "late-promise-with-native-playback", "drop-first-block",
         "withhold-credits", "delay-native-play", "stall-original-100ms",
         "cancel-before-capture", "cancel-during-capture", "revision-during-capture",
         "suspend-during-capture"]


def sha(path: Path) -> str:
    with path.open("rb") as stream:
        return hash_stream(stream)


def hash_stream(stream) -> str:
    digest = hashlib.sha256()
    while chunk := stream.read(1024 * 1024):
        digest.update(chunk)
    return digest.hexdigest()


def utc() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def write_json(path: Path, value: dict, exclusive: bool = False) -> None:
    with path.open("x" if exclusive else "w") as out:
        json.dump(value, out, indent=2)
        out.write("\n")
    path.chmod(0o600)


def load_generator(payload: Path):
    for name, expected in FROZEN.items():
        if sha(payload / name) != expected:
            raise RuntimeError(f"Frozen payload changed: {name}")
    manifest = json.loads((payload / V5 / "payload-hashes.json").read_text())
    if manifest["shippingCommit"] != SHIPPING_SHA or len(manifest["payloadSha256"]) != 10:
        raise RuntimeError("Audible payload manifest identity changed")
    for name, expected in manifest["payloadSha256"].items():
        if Path(name).name != name or sha(payload / V5 / name) != expected:
            raise RuntimeError(f"Audible payload changed: {name}")
    module = SimpleNamespace(**runpy.run_path(str(payload / PRIOR / "prepare-disposable-copy.py")))
    if module.SHIPPING_SHA != SHIPPING_SHA or len(module.PINNED) != 19:
        raise RuntimeError("Prior shipping pins changed")
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
        raise RuntimeError("Evidence base must be separate from source and payload checkouts")


def archive_binding(archive: Path, source: Path, outputs: dict | None = None) -> dict:
    # Transport headers/umask may differ across Git versions. Content and
    # canonical Git modes/link inventory remain authoritative. Retain actual
    # transport identity and compare it with this run's freeze before/after.
    archive_sha, archive_bytes = sha(archive), archive.stat().st_size
    count, items, mode_items, symlinks = 0, [], [], 0
    with tarfile.open(archive) as bundle:
        for member in bundle:
            relative = Path(member.name)
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError("Unsafe source archive path")
            target = source / relative
            if member.isfile():
                if target.is_symlink() or not target.is_file():
                    raise RuntimeError(f"Source file type changed: {member.name}")
                mode = "100755" if member.mode & 0o100 else "100644"
                actual_mode = "100755" if target.stat().st_mode & 0o100 else "100644"
                if mode != actual_mode:
                    raise RuntimeError(f"Source executable mode changed: {member.name}")
                mode_items.append(member.name + "\t" + mode + "\t\n")
                expected = hash_stream(bundle.extractfile(member))
                if sha(target) != expected:
                    raise RuntimeError(f"Source archive binding changed: {member.name}")
                items.append(member.name + "\t" + expected + "\n")
                count += 1
            elif member.issym():
                if not target.is_symlink() or os.readlink(target) != member.linkname:
                    raise RuntimeError(f"Source link changed: {member.name}")
                mode_items.append(member.name + "\t120000\t" + member.linkname + "\n")
                symlinks += 1
            elif not member.isdir() and not member.type == tarfile.XGLTYPE:
                raise RuntimeError(f"Unsupported source archive member: {member.name}")
    aggregate = hashlib.sha256("".join(sorted(items)).encode()).hexdigest()
    modes = hashlib.sha256("".join(sorted(mode_items)).encode()).hexdigest()
    if count != SOURCE_FILES or aggregate != SOURCE_AGGREGATE or modes != MODE_AGGREGATE:
        raise RuntimeError("Full archived source content/mode/link inventory changed")
    for name, expected in (outputs or {}).items():
        if sha(source / name) != expected:
            raise RuntimeError(f"Prepared output changed: {name}")
    return {"unchangedArchiveFiles": count, "aggregateSha256": aggregate,
            "canonicalModeAndSymlinkAggregateSha256": modes,
            "unchangedArchiveSymlinks": symlinks, "prototypeOutputsMatch": len(outputs or {}),
            "archiveSha256": archive_sha, "archiveBytes": archive_bytes,
            "referenceArchiveSha256Matches": archive_sha == ARCHIVE_SHA,
            "referenceArchiveBytesMatches": archive_bytes == ARCHIVE_BYTES}


def dependency_check(base: Path, module) -> dict:
    lock = base / "dependencies/package-lock.json"
    package = base / "dependencies/node_modules/mediabunny"
    entry = package / "dist/modules/src/index.js"
    lock_data = json.loads(lock.read_text())["packages"]["node_modules/mediabunny"]
    if (sha(lock) != module.EXPECTED_LOCK_SHA256 or lock_data.get("version") != "1.65.2"
            or lock_data.get("integrity") != module.EXPECTED_INTEGRITY
            or sha(entry) != module.EXPECTED_ENTRY_SHA256
            or module.tree_digest(package) != module.EXPECTED_TREE_SHA256):
        raise RuntimeError("Pinned external dependency changed")
    return {"entry": str(entry), "packageTreeSha256": module.EXPECTED_TREE_SHA256,
            "packageLockSha256": sha(lock), "entrySha256": sha(entry)}


def prepare(args) -> None:
    payload = Path(__file__).resolve().parent
    shipping, base = args.shipping_root.resolve(strict=True), args.base_dir.resolve(strict=True)
    assert_separate(base, shipping, payload)
    module = load_generator(payload)
    if (base / "source").exists() or (base / "preparation-journal.json").exists():
        raise RuntimeError("Preparation already exists; never overwrite or retry it")
    journal_path = base / "preparation-journal.json"
    journal = {"schema": "rendprop-hosted-audible-preparation-v1", "status": "preparing",
               "startedAtUTC": utc(), "shippingCommit": SHIPPING_SHA, "partialSuite": True,
               "shippingHashesBefore": shipping_check(shipping, module.PINNED),
               "payloadHashes": {p.relative_to(payload).as_posix(): sha(p)
                                  for p in sorted(payload.rglob("*"))
                                  if p.is_file() and "__pycache__" not in p.parts}}
    write_json(journal_path, journal, exclusive=True)
    try:
        tree = subprocess.check_output(["git", "rev-parse", SHIPPING_SHA + "^{tree}"],
                                       cwd=shipping, text=True).strip()
        if tree != SHIPPING_TREE:
            raise RuntimeError("Frozen shipping tree differs")
        archive = base / "shipping-source.tar"
        journal["archiveTransport"] = {
            "gitVersion": subprocess.check_output(["git", "--version"], text=True, timeout=10).strip(),
            "commandFormat": "git archive --format=tar <exact shipping SHA>",
            "referenceArchiveSha256": ARCHIVE_SHA,
            "referenceArchiveBytes": ARCHIVE_BYTES,
            "referenceTransportIdentityRequired": False,
            "authoritativeContentAggregateSha256": SOURCE_AGGREGATE,
            "authoritativeModeAndSymlinkAggregateSha256": MODE_AGGREGATE,
        }
        subprocess.run(["git", "archive", "--format=tar", "--output", str(archive), SHIPPING_SHA],
                       cwd=shipping, check=True, timeout=90)
        journal["shippingArchiveBinding"] = archive_binding(archive, shipping)
        source = base / "source"
        source.mkdir(mode=0o700)
        with tarfile.open(archive) as bundle:
            bundle.extractall(source, filter="data")
        journal["sourceArchiveBindingBeforePreparation"] = archive_binding(archive, source)
        locked = shipping / "apps/studio/node_modules"
        if not locked.is_dir():
            raise RuntimeError("Locked Studio dependencies missing")
        (source / "apps/studio/node_modules").symlink_to(locked, target_is_directory=True)
        dependency_check(base, module)
        manifest = base / "prepared-manifest.json"
        subprocess.run([shutil.which("python3") or "python3", str(payload / V5 / "prepare-audible-copy.py"),
                        "--checkout", str(source), "--dependency-root", str(base / "dependencies"),
                        "--receipt", str(manifest)], check=True, timeout=60)
        prepared = json.loads(manifest.read_text())
        binding = archive_binding(archive, source, prepared["outputsSha256"])
        freeze = {"schema": "rendprop-hosted-audible-source-freeze-v1", "shippingCommit": SHIPPING_SHA,
                  "shippingTree": SHIPPING_TREE, "archiveSha256": sha(archive),
                  "archiveBytes": archive.stat().st_size, "archiveBinding": binding,
                  "preparedManifestSha256": sha(manifest), "runtimeExecuted": False}
        write_json(base / "source-freeze.json", freeze, exclusive=True)
        journal.update(status="prepared-not-run", preparedManifestSha256=sha(manifest),
                       sourceBindingAfterPreparation=binding,
                       shippingHashesAfter=shipping_check(shipping, module.PINNED))
    except BaseException as error:
        journal.update(status="preparation-failed", errorClass=type(error).__name__, error=str(error)[:800])
        raise
    finally:
        journal["finishedAtUTC"] = utc()
        write_json(journal_path, journal)
    print(json.dumps({"status": journal["status"], "source": str(source)}))


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


def require(value, message: str) -> None:
    if not value:
        raise RuntimeError(message)


def check_receipt(receipt: dict, expected_sources: dict | None = None) -> None:
    require(receipt.get("status") == "prototype-case-passed" and receipt.get("partialSuite") is True,
            "No completed partial audible suite pass")
    require(receipt.get("runtimeProfile") == "hosted-exact", "Local-observation mode is not hosted evidence")
    require(receipt.get("externalRequests") == [] and receipt.get("errors") == [], "Fixture isolation failed")
    require(bool(receipt.get("sourceHashesBefore")) and
            receipt.get("sourceHashesBefore") == receipt.get("sourceHashesAfter"), "Receipt source binding failed")
    if expected_sources is not None:
        require(receipt["sourceHashesBefore"] == expected_sources, "Receipt source inputs differ from prepared files")
    require(receipt.get("dependencyTreeBefore") == receipt.get("dependencyTreeAfter") ==
            "b68f9bb6b4ffb438935e12e684c7b1a989d1ad592afef166ad1ef1d1792ebe64", "Receipt dependency binding failed")
    cases = receipt.get("cases", [])
    require([row.get("name") for row in cases] == CASES, "Two positive and eight refusal cases are required")
    require(len(receipt.get("checks", [])) == 3, "Media oracle completion evidence missing")
    for index, row in enumerate(cases):
        proof = row.get("webCodecs", {})
        if index < 2:
            require(row.get("result", {}).get("ok") is True, "Positive audible case failed")
            require(proof.get("requested") == 90 and len(proof.get("encoded", [])) == 90
                    and proof.get("finalized") is True and proof.get("failed") is False,
                    "Actual encoded evidence incomplete")
            timestamps = sorted(item.get("timestamp", float("nan")) for item in proof["encoded"])
            require(all(isinstance(t, (int, float)) and math.isfinite(t) and abs(t-i/30) <= .001
                        for i, t in enumerate(timestamps)), "Encoded PTS evidence changed")
            audio = proof.get("audio", {})
            require(audio.get("frames") == 144000 and audio.get("blocks") == 141 and
                    audio.get("channels") == 2 and audio.get("sampleRate") == 48000 and
                    0 < audio.get("maxQueueDepth", 99) <= 8, "PCM sample/count/credit evidence incomplete")
            pcm = row.get("pcmTrace") if index == 0 else row.get("pcm")
            require(pcm and pcm.get("audioStateAfterClose") == "closed" and
                    pcm.get("ownedTracksAfterClose") == 0, "Positive audio cleanup failed")
            require(row.get("probes") if index == 0 else row.get("pcmProbe"), "Actual media probe evidence missing")
            if index == 1:
                require(row.get("injected") is True and row.get("outerAudioState") == "closed",
                        "Late play-promise positive injection/cleanup missing")
        else:
            require(row.get("result", {}).get("ok") is False and row.get("outerAudioState") == "closed",
                    "Refusal or cleanup evidence incomplete")
            require(proof.get("finalized") is not True and proof.get("failed") is True,
                    "Refused output was finalized")
            if row["name"] not in ("drop-first-block", "withhold-credits"):
                require(row.get("injected") is True, "Refusal injection did not execute")
            pcm = row.get("pcm")
            if pcm:
                require(pcm.get("audioStateAfterClose") == "closed" and pcm.get("ownedTracksAfterClose") == 0,
                        "Refused audio resource cleanup failed")
    first = cases[0]["probes"]
    require(first.get("decodedFrames") == 90 and abs(first.get("duration", 99)-3) <= 2/30 and
            math.isfinite(first.get("avDurationGap", float("nan"))) and first["avDurationGap"] <= 2/30,
            "Decoded PTS/duration oracle evidence incomplete")
    require(bool(first.get("pixels")) and bool(first.get("pcm")), "Transition/PCM actual probes absent")


def run(args) -> None:
    payload = Path(__file__).resolve().parent
    shipping, base = args.shipping_root.resolve(strict=True), args.base_dir.resolve(strict=True)
    assert_separate(base, shipping, payload)
    module = load_generator(payload)
    shipping_check(shipping, module.PINNED)
    manifest_path = base / "prepared-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    freeze_path = base / "source-freeze.json"
    freeze = json.loads(freeze_path.read_text())
    require(manifest["shippingCommit"] == freeze["shippingCommit"] == SHIPPING_SHA, "Prepared commit mismatch")
    require(sha(manifest_path) == freeze["preparedManifestSha256"], "Prepared manifest changed")
    source, archive = base / "source", base / "shipping-source.tar"
    binding = archive_binding(archive, source, manifest["outputsSha256"])
    require(binding == freeze["archiveBinding"], "Frozen full source binding changed")
    dependency = dependency_check(base, module)
    require(Path(manifest["externalDependency"]["entry"]).resolve() == Path(dependency["entry"]).resolve(),
            "Prepared dependency alias differs")
    require(os.environ.get("GITHUB_RUN_ATTEMPT") == "1", "Only one original dispatch is authorized")
    run_dir = base / "run-1"
    run_dir.mkdir(mode=0o700)  # Exclusive one-run latch; no retries.
    artifacts = run_dir / "artifacts"
    artifacts.mkdir(mode=0o700)
    journal_path = run_dir / "journal.json"
    journal = {"schema": "rendprop-one-hosted-audible-proof-v1", "status": "preflight",
               "startedAtUTC": utc(), "shippingCommit": SHIPPING_SHA, "partialSuite": True,
               "attemptsAuthorized": 1, "runtimeProfile": "hosted-exact",
               "audioOutputMode": "AudioContext default device; frozen Playwright headless launch",
               "scope": "Known three-second audible original2x fixture, two positive/eight refusal cases; NOT required CI or full Studio/browser parity.",
               "runtimeVersionsRaw": {}, "runtimeVersions": {},
               "driverSha256": sha(Path(__file__).resolve()), "preparedManifestSha256": sha(manifest_path),
               "preparationJournalSha256": sha(base / "preparation-journal.json"),
               "sourceFreezeSha256": sha(freeze_path), "archiveBindingBefore": binding,
               "githubRunId": os.environ.get("GITHUB_RUN_ID"), "githubRunAttempt": os.environ.get("GITHUB_RUN_ATTEMPT")}
    write_json(journal_path, journal, exclusive=True)
    effective_exit, child = 1, None
    previous_handlers = {}
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"Hosted driver interrupted by signal {signum}")
    try:
        for sig in (signal.SIGTERM, signal.SIGINT):
            previous_handlers[sig] = signal.signal(sig, interrupted)
        for label, command in {
            "node": [str(args.node), "--version"], "browser": [str(args.browser), "--version"],
            "ffmpeg": ["ffmpeg", "-version"], "ffprobe": ["ffprobe", "-version"]
        }.items():
            raw = subprocess.check_output(command, text=True, stderr=subprocess.STDOUT, timeout=10).splitlines()[0]
            journal["runtimeVersionsRaw"][label] = raw
            journal["runtimeVersions"][label] = raw.strip()
        require(journal["runtimeVersions"] == VERSIONS, "Hosted runtime differs from pinned condition")
        expected_sources = {name: sha(source / "apps/studio" / name) for name in (
            "src/editor/experimental-webcodecs.ts", "src/editor/audible-pcm.ts",
            "src/editor/audible-pcm-worklet.js", "tests/audible-proof-fixture.ts",
            "tests/audible-proof-fixture.html", "tests/audible-proof-browser.mjs",
            *["src/editor/" + name + ".ts" for name in
              ("export", "model", "media", "recording-clock", "overlay-renderer", "mp4-cadence")])}
        journal.update(status="running", loadBefore=os.getloadavg(), expectedReceiptSourceHashes=expected_sources)
        write_json(journal_path, journal)
        env = dict(os.environ, STUDIO_BROWSER_EXECUTABLE=str(args.browser),
                   AUDIBLE_PROOF_MEDIABUNNY_ENTRY=dependency["entry"], TMPDIR=str(artifacts))
        with (run_dir / "run.log").open("x") as log:
            child = subprocess.Popen([str(args.node), str(source / "apps/studio/tests/audible-proof-browser.mjs")],
                                     cwd=source / "apps/studio", env=env, stdout=log, stderr=subprocess.STDOUT,
                                     start_new_session=True)
            try:
                code = child.wait(timeout=150)
            except subprocess.TimeoutExpired:
                journal["childTimedOut"] = True
                stop_owned_tree(child, journal)
                raise RuntimeError("One audible suite exceeded the150-second process limit")
        journal.update(childExitCode=code, loadAfter=os.getloadavg())
        paths = list(artifacts.glob("rendprop-audible-webcodecs-*/receipt.json"))
        require(len(paths) == 1, "Expected exactly one browser suite receipt")
        receipt_path = paths[0]
        receipt = json.loads(receipt_path.read_text())
        journal.update(receipt=str(receipt_path), receiptSha256=sha(receipt_path), receiptStatus=receipt.get("status"))
        if code == 0:
            check_receipt(receipt, expected_sources)
            effective_exit = 0
            journal["status"] = "prototype-case-passed"
        else:
            journal["status"] = "prototype-case-failed"
    except BaseException as error:
        journal.update(status="prototype-error", errorClass=type(error).__name__, error=str(error)[:800])
    finally:
        if child is not None and child.poll() is None:
            try:
                stop_owned_tree(child, journal)
            except BaseException as error:
                journal["ownedCleanupError"] = str(error)[:500]
                effective_exit = 1
        try:
            journal["archiveBindingAfter"] = archive_binding(archive, source, manifest["outputsSha256"])
            require(journal["archiveBindingAfter"] == binding, "Full source post-binding changed")
            journal["shippingArchiveBindingAfter"] = archive_binding(archive, shipping)
            journal["shippingHashesAfter"] = shipping_check(shipping, module.PINNED)
            journal["dependencyAfter"] = dependency_check(base, module)
            load_generator(payload)
        except BaseException as error:
            effective_exit = 1
            journal.update(status="prototype-error", postBindingErrorClass=type(error).__name__, postBindingError=str(error)[:800])
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)
        if effective_exit != 0 and journal["status"] == "prototype-case-passed":
            journal["status"] = "prototype-error"
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
            parser.error("run requires explicit --browser and available --node")
        args.browser = args.browser.resolve(strict=True)
        args.node = Path(args.node).resolve(strict=True)
        run(args)


if __name__ == "__main__":
    main()
