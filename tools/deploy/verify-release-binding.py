#!/usr/bin/env python3
"""Bind reviewed source, raw CI evidence and retained release bytes. File-only."""
from __future__ import annotations

import sys
sys.dont_write_bytecode = True

import argparse
import datetime as dt
import importlib.util
import json
import math
from pathlib import Path
import re
import stat

_spec = importlib.util.spec_from_file_location(
    "rollout_readback_helpers", Path(__file__).with_name("verify-rollout-readback.py"))
_guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_guard)
Refusal, require = _guard.Refusal, _guard.require
SHA = r"[0-9a-f]{64}"
COMMIT = r"[0-9a-f]{40}"
UUID = r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"


def shape(value, keys, code):
    require(isinstance(value, dict) and set(value) == set(keys), code)


def integer(value):
    return type(value) is int and value > 0


def relative(base, name):
    require(isinstance(name, str) and len(name) <= 1024 and
            re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", name) and
            all(part not in (".", "..") for part in name.split("/")), "unsafe_relative_path")
    target = base
    for part in name.split("/"):
        target = target / part
        try:
            require(not stat.S_ISLNK(target.lstat().st_mode), "symlink_path")
        except OSError:
            raise Refusal("input_path_unavailable") from None
    return target


def bounded(value, depth=0, budget=None):
    budget = [0] if budget is None else budget
    budget[0] += 1
    require(depth <= 40 and budget[0] <= 50000, "json_complexity")
    if isinstance(value, dict):
        for key, child in value.items():
            require(isinstance(key, str) and len(key) <= 1024, "json_key_shape")
            bounded(child, depth + 1, budget)
    elif isinstance(value, list):
        for child in value:
            bounded(child, depth + 1, budget)
    elif isinstance(value, str):
        require(len(value) <= 65536, "json_string_size")


def verify(contract_path, contract_sha256, now=None):
    require(isinstance(contract_sha256, str) and re.fullmatch(SHA, contract_sha256), "contract_hash_shape")
    raw, actual_hash, _ = _guard.file_bytes(contract_path, _guard.JSON_LIMIT)
    require(actual_hash == contract_sha256, "contract_hash_mismatch")
    contract = _guard.decode(raw)
    bounded(contract)
    _guard.secret_safe(contract)
    shape(contract, ("schema", "identity", "required_jobs", "max_age_seconds", "source", "run",
                     "jobs_pages", "release", "artifacts"), "contract_shape")
    require(contract["schema"] == "rendprop-release-binding-v1", "contract_schema")
    identity = contract["identity"]
    shape(identity, ("repository", "branch", "workflow_path", "source_sha", "run_id", "run_attempt",
                     "environment", "account", "resource", "version"), "identity_shape")
    require(isinstance(identity["repository"], str) and
            re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", identity["repository"]), "repository_shape")
    require(isinstance(identity["branch"], str) and 0 < len(identity["branch"]) <= 256 and
            re.fullmatch(r"[A-Za-z0-9_./-]+", identity["branch"]), "branch_shape")
    require(isinstance(identity["workflow_path"], str) and
            re.fullmatch(r"\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml", identity["workflow_path"]), "workflow_shape")
    require(isinstance(identity["source_sha"], str) and re.fullmatch(COMMIT, identity["source_sha"]), "commit_shape")
    require(integer(identity["run_id"]) and integer(identity["run_attempt"]), "run_identity_shape")
    for field in ("environment", "account", "resource"):
        require(isinstance(identity[field], str) and re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", identity[field]), "resource_identity_shape")
    require(isinstance(identity["version"], str) and re.fullmatch(UUID, identity["version"]), "version_shape")
    required = contract["required_jobs"]
    require(isinstance(required, list) and 1 <= len(required) <= 128 and
            all(isinstance(name, str) and 0 < len(name) <= 256 and
                not any(ord(c) < 32 for c in name) for name in required) and
            len(required) == len(set(required)), "required_jobs_shape")
    age = contract["max_age_seconds"]
    require(type(age) is int and 1 <= age <= _guard.MAX_AGE, "age_policy")
    clock = now or dt.datetime.now(dt.timezone.utc)
    require(clock.tzinfo is not None, "clock_shape")
    base = Path(contract_path).parent.resolve(strict=True)
    hashes = {"contract": actual_hash}

    def load(reference, label):
        shape(reference, ("path", "sha256"), "document_reference")
        require(isinstance(reference["sha256"], str) and re.fullmatch(SHA, reference["sha256"]), "document_hash_shape")
        path = relative(base, reference["path"])
        data, received, _ = _guard.file_bytes(path, _guard.JSON_LIMIT)
        require(received == reference["sha256"], "document_hash_mismatch")
        value = _guard.decode(data)
        bounded(value)
        hashes[label] = received
        return value

    source = load(contract["source"], "source")
    shape(source, ("repository", "branch", "head", "remote_head", "tracked_clean", "observed_at_utc", "artifacts"), "source_shape")
    require(source["repository"] == identity["repository"] and source["branch"] == identity["branch"], "source_repository_mismatch")
    require(source["head"] == source["remote_head"] == identity["source_sha"], "source_commit_mismatch")
    require(source["tracked_clean"] is True, "source_dirty")
    source_time = _guard.observed(source["observed_at_utc"], clock, age, "/source/observed_at_utc")

    run = load(contract["run"], "run")
    require(isinstance(run, dict) and isinstance(run.get("repository"), dict), "ci_run_shape")
    require(run["repository"].get("full_name") == identity["repository"] and
            run.get("head_branch") == identity["branch"] and run.get("path") == identity["workflow_path"], "ci_repository_workflow_mismatch")
    require(run.get("head_sha") == identity["source_sha"], "ci_commit_mismatch")
    require(type(run.get("id")) is int and run["id"] == identity["run_id"] and
            type(run.get("run_attempt")) is int and run["run_attempt"] == identity["run_attempt"], "ci_run_attempt_mismatch")
    require(run.get("status") == "completed" and run.get("conclusion") == "success", "ci_run_not_success")

    pages = contract["jobs_pages"]
    require(isinstance(pages, list) and 1 <= len(pages) <= 20, "jobs_pages_shape")
    jobs, total, per_page = [], None, None
    for number, page in enumerate(pages, 1):
        shape(page, ("page", "per_page", "path", "sha256"), "jobs_page_reference")
        require(type(page["page"]) is int and page["page"] == number and
                type(page["per_page"]) is int and 1 <= page["per_page"] <= 100, "jobs_page_sequence")
        per_page = page["per_page"] if per_page is None else per_page
        require(page["per_page"] == per_page, "jobs_page_size_drift")
        payload = load({key: page[key] for key in ("path", "sha256")}, "jobs_page_" + str(number))
        require(isinstance(payload, dict) and type(payload.get("total_count")) is int and
                1 <= payload["total_count"] <= 1000 and isinstance(payload.get("jobs"), list), "jobs_payload_shape")
        total = payload["total_count"] if total is None else total
        require(payload["total_count"] == total, "jobs_total_drift")
        expected_count = min(per_page, max(0, total - (number - 1) * per_page))
        require(len(payload["jobs"]) == expected_count, "jobs_page_incomplete")
        jobs.extend(payload["jobs"])
    require(len(pages) == math.ceil(total / per_page) and len(jobs) == total, "jobs_pagination_incomplete")
    job_ids = set()
    for job in jobs:
        require(isinstance(job, dict) and integer(job.get("id")) and
                isinstance(job.get("name"), str), "job_shape")
        require(job["id"] not in job_ids, "duplicate_job_id")
        job_ids.add(job["id"])
        require(type(job.get("run_id")) is int and job["run_id"] == identity["run_id"] and
                type(job.get("run_attempt")) is int and job["run_attempt"] == identity["run_attempt"] and
                job.get("head_sha") == identity["source_sha"], "job_run_attempt_commit_mismatch")
    for name in required:
        matches = [job for job in jobs if job["name"] == name]
        require(len(matches) == 1, "required_job_missing_or_ambiguous")
        require(matches[0].get("status") == "completed" and matches[0].get("conclusion") == "success", "required_job_not_success")

    release = load(contract["release"], "release")
    shape(release, ("identity", "source_sha", "observed_at_utc", "deployment", "version", "artifacts"), "release_shape")
    shape(release["identity"], ("environment", "account", "resource"), "release_identity_shape")
    require(release["identity"] == {key: identity[key] for key in ("environment", "account", "resource")}, "release_identity_mismatch")
    require(release["source_sha"] == identity["source_sha"], "release_source_mismatch")
    release_time = _guard.observed(release["observed_at_utc"], clock, age, "/release/observed_at_utc")
    require(release_time >= source_time, "release_precedes_source")
    deployment, version = release["deployment"], release["version"]
    require(isinstance(deployment, dict) and isinstance(deployment.get("versions"), list) and
            len(deployment["versions"]) == 1, "release_not_single_version")
    active = deployment["versions"][0]
    require(isinstance(active, dict) and active.get("version_id") == identity["version"] and
            type(active.get("percentage")) in (int, float) and active["percentage"] == 100, "release_version_or_traffic_mismatch")
    require(isinstance(version, dict) and version.get("id") == identity["version"], "immutable_version_mismatch")

    artifacts = contract["artifacts"]
    require(isinstance(artifacts, dict) and 1 <= len(artifacts) <= 256, "artifact_map_shape")
    require(source["artifacts"] == {name: entry.get("sha256") for name, entry in artifacts.items() if isinstance(entry, dict)}, "source_artifact_set_mismatch")
    rows = release["artifacts"]
    require(isinstance(rows, list) and len(rows) == len(artifacts), "release_artifact_set_mismatch")
    by_name = {}
    for row in rows:
        shape(row, ("name", "sha256", "bytes", "http_status"), "readback_artifact_shape")
        require(isinstance(row["name"], str) and row["name"] not in by_name, "readback_artifact_duplicate")
        by_name[row["name"]] = row
    require(set(by_name) == set(artifacts), "release_artifact_set_mismatch")
    total_bytes, artifact_hashes = 0, {}
    for name, entry in artifacts.items():
        # Names and all paths are confined to this reviewed input directory.
        require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", name) and
                all(part not in (".", "..") for part in name.split("/")), "artifact_name_shape")
        shape(entry, ("sha256", "path", "readback_path"), "artifact_reference")
        require(isinstance(entry["sha256"], str) and re.fullmatch(SHA, entry["sha256"]), "artifact_hash_shape")
        row = by_name[name]
        require(row["sha256"] == entry["sha256"] and type(row["bytes"]) is int and row["bytes"] >= 0 and
                type(row["http_status"]) is int and row["http_status"] == 200, "readback_artifact_not_verified")
        for field in ("path", "readback_path"):
            _, received, size = _guard.file_bytes(relative(base, entry[field]), _guard.ARTIFACT_LIMIT, retain=False)
            total_bytes += size
            require(total_bytes <= _guard.TOTAL_ARTIFACT_LIMIT, "artifact_total_size")
            require(received == entry["sha256"] and size == row["bytes"], "artifact_bytes_mismatch")
        artifact_hashes[name] = entry["sha256"]
    return {"status": "HISTORICAL_FILE_BINDING" if now is not None else "VERIFIED_FILE_BINDING",
            "bindingSHA256": _guard.digest(identity), "inputSHA256": hashes,
            "artifactSHA256": artifact_hashes, "requiredJobs": len(required), "collectedJobs": len(jobs),
            "authority": "Reviewed files only; no collector authentication, remote completeness or deployment authorization."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", required=True, type=Path)
    parser.add_argument("--contract-sha256", required=True)
    args = parser.parse_args()
    try:
        result, code = verify(args.contract, args.contract_sha256), 0
    except Refusal as error:
        # Never print caller-controlled values, exception text, raw API data or paths.
        result, code = {"status": "REFUSED", "code": error.code}, 2
    except Exception:
        result, code = {"status": "REFUSED", "code": "input_error"}, 2
    print(json.dumps(result, sort_keys=True, allow_nan=False))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
