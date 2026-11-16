#!/usr/bin/env python3
"""Closed file fixtures; source override exists only for copied mutation controls."""
import copy
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(os.environ.get("RENDPROP_RELEASE_BINDING_TEST_SOURCE", Path(__file__).with_name("verify-release-binding.py")))
spec = importlib.util.spec_from_file_location("release_binding", SOURCE)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
NOW = dt.datetime(2026, 10, 19, 5, tzinfo=dt.timezone.utc)


class ReleaseBinding(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="release-binding-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.identity = {"repository": "fixture-owner/fixture-repo", "branch": "feature/release",
            "workflow_path": ".github/workflows/ci.yml", "source_sha": "a" * 40,
            "run_id": 700, "run_attempt": 2, "environment": "production", "account": "fixture-account",
            "resource": "fixture-worker", "version": "01234567-89ab-cdef-0123-456789abcdef"}
        self.artifact = self.root / "worker.js"
        self.artifact.write_bytes(b"export default {};\n")
        self.readback = self.root / "served.js"
        self.readback.write_bytes(self.artifact.read_bytes())
        digest = self.sha(self.artifact)
        self.contract = {"schema": "rendprop-release-binding-v1", "identity": self.identity,
            "required_jobs": ["Unit", "Secret scan"], "max_age_seconds": 300,
            "source": {}, "run": {}, "jobs_pages": [], "release": {},
            "artifacts": {"worker.js": {"path": "worker.js", "readback_path": "served.js", "sha256": digest}}}
        self.source = {"repository": self.identity["repository"], "branch": self.identity["branch"],
            "head": "a" * 40, "remote_head": "a" * 40, "tracked_clean": True,
            "observed_at_utc": (NOW - dt.timedelta(seconds=30)).isoformat(), "artifacts": {"worker.js": digest}}
        self.run = {"id": 700, "run_attempt": 2, "repository": {"full_name": self.identity["repository"]},
            "head_sha": "a" * 40, "head_branch": self.identity["branch"], "path": self.identity["workflow_path"],
            "status": "completed", "conclusion": "success"}
        jobs = [{"id": n + 1, "name": name, "run_id": 700, "run_attempt": 2, "head_sha": "a" * 40,
                 "status": "completed", "conclusion": "success"} for n, name in enumerate(["Unit", "Secret scan", "Build"])]
        self.pages = [{"total_count": 3, "jobs": jobs[:2]}, {"total_count": 3, "jobs": jobs[2:]}]
        self.release = {"identity": {key: self.identity[key] for key in ("environment", "account", "resource")},
            "source_sha": "a" * 40, "observed_at_utc": (NOW - dt.timedelta(seconds=5)).isoformat(),
            "deployment": {"id": "fixture-deployment", "versions": [{"version_id": self.identity["version"], "percentage": 100}]},
            "version": {"id": self.identity["version"], "resources": {"bindings": []}},
            "artifacts": [{"name": "worker.js", "sha256": digest, "bytes": self.artifact.stat().st_size, "http_status": 200}]}

    @staticmethod
    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def write_ref(self, name, value):
        path = self.root / name
        path.write_text(json.dumps(value))
        return {"path": name, "sha256": self.sha(path)}

    def save(self):
        for key in ("source", "run", "release"):
            self.contract[key] = self.write_ref(key + ".json", getattr(self, key))
        self.contract["jobs_pages"] = [{"page": n + 1, "per_page": 2,
            **self.write_ref("jobs" + str(n + 1) + ".json", page)} for n, page in enumerate(self.pages)]
        path = self.root / "contract.json"
        path.write_text(json.dumps(self.contract))
        return path, self.sha(path)

    def verify(self):
        path, digest = self.save()
        return gate.verify(path, digest, now=NOW)

    def refuses(self, code):
        with self.assertRaises(gate.Refusal) as caught:
            self.verify()
        self.assertEqual(caught.exception.code, code)

    def test_exact_source_raw_ci_paginated_jobs_version_and_both_bytes(self):
        result = self.verify()
        self.assertEqual(result["status"], "HISTORICAL_FILE_BINDING")
        self.assertEqual(result["requiredJobs"], 2)
        self.assertEqual(result["collectedJobs"], 3)
        self.assertEqual(result["artifactSHA256"], {"worker.js": self.sha(self.artifact)})

    def test_wrong_source_commit(self):
        self.source["head"] = "b" * 40
        self.refuses("source_commit_mismatch")

    def test_wrong_remote_commit(self):
        self.source["remote_head"] = "b" * 40
        self.refuses("source_commit_mismatch")

    def test_dirty_source(self):
        self.source["tracked_clean"] = False
        self.refuses("source_dirty")

    def test_ci_green_for_different_commit(self):
        self.run["head_sha"] = "b" * 40
        self.refuses("ci_commit_mismatch")

    def test_wrong_ci_attempt(self):
        self.run["run_attempt"] = 1
        self.refuses("ci_run_attempt_mismatch")

    def test_wrong_ci_repository(self):
        self.run["repository"]["full_name"] = "another/repository"
        self.refuses("ci_repository_workflow_mismatch")

    def test_wrong_ci_workflow(self):
        self.run["path"] = ".github/workflows/other.yml"
        self.refuses("ci_repository_workflow_mismatch")

    def test_actual_failed_or_running_run_never_qualifies(self):
        for status, conclusion in [("completed", "failure"), ("in_progress", None), ("completed", "cancelled")]:
            with self.subTest(status=status, conclusion=conclusion):
                self.run.update(status=status, conclusion=conclusion)
                self.refuses("ci_run_not_success")

    def test_failed_required_job_even_when_run_metadata_says_success(self):
        self.pages[0]["jobs"][0]["conclusion"] = "failure"
        self.refuses("required_job_not_success")

    def test_skipped_running_or_cancelled_required_job(self):
        for status, conclusion in [("completed", "skipped"), ("in_progress", None), ("completed", "cancelled"), ("completed", "neutral")]:
            with self.subTest(status=status, conclusion=conclusion):
                self.pages[0]["jobs"][0].update(status=status, conclusion=conclusion)
                self.refuses("required_job_not_success")

    def test_missing_required_job(self):
        self.contract["required_jobs"].append("Not collected")
        self.refuses("required_job_missing_or_ambiguous")

    def test_ambiguous_required_job_name(self):
        self.pages[1]["jobs"][0]["name"] = "Unit"
        self.refuses("required_job_missing_or_ambiguous")

    def test_duplicate_job_id(self):
        self.pages[1]["jobs"][0]["id"] = 1
        self.refuses("duplicate_job_id")

    def test_mixed_job_attempt(self):
        self.pages[1]["jobs"][0]["run_attempt"] = 1
        self.refuses("job_run_attempt_commit_mismatch")

    def test_partial_pagination(self):
        self.pages.pop()
        self.refuses("jobs_pagination_incomplete")

    def test_short_first_page(self):
        self.pages[0]["jobs"].pop()
        self.refuses("jobs_page_incomplete")

    def test_page_total_drift(self):
        self.pages[1]["total_count"] = 4
        self.refuses("jobs_total_drift")

    def test_wrong_resource(self):
        self.release["identity"]["resource"] = "other-worker"
        self.refuses("release_identity_mismatch")

    def test_wrong_release_source(self):
        self.release["source_sha"] = "b" * 40
        self.refuses("release_source_mismatch")

    def test_wrong_active_version(self):
        self.release["deployment"]["versions"][0]["version_id"] = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        self.refuses("release_version_or_traffic_mismatch")

    def test_split_or_nonfull_traffic(self):
        self.release["deployment"]["versions"][0]["percentage"] = 99
        self.refuses("release_version_or_traffic_mismatch")
        self.release["deployment"]["versions"].append(copy.deepcopy(self.release["deployment"]["versions"][0]))
        self.refuses("release_not_single_version")

    def test_wrong_immutable_version(self):
        self.release["version"]["id"] = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        self.refuses("immutable_version_mismatch")

    def test_artifact_mutation(self):
        self.artifact.write_bytes(b"changed-local\n")
        self.refuses("artifact_bytes_mismatch")

    def test_retained_served_bytes_mutation(self):
        self.readback.write_bytes(b"changed-served\n")
        self.refuses("artifact_bytes_mismatch")

    def test_source_artifact_omission(self):
        self.source["artifacts"] = {}
        self.refuses("source_artifact_set_mismatch")

    def test_missing_hosted_artifact(self):
        self.release["artifacts"] = []
        self.refuses("release_artifact_set_mismatch")

    def test_hosted_not_http200(self):
        self.release["artifacts"][0]["http_status"] = 404
        self.refuses("readback_artifact_not_verified")

    def test_bare_success_report_is_not_raw_ci(self):
        self.run = {"success": True}
        self.refuses("ci_run_shape")

    def test_stale_future_or_inverted_capture(self):
        self.source["observed_at_utc"] = (NOW - dt.timedelta(seconds=301)).isoformat()
        self.refuses("snapshot_not_fresh")
        self.source["observed_at_utc"] = (NOW + dt.timedelta(seconds=1)).isoformat()
        self.refuses("snapshot_not_fresh")
        self.source["observed_at_utc"] = (NOW - dt.timedelta(seconds=1)).isoformat()
        self.refuses("release_precedes_source")

    def test_artifact_symlink(self):
        self.artifact.unlink()
        self.artifact.symlink_to(self.readback)
        self.refuses("symlink_path")

    def test_parent_symlink(self):
        (self.root / "alias").symlink_to(self.root, target_is_directory=True)
        self.contract["artifacts"]["worker.js"]["path"] = "alias/worker.js"
        self.refuses("symlink_path")

    def test_parent_traversal(self):
        self.contract["artifacts"]["worker.js"]["path"] = "../worker.js"
        self.refuses("unsafe_relative_path")

    def test_reference_hash_tamper(self):
        path, digest = self.save()
        (self.root / "run.json").write_text('{"success": true}')
        with self.assertRaises(gate.Refusal) as caught:
            gate.verify(path, digest, now=NOW)
        self.assertEqual(caught.exception.code, "document_hash_mismatch")

    def test_no_exception_override(self):
        self.contract["allow_failed_jobs"] = ["Unit"]
        self.refuses("contract_shape")

    def test_cli_fresh_and_safe_refusal(self):
        now = dt.datetime.now(dt.timezone.utc)
        self.source["observed_at_utc"] = (now - dt.timedelta(seconds=10)).isoformat()
        self.release["observed_at_utc"] = (now - dt.timedelta(seconds=1)).isoformat()
        path, digest = self.save()
        command = [sys.executable, str(SOURCE), "--contract", str(path), "--contract-sha256", digest]
        passed = subprocess.run(command, capture_output=True, timeout=10)
        self.assertEqual(passed.returncode, 0, passed.stderr.decode())
        self.assertEqual(json.loads(passed.stdout)["status"], "VERIFIED_FILE_BINDING")
        self.run["repository"]["full_name"] = "PRIVATE_VALUE_MUST_NOT_PRINT"
        path, digest = self.save()
        command[-1] = digest
        refused = subprocess.run(command, capture_output=True, timeout=10)
        self.assertEqual(refused.returncode, 2)
        self.assertEqual(json.loads(refused.stdout)["code"], "ci_repository_workflow_mismatch")
        self.assertNotIn(b"PRIVATE_VALUE", refused.stdout + refused.stderr)
        self.assertNotIn(str(self.root).encode(), refused.stdout + refused.stderr)

    def test_cli_copied_tools_create_no_bytecode_or_files(self):
        now = dt.datetime.now(dt.timezone.utc)
        self.source["observed_at_utc"] = (now - dt.timedelta(seconds=10)).isoformat()
        self.release["observed_at_utc"] = (now - dt.timedelta(seconds=1)).isoformat()
        path, digest = self.save()
        tools = self.root / "copied-tools"
        tools.mkdir()
        checker = tools / "verify-release-binding.py"
        checker.write_bytes(SOURCE.read_bytes())
        helper = tools / "verify-rollout-readback.py"
        helper.write_bytes(SOURCE.with_name(helper.name).read_bytes())
        before = {str(p.relative_to(tools)): self.sha(p) for p in tools.rglob("*") if p.is_file()}
        env = os.environ.copy()
        env.pop("PYTHONDONTWRITEBYTECODE", None)
        result = subprocess.run([sys.executable, str(checker), "--contract", str(path),
            "--contract-sha256", digest], cwd=tools, env=env, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        after = {str(p.relative_to(tools)): self.sha(p) for p in tools.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        self.assertEqual(sorted(p.name for p in tools.iterdir()), sorted(before))
        self.assertFalse(any(p.name == "__pycache__" or p.suffix == ".pyc" for p in tools.rglob("*")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
