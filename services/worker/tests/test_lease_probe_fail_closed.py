"""A transient/ambiguous schema probe must never authorize an unleased claim.

Calls the actual db claim path. Only requests.request is replaced; the fake
accepts a claim PATCH even while the schema probe fails, reproducing the gap.
"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import requests
import db


class LeaseProbeTests(unittest.TestCase):
    def setUp(self):
        self.enterContext(patch.object(db, "_LEASE_SUPPORTED", None))
        self.enterContext(patch.object(db, "WORKER_ID", "fixture-worker"))
        self.enterContext(patch.object(requests.sessions.Session, "send",
            side_effect=AssertionError("No test may send an HTTP request")))
        self.transport = self.enterContext(patch.object(requests, "request", side_effect=self.request))
        self.row = {"id": "fixture-job", "status": "queued", "source": "worker", "attempts": 0}
        self.calls = []
        self.probe_response = requests.Timeout("synthetic timeout")

    def request(self, method, url, **kw):
        self.calls.append((method, dict(kw.get("params") or {})))
        req = requests.Request(method, "https://fixture.invalid/rest/v1/render_jobs",
                               params=kw.get("params")).prepare()
        query = parse_qs(urlparse(req.url).query)
        if method == "GET" and query.get("select") == ["id,lease_expires_at,attempts,worker_id"]:
            if isinstance(self.probe_response, Exception):
                raise self.probe_response
            status, payload = self.probe_response
        elif method == "GET":
            self.assertEqual(query.get("status"), ["in.(created,queued)"])
            status, payload = 200, [dict(self.row)]
        elif method == "PATCH":
            self.assertEqual(query.get("id"), ["eq.fixture-job"])
            self.assertEqual(query.get("status"), ["in.(created,queued)"])
            self.row.update(kw["json"])
            status, payload = 200, [dict(self.row)]
        else:
            raise AssertionError(f"Unexpected method {method}")
        response = requests.Response()
        response.status_code = status
        response._content = json.dumps(payload).encode()
        response.request, response.url = req, req.url
        return response

    def assert_retryable_without_claim(self):
        with self.assertRaises(db.DBError):
            db.claim_next_job()
        self.assertIsNone(db._LEASE_SUPPORTED, "an unknown schema must not be cached as legacy")
        self.assertEqual(self.row["status"], "queued")
        self.assertFalse(any(method == "PATCH" for method, _ in self.calls))
        self.probe_response = (200, [])
        claimed = db.claim_next_job()
        self.assertEqual(claimed["worker_id"], "fixture-worker")
        self.assertTrue(claimed["lease_expires_at"])
        self.assertEqual(claimed["attempts"], 1)
        self.assertEqual(sum(method == "PATCH" for method, _ in self.calls), 1)

    def test_timeout_never_claims_unleased_then_recovers(self):
        self.assert_retryable_without_claim()

    def test_connection_failure_never_claims_unleased_then_recovers(self):
        self.probe_response = requests.ConnectionError("synthetic reset")
        self.assert_retryable_without_claim()

    def test_503_never_claims_unleased_then_recovers(self):
        self.probe_response = (503, {"message": "synthetic unavailable"})
        self.assert_retryable_without_claim()

    def test_503_missing_column_words_are_not_schema_evidence(self):
        self.probe_response = (503, {"code": "42703", "message": 'column "worker_id" does not exist'})
        self.assert_retryable_without_claim()

    def test_query_parse_error_is_not_missing_schema(self):
        self.probe_response = (400, {"code": "PGRST100", "message": "synthetic malformed select"})
        self.assert_retryable_without_claim()

    def test_permission_error_is_not_missing_schema(self):
        self.probe_response = (403, {"code": "42501", "message": "synthetic denied"})
        self.assert_retryable_without_claim()

    def test_unrelated_missing_column_does_not_enable_legacy_mode(self):
        self.probe_response = (400, {"code": "42703", "message": 'column "id" does not exist'})
        self.assert_retryable_without_claim()

    def test_unstructured_error_words_do_not_enable_legacy_mode(self):
        self.probe_response = (400, {"message": 'column "worker_id" does not exist'})
        self.assert_retryable_without_claim()

    def assert_confirmed_legacy(self, code):
        self.probe_response = (400, {"code": code, "message": 'column "worker_id" does not exist'})
        claimed = db.claim_next_job()
        self.assertFalse(db._LEASE_SUPPORTED)
        self.assertNotIn("worker_id", claimed)
        self.assertNotIn("lease_expires_at", claimed)
        self.assertEqual(claimed["attempts"], 0)
        self.assertEqual(sum(method == "PATCH" for method, _ in self.calls), 1)
        self.assertFalse(db.lease_supported())
        probes = [params for method, params in self.calls
                  if params.get("select") == "id,lease_expires_at,attempts,worker_id"]
        self.assertEqual(len(probes), 1, "confirmed legacy schema retains the existing cached mode")

    def test_confirmed_42703_retains_documented_legacy_compatibility(self):
        self.assert_confirmed_legacy("42703")

    def test_confirmed_pgrst204_retains_documented_legacy_compatibility(self):
        self.assert_confirmed_legacy("PGRST204")


if __name__ == "__main__":
    unittest.main(verbosity=2)
