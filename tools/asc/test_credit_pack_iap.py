"""Offline Apple JSON:API contract and idempotency checks for one credit pack."""

import io
from contextlib import redirect_stderr
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import credit_pack_iap as pack


APP_ID = "rendprop-app-id"
IAP_ID = "credit-iap-id"
VERSION_ID = "credit-version-id"
POINT_ID = "usa-3999-point"


def row(kind, identifier, **attrs):
    return {"type": kind, "id": identifier, "attributes": attrs}


class FakeClient:
    def __init__(self):
        self.calls = []
        self.product = None
        self.availability = None
        self.price = None
        self.empty_schedule = False
        self.price_point = "39.99"
        self.version = None
        self.localization = None

    def get(self, path, params=None):
        self.calls.append(("GET", path, params))
        if path == "/v1/apps":
            return {"data": [row("apps", APP_ID, bundleId="com.rendprop.app")]}
        raise AssertionError("unexpected GET %s" % path)

    def get_all(self, path, params=None):
        self.calls.append(("GET_ALL", path, params))
        if path == "/v1/apps/%s/inAppPurchasesV2" % APP_ID:
            return [self.product] if self.product else []
        if path == "/v1/inAppPurchaseAvailabilities/%s/availableTerritories" % IAP_ID:
            return [row("territories", t) for t in (self.availability or (False, []))[1]]
        if path == "/v2/inAppPurchases/%s/pricePoints" % IAP_ID:
            if self.price_point is None:
                return []
            point = row("inAppPurchasePricePoints", POINT_ID,
                        customerPrice=self.price_point)
            point["relationships"] = {
                "territory": pack.relationship("territories", "USA")}
            return [point]
        if path == "/v2/inAppPurchases/%s/versions" % IAP_ID:
            return [self.version] if self.version else []
        if path == "/v1/inAppPurchaseVersions/%s/localizations" % VERSION_ID:
            return [self.localization] if self.localization else []
        raise AssertionError("unexpected GET_ALL %s" % path)

    def get_optional(self, path, params=None):
        self.calls.append(("GET_OPTIONAL", path, params))
        if path == "/v2/inAppPurchases/%s/inAppPurchaseAvailability" % IAP_ID:
            if self.availability is None:
                return None
            enabled, territories = self.availability
            return {"data": row("inAppPurchaseAvailabilities", IAP_ID,
                                availableInNewTerritories=enabled)}
        if path == "/v2/inAppPurchases/%s/iapPriceSchedule" % IAP_ID:
            if self.price is None and not self.empty_schedule:
                return None
            schedule = row("inAppPurchasePriceSchedules", IAP_ID)
            schedule["relationships"] = {
                "baseTerritory": pack.relationship("territories", "USA")}
            return {"data": schedule}
        raise AssertionError("unexpected GET_OPTIONAL %s" % path)

    def get_all_included(self, path, params=None):
        self.calls.append(("GET_ALL_INCLUDED", path, params))
        assert path == "/v1/inAppPurchasePriceSchedules/%s/manualPrices" % IAP_ID
        if self.price is None:
            return [], []
        price = row("inAppPurchasePrices", "price-id", startDate=None)
        price["relationships"] = {
            "territory": pack.relationship("territories", "USA"),
            "inAppPurchasePricePoint": pack.relationship(
                "inAppPurchasePricePoints", POINT_ID),
        }
        point = row("inAppPurchasePricePoints", POINT_ID,
                    customerPrice=self.price)
        return [price], [point]

    def post(self, path, body):
        self.calls.append(("POST", path, body))
        data = body["data"]
        if path == "/v2/inAppPurchases":
            assert data["type"] == "inAppPurchases"
            assert data["attributes"]["inAppPurchaseType"] == "CONSUMABLE"
            assert data["attributes"]["productId"] == pack.PRODUCT_ID
            assert data["relationships"]["app"] == pack.relationship("apps", APP_ID)
            self.product = row("inAppPurchases", IAP_ID,
                               name=pack.INTERNAL_NAME,
                               productId=pack.PRODUCT_ID,
                               inAppPurchaseType="CONSUMABLE")
        elif path == "/v1/inAppPurchaseAvailabilities":
            assert data["attributes"]["availableInNewTerritories"] is False
            assert data["relationships"]["availableTerritories"] == {
                "data": [{"type": "territories", "id": "USA"}]}
            self.availability = (False, ["USA"])
        elif path == "/v1/inAppPurchasePriceSchedules":
            assert data["type"] == "inAppPurchasePriceSchedules"
            assert data["relationships"]["baseTerritory"] == \
                pack.relationship("territories", "USA")
            handle = data["relationships"]["manualPrices"]["data"][0]["id"]
            assert handle.startswith("${")
            assert body["included"][0]["id"] == handle
            assert body["included"][0]["relationships"]["inAppPurchasePricePoint"] == \
                pack.relationship("inAppPurchasePricePoints", POINT_ID)
            self.price = "39.99"
        elif path == "/v1/inAppPurchaseVersions":
            assert data["relationships"]["inAppPurchase"] == \
                pack.relationship("inAppPurchases", IAP_ID)
            self.version = row("inAppPurchaseVersions", VERSION_ID,
                               state="PREPARE_FOR_SUBMISSION")
        elif path == "/v2/inAppPurchaseLocalizations":
            assert data["attributes"] == {
                "locale": "en-US", "name": pack.DISPLAY_NAME,
                "description": pack.DESCRIPTION}
            assert data["relationships"]["version"] == \
                pack.relationship("inAppPurchaseVersions", VERSION_ID)
            self.localization = row("inAppPurchaseLocalizations", "localization-id",
                                    **data["attributes"])
        else:
            raise AssertionError("unexpected POST %s" % path)
        return {"data": data}


class CreditPackTests(unittest.TestCase):
    def test_plan_is_read_only_and_defers_dependent_steps(self):
        client = FakeClient()
        output = io.StringIO()
        self.assertEqual(pack.main(["plan"], client=client, out=output), 0)
        self.assertIn("absent", output.getvalue())
        self.assertIn("USD 39.99", output.getvalue())
        self.assertFalse(any(call[0] == "POST" for call in client.calls))

    def test_apply_requires_exact_product_confirmation_even_with_fake_client(self):
        client = FakeClient()
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            pack.main(["apply"], client=client, out=io.StringIO())
        self.assertEqual(client.calls, [])

    def test_full_apply_is_idempotent_and_exact(self):
        client = FakeClient()
        state = pack.apply(client, APP_ID)
        self.assertEqual(str(state["price"]), "39.99")
        self.assertEqual(state["availability"], (False, ["USA"]))
        self.assertEqual(state["localization"]["attributes"]["locale"], "en-US")
        paths = [call[1] for call in client.calls if call[0] == "POST"]
        self.assertEqual(paths, [
            "/v2/inAppPurchases", "/v1/inAppPurchaseAvailabilities",
            "/v1/inAppPurchasePriceSchedules", "/v1/inAppPurchaseVersions",
            "/v2/inAppPurchaseLocalizations",
        ])
        pack.apply(client, APP_ID)
        self.assertEqual([call[1] for call in client.calls if call[0] == "POST"],
                         paths)

    def test_cli_apply_with_exact_confirmation_runs_only_fixed_product(self):
        client = FakeClient()
        output = io.StringIO()
        self.assertEqual(pack.main(
            ["apply", "--confirm-product-id", pack.PRODUCT_ID],
            client=client, out=output), 0)
        self.assertIn("Apple IAP ID: %s" % IAP_ID, output.getvalue())
        self.assertEqual(client.product["attributes"]["productId"], pack.PRODUCT_ID)

    def test_missing_exact_price_point_leaves_created_product_unpriced(self):
        client = FakeClient()
        client.price_point = "30.00"
        with self.assertRaisesRegex(pack.CreditPackError, "exact USA"):
            pack.apply(client, APP_ID)
        self.assertIsNone(client.price)
        self.assertIsNotNone(client.product)
        self.assertFalse(any(c[1] == "/v1/inAppPurchasePriceSchedules"
                             for c in client.calls if c[0] == "POST"))

    def test_empty_schedule_resource_is_still_unpriced(self):
        client = FakeClient()
        client.empty_schedule = True
        state = pack.apply(client, APP_ID)
        self.assertEqual(state["price"], pack.CUSTOMER_PRICE)

    def test_wrong_existing_type_is_rejected_without_writes(self):
        client = FakeClient()
        client.product = row("inAppPurchases", IAP_ID,
                             productId=pack.PRODUCT_ID,
                             inAppPurchaseType="NON_CONSUMABLE")
        with self.assertRaisesRegex(pack.CreditPackError, "not CONSUMABLE"):
            pack.apply(client, APP_ID)
        self.assertFalse(any(c[0] == "POST" for c in client.calls))

    def test_wrong_existing_price_and_territory_are_rejected(self):
        for override in ("price", "availability"):
            with self.subTest(override=override):
                client = FakeClient()
                client.product = row("inAppPurchases", IAP_ID,
                                     productId=pack.PRODUCT_ID,
                                     inAppPurchaseType="CONSUMABLE")
                client.availability = (False, ["USA"])
                client.price = "39.99"
                if override == "price":
                    client.price = "29.99"
                else:
                    client.availability = (True, ["USA", "CAN"])
                with self.assertRaises(pack.CreditPackError):
                    pack.apply(client, APP_ID)
                self.assertFalse(any(c[0] == "POST" for c in client.calls))

    def test_existing_localization_conflict_is_rejected(self):
        client = FakeClient()
        client.product = row("inAppPurchases", IAP_ID,
                             productId=pack.PRODUCT_ID,
                             inAppPurchaseType="CONSUMABLE")
        client.availability = (False, ["USA"])
        client.price = "39.99"
        client.version = row("inAppPurchaseVersions", VERSION_ID,
                             state="PREPARE_FOR_SUBMISSION")
        client.localization = row("inAppPurchaseLocalizations", "localization-id",
                                  locale="en-US", name="Other", description="Other")
        with self.assertRaisesRegex(pack.CreditPackError, "localization differs"):
            pack.apply(client, APP_ID)
        self.assertFalse(any(c[0] == "POST" for c in client.calls))


if __name__ == "__main__":
    unittest.main()
