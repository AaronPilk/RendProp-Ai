#!/usr/bin/env python3
"""Offline edge regression: real tests, exact receipts, no inherited credentials.

This never starts an API server or permits test network access. Dependency
resolution must use the existing Deno cache; a cache miss is a reported failure,
not permission to send a request. Logs stay in a fresh retained /tmp directory.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def summary_counts(output):
    # A test named "unknown fields are ignored" is not a skipped test. Inspect
    # the runner's final summary only; otherwise the gate produces false alarms.
    lines = re.findall(r"^(?:ok|FAILED) \| \d+ passed \| \d+ failed[^\n]*$", output, re.MULTILINE)
    require(len(lines) == 1, "Missing or ambiguous Deno summary")
    summary = lines[0]
    passed = int(re.search(r"(\d+) passed", summary).group(1))
    failed = int(re.search(r"(\d+) failed", summary).group(1))
    ignored = re.search(r"(\d+) ignored", summary)
    return passed, failed, int(ignored.group(1)) if ignored else 0


def main():
    root = Path(__file__).resolve().parents[2]
    functions = root / "services/supabase/functions"
    deno = shutil.which("deno")
    require(deno is not None, "Deno must already be installed")
    # The cache path is discovered, not guessed. No source code executes here.
    info = json.loads(subprocess.check_output([deno, "info", "--no-config", "--json"], text=True))
    environment = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "DENO_DIR": info["denoDir"],
        "NO_COLOR": "1", "DENO_NO_PROMPT": "1",
    }
    out = Path(tempfile.mkdtemp(prefix="rendprop-edge-audit-", dir="/tmp"))
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    tests = sorted(p for p in functions.rglob("*.ts") if p.name.endswith((".test.ts", "_test.ts")))
    entrypoints = sorted(p for p in functions.glob("*/index.ts") if p.parent.name != "_shared")
    require(tests and entrypoints, "Missing real tests or route entrypoints")
    manifest = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted(set(tests + entrypoints))}
    common = ["--no-config", "--no-lock", "--cached-only", "--node-modules-dir=manual"]
    permissions = ["--deny-net", "--deny-run", "--deny-write", "--allow-env",
                   f"--allow-read={root}", "--no-prompt"]

    def run(name, command, cwd=functions):
        started = datetime.now(timezone.utc).isoformat()
        try:
            result = subprocess.run(command, cwd=cwd, env=environment, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    timeout=300, check=False)
            code, output = result.returncode, result.stdout
        except subprocess.TimeoutExpired as error:
            code = 124
            output = error.stdout or b""
            if isinstance(output, bytes):
                output = output.decode("utf-8", errors="replace")
            output += "\nFAIL: five-minute command deadline exceeded\n"
        path = out / (name + ".log")
        path.write_text(output)
        record = {"name": name, "command": command, "cwd": str(cwd), "exit": code,
                  "started": started, "log": str(path),
                  "logSHA256": hashlib.sha256(path.read_bytes()).hexdigest()}
        return record, output

    unit, output = run("edge-unit", [deno, "test", *common, *permissions,
                                     *[str(p.relative_to(functions)) for p in tests]])
    try:
        passed, failed, ignored = summary_counts(output)
    except RuntimeError:
        passed, failed, ignored = 0, -1, -1
    unit["testFiles"] = len(tests)
    unit["passedTests"], unit["failedTests"], unit["ignoredTests"] = passed, failed, ignored
    unit["accepted"] = unit["exit"] == 0 and passed > 0 and failed == 0 and ignored == 0
    print(f"edge-unit: exit={unit['exit']}, accepted={unit['accepted']}, passed={unit['passedTests']}", flush=True)

    def check_entrypoint(path):
        record, _ = run("check-" + path.parent.name,
                        # check has no --cached-only in Deno 2.7.13. Denying
                        # imports permits existing cache use without downloads.
                        [deno, "check", "--no-config", "--no-lock",
                         "--node-modules-dir=manual", "--deny-import",
                         str(path.relative_to(functions))])
        return record

    with ThreadPoolExecutor(max_workers=2) as pool:
        checks = list(pool.map(check_entrypoint, entrypoints))
    for check in checks:
        print(f"{check['name']}: exit={check['exit']}", flush=True)

    # Execute the same real Turnstile tests against an actual copied-source
    # fail-open defect. A loader/type error is NOT a successful negative control.
    mutant_dir = out / "turnstile-mutant"
    mutant_dir.mkdir()
    original = (functions / "leads/turnstile.ts").read_text()
    require(original.count("return optedOut;") == 1, "Mutation anchor changed")
    (mutant_dir / "turnstile.ts").write_text(original.replace("return optedOut;", "return true;"))
    (mutant_dir / "turnstile.test.ts").write_bytes((functions / "leads/turnstile.test.ts").read_bytes())
    negative, negative_output = run("negative-turnstile", [deno, "test", *common, *permissions,
                                                           str(mutant_dir / "turnstile.test.ts")])
    try:
        negative_passed, negative_failed, negative_ignored = summary_counts(negative_output)
    except RuntimeError:
        negative_passed, negative_failed, negative_ignored = 0, 0, -1
    negative["passedTests"] = negative_passed
    negative["failedTests"] = negative_failed
    negative["ignoredTests"] = negative_ignored
    negative["accepted"] = negative["exit"] == 1 and negative_failed > 0 and negative_ignored == 0
    print(f"negative-turnstile: exit={negative['exit']}, detected={negative['accepted']}", flush=True)
    report = {
        "sourceCommit": source, "denoVersion": info["denoVersion"],
        "environment": "cleared; PATH, discovered DENO_DIR, NO_COLOR and DENO_NO_PROMPT only",
        "sourceManifestSHA256": hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest(),
        "sourceFiles": manifest, "unit": unit, "entrypointChecks": checks,
        "negativeControl": negative, "runtimeNetworkPermitted": False,
        "liveRoutesTested": 0, "productionMutations": 0,
        "passed": unit["accepted"] and all(c["exit"] == 0 for c in checks) and negative["accepted"],
    }
    (out / "receipt.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Retained evidence:", out / "receipt.json", flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
