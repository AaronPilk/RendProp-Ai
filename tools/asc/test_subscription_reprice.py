"""Offline transaction-level tests for future subscription pricing changes."""

import io
import sys
import unittest
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import asc  # noqa: E402
import subscription_reprice as reprice  # noqa: E402
from test_asc import Args, FakeAsc  # noqa: E402


TODAY = date(2026, 10, 27)
EFFECTIVE = "2026-10-31"
OLD_USD = {
    "com.rendprop.app.starter.monthly": "49.00",
    "com.rendprop.app.pro.monthly": "99.00",
    "com.rendprop.app.team.monthly": "249.00",
}


def seeded_client():
    fake = FakeAsc()
    client = asc.Client(None, transport=fake, verbose=False, out=io.StringIO())
    assert asc.cmd_subscriptions(client, Args(), io.StringIO()) == 0
    for product_id, amount in OLD_USD.items():
        fake.repoint_price(product_id, amount)
    fake.writes.clear()
    fake.bodies.clear()
    return fake, client


class SubscriptionRepriceTests(unittest.TestCase):
    def test_read_only_plan_has_exact_prices_and_no_writes(self):
        fake, client = seeded_client()
        out = io.StringIO()
        self.assertEqual(reprice.run(client, "plan", EFFECTIVE, out=out, today=TODAY), 0)
        self.assertEqual(fake.writes, [])
        self.assertIn("USD 49.00; target USD 49.99", out.getvalue())
        self.assertIn("USD 99.00; target USD 99.99", out.getvalue())
        self.assertIn("USD 249.00; target USD 249.99", out.getvalue())
        self.assertIn("3 new USA schedules", out.getvalue())

    def test_apply_preserves_current_subscribers_and_is_idempotent(self):
        fake, client = seeded_client()
        out = io.StringIO()
        self.assertEqual(reprice.run(client, "apply", EFFECTIVE,
                                     confirm_preserve=True, out=out, today=TODAY), 0)
        posts = [(path, body) for method, path, body in fake.bodies
                 if method == "POST" and path == "/v1/subscriptionPrices"]
        self.assertEqual(len(posts), 3)
        for _path, body in posts:
            attrs = body["data"]["attributes"]
            self.assertEqual(attrs, {"startDate": EFFECTIVE,
                                     "preserveCurrentPrice": True,
                                     "planType": "UPFRONT"})
            rel = body["data"]["relationships"]
            self.assertEqual(rel["territory"]["data"]["id"], "USA")
            point_id = rel["subscriptionPricePoint"]["data"]["id"]
            self.assertEqual(asc.price_point_territory({"id": point_id}), "USA")
            product = next(row for row in fake.store["subscriptions"].values()
                           if row["id"] == rel["subscription"]["data"]["id"])
            spec = next(s for s in asc.SUBSCRIPTIONS
                        if s["productId"] == product["attributes"]["productId"])
            self.assertEqual(fake.point_amounts[point_id], spec["usd"])

        fake.writes.clear()
        rerun = io.StringIO()
        self.assertEqual(reprice.run(client, "apply", EFFECTIVE,
                                     confirm_preserve=True, out=rerun, today=TODAY), 0)
        self.assertEqual(fake.writes, [])
        self.assertIn("does not prove whether", rerun.getvalue())
        self.assertIn("No new USA price schedules", rerun.getvalue())

    def test_apply_requires_explicit_subscriber_preservation(self):
        fake, client = seeded_client()
        with self.assertRaisesRegex(reprice.RepriceError, "requires"):
            reprice.run(client, "apply", EFFECTIVE, today=TODAY)
        self.assertEqual(fake.writes, [])

    def test_lead_time_and_date_validation_fail_before_writes(self):
        for candidate in ("2026-10-27", "2026-10-28", "2026-10-29",
                          "2026-02-30", "10/31/2026"):
            with self.subTest(candidate=candidate):
                fake, client = seeded_client()
                with self.assertRaises(reprice.RepriceError):
                    reprice.run(client, "apply", candidate,
                                confirm_preserve=True, today=TODAY)
                self.assertEqual(fake.writes, [])

    def test_existing_future_change_is_never_overwritten(self):
        fake, client = seeded_client()
        # The last target has a conflicting schedule. The planner must inspect
        # all products and refuse before it writes even to the first target.
        decisions = reprice.plan_changes(client, EFFECTIVE, today=TODAY)
        team_row = decisions[-1]
        body = reprice.price_create_body(team_row)
        body["data"]["attributes"]["startDate"] = "2026-11-01"
        client.post("/v1/subscriptionPrices", body)
        fake.writes.clear()
        with self.assertRaisesRegex(reprice.RepriceError, "refusing to overwrite"):
            reprice.run(client, "apply", EFFECTIVE,
                        confirm_preserve=True, today=TODAY)
        self.assertEqual(fake.writes, [])

    def test_exact_scheduled_date_can_be_rerun_inside_new_schedule_lead_time(self):
        fake, client = seeded_client()
        reprice.run(client, "apply", EFFECTIVE,
                    confirm_preserve=True, out=io.StringIO(), today=TODAY)
        fake.writes.clear()
        self.assertEqual(reprice.run(client, "apply", EFFECTIVE,
                                     confirm_preserve=True, out=io.StringIO(),
                                     today=date(2026, 10, 30)), 0)
        self.assertEqual(fake.writes, [])

    def test_preserved_old_cohort_does_not_hide_an_exact_future_schedule(self):
        fake, client = seeded_client()
        reprice.run(client, "apply", EFFECTIVE,
                    confirm_preserve=True, out=io.StringIO(), today=TODAY)
        for row in fake.store["subscriptionPrices"].values():
            if row["_parents"].get("territory") == "USA" and \
                    not row["attributes"].get("startDate"):
                row["attributes"]["preserved"] = True
        fake.writes.clear()
        out = io.StringIO()
        self.assertEqual(reprice.run(client, "apply", EFFECTIVE,
                                     confirm_preserve=True, out=out, today=TODAY), 0)
        self.assertIn("current USA unverified", out.getvalue())
        self.assertEqual(fake.writes, [])

    def test_missing_exact_price_point_blocks_all_writes(self):
        fake, client = seeded_client()
        # Only the last target lacks its exact .99 point.
        fake.price_ladder = ["29.99", "49.99", "99.99", "249.00"]
        with self.assertRaisesRegex(reprice.RepriceError, "0 provably exact"):
            reprice.run(client, "apply", EFFECTIVE,
                        confirm_preserve=True, today=TODAY)
        self.assertEqual(fake.writes, [])

    def test_missing_subscription_blocks_all_writes(self):
        fake, client = seeded_client()
        for row_id, row in list(fake.store["subscriptions"].items()):
            if row["attributes"].get("productId") == "com.rendprop.app.team.monthly":
                del fake.store["subscriptions"][row_id]
        with self.assertRaisesRegex(reprice.RepriceError, "is missing"):
            reprice.run(client, "apply", EFFECTIVE,
                        confirm_preserve=True, today=TODAY)
        self.assertEqual(fake.writes, [])

    def test_current_exact_price_does_not_need_a_write(self):
        fake, client = seeded_client()
        fake.repoint_price("com.rendprop.app.starter.monthly", "49.99")
        fake.writes.clear()
        out = io.StringIO()
        reprice.run(client, "plan", EFFECTIVE, out=out, today=TODAY)
        self.assertIn("already-current", out.getvalue())
        self.assertIn("2 new USA schedules", out.getvalue())
        self.assertEqual(fake.writes, [])


if __name__ == "__main__":
    unittest.main()
