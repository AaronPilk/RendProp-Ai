"""Actual worker/ledger HTTP transport against two owned loopback servers.

Only synthetic keys are installed. No external address, funding, provider or
customer data is used. Removed-guard controls must leak to the second local
server and fail the same named oracle; they never modify product files.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import inspect
import io
import json
import os
from pathlib import Path
import sys
import textwrap
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
# Neither imported settings module may read a developer's private dotenv file.
# Process-local synthetic settings replace every credential/env boundary.
keep = {k: os.environ[k] for k in ("PATH", "LANG", "TMPDIR") if k in os.environ}
os.environ.clear(); os.environ.update(keep)
os.environ["SUPABASE_SECRET_KEY"] = "sb_secret_synthetic_redirect_test_only"
sys.path[:0] = [str(ROOT / "services/worker"), str(ROOT / "services/pipeline")]
original_exists = Path.exists
with patch.object(Path, "exists", lambda p: False if p.name == ".env" else original_exists(p)):
    import db
    import cost_ledger
    from providers import base

SOURCE_PATHS = [ROOT / p for p in ["services/worker/db.py", "services/pipeline/cost_ledger.py",
    "services/pipeline/providers/base.py", "services/worker/tests/test_credential_redirect_boundary.py"]]
source_hashes = lambda: {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCE_PATHS}
START = source_hashes()
COUNTS = {"firstRequests": 0, "secondRequests": 0, "guardControlsRejected": 0}


class LocalHTTPFixture:
    def __init__(self):
        self.first = []; self.second = []; self.redirect_status = 302; self.rollup = False
        fixture = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass
            def dispatch(self):
                length = int(self.headers.get("Content-Length", "0"))
                if length > 16_384:
                    self.send_error(413); return
                self.rfile.read(length)
                entry = {"method": self.command, "path": self.path,
                         "apikey": self.headers.get("apikey"), "authorization": self.headers.get("Authorization")}
                second = self.server is fixture.sink
                (fixture.second if second else fixture.first).append(entry)
                COUNTS["secondRequests" if second else "firstRequests"] += 1
                if not second and fixture.redirect_status is not None and not (fixture.rollup and self.command == "GET"):
                    self.send_response(fixture.redirect_status)
                    self.send_header("Location", fixture.second_url + "/sink")
                    body = b'{"message":"synthetic redirect"}'
                else:
                    self.send_response(200)
                    body = json.dumps({"reserved": True} if "/rpc/" in self.path else [{"total_cents": 1.25}]).encode()
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
            do_GET = dispatch; do_POST = dispatch; do_PATCH = dispatch
        self.origin = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.sink = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.first_url = "http://127.0.0.1:" + str(self.origin.server_port)
        self.second_url = "http://127.0.0.1:" + str(self.sink.server_port)
        self.threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in (self.origin, self.sink)]
        for thread in self.threads: thread.start()
    def close(self):
        for server in (self.origin, self.sink): server.shutdown(); server.server_close()
        for thread in self.threads: thread.join(timeout=2)
        if any(thread.is_alive() for thread in self.threads): raise RuntimeError("Owned HTTP server remained active")


class CredentialRedirectTests(unittest.TestCase):
    def setUp(self):
        self.fixture = LocalHTTPFixture(); self.addCleanup(self.fixture.close)
        self.settings = SimpleNamespace(supabase_url=self.fixture.first_url,
            supabase_service_role_key="sb_secret_synthetic_redirect_test_only", db_schema="public")
        self.enterContext(patch.object(db, "SETTINGS", self.settings))
        self.ledger = cost_ledger.CostLedger(supabase_url=self.fixture.first_url,
            service_key=self.settings.supabase_service_role_key, verbose=False)
    def no_second(self):
        self.assertEqual(self.fixture.second, [], "redirect reached second endpoint")
    def worker_redirect(self, code=302, method="GET"):
        self.fixture.redirect_status = code
        response = db._request(method, "cost_ledger", headers=db._headers(), timeout=2,
                               allow_redirects=True)  # Caller cannot override the product refusal.
        self.no_second()
        with self.assertRaises(db.DBError): db._check(response)
        self.assertEqual(response.status_code, code)
    def test_worker_all_redirect_codes_and_methods(self):
        for key in ["sb_secret_synthetic_redirect_test_only", "synthetic-legacy-redirect-only"]:
            self.settings.supabase_service_role_key = key
            for code in [301, 302, 303, 307, 308]:
                for method in ["GET", "POST"]:
                    with self.subTest(key_kind=key.startswith("sb_secret_"), code=code, method=method):
                        before = len(self.fixture.first); self.worker_redirect(code, method)
                        self.assertEqual(len(self.fixture.first), before + 1)
                        self.assertEqual(self.fixture.first[-1]["apikey"], key)
    def test_ledger_get_and_insert_deny_redirects(self):
        for key in ["sb_secret_synthetic_redirect_test_only", "synthetic-legacy-redirect-only"]:
            self.ledger.service_key = key
            for code in [301, 302, 303, 307, 308]:
                self.fixture.redirect_status = code
                for action in [lambda: self.ledger.job_total_cents("synthetic-job"),
                               lambda: self.ledger._insert_once({"idempotency_key": "synthetic-owned-receipt"})]:
                    with self.subTest(key_kind=key.startswith("sb_secret_"), code=code):
                        before = len(self.fixture.first)
                        with self.assertRaises(base.ProviderError): action()
                        self.no_second(); self.assertEqual(len(self.fixture.first), before + 1)
                        self.assertEqual(self.fixture.first[-1]["apikey"], key)
    def test_ledger_best_effort_rollup_cannot_forward_keys(self):
        self.fixture.rollup = True
        for code in [302, 307]:
            self.fixture.redirect_status = code
            before = len(self.fixture.first)
            with contextlib.redirect_stdout(io.StringIO()) as log: self.ledger._rollup_best_effort("synthetic-job")
            self.no_second(); self.assertEqual(len(self.fixture.first), before + 2)
            self.assertEqual([r["method"] for r in self.fixture.first[-2:]], ["GET", "PATCH"])
            self.assertIn("cost rollup", log.getvalue())
    def test_unredirected_worker_and_ledger_contract_remains_usable(self):
        self.fixture.redirect_status = None
        response = db._request("GET", "cost_ledger", headers=db._headers(), timeout=2)
        db._check(response); self.assertEqual(db._json(response), [{"total_cents": 1.25}])
        self.assertEqual(self.ledger.job_total_cents("synthetic-job"), 1.25)
        self.ledger._insert_once({"idempotency_key": "synthetic-owned-receipt"})
        self.ledger._rollup_best_effort("synthetic-job"); self.no_second()
    def test_local_canary_proves_normal_redirect_capture(self):
        self.fixture.redirect_status = 302
        result = base.request_json(self.fixture.first_url + "/canary", method="GET",
            headers={"apikey": "sb_secret_synthetic_canary_only"}, timeout=2)
        self.assertIsInstance(result, list)
        self.assertEqual(len(self.fixture.second), 1)
        self.assertEqual(self.fixture.second[0]["apikey"], "sb_secret_synthetic_canary_only")
    def test_removed_worker_guard_is_rejected_by_actual_transport_oracle(self):
        source = inspect.getsource(db._request)
        changed = source.replace('kw["allow_redirects"] = False', 'kw["allow_redirects"] = True')
        self.assertNotEqual(source, changed)
        namespace = dict(db.__dict__); exec(compile(changed, "synthetic-worker-redirect-mutant", "exec"), namespace)
        with patch.object(db, "_request", namespace["_request"]):
            with self.assertRaisesRegex(AssertionError, "redirect reached second endpoint"):
                self.worker_redirect()
        self.assertEqual(len(self.fixture.second), 1); COUNTS["guardControlsRejected"] += 1
    def test_removed_ledger_guard_is_rejected_by_actual_transport_oracle(self):
        source = textwrap.dedent(inspect.getsource(cost_ledger.CostLedger._insert_once))
        changed = source.replace("follow_redirects=False", "follow_redirects=True")
        self.assertNotEqual(source, changed)
        namespace = dict(cost_ledger.__dict__); exec(compile(changed, "synthetic-ledger-redirect-mutant", "exec"), namespace)
        with patch.object(cost_ledger.CostLedger, "_insert_once", namespace["_insert_once"]):
            self.ledger._insert_once({"idempotency_key": "synthetic-owned-receipt"})
            with self.assertRaisesRegex(AssertionError, "redirect reached second endpoint"): self.no_second()
        self.assertEqual(len(self.fixture.second), 1); COUNTS["guardControlsRejected"] += 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--out", type=Path); args = parser.parse_args()
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CredentialRedirectTests))
    end = source_hashes(); passed = result.wasSuccessful() and START == end
    receipt = {"passed": passed, "testsRun": result.testsRun, "failures": len(result.failures), "errors": len(result.errors),
               "sourceHashes": START, "sourceUnchanged": START == end, "localHTTP": COUNTS,
               "externalRequests": 0, "realCredentialsRead": 0,
               "limitations": ["Only two owned127.0.0.1 endpoints and synthetic keys were used.",
                   "Actual product request methods executed; no hosted/provider/funding/customer actions.",
                   "Default transport canary and two in-memory removed-guard controls deliberately reach the second local endpoint, proving capture/oracle sensitivity."]}
    if args.out:
        args.out.mkdir(parents=True, exist_ok=False)
        (args.out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"passed": passed, "testsRun": result.testsRun, "guardControlsRejected": COUNTS["guardControlsRejected"]}))
    raise SystemExit(0 if passed else 1)
