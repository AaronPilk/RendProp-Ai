#!/usr/bin/env python3
"""Closed money/privacy/identity controls; no provider or database access."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
import io
from unittest.mock import patch

from api_cost_report import accounting_report, private_write, csv_cell, collect, TABLES


def fixture():
    result = {"schema": 1, "currency": "USD", "exported_at": "2026-10-15T00:00:00Z", "max_rows_per_table": 100, "authority": {"bypass_rls": True}}
    for name in TABLES:
        result[name] = []
    result["ledger"] = [{"id": "line1", "org_id": "org1", "billing_org_id": "team1", "job_id": None, "feature": "photo_edit", "provider": "gemini", "model": "image", "units": "1", "unit_cost_cents": ".1", "total_cents": ".1000", "meta": {"request_key": "request1", "stage": "photo.stage:0", "cost_basis": "complete_image_bound", "prompt": "CUSTOMER_SECRET", "request_id": "https://signed.private/secret"}}]
    return counted(result)


def counted(value):
    value["counts"] = {name: len(value[name]) for name in TABLES}
    return value


def hold(**overrides):
    return {"id": "hold1", "org_id": "org1", "actor_id": "actor1", "request_key": "request1", "stage": "photo.stage:0", "provider": "gemini", "model": "image", "hold_cents": "2.5000", "state": "succeeded", "tariff_version": "photo-price-20261015", **overrides}


class AccountingTests(unittest.TestCase):
    def test_fractional_cents_and_no_invoice_claim(self):
        f = fixture()
        f["ledger"].append({**copy.deepcopy(f["ledger"][0]), "id": "line2", "total_cents": ".2000"})
        r = accounting_report(counted(f))
        self.assertEqual(r["totals"]["recorded_ledger_cents"], "0.3000")
        self.assertTrue(all(not x["invoice_verified"] for x in r["ledger"]))

    def test_same_row_idempotent_but_distinct_real_rows_not_dropped(self):
        f = fixture(); f["ledger"] *= 2
        self.assertEqual(accounting_report(counted(f))["totals"]["recorded_ledger_cents"], "0.1000")
        f["ledger"][1] = {**f["ledger"][1], "total_cents": "9"}
        with self.assertRaisesRegex(ValueError, "Conflicting"):
            accounting_report(counted(f))

    def test_missing_direct_link_uses_exact_five_field_match(self):
        f = fixture(); f["serving"] = [hold()]
        r = accounting_report(counted(f))
        self.assertEqual(r["unledgered_hold_cents"], "0.0000")
        self.assertEqual(r["ledger"][0]["tariff_versions"], ["photo-price-20261015"])
        for key in ("org_id", "request_key", "stage", "provider", "model"):
            bad = copy.deepcopy(f); bad["serving"][0][key] = "different"
            self.assertEqual(accounting_report(counted(bad))["unledgered_hold_cents"], "2.5000")

    def test_uncertain_hold_is_not_recorded_spend_or_automatically_freed(self):
        f = fixture(); f["serving"] = [hold(request_key="unknown", state="uncertain")]
        r = accounting_report(counted(f))
        self.assertEqual(r["unledgered_hold_cents"], "2.5000")
        self.assertEqual(r["totals"]["recorded_ledger_cents"], "0.1000")

    def test_rejected_and_released_are_not_unknown_liability(self):
        f = fixture(); f["serving"] = [hold(state="rejected", request_key="unknown")]
        f["video"] = [{"id": "video", "released_at": "2026-10-15T00:00:00Z"}]
        self.assertEqual(accounting_report(counted(f))["unledgered_hold_cents"], "0.0000")

    def test_same_supplier_hold_in_two_journals_counted_once(self):
        f = fixture(); f["serving"] = [hold(request_key="video-key", stage="reel", provider="fal", model="kling")]
        f["video"] = [{"id": "video", "org_id": "org1", "actor_id": "actor1", "idempotency_key": "video-key", "feature": "reel", "provider": "fal", "model": "kling", "hold_cents": "2.5"}]
        r = accounting_report(counted(f))
        self.assertEqual(r["unledgered_hold_cents"], "2.5000")
        self.assertEqual(len(r["cross_journal_overlaps_not_added_twice"]), 1)

    def test_funding_and_invoices_never_added_to_consumption(self):
        events = [{"id": "top-up", "kind": "provider_credit_funding", "currency": "USD", "amount_cents": "2500"}, {"id": "invoice", "kind": "supplier_usage_invoice", "currency": "USD", "amount_cents": "100", "evidence": "supplier_invoice", "supplier_invoice_id": "inv-1"}]
        r = accounting_report(fixture(), events + events)
        self.assertEqual(r["provider_credit_funding_cents"], "2500.0000")
        self.assertEqual(r["totals"]["recorded_ledger_cents"], "0.1000")
        self.assertEqual(len(r["external_events_separate_from_consumption"]), 2)
        self.assertEqual(r["external_supplier_usage_invoice_cents_not_added"], "100.0000")

    def test_higher_overlapping_hold_keeps_excess(self):
        f = fixture(); f["serving"] = [hold(request_key="video-key", stage="reel", provider="fal", model="kling")]
        f["video"] = [{"id": "video", "org_id": "org1", "actor_id": "actor1", "idempotency_key": "video-key", "feature": "reel", "provider": "fal", "model": "kling", "hold_cents": "4"}]
        self.assertEqual(accounting_report(counted(f))["unledgered_hold_cents"], "4.0000")

    def test_foreign_ledger_link_and_conflicting_spool_refuse(self):
        f = fixture(); f["serving"] = [hold(ledger_id="line1", org_id="foreign")]
        with self.assertRaisesRegex(ValueError, "Foreign"): accounting_report(counted(f))
        f = fixture(); f["ledger"][0]["idempotency_key"] = "saved"
        with self.assertRaisesRegex(ValueError, "Spool conflicts"):
            accounting_report(f, spool=[{"idempotency_key": "saved", "total_cents": "9"}])
        with self.assertRaisesRegex(ValueError, "Spool conflicts"):
            accounting_report(f, spool=[{"idempotency_key": "saved", "total_cents": ".1", "provider": "foreign"}])

    def test_unproven_invoice_and_csv_formula_refuse_or_escape(self):
        with self.assertRaisesRegex(ValueError, "evidence"):
            accounting_report(fixture(), [{"id": "invoice", "kind": "supplier_usage_invoice", "currency": "USD", "amount_cents": "1"}])
        for s in ("=SUM(1,2)", "+99", "@external", "-formula", "\tformula"):
            self.assertEqual(csv_cell(s), "'" + s)
        self.assertEqual(csv_cell("fal"), "fal")

    def test_failed_retry_still_costs_and_duplicate_supplier_is_flag_not_discount(self):
        f = fixture(); x = f["ledger"][0]; x["meta"].update(request_id="supplier1", stage="photo.retry:0", failed=True)
        f["ledger"].append({**copy.deepcopy(x), "id": "line2"})
        r = accounting_report(counted(f))
        self.assertEqual(r["totals"]["recorded_in_failed_or_refused_context_cents"], "0.2000")
        self.assertEqual(r["totals"]["recorded_ledger_cents"], "0.2000")
        self.assertTrue(r["ledger"][0]["retry"])
        self.assertEqual(len(r["possible_duplicate_supplier_ids"]), 1)

    def test_spool_replay_does_not_duplicate_persisted_charge(self):
        f = fixture(); f["ledger"][0]["idempotency_key"] = "already-saved"
        spool = [{"row": {"idempotency_key": "already-saved", "total_cents": ".1"}}, {"row": {"idempotency_key": "pending", "total_cents": "2.3"}}]
        r = accounting_report(f, spool=spool + spool)
        self.assertEqual(len(r["pending_spool_not_added_to_ledger"]), 1)
        self.assertEqual(r["totals"]["recorded_ledger_cents"], "0.1000")

    def test_scoped_totals_and_private_text_not_exposed(self):
        f = fixture(); f["photo_scope"] = [{"org_id": "org1", "request_key": "request1", "listing_id": "listing-secret", "check_id": "check1"}]
        r = accounting_report(counted(f)); text = json.dumps(r)
        self.assertNotIn("CUSTOMER_SECRET", text); self.assertNotIn("signed.private", text)
        self.assertNotIn("listing-secret", text); self.assertNotIn('"org1"', text)
        self.assertNotEqual(r["ledger"][0]["listing"], "unknown")
        self.assertEqual(r["ledger"][0]["supplier_request_ids"], [])

    def test_deleted_ledger_receipt_retained_separately_not_double_added(self):
        f = fixture(); f["video"] = [{"id": "v", "cost_ledger_id": "deleted", "provider_request_id": "supplier", "total_cents": "210"}]
        r = accounting_report(counted(f))
        self.assertEqual(len(r["settled_receipts_without_retained_ledger"]), 1)
        self.assertEqual(r["totals"]["recorded_ledger_cents"], "0.1000")

    def test_partial_nonfinite_negative_and_foreign_currency_refused(self):
        for value in ("NaN", "Infinity", "-1", None):
            f = fixture(); f["ledger"][0]["total_cents"] = value
            with self.assertRaises(ValueError): accounting_report(f)
        f = fixture(); f["counts"]["ledger"] = 2
        with self.assertRaisesRegex(ValueError, "Incomplete"): accounting_report(f)
        f = fixture(); f["currency"] = "EUR"
        with self.assertRaises(ValueError): accounting_report(f)
        f = fixture(); f["authority"]["bypass_rls"] = False
        with self.assertRaisesRegex(ValueError, "all-account"): accounting_report(f)

    def test_private_export_no_overwrite(self):
        with tempfile.TemporaryDirectory() as root:
            p = Path(root) / "receipt"; private_write(p, "private")
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError): private_write(p, "replacement")

    def test_separate_presenter_erase_spatial_records_do_not_inflate_ledger(self):
        f = fixture(); f["other_journals"] = [{"kind": "presenter", "id": "p1", "org_id": "org1", "listing_id": "l1", "state": "done", "priced_cents": "100", "held_cents": "0", "charged_cents": "95", "has_billing_reference": True}]
        f["spatial"] = [{"id": "s1", "status": "failed", "cost_cents": "2500"}]
        r = accounting_report(counted(f))
        self.assertEqual(r["totals"]["recorded_ledger_cents"], "0.1000")
        self.assertEqual(r["other_accounting_journals_not_added_to_ledger"][0]["charged_cents"], "95.0000")
        self.assertEqual(r["spatial_cost_rollups_not_added_to_ledger"][0]["reported_cents"], "2500.0000")

    def test_collector_read_only_exact_target_no_provider_no_secret_output(self):
        calls = []
        def opener(req, timeout):
            calls.append(req)
            self.assertEqual(req.full_url, "https://api.supabase.com/v1/projects/abcdefghijklmnopqrst/database/query/read-only")
            self.assertEqual(req.method, "POST"); self.assertEqual(timeout, 60)
            self.assertEqual(set(json.loads(req.data)), {"query"})
            self.assertEqual(req.headers["Authorization"], "Bearer fixture-management")
            return io.BytesIO(json.dumps([{"snapshot": fixture()}]).encode())
        with patch.dict("os.environ", {"COST_TEST_TOKEN": "fixture-management"}):
            self.assertEqual(collect("abcdefghijklmnopqrst", "COST_TEST_TOKEN", opener)["schema"], 1)
            def fail(req, timeout): raise RuntimeError("credential fixture-management must not escape")
            with self.assertRaisesRegex(ValueError, "no retry") as error:
                collect("abcdefghijklmnopqrst", "COST_TEST_TOKEN", fail)
            self.assertNotIn("fixture-management", str(error.exception))
        self.assertEqual(len(calls), 1)


if __name__ == "__main__":
    unittest.main()
