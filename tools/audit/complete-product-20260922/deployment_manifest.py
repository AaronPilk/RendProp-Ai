#!/usr/bin/env python3
"""Build a review-only function/source manifest from local source and saved readbacks.

No API, deployment, authentication, or migration command is executed. Saved
readbacks stay outside Git; this report contains source hashes and version metadata.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / "services/supabase/functions"
SHARED_CHANGES = {"_shared/ledger.ts", "_shared/router.ts", "_shared/providers/chain.ts"}
DIRECT_CHANGES = {"admin", "ai-photo", "ai-video", "studio", "tours"}


def closure(path, seen=None):
    seen = set() if seen is None else seen
    if path in seen: return seen
    seen.add(path)
    # Includes type imports deliberately: staging must also be typecheckable.
    # Remote/package imports remain the source's existing declared dependencies.
    for specifier in re.findall(r'(?:from\s*|import\s*\()[\"\']([^\"\']+)[\"\']', path.read_text()):
        if specifier.startswith("."):
            dependency = (path.parent / specifier).resolve()
            if not dependency.is_relative_to(BASE): raise RuntimeError("Unexpected import outside functions")
            if not dependency.is_file(): raise RuntimeError("Missing local dependency: " + str(dependency))
            closure(dependency, seen)
    return seen


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--readbacks", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = {"kind": "review-only, not deployed", "baseCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "sourceNote": "Working tree hashes are authoritative; the base commit may precede current edits.",
              "prerequisites": ["Confirm live migration names/content; eight Studio migrations are already applied under live timestamp versions.",
                                "Apply only missing 0055_video_reflection_jobs and 0056_active_photo_fallback, each atomically, before new ai-video/ai-photo dispatch.",
                                "Preserve disabled routes, current runtime flags, provider keys and existing per-function verify_jwt values.",
                                "Read back every declared changed function after deployment; compare each bundled source and record its new version."],
              "functions": [], "sourceFiles": {}}
    for entry in sorted(BASE.glob("*/index.ts")):
        name = entry.parent.name
        if name == "_shared": continue
        dependencies = closure(entry)
        relative = sorted(str(p.relative_to(BASE)) for p in dependencies)
        shared = sorted(SHARED_CHANGES.intersection(relative))
        snapshot = args.readbacks / ("live-" + name + "-before.json")
        record = {"name": name, "sources": relative, "changedSharedDependencies": shared,
                  "candidateForDeployment": name in DIRECT_CHANGES or bool(shared), "liveSnapshot": "unavailable; read before deployment"}
        if snapshot.is_file():
            live = json.loads(snapshot.read_text())
            differences, missing = [], []
            for file in live["files"]:
                local = BASE / file["name"].removeprefix("functions/")
                if not local.is_file(): missing.append(file["name"])
                elif local.read_text() != file["content"]: differences.append(file["name"].removeprefix("functions/"))
            record.update({"liveSnapshot": "saved read-only source", "liveVersionBefore": live["version"],
                           "preserveVerifyJwt": live["verify_jwt"], "liveComparedFiles": len(live["files"]),
                           "liveDifferentFiles": sorted(differences), "liveFilesAbsentLocally": missing})
            if missing: raise RuntimeError("Live source missing locally for " + name)
            # Existing unchanged packages are not redeployed just to bump a version.
            record["candidateForDeployment"] = bool(differences)
        report["functions"].append(record)
        for path in dependencies:
            report["sourceFiles"][str(path.relative_to(BASE))] = hashlib.sha256(path.read_bytes()).hexdigest()
    report["deployCandidates"] = [f["name"] for f in report["functions"] if f["candidateForDeployment"]]
    report["requiredReadbacks"] = [f["name"] for f in report["functions"] if f["candidateForDeployment"] and f["liveSnapshot"].startswith("unavailable")]
    report["sourceFiles"] = dict(sorted(report["sourceFiles"].items()))
    report["migrations"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT / "services/supabase/migrations").glob("005[56]*.sql"))}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"manifest": str(args.output), "deployCandidates": report["deployCandidates"], "requiredReadbacks": report["requiredReadbacks"]}))


if __name__ == "__main__": main()
