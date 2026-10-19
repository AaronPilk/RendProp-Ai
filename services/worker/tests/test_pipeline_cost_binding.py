"""Actual funding capture/ledger retry routing; supplier HTTP remains closed."""
import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "pipeline"))
import cost_ledger
import cost_spool
from providers import base, funding

URL = "https://queue.fal.run/fal-ai/flux-pro/kontext"
RPC = "https://closed.fixture.invalid/rest/v1/rpc/pipeline_record_provider_cost"
ATTEMPT = funding.ProviderFundingAttempt("b7300000-0000-4000-8000-000000000001", "b7300000-0000-4000-8000-00000000000a",
    "b7300000-0000-4000-8000-00000000000b", "b7300000-0000-4000-8000-00000000000c", "worker:" + "a" * 48,
    "fal", "fal-ai/flux-pro/kontext", "a" * 64)


class Reply:
    def __init__(self, data):
        self.data = data
    def __enter__(self):
        return self
    def __exit__(self, *args):
        return False
    def read(self):
        return self.data


class PipelineLedgerSpoolTests(unittest.TestCase):
    """Rollout order is SQL first, then worker: a worker that meets a database
    WITHOUT the binding RPC must spool the bound row (degraded, no further paid
    calls) and replay the SAME key once the RPC exists — never fall back to an
    unbound legacy insert, never lose or double-record the spend."""

    def setUp(self):
        self.sent = []
        self.rpc_present = False
        self.tmp = self.enterContext(tempfile.TemporaryDirectory())
        self.enterContext(patch.dict(os.environ, {cost_spool.ENV_PATH: os.path.join(self.tmp, "cost_spool.jsonl")}))
        self.enterContext(patch.object(cost_ledger.time, "sleep", lambda s: None))
        self.enterContext(patch.object(base.urllib.request, "build_opener", lambda *a: type("Opener", (), {"open": staticmethod(self.closed)})()))
        self.enterContext(patch.object(base.urllib.request, "urlopen", self.closed))
        self.ledger = cost_ledger.CostLedger("https://closed.fixture.invalid", "synthetic-only", False)

    def closed(self, req, timeout=None):
        url = req.full_url
        self.sent.append((req.get_method(), url))
        if url == RPC:
            if not self.rpc_present:
                # PostgREST's answer for a function the schema cache does not have.
                body = json.dumps({"code": "PGRST202", "message": "Could not find the function public.pipeline_record_provider_cost in the schema cache"}).encode()
                raise urllib.error.HTTPError(url, 404, "Not Found", {}, io.BytesIO(body))
            p = json.loads(req.data)
            return Reply(json.dumps({"recorded": True, "ledger_id": "b7300000-0000-4000-8000-0000000000ff",
                "billing_org_id": p["p_org"], "reservation_id": p["p_reservation"], "idempotency_key": "pipeline:" + p["p_reservation"],
                "actor_id": p["p_actor"], "org_id": p["p_org"], "request_key": p["p_key"], "stage": p["p_stage"],
                "provider": p["p_provider"], "model": p["p_model"], "input_sha256": p["p_input_sha256"]}).encode())
        raise AssertionError("Unexpected closed transport: " + req.get_method() + " " + url)

    def record(self):
        return self.ledger.record(feature="restage", provider="fal", model="fal-ai/flux-pro/kontext", units=1,
            unit_cost_cents=4, total_cents=4, job_id=ATTEMPT.request_key, org_id=ATTEMPT.org_id,
            meta={"fallback": "flux_kontext"}, funding_attempt=ATTEMPT)

    def test_missing_rpc_spools_the_bound_row_and_replays_the_same_key_once_the_rpc_exists(self):
        with self.assertRaises(cost_ledger.LedgerError) as raised:
            self.record()
        self.assertIn("PGRST202", str(raised.exception))
        self.assertIs(self.ledger.degraded, True, "no further paid calls while the bound spend is unrecorded")
        self.assertEqual(self.ledger.spooled_rows, 1)
        self.assertEqual(self.sent, [("POST", RPC)] * cost_ledger.LEDGER_RETRY_ATTEMPTS, "only the binding RPC is tried; never an unbound legacy cost_ledger insert")
        spooled = cost_spool.read_all()
        self.assertEqual(len(spooled), 1)
        row = spooled[0]["row"]
        self.assertEqual(row["idempotency_key"], "pipeline:" + ATTEMPT.reservation_id)
        self.assertEqual(row["meta"]["pipeline_funding"], ATTEMPT.metadata())
        self.assertEqual(spooled[0]["source"], "pipeline")
        # The RPC is still missing: the replay pass stops, nothing is dropped.
        self.sent.clear()
        self.assertEqual(self.ledger.flush_spool(), (0, 1))
        self.assertIs(self.ledger.degraded, True)
        self.assertEqual(self.sent, [("POST", RPC)])
        # SQL rolled out: the SAME spooled row replays through the RPC with its
        # original key and identity, the spool empties and the ledger recovers.
        self.rpc_present = True
        self.sent.clear()
        self.assertEqual(self.ledger.flush_spool(), (1, 0))
        self.assertIs(self.ledger.degraded, False)
        self.assertEqual(self.sent, [("POST", RPC)])
        self.assertEqual(cost_spool.read_all(), [])

    def test_receipt_that_does_not_echo_the_admitted_identity_is_spooled_not_trusted(self):
        self.rpc_present = True
        original = self.closed
        def foreign(req, timeout=None):
            reply = original(req, timeout)
            data = json.loads(reply.read()); data["reservation_id"] = "b7300000-0000-4000-8000-00000000dead"
            return Reply(json.dumps(data).encode())
        with patch.object(base.urllib.request, "build_opener", lambda *a: type("Opener", (), {"open": staticmethod(foreign)})()):
            with self.assertRaises(cost_ledger.LedgerError) as raised:
                self.record()
        self.assertIn("not confirmed", str(raised.exception))
        self.assertIs(self.ledger.degraded, True)
        self.assertEqual(len(cost_spool.read_all()), 1)

class PipelineCaptureTests(unittest.TestCase):
    def session(self, receipt):
        def rpc(name, args):
            return receipt if name == "serving_cost_reserve" else {"finished": True}
        return funding.ServingSession("actor", "org", "worker-job-123456", rpc, lambda: None)

    def test_scope_captures_admitted_identity_and_does_not_change_http_outcome(self):
        states = []
        s = self.session({"reserved": True, "id": "b7300000-0000-4000-8000-000000000001"})
        original = s.rpc
        def rpc(name, args):
            if name == "serving_cost_finish": states.append(args["p_state"])
            return original(name, args)
        s.rpc = rpc
        with patch.object(base.urllib.request, "urlopen", return_value=io.BytesIO(b'{}')), \
             funding.serving_session(s), funding.capture_provider_attempts() as attempts:
            self.assertEqual(base.request_json(URL, payload={"image_url": "fixture"}), {})
        self.assertEqual(states, ["uncertain"])
        a = funding.result_funding(attempts, "fal", "fal-ai/flux-pro/kontext")
        self.assertEqual(a.reservation_id, "b7300000-0000-4000-8000-000000000001")
        self.assertEqual(a.request_key, s.job_id)
        self.assertEqual(a.stage, "worker:" + a.input_sha256[:48])
        self.assertIsNone(funding.result_funding(attempts, "gemini", a.model))
        self.assertIsNone(funding.result_funding(attempts * 2, a.provider, a.model))
        with funding.capture_provider_attempts() as next_attempts:
            self.assertEqual(next_attempts, [])

    def test_scoped_malformed_admission_never_submits(self):
        for receipt in ({"reserved": True}, {"reserved": True, "id": "foreign"}, {"reserved": 1}):
            with self.subTest(receipt=receipt), patch.object(base.urllib.request, "urlopen") as send, \
                 funding.serving_session(self.session(receipt)), funding.capture_provider_attempts():
                with self.assertRaises(base.ProviderFundingError): base.request_json(URL, payload={})
                send.assert_not_called()

if __name__ == "__main__": unittest.main()
