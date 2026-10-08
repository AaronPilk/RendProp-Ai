#!/usr/bin/env python3
"""Run complete real reflection controller against controlled async boundaries.

No network, upload, provider, customer media, or application containers are used.
Video/API/upload implementations are doubles; controller and journal are real.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent


def save_receipt(out, receipt):
    pending = out / ".receipt.pending"
    with pending.open("w") as f:
        json.dump(receipt, f, indent=2); f.write("\n")
        f.flush(); os.fsync(f.fileno())
    pending.replace(out / "receipt.json")
    fd = os.open(out, os.O_RDONLY)
    try: os.fsync(fd)
    finally: os.close(fd)


def stop_owned_group(child):
    # A compiler leader may exit before a descendant. Always attempt KILL for
    # the exact group created by this runner, even after wait() returns.
    for sig in [signal.SIGTERM, signal.SIGKILL]:
        try: os.killpg(child.pid, sig)
        except ProcessLookupError: pass
        try: child.wait(timeout=2)
        except subprocess.TimeoutExpired: pass
    if child.poll() is None:
        raise RuntimeError("Owned command exit unknown after bounded cleanup")


def run_command(command, out, label, seconds, receipt):
    argv = list(map(str, command))
    stdout_path, stderr_path = out / f"{label}.stdout.log", out / f"{label}.stderr.log"
    started = time.monotonic()
    row = {"label": label, "argv": argv, "timeoutSeconds": seconds,
           "exit": None, "timedOut": False, "failure": None}
    receipt["commands"].append(row)
    save_receipt(out, receipt)
    child = None
    try:
        with stdout_path.open("xb") as stdout, stderr_path.open("xb") as stderr:
            try:
                if time.monotonic() - started >= seconds:
                    raise TimeoutError("Command deadline elapsed before launch")
                child = subprocess.Popen(argv, cwd=ROOT, stdin=subprocess.DEVNULL,
                                         stdout=stdout, stderr=stderr, start_new_session=True)
                while child.poll() is None:
                    if time.monotonic() - started >= seconds:
                        raise TimeoutError(f"{label} exceeded its {seconds}s bound; no retry")
                    if stdout_path.stat().st_size + stderr_path.stat().st_size > 16 * 1024 * 1024:
                        raise RuntimeError("Command output exceeded its 16MiB bound")
                    time.sleep(.05)
                row["exit"] = child.returncode
            finally:
                if child is not None:
                    stop_owned_group(child)
                    row["exit"] = child.returncode
                stdout.flush(); stderr.flush()
                os.fsync(stdout.fileno()); os.fsync(stderr.fileno())
        if stdout_path.stat().st_size + stderr_path.stat().st_size > 16 * 1024 * 1024:
            raise RuntimeError("Command output exceeded its 16MiB bound")
        if time.monotonic() - started >= seconds:
            raise TimeoutError(f"{label} exceeded its {seconds}s bound; no retry")
        output = stdout_path.read_bytes().decode("utf-8")
        if row["exit"] != 0:
            raise RuntimeError(f"{label} failed with exit {row['exit']}: {out}")
        return output
    except BaseException as error:
        row["timedOut"] = isinstance(error, TimeoutError)
        row["failure"] = {"class": type(error).__name__, "reason": str(error)}
        raise
    finally:
        row["elapsedSeconds"] = time.monotonic() - started
        logs = [p for p in [stdout_path, stderr_path] if p.is_file()]
        if sum(p.stat().st_size for p in logs) <= 16 * 1024 * 1024:
            (out / f"{label}.log").write_bytes(b"".join(p.read_bytes() for p in logs))
        row["logs"] = []
        for p in logs:
            with p.open("rb") as f: digest = hashlib.file_digest(f, "sha256").hexdigest()
            row["logs"].append({"path": str(p), "bytes": p.stat().st_size, "sha256": digest})
        save_receipt(out, receipt)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", action="store_true")
    parser.add_argument("--evidence-dir", type=Path)
    args = parser.parse_args()
    if args.evidence_dir is not None:
        out = args.evidence_dir
        if not out.is_absolute() or out.exists() or not out.parent.is_dir() or out.parent.is_symlink():
            raise RuntimeError("New absolute owned evidence directory required")
        out.mkdir(mode=0o700)
    else:
        out = Path(tempfile.mkdtemp(prefix="rendprop-reflection-controller-",
                                   dir=os.environ.get("RUNNER_TEMP")))
    source_path = HERE / "BaselineReflectionRemoval.swift" if args.baseline else ROOT / "apps/ios/Rendprop/Render/ReflectionRemoval.swift"
    api_path = ROOT / "apps/ios/Rendprop/Networking/ReflectionAPI.swift"
    controller = source_path.read_text().replace("private(set) ", "").replace("private ", "fileprivate ")
    if args.baseline:
        # Baseline had an unrelated Swift isolation compile error. This changes
        # only that annotation so its actual async behavior can be executed.
        controller = controller.replace("    static var directory: URL", "    nonisolated static var directory: URL")
    fixture = (HERE / "checks.swift").read_text()
    if args.baseline:
        before, rest = fixture.split("// FIXED_ONLY_START")
        _, after = rest.split("// FIXED_ONLY_END")
        fixture = before + after
    generated = out / "ControllerChecks.swift"
    generated.write_text(fixture.replace("// REAL_CONTROLLER", controller).replace("// REAL_API", api_path.read_text()))
    binary = out / "controller-checks"
    receipt = {"baseline": args.baseline, "status": "running", "runnerSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "sourceSHA256": [
        {"path": str(p.relative_to(ROOT)), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
        for p in [source_path, api_path, HERE / "checks.swift"]], "commands": []}
    try:
        run_command(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", generated, "-o", binary], out, "compile", 240, receipt)
        output = run_command([binary, out / "documents", "baseline" if args.baseline else "fixed"], out, "execute", 120, receipt)
        receipt["result"] = json.loads(output)
        receipt["status"] = "pass"
    except BaseException as error:
        receipt["status"] = "fail"
        receipt["failure"] = {"class": type(error).__name__, "reason": str(error)}
        raise
    finally:
        save_receipt(out, receipt)
    print(json.dumps({"evidence": str(out), **receipt["result"]}, indent=2))


if __name__ == "__main__": main()
