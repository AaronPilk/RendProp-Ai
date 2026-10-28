"""Offline fault controls for restoration after Apple's approved-price denial."""

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
MAX = "com.rendprop.app.starter.monthly"


class FakeScheduled(FakeAsc):
    fail_scheduled_post = False
    accept_without_readback = False

    def __call__(self, method, url, headers, body):
        path = urlparse(url).path
        attrs = ((json.loads(body.decode("utf-8")).get("data") or {}).get("attributes")
                 if body and method == "POST" else None)
        scheduled_post = method == "POST" and path == "/v1/subscriptionPrices" and \
            attrs is not None and attrs.get("startDate") == price_now.EXPECTED_DATE
        if scheduled_post and self.fail_scheduled_post:
            self.writes.append((method, path))
            return 409, {}, b'{"errors":[{"code":"STATE_ERROR","status":"409"}]}'
        if scheduled_post and self.accept_without_readback:
            self.writes.append((method, path))
            return 201, {}, b'{"data":{"type":"subscriptionPrices","id":"not-visible"}}'
        response = super().__call__(method, url, headers, body)
        if scheduled_post and response[0] == 201:
            data = json.loads(response[2])
            self.store["subscriptionPrices"][data["data"]["id"]]["attributes"]["preserved"] = False
        return response


def seeded_client():
    fake = FakeScheduled()
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


def remove_max_future(fake, client, snapshot):
    client.request("DELETE", "/v1/subscriptionPrices/%s" %
                   snapshot[MAX]["future_price_id"], expect=(204,))
    fake.writes.clear()
    fake.bodies.clear()


class SubscriptionPriceRecoveryTests(unittest.TestCase):
    def test_plan_is_read_only_and_sees_exact_deleted_max(self):
        fake, client, snapshot = seeded_client()
        remove_max_future(fake, client, snapshot)
        out = io.StringIO()
        self.assertEqual(price_now.run(client, "plan", snapshot=snapshot, out=out), 0)
        self.assertEqual(fake.writes, [])
        self.assertIn("starter.monthly: deleted", out.getvalue())

    def test_restore_writes_only_max_future_phase_and_is_idempotent(self):
        fake, client, snapshot = seeded_client()
        remove_max_future(fake, client, snapshot)
        out = io.StringIO()
        self.assertEqual(price_now.run(client, "restore-max", True, True,
                                       snapshot, out), 0)
        self.assertEqual(fake.writes, [("POST", "/v1/subscriptionPrices")])
        body = fake.bodies[0][2]
        self.assertEqual(body["data"]["attributes"],
                         {"startDate": price_now.EXPECTED_DATE,
                          "preserveCurrentPrice": True, "planType": "UPFRONT"})
        self.assertEqual(body["data"]["relationships"]["subscription"]["data"]["id"],
                         snapshot[MAX]["subscription_id"])
        fake.writes.clear()
        self.assertEqual(price_now.run(client, "restore-max", True, True,
                                       snapshot, io.StringIO()), 0)
        self.assertEqual(fake.writes, [])

    def test_immediate_apply_is_permanently_disabled(self):
        fake, client, snapshot = seeded_client()
        with self.assertRaisesRegex(price_now.PriceNowError, "immediate changes are disabled"):
            price_now.run(client, "apply", True, True, snapshot)
        self.assertEqual(fake.writes, [])

    def test_restore_requires_both_flags(self):
        fake, client, snapshot = seeded_client()
        remove_max_future(fake, client, snapshot)
        for live, preserve in ((False, False), (False, True), (True, False)):
            with self.subTest(live=live, preserve=preserve):
                with self.assertRaisesRegex(price_now.PriceNowError, "requires"):
                    price_now.run(client, "restore-max", live, preserve, snapshot)
        self.assertEqual(fake.writes, [])

    def test_drift_in_ultra_or_team_blocks_restoration(self):
        fake, client, snapshot = seeded_client()
        remove_max_future(fake, client, snapshot)
        team = snapshot["com.rendprop.app.team.monthly"]
        fake.store["subscriptionPrices"][team["future_price_id"]]["attributes"][
            "startDate"] = "2026-10-31"
        with self.assertRaisesRegex(price_now.PriceNowError, "phase changed"):
            price_now.run(client, "restore-max", True, True, snapshot)
        self.assertEqual(fake.writes, [])

    def test_approved_schedule_denial_stops_without_retry(self):
        fake, client, snapshot = seeded_client()
        remove_max_future(fake, client, snapshot)
        fake.fail_scheduled_post = True
        with self.assertRaises(asc.ApiError):
            price_now.run(client, "restore-max", True, True, snapshot)
        self.assertEqual(fake.writes, [("POST", "/v1/subscriptionPrices")])

    def test_accepted_post_without_readback_stops(self):
        fake, client, snapshot = seeded_client()
        remove_max_future(fake, client, snapshot)
        fake.accept_without_readback = True
        with self.assertRaisesRegex(price_now.PriceNowError, "not confirmed"):
            price_now.run(client, "restore-max", True, True, snapshot)
        self.assertEqual(fake.writes, [("POST", "/v1/subscriptionPrices")])


if __name__ == "__main__":
    unittest.main()
