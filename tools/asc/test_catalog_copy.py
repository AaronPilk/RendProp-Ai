import io
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, "tools/asc")
import asc
import catalog_copy


class PriceClient:
    def __init__(self, amount="29.99", date=None, offer=True):
        self.amount = amount
        self.date = date
        self.offer = offer

    def get_all(self, path):
        if path.endswith("/introductoryOffers"):
            return [{"attributes": {"offerMode": "FREE_TRIAL", "duration": "ONE_WEEK",
                                    "numberOfPeriods": 1, "targetSubscriptionPlanType": "UPFRONT",
                                    "startDate": datetime.now(timezone.utc).date().isoformat(),
                                    "endDate": None}}] if self.offer else []
        raise AssertionError(path)

    def get_all_included(self, path, params=None):
        if not path.endswith("/prices"):
            raise AssertionError(path)
        prices = [{"relationships": {
            "territory": {"data": {"id": "USA"}},
            "subscriptionPricePoint": {"data": {"id": "point"}}},
            "attributes": {"preserved": False, "planType": "UPFRONT",
                           "startDate": self.date}}]
        included = [{"type": "subscriptionPricePoints", "id": "point",
                     "attributes": {"customerPrice": self.amount}}]
        return prices, included


class PatchClient:
    def __init__(self, honor_patch=True):
        self.honor_patch = honor_patch
        self.resources = {"/v1/subscriptionLocalizations/sub":
                          {"type": "subscriptionLocalizations", "id": "sub",
                           "attributes": {"name": "Old", "description": "Old"}}}
        self.writes = []

    def patch(self, path, body):
        self.writes.append((path, body))
        if self.honor_patch:
            self.resources[path]["attributes"].update(body["data"]["attributes"])
        return {"data": self.resources[path]}

    def get(self, path):
        return {"data": self.resources[path]}


class CatalogCopyTests(unittest.TestCase):
    def test_source_catalog_and_metadata_limits(self):
        catalog_copy.verify_source()
        specs = catalog_copy.specs()
        self.assertEqual(len(specs), 10)
        self.assertEqual(specs[0]["description"], "60 AI credits monthly; 1 seat.")
        self.assertEqual(specs[-1]["description"], "1,200 AI credits monthly; 9 seats.")
        self.assertIn("Max (120, one seat)", catalog_copy._copy_file("description", 4000))
        self.assertIn("four monthly products", catalog_copy._copy_file("review_notes", 4000))
        self.assertIn("If activated, a paid Team owner", catalog_copy._copy_file("description_team_seats", 4000))
        self.assertIn("More Team seats", catalog_copy._copy_file("review_notes_team_seats", 4000))

    def test_price_and_trial_require_exact_usa_terms(self):
        spec = catalog_copy.specs()[0]
        sub = {"id": "sub"}
        self.assertIsNone(catalog_copy._validate_price_and_trial(
            PriceClient(), sub, spec))
        with self.assertRaisesRegex(catalog_copy.CopyError, "exact non-preserved USA"):
            catalog_copy._validate_price_and_trial(PriceClient(amount="29.00"), sub, spec)
        with self.assertRaisesRegex(catalog_copy.CopyError, "no open 7-day"):
            catalog_copy._validate_price_and_trial(PriceClient(offer=False), sub, spec)

    def test_team_variant_requires_removal_of_introductory_offer(self):
        spec = catalog_copy.specs()[4]
        self.assertIsNone(catalog_copy._validate_price_and_trial(
            PriceClient(amount=spec["usd"], offer=False), {"id": "team4"}, spec,
            require_trial=False))
        with self.assertRaisesRegex(catalog_copy.CopyError, "trial offer"):
            catalog_copy._validate_price_and_trial(
                PriceClient(amount=spec["usd"], offer=True), {"id": "team4"}, spec,
                require_trial=False)

    def test_team_variant_copy_needs_explicit_native_and_operator_activation(self):
        with patch.object(catalog_copy, "verify_source", return_value=True):
            with self.assertRaisesRegex(catalog_copy.CopyError, "native StoreKit allowlist"):
                catalog_copy.plan(None, include_team_seats=True)
        snapshot = (catalog_copy.EXPECTED_APP_ID, "version", [], [])
        with patch.object(catalog_copy, "plan", return_value=snapshot):
            with self.assertRaisesRegex(catalog_copy.CopyError, "confirm-team-seat-activation"):
                catalog_copy.run(PatchClient(), "apply", catalog_copy.EXPECTED_APP_ID,
                                 "version", True, True, False, out=io.StringIO())

    def test_existing_products_require_the_known_future_schedule(self):
        spec = catalog_copy.specs()[1]
        with self.assertRaisesRegex(catalog_copy.CopyError, "expected 2026-10-30"):
            catalog_copy._validate_price_and_trial(
                PriceClient(amount="49.99", date="2026-10-31"), {"id": "sub"}, spec)
        self.assertEqual(catalog_copy._validate_price_and_trial(
            PriceClient(amount="49.99", date="2026-10-30"), {"id": "sub"}, spec),
            "2026-10-30")

    def test_plan_never_writes_and_apply_requires_exact_confirmation(self):
        changes = [{"kind": "subscriptionLocalizations", "id": "sub",
                    "attrs": {"name": "Pro Monthly", "description": "60 AI credits monthly; 1 seat."}}]
        snapshot = (catalog_copy.EXPECTED_APP_ID, "version", changes, [])
        client = PatchClient()
        with patch.object(catalog_copy, "plan", return_value=snapshot):
            self.assertEqual(catalog_copy.run(client, "plan", out=io.StringIO()), 0)
            self.assertFalse(client.writes)
            with self.assertRaisesRegex(catalog_copy.CopyError, "requires"):
                catalog_copy.run(client, "apply", out=io.StringIO())
            self.assertFalse(client.writes)
            with self.assertRaisesRegex(catalog_copy.CopyError, "credit-activation"):
                catalog_copy.run(client, "apply", catalog_copy.EXPECTED_APP_ID,
                                 "version", out=io.StringIO())
            self.assertFalse(client.writes)
            self.assertEqual(catalog_copy.run(client, "apply", catalog_copy.EXPECTED_APP_ID,
                                              "version", True, out=io.StringIO()), 0)
            self.assertEqual(len(client.writes), 1)
            self.assertEqual(client.resources[client.writes[0][0]]["attributes"]["name"],
                             "Pro Monthly")

    def test_apply_stops_when_readback_disagrees(self):
        changes = [{"kind": "subscriptionLocalizations", "id": "sub",
                    "attrs": {"name": "Pro Monthly"}}]
        snapshot = (catalog_copy.EXPECTED_APP_ID, "version", changes, [])
        with patch.object(catalog_copy, "plan", return_value=snapshot):
            with self.assertRaisesRegex(catalog_copy.CopyError, "did not confirm"):
                catalog_copy.run(PatchClient(honor_patch=False), "apply",
                                 catalog_copy.EXPECTED_APP_ID, "version", True,
                                 out=io.StringIO())

    def test_real_phone_review_png_may_use_apple_supported_native_size(self):
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / "paywall.png"
            def png_header(width, height):
                return (b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\x0dIHDR" +
                        width.to_bytes(4, "big") + height.to_bytes(4, "big") +
                        b"\x08\x02\x00\x00\x00" + b"\x00\x00\x00\x00")
            image.write_bytes(png_header(1206, 2622))
            self.assertIsNone(asc.iap_review_screenshot_issue(image))
            image.write_bytes(png_header(800, 800))
            self.assertIn("native supported iPhone", asc.iap_review_screenshot_issue(image))

    def test_team_review_images_are_product_specific(self):
        self.assertEqual(asc.iap_review_screenshot_for_product("com.rendprop.app.pro29.monthly").name,
                         "paywall.png")
        for seats in range(4, 10):
            product_id = "com.rendprop.app.team%d.monthly" % seats
            self.assertEqual(asc.iap_review_screenshot_for_product(product_id).name,
                             "team%d.png" % seats)


if __name__ == "__main__":
    unittest.main()
