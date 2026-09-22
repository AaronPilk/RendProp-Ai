#!/usr/bin/env python3
"""Offline edge regression: real tests, exact receipts, no inherited credentials.

This never starts an API server or permits test network access. The runner
prepares its own dependencies first: one `deno install` pass, with the network
allowed for that step alone, resolves the pinned std/npm imports into the Deno
cache and the functions' node_modules directory. Every test and typecheck
afterwards runs --cached-only / --deny-import; a cache miss there is a reported
failure, not permission to send a request. Logs stay in a fresh retained /tmp
directory.
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

# Network plumbing the preparation step may inherit. Proxies and CA bundles
# are how a sandbox reaches deno.land and npm at all; none of them is a
# service credential, and the test/check steps never see them.
PREPARATION_ENV_PASSTHROUGH = (
    "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
    "DENO_CERT", "DENO_TLS_CA_STORE", "SSL_CERT_FILE", "NPM_CONFIG_REGISTRY",
)


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


def first_party(path):
    # node_modules is Deno's managed npm mirror, created by the preparation
    # step. It is neither a test source nor part of the bound source manifest.
    return "node_modules" not in path.parts


def main():
    root = Path(__file__).resolve().parents[2]
    def clean_source():
        require(not subprocess.check_output(["git", "status", "--porcelain"], cwd=root, text=True).strip(),
                "Checkpoint clean source before collecting an edge receipt")
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    source = clean_source()
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
    preparation_environment = dict(environment)
    for name in PREPARATION_ENV_PASSTHROUGH:
        if name in os.environ:
            preparation_environment[name] = os.environ[name]
    out = Path(tempfile.mkdtemp(prefix="rendprop-edge-audit-", dir="/tmp"))
    tests = sorted(p for p in functions.rglob("*.ts")
                   if first_party(p.relative_to(functions)) and p.name.endswith((".test.ts", "_test.ts")))
    entrypoints = sorted(p for p in functions.glob("*/index.ts") if p.parent.name not in ("_shared", "node_modules"))
    require(tests and entrypoints, "Missing real tests or route entrypoints")
    def source_manifest():
        # Tests and entrypoints alone omit the shared adapters being repaired.
        # Bind all first-party edge code and SQL fixtures, not only test names.
        paths = {p for p in functions.rglob("*.ts") if first_party(p.relative_to(functions))}
        paths.update((root / "services/supabase").glob("*/*.sql"))
        # The upload test registration files import actual-handler fixtures
        # from tools/audit. Bind those bodies, not just their three-line imports.
        paths.update((root / "tools/audit").glob("*.ts"))
        paths.add(Path(__file__).resolve())
        paths.update(functions.glob("deno.*"))
        return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted(paths) if p.is_file()}
    manifest = source_manifest()
    # auto, not manual: manual expects somebody else to have populated
    # node_modules and fails a cold checkout with "Could not find a matching
    # package for 'npm:@supabase/supabase-js@2'". auto reuses the directory the
    # preparation step below populates, and --cached-only still refuses any
    # download during the tests themselves.
    common = ["--no-config", "--no-lock", "--cached-only", "--node-modules-dir=auto"]
    permissions = ["--deny-net", "--deny-run", "--deny-write", "--allow-env",
                   f"--allow-read={root}", "--no-prompt"]

    def run(name, command, cwd=functions, env=environment):
        started = datetime.now(timezone.utc).isoformat()
        try:
            result = subprocess.run(command, cwd=cwd, env=env, text=True,
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

    # Preparation: the only step that may touch the network. `deno install
    # --entrypoint` walks exactly the module graphs the tests and route
    # entrypoints import, caches the pinned std/jsr/npm dependencies and lays
    # out node_modules; it executes no test or route code. Idempotent on a
    # warm cache (the log then says "Downloaded 0 packages").
    preparation, preparation_output = run(
        "prepare-dependencies",
        [deno, "install", "--no-config", "--no-lock", "--node-modules-dir=auto", "--entrypoint",
         *[str(p.relative_to(functions)) for p in tests + entrypoints]],
        env=preparation_environment)
    preparation["networkPermitted"] = True
    preparation["inheritedEnvironment"] = sorted(name for name in PREPARATION_ENV_PASSTHROUGH
                                                 if name in preparation_environment)
    preparation["nodeModulesDir"] = str(functions / "node_modules")
    preparation["accepted"] = preparation["exit"] == 0 and (functions / "node_modules").is_dir()
    print(f"prepare-dependencies: exit={preparation['exit']}, accepted={preparation['accepted']}", flush=True)
    require(preparation["accepted"], f"Dependency preparation failed; see {preparation['log']}")

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
                        # imports permits existing cache use without downloads;
                        # the npm side resolves from the prepared node_modules.
                        [deno, "check", "--no-config", "--no-lock",
                         "--node-modules-dir=auto", "--deny-import",
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
    unchanged = source_manifest() == manifest and clean_source() == source
    report = {
        "sourceCommit": source, "denoVersion": info["denoVersion"],
        "environment": "cleared; PATH, discovered DENO_DIR, NO_COLOR and DENO_NO_PROMPT only "
                       "(the preparation step additionally inherits proxy/CA variables, listed in preparation)",
        "sourceManifestSHA256": hashlib.sha256(json.dumps(manifest, sort_keys=True).encode()).hexdigest(),
        "sourceFiles": manifest, "preparation": preparation, "unit": unit, "entrypointChecks": checks,
        "negativeControl": negative, "runtimeNetworkPermitted": False,
        "sourceUnchanged": unchanged,
        "liveRoutesTested": 0, "productionMutations": 0,
        "passed": unchanged and preparation["accepted"] and unit["accepted"]
                  and all(c["exit"] == 0 for c in checks) and negative["accepted"],
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
