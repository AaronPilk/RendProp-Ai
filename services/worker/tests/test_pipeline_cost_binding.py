"""Actual funding capture/ledger retry routing; supplier HTTP remains closed."""
import io
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "pipeline"))
from providers import base, funding

URL = "https://queue.fal.run/fal-ai/flux-pro/kontext"

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
