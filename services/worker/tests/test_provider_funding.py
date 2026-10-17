"""Actual legacy provider transport, mocked HTTP/DB; no paid calls."""
import io
import json
import sys
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "pipeline"))
from providers import base, funding

URL = "https://queue.fal.run/fal-ai/flux-pro/kontext"
GEMINI = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image:generateContent"


class FundingTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.held = set()
        self.sponsor = False
        self.authorize = Mock()
        self.session = funding.ServingSession("actor", "org", "worker-job-123456", self.rpc, self.authorize)
        self.send = self.enterContext(patch.object(base.urllib.request, "urlopen",
            return_value=io.BytesIO(b'{"request_id":"fixture"}')))

    def rpc(self, name, args):
        self.calls.append((name, args.copy()))
        if name.startswith("org_has_"):
            return self.sponsor
        if name == "serving_cost_reserve":
            key = args["p_stage"]
            if key in self.held:
                raise funding.FundingUnavailable("A recorded attempt cannot dispatch again")
            self.held.add(key)
            return {"reserved": True}
        return {"finished": True}

    def run_request(self, url=URL, payload=None, retries=2):
        with funding.serving_session(self.session):
            return base.request_json(url, payload=payload or {"image_url": "data:fixture"}, retries=retries)

    def test_no_session_or_fake_shape_cannot_dispatch(self):
        with self.assertRaises(base.ProviderFundingError):
            base.request_json(URL, payload={})
        self.send.assert_not_called()
        self.session.rpc = lambda *_: {"reserved": 1}
        with self.assertRaises(base.ProviderFundingError):
            self.run_request()
        self.send.assert_not_called()

    def test_hold_precedes_paid_dispatch_and_includes_full_input_and_combined_output(self):
        payload = {"contents": [], "generationConfig": {
            "candidateCount": 1, "maxOutputTokens": funding.IMAGE_MAX_OUTPUT_TOKENS,
            "responseModalities": ["IMAGE"], "imageConfig": {"imageSize": "1K"}}}
        self.run_request(GEMINI, payload)
        reserve = next(args for name, args in self.calls if name == "serving_cost_reserve")
        self.assertEqual(reserve["p_hold_cents"], 31.1296)
        self.assertEqual(reserve["p_actor"], "actor")
        self.assertEqual(self.calls[-1][1]["p_state"], "uncertain")
        self.authorize.assert_called_once()

    def test_changed_gemini_payload_cannot_use_a_smaller_hold(self):
        original = {"contents": [], "generationConfig": {
            "candidateCount": 1, "maxOutputTokens": funding.IMAGE_MAX_OUTPUT_TOKENS,
            "responseModalities": ["IMAGE"], "imageConfig": {"imageSize": "1K"}}}
        from copy import deepcopy
        larger = deepcopy(original)
        larger["generationConfig"]["maxOutputTokens"] = 8192
        self.assertEqual(funding.quote("gemini", "gemini-3.1-flash-image", larger), 55.7056)
        for field, value in (("candidateCount", 2), ("candidateCount", True),
                             ("maxOutputTokens", None), ("maxOutputTokens", 32769),
                             ("maxOutputTokens", True), ("imageConfig", {"imageSize": "4K"}),
                             ("responseModalities", ["TEXT", "IMAGE"])):
            changed = deepcopy(original)
            changed["generationConfig"][field] = value
            with self.subTest(field=field, value=value):
                with self.assertRaises(base.ProviderFundingError):
                    self.run_request(GEMINI, changed)
                self.send.assert_not_called()
        original["tools"] = [{"googleSearch": {}}]
        with self.assertRaises(base.ProviderFundingError):
            self.run_request(GEMINI, original)
        self.send.assert_not_called()

    def test_real_gemini_adapter_sends_the_priced_payload(self):
        from types import SimpleNamespace
        from providers import gemini
        self.send.return_value = io.BytesIO(json.dumps({"candidates": [{"content": {"parts": [
            {"inlineData": {"mimeType": "image/png", "data": "aW1hZ2U="}}
        ]}}]}).encode())
        with patch.object(gemini, "SETTINGS", SimpleNamespace(
                gemini_api_key="offline-fixture", gemini_image_model="gemini-3.1-flash-image")):
            with funding.serving_session(self.session):
                self.assertEqual(gemini.restage(b"source-image", "Declutter this room"), b"image")
        actual = json.loads(self.send.call_args.args[0].data)
        reserve = next(args for name, args in self.calls if name == "serving_cost_reserve")
        self.assertEqual(actual["generationConfig"]["imageConfig"], {"imageSize": "1K"})
        self.assertEqual(actual["generationConfig"]["maxOutputTokens"], 4096)
        self.assertEqual(actual["generationConfig"]["candidateCount"], 1)
        self.assertEqual(reserve["p_hold_cents"], 31.1296)
        self.assertEqual(self.send.call_count, 1)

    def test_db_failure_and_lost_lease_cannot_dispatch(self):
        self.session.rpc = Mock(side_effect=RuntimeError("DB unavailable"))
        with self.assertRaises(RuntimeError):
            self.run_request()
        self.send.assert_not_called()
        self.authorize.side_effect = RuntimeError("lease lost")
        with self.assertRaises(RuntimeError):
            self.run_request()
        self.send.assert_not_called()

    def test_replay_preserves_tombstone_and_has_no_second_post(self):
        self.run_request()
        with self.assertRaises(base.ProviderFundingError):
            self.run_request()
        self.assertEqual(self.send.call_count, 1)

    def test_ambiguous_503_or_timeout_retains_hold_without_retry(self):
        for error in (urllib.error.HTTPError(URL, 503, "unavailable", {}, io.BytesIO(b"{}")), TimeoutError()):
            with self.subTest(error=type(error).__name__):
                self.held.clear()
                self.send.reset_mock()
                self.send.side_effect = error
                with self.assertRaises(base.ProviderError):
                    self.run_request(retries=4)
                self.assertEqual(self.send.call_count, 1)
                self.assertEqual(self.calls[-1][1]["p_state"], "uncertain")
                self.assertIsNone(self.calls[-1][1]["p_rejection_status"])

    def test_proven_429_rejection_is_recorded_without_implicit_retry(self):
        self.send.side_effect = urllib.error.HTTPError(URL, 429, "limited", {}, io.BytesIO(b"{}"))
        with self.assertRaises(base.ProviderError):
            self.run_request()
        self.assertEqual(self.send.call_count, 1)
        self.assertEqual(self.calls[-1][1]["p_state"], "rejected")
        self.assertEqual(self.calls[-1][1]["p_rejection_status"], 429)

    def test_unknown_rate_requires_explicit_unlimited_sponsorship(self):
        unknown = "https://queue.fal.run/fal-ai/unpriced"
        with self.assertRaises(base.ProviderFundingError):
            self.run_request(unknown)
        self.send.assert_not_called()
        self.sponsor = True
        self.run_request(unknown)
        reserve = next(args for name, args in self.calls if name == "serving_cost_reserve")
        self.assertEqual(reserve["p_tariff_version"], "unpriced-private-sponsorship")
        self.assertEqual(reserve["p_hold_cents"], 1)

    def test_malformed_json_and_lost_settlement_keep_liability(self):
        self.send.return_value = io.BytesIO(b"not-json")
        with self.assertRaises(base.ProviderError):
            self.run_request()
        self.assertEqual(self.calls[-1][1]["p_state"], "uncertain")
        self.held.clear()
        self.send.return_value = io.BytesIO(b"{}")
        original = self.rpc
        def no_settlement(name, args):
            if name == "serving_cost_finish":
                raise RuntimeError("response lost")
            return original(name, args)
        self.session.rpc = no_settlement
        self.assertEqual(self.run_request(), {})
        self.assertEqual(len(self.held), 1)

    def test_reads_and_ledger_writes_do_not_require_generation_funds(self):
        self.assertIsNone(funding.reserve_paid(URL + "/requests/fixture", "GET", None))
        self.assertIsNone(funding.reserve_paid("https://project.supabase.co/rest/v1/cost_ledger", "POST", {}))
        with funding.serving_session(self.session):
            pass
        with self.assertRaises(base.ProviderFundingError):
            base.request_json(URL, payload={})


if __name__ == "__main__":
    unittest.main()
