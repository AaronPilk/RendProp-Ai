#!/usr/bin/env python3
"""Readiness gate contracts without an Apple write or network request."""

import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import one_time_iap_readiness as gate


class FakeClient:
    def __init__(self, product_state="READY_TO_SUBMIT", shot_state="COMPLETE"):
        self.product_state = product_state
        self.shot_state = shot_state
        self.calls = []

    def get_all(self, path, params=None):
        self.calls.append(("GET", path, params))
        assert path == "/v1/apps/app/inAppPurchasesV2"
        sku = params["filter[productId]"]
        return [{"type": "inAppPurchases", "id": "iap", "attributes": {
            "productId": sku, "inAppPurchaseType": "CONSUMABLE",
            "state": self.product_state, "reviewNote": "How to review this purchase.",
        }}]

    def get_optional(self, path):
        self.calls.append(("GET", path, None))
        assert path == "/v2/inAppPurchases/iap/appStoreReviewScreenshot"
        if self.shot_state is None:
            return None
        return {"data": {"type": "inAppPurchaseAppStoreReviewScreenshots",
                         "id": "shot", "attributes": {
                             "sourceFileChecksum": "ad4b329902919ed1dbdb1e7677f91741",
                             "assetDeliveryState": {"state": self.shot_state},
                         }}}


class ReadinessTests(unittest.TestCase):
    def inspect(self, client, expected=None, **overrides):
        expected = expected or gate.PRODUCTS[0]
        with patch.object(gate.pack, "read_availability", return_value=overrides.get("availability", (False, ["USA"]))), \
             patch.object(gate.pack, "read_us_price", return_value=overrides.get("price", expected.price)), \
             patch.object(gate.pack, "read_versions", return_value=([{"id": "version"}], {"id": "version"})), \
             patch.object(gate.pack, "read_localization", return_value={"attributes": {
                 "name": expected.name,
                 "description": overrides.get("description", "One purchase for one workspace."),
             }}):
            return gate.inspect_product(client, "app", expected)

    def test_complete_exact_product_is_ready(self):
        client = FakeClient()
        self.assertEqual(self.inspect(client), [])
        self.assertEqual(len(client.calls), 2)
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    def test_missing_screenshot_blocks_even_with_full_localization(self):
        reasons = self.inspect(FakeClient("MISSING_METADATA", None))
        self.assertIn("App Review screenshot is missing", reasons)
        self.assertIn("Apple product state is MISSING_METADATA", reasons)

    def test_upload_in_progress_is_not_ready(self):
        self.assertIn("App Review screenshot is UPLOAD_COMPLETE",
                      self.inspect(FakeClient(shot_state="UPLOAD_COMPLETE")))

    def test_wrong_price_or_availability_blocks(self):
        reasons = self.inspect(FakeClient(), price=gate.Decimal("29.99"),
                               availability=(True, ["USA", "CAN"]))
        self.assertTrue(any("USA price" in reason for reason in reasons))
        self.assertTrue(any("availability" in reason for reason in reasons))

    def test_description_length_is_checked(self):
        reasons = self.inspect(FakeClient(), description="x" * 46)
        self.assertIn("en-US description is missing or exceeds 45 characters", reasons)

    def test_require_ready_exits_nonzero_without_mutating(self):
        client = FakeClient("MISSING_METADATA", None)
        out = io.StringIO()
        with patch.object(gate.asc, "require_app", return_value={"id": "app"}), \
             patch.object(gate.pack, "read_availability", return_value=(False, ["USA"])), \
             patch.object(gate.pack, "read_us_price", side_effect=[p.price for p in gate.PRODUCTS]), \
             patch.object(gate.pack, "read_versions", return_value=([{"id": "version"}], {"id": "version"})), \
             patch.object(gate.pack, "read_localization", side_effect=[{"attributes": {
                 "name": p.name, "description": "Accurate description."
             }} for p in gate.PRODUCTS]):
            self.assertEqual(gate.main(["--require-ready"], client=client, out=out), 1)
        self.assertEqual(out.getvalue().count("BLOCKED"), 2)
        self.assertTrue(all(call[0] == "GET" for call in client.calls))


if __name__ == "__main__":
    unittest.main()
