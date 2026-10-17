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

    def test_unbound_multi_attempt_aggregate_stays_fully_held_and_is_reported_with_a_count(self):
        # Two admitted worker attempts behind one result (same job, provider and
        # model), one legacy ledger row with no binding: nothing is netted and
        # the ambiguity is reported explicitly, not inferred per attempt.
        f = fixture()
        f["ledger"][0].update(org_id="org1", billing_org_id="org1", provider="fal", model="fal-ai/flux-pro/kontext", total_cents="4", idempotency_key="legacy-uuid")
        f["ledger"][0]["meta"] = {"fallback": "flux_kontext"}
        f["serving"] = [hold(id="hold1", stage="worker:" + "a" * 48, state="uncertain", provider="fal", model="fal-ai/flux-pro/kontext", billing_org_id="org1", hold_cents="4"),
                        hold(id="hold2", stage="worker:" + "b" * 48, state="succeeded", provider="fal", model="fal-ai/flux-pro/kontext", billing_org_id="org1", hold_cents="4"),
                        hold(id="hold3", stage="worker:" + "c" * 48, state="uncertain", provider="fal", model="fal-ai/flux-pro/kontext", billing_org_id="org1", hold_cents="3", request_key="request2")]
        r = accounting_report(counted(f))
        self.assertEqual(r["totals"]["recorded_ledger_cents"], "4.0000")
        self.assertEqual(r["unledgered_hold_cents"], "11.0000", "the aggregate's holds and the lone attempt all stay fully held")
        aggregate = r["unbound_multi_attempt_aggregates"]
        self.assertEqual((aggregate["count"], aggregate["attempt_count"], aggregate["held_cents"]), (1, 2, "8.0000"))
        self.assertEqual(len(aggregate["groups"]), 1)
        self.assertEqual((aggregate["groups"][0]["attempts"], aggregate["groups"][0]["held_cents"], aggregate["groups"][0]["accounting"]), (2, "8.0000", "unbound multi-attempt aggregate"))
        self.assertEqual(aggregate["groups"][0]["states"], ["succeeded", "uncertain"])
        flagged = {h["id"]: h.get("accounting") for h in r["unledgered_holds"]}
        self.assertEqual(flagged, {"hold1": "unbound multi-attempt aggregate", "hold2": "unbound multi-attempt aggregate", "hold3": None})
        self.assertNotIn("request1", str(aggregate), "request keys are pseudonymised")
        # A single unbound attempt and a bound attempt are never an aggregate.
        self.assertEqual(accounting_report(linked())["unbound_multi_attempt_aggregates"], {"count": 0, "attempt_count": 0, "held_cents": "0.0000", "groups": []})


if __name__ == "__main__":
    unittest.main()
