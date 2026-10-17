"""Actual private-report residual projection; no network or financial writes."""
import copy
import unittest
from test_api_cost_report import fixture, counted, hold
from api_cost_report import accounting_report


def linked(bound="20", modeled="4"):
    f = fixture()
    r = f["ledger"][0]
    r.update(total_cents=modeled, billing_org_id="org1", idempotency_key="pipeline:hold1")
    r["meta"].update(pipeline_cost_protocol="pipeline-cost-v1", pipeline_reservation_id="hold1",
                     actor_id="actor1", input_sha256="a" * 64)
    f["serving"] = [hold(hold_cents=bound, state="uncertain", billing_org_id="org1", input_sha256="a" * 64)]
    return counted(f)


class PipelineResidualTests(unittest.TestCase):
    def test_unknown_bound_is_not_replaced_by_smaller_modeled_price(self):
        r = accounting_report(linked())
        self.assertEqual(r["totals"]["recorded_ledger_cents"], "4.0000")
        self.assertEqual(r["unledgered_hold_cents"], "16.0000")
        residual = r["unledgered_holds"][0]
        self.assertEqual(residual["admitted_bound_cents"], "20.0000")
        self.assertEqual(residual["linked_modeled_cents"], "4.0000")
        self.assertEqual(residual["state"], "uncertain")
        self.assertIs(residual["invoice_verified"], False)

    def test_equal_or_larger_recorded_cost_is_counted_once(self):
        for bound, modeled in (("4", "4"), ("2", "4")):
            with self.subTest(bound=bound):
                r = accounting_report(linked(bound, modeled))
                self.assertEqual(r["totals"]["recorded_ledger_cents"], "4.0000")
                self.assertEqual(r["unledgered_hold_cents"], "0.0000")

    def test_foreign_actor_input_payer_or_attempt_never_net(self):
        for key in ("actor_id", "input_sha256", "request_key", "stage", "pipeline_reservation_id"):
            f = linked(); f["ledger"][0]["meta"][key] = "foreign"
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "pipeline"):
                accounting_report(f)
        for key in ("billing_org_id", "provider", "model", "idempotency_key"):
            f = linked(); f["ledger"][0][key] = "foreign"
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "pipeline"):
                accounting_report(f)

    def test_legacy_and_missing_receipt_keep_their_original_conservative_scope(self):
        f = linked(); f["ledger"] = []; r = accounting_report(counted(f))
        self.assertEqual(r["unledgered_hold_cents"], "20.0000")
        legacy = fixture(); legacy["serving"] = [hold()]
        self.assertEqual(accounting_report(counted(legacy))["unledgered_hold_cents"], "0.0000")

    def test_prospective_missing_snapshot_identity_cannot_discount(self):
        f = linked(); del f["serving"][0]["input_sha256"]
        with self.assertRaisesRegex(ValueError, "pipeline"):
            accounting_report(f)


if __name__ == "__main__":
    unittest.main()
