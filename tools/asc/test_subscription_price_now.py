"""Offline fault controls for the one-off immediate USA reprice."""

import io
import json
import sys
import unittest
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))

import asc  # noqa: E402
import subscription_price_now as price_now  # noqa: E402
import subscription_reprice as scheduled  # noqa: E402
from test_asc import Args, FakeAsc  # noqa: E402


OLD = {"com.rendprop.app.starter.monthly": "49.00",
       "com.rendprop.app.pro.monthly": "99.00",
       "com.rendprop.app.team.monthly": "249.00"}


class FakeImmediate(FakeAsc):
    fail_null_post = False
    accept_without_readback = False

    def __call__(self, method, url, headers, body):
        path = urlparse(url).path
        attrs = ((json.loads(body.decode("utf-8")).get("data") or {}).get("attributes")
                 if body and method == "POST" else None)
        immediate = method == "POST" and path == "/v1/subscriptionPrices" and \
            attrs is not None and "startDate" in attrs and attrs["startDate"] is None
        if immediate and self.fail_null_post:
            self.writes.append((method, path))
            return 409, {}, b'{"errors":[{"code":"ENTITY_ERROR","status":"409"}]}'
        if immediate and self.accept_without_readback:
            self.writes.append((method, path))
            return 201, {}, b'{"data":{"type":"subscriptionPrices","id":"not-visible"}}'
        response = super().__call__(method, url, headers, body)
        if immediate and response[0] == 201:
            # The real API reports the new non-preserved current price.
            data = json.loads(response[2])
            self.store["subscriptionPrices"][data["data"]["id"]]["attributes"]["preserved"] = False
        return response


def seeded_client():
    fake = FakeImmediate()
    client = asc.Client(None, transport=fake, verbose=False, out=io.StringIO())
    assert asc.cmd_subscriptions(client, Args(), io.StringIO()) == 0
    snapshot = {}
    subs = {r["attributes"]["productId"]: r
            for r in fake.store["subscriptions"].values()}
    for product_id in scheduled.EXISTING_MONTHLY_IDS:
        spec = next(s for s in asc.SUBSCRIPTIONS if s["productId"] == product_id)
        sub = subs[product_id]
        fake.repoint_price(product_id, OLD[product_id])
        old = next(r for r in fake.store["subscriptionPrices"].values()
                   if r["_parents"].get("subscription") == sub["id"] and
                   r["_parents"].get("territory") == "USA")
        old["attributes"]["planType"] = "UPFRONT"
        old["attributes"]["preserved"] = True
        point = scheduled._exact_point(client, sub["id"],
                                       scheduled._amount(spec["usd"]))
        response = client.post("/v1/subscriptionPrices", {"data": {
            "type": "subscriptionPrices",
            "attributes": {"startDate": price_now.EXPECTED_DATE,
                           "preserveCurrentPrice": True, "planType": "UPFRONT"},
            "relationships": {
                "subscription": asc.relationship("subscriptions", sub["id"]),
                "territory": asc.relationship("territories", "USA"),
                "subscriptionPricePoint": asc.relationship("subscriptionPricePoints", point),
            }}})
        future_id = response["data"]["id"]
        fake.store["subscriptionPrices"][future_id]["attributes"]["preserved"] = False
        snapshot[product_id] = {"subscription_id": sub["id"],
                                "old_price_id": old["id"],
                                "future_price_id": future_id, "point_id": point,
                                "old_usd": OLD[product_id], "target_usd": spec["usd"]}
    fake.writes.clear()
    fake.bodies.clear()
    return fake, client, snapshot


class SubscriptionPriceNowTests(unittest.TestCase):
    def test_plan_is_get_only_and_snapshot_is_exact(self):
        fake, client, snapshot = seeded_client()
        out = io.StringIO()
        self.assertEqual(price_now.run(client, "plan", snapshot=snapshot, out=out), 0)
        self.assertEqual(fake.writes, [])
        self.assertEqual(out.getvalue().count("scheduled"), 3)

    def test_apply_deletes_only_pinned_future_rows_and_posts_null_date(self):
        fake, client, snapshot = seeded_client()
        out = io.StringIO()
        self.assertEqual(price_now.run(client, "apply", True, True, snapshot, out), 0)
        self.assertEqual(len(fake.writes), 6)
        for i, product_id in enumerate(snapshot):
            self.assertEqual(fake.writes[2*i],
                             ("DELETE", "/v1/subscriptionPrices/%s" %
                              snapshot[product_id]["future_price_id"]))
            self.assertEqual(fake.writes[2*i+1], ("POST", "/v1/subscriptionPrices"))
        bodies = [body for method, path, body in fake.bodies
                  if method == "POST" and path == "/v1/subscriptionPrices"]
        self.assertEqual(len(bodies), 3)
        for body in bodies:
            self.assertEqual(body["data"]["attributes"],
                             {"startDate": None, "preserveCurrentPrice": True,
                              "planType": "UPFRONT"})
            self.assertEqual(body["data"]["relationships"]["territory"]["data"]["id"],
                             "USA")
        fake.writes.clear()
        self.assertEqual(price_now.run(client, "apply", True, True,
                                       snapshot, io.StringIO()), 0)
        self.assertEqual(fake.writes, [])

    def test_apply_requires_both_flags(self):
        fake, client, snapshot = seeded_client()
        for live, preserve in ((False, False), (False, True), (True, False)):
            with self.subTest(live=live, preserve=preserve):
                with self.assertRaisesRegex(price_now.PriceNowError, "requires"):
                    price_now.run(client, "apply", live, preserve, snapshot)
        self.assertEqual(fake.writes, [])

    def test_last_product_point_drift_blocks_all_writes(self):
        fake, client, snapshot = seeded_client()
        fake.price_ladder = ["29.99", "49.99", "99.99", "249.00"]
        with self.assertRaises((price_now.PriceNowError, scheduled.RepriceError)):
            price_now.run(client, "apply", True, True, snapshot, io.StringIO())
        self.assertEqual(fake.writes, [])

    def test_unexpected_future_date_blocks_all_writes(self):
        fake, client, snapshot = seeded_client()
        team = snapshot["com.rendprop.app.team.monthly"]
        fake.store["subscriptionPrices"][team["future_price_id"]]["attributes"][
            "startDate"] = "2026-10-31"
        with self.assertRaisesRegex(price_now.PriceNowError, "phase changed"):
            price_now.run(client, "apply", True, True, snapshot)
        self.assertEqual(fake.writes, [])

    def test_delete_denial_stops_without_post(self):
        fake, client, snapshot = seeded_client()
        fake.price_delete_error = (409, "PRICE_LOCKED")
        with self.assertRaises(asc.ApiError):
            price_now.run(client, "apply", True, True, snapshot)
        self.assertEqual(len(fake.writes), 1)
        self.assertEqual(fake.writes[0][0], "DELETE")

    def test_post_denial_stops_and_next_run_can_resume_deleted_phase(self):
        fake, client, snapshot = seeded_client()
        fake.fail_null_post = True
        with self.assertRaises(asc.ApiError):
            price_now.run(client, "apply", True, True, snapshot)
        self.assertEqual([m for m, _ in fake.writes], ["DELETE", "POST"])
        fake.fail_null_post = False
        fake.writes.clear()
        self.assertEqual(price_now.run(client, "apply", True, True,
                                       snapshot, io.StringIO()), 0)
        self.assertEqual(fake.writes[0], ("POST", "/v1/subscriptionPrices"))

    def test_accepted_post_without_readback_stops_before_next_product(self):
        fake, client, snapshot = seeded_client()
        fake.accept_without_readback = True
        with self.assertRaisesRegex(price_now.PriceNowError, "not confirmed"):
            price_now.run(client, "apply", True, True, snapshot)
        self.assertEqual([m for m, _ in fake.writes], ["DELETE", "POST"])

    def test_subscription_identity_drift_blocks_all_writes(self):
        fake, client, snapshot = seeded_client()
        team = snapshot["com.rendprop.app.team.monthly"]
        team["subscription_id"] = "wrong"
        with self.assertRaisesRegex(price_now.PriceNowError, "identity/period"):
            price_now.run(client, "apply", True, True, snapshot)
        self.assertEqual(fake.writes, [])


if __name__ == "__main__":
    unittest.main()
