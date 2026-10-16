#!/usr/bin/env python3
"""Closed controls for the schema-2 provider attempt journal, uncertain-dispatch
ledger context and duplicate attempt identities. No provider or database access.

Run against the pre-fix report these fail on the first schema-2 fixture
("Unsupported accounting snapshot"); that refusal is the old defect — an
unresolved or lost RentCast dispatch was invisible to the owner report."""
import copy
import json
import unittest

from api_cost_report import accounting_report, SCHEMA_TABLES


def counted(value):
    value["counts"] = {name: len(value[name]) for name in SCHEMA_TABLES[value["schema"]]}
    return value


def fixture(schema=2):
    result = {"schema": schema, "currency": "USD", "exported_at": "2026-10-16T00:00:00Z", "max_rows_per_table": 100, "authority": {"bypass_rls": True}}
    for name in SCHEMA_TABLES[schema]:
        result[name] = []
    return counted(result)


def attempt(**overrides):
    base = {"id": "attempt1", "actor_id": "actor1", "org_id": "org1", "billing_org_id": "team1", "provider": "rentcast", "stage": "property.lookup",
            "model": "properties", "outcome": "intent", "http_status": None, "provider_request_id": None, "estimated_cents": None,
            "price_basis": "unknown", "ledger_status": "not_booked", "actual_cents": None, "created_at": "2026-10-16T00:00:00Z", "terminal_at": None}
    return {**base, **overrides}


def ledger(**overrides):
    base = {"id": "line1", "org_id": "org1", "billing_org_id": "team1", "job_id": None, "feature": "property_lookup", "provider": "rentcast", "model": "properties",
            "units": "1", "unit_cost_cents": "7", "total_cents": "7.0000", "meta": {"cost_basis": "configured_per_call_estimate", "result": "hit", "provider_attempt_id": "attempt-hit"}}
    return {**base, **overrides}


class ProviderAttemptJournalTests(unittest.TestCase):
    def test_unknown_outcomes_are_listed_without_an_amount_and_never_zero(self):
        f = fixture()
        f["provider_attempts"] = [attempt(id="a-intent"), attempt(id="a-lost", outcome="transport_unknown", terminal_at="2026-10-16T00:00:12Z")]
        r = accounting_report(counted(f))
        journal = r["provider_attempt_journal"]
        self.assertTrue(journal["exported"])
        self.assertEqual(journal["by_outcome"]["intent"], 1)
        self.assertEqual(journal["by_outcome"]["transport_unknown"], 1)
        self.assertEqual(len(journal["unknown_outcome_attempts"]), 2)
        self.assertTrue(all(x["estimated_cents"] is None and x["amount"] == "unknown" for x in journal["unknown_outcome_attempts"]))
        self.assertIsNone(journal["unknown_outcome_cents"])
        self.assertNotIn("recorded_ledger_cents", r["totals"], "no ledger row means no recorded consumption, and no invented one")
        text = json.dumps(r)
        self.assertNotIn("actor1", text)
        self.assertNotIn('"unknown_outcome_cents": 0', text)

    def test_priced_attempt_without_retained_ledger_row_is_a_reconciliation_item(self):
        f = fixture()
        f["provider_attempts"] = [
            attempt(id="attempt-hit", outcome="hit", http_status=200, estimated_cents="7.0000", price_basis="configured_catalog_estimate_not_invoice", ledger_status="recorded", terminal_at="2026-10-16T00:00:01Z", provider_request_id="0f1e2d3c-4b5a-4968-8776-655443322110"),
            attempt(id="attempt-miss", outcome="no_record", http_status=404, estimated_cents="7.0000", price_basis="configured_catalog_estimate_not_invoice", ledger_status="unconfirmed", terminal_at="2026-10-16T00:00:02Z"),
        ]
        f["ledger"] = [ledger()]
        r = accounting_report(counted(f))
        journal = r["provider_attempt_journal"]
        self.assertEqual(journal["priced_attempt_estimate_cents_not_added_to_ledger_total"], "14.0000")
        self.assertEqual(r["totals"]["recorded_ledger_cents"], "7.0000", "the estimate is never added to consumption")
        missing = journal["priced_attempts_without_retained_ledger_row"]
        self.assertEqual([m["outcome"] for m in missing], ["no_record"])
        self.assertEqual(journal["priced_attempts_without_retained_ledger_cents"], "7.0000")
        retained = next(p for p in journal["priced_attempts"] if p["outcome"] == "hit")
        self.assertEqual(retained["retained_ledger_ids"], ["line1"])
        self.assertEqual(retained["supplier_request_id"], "0f1e2d3c-4b5a-4968-8776-655443322110")
        self.assertFalse(retained["invoice_verified"])
        self.assertEqual(r["ledger"][0]["cost_basis"], "catalog_estimate")

    def test_refused_attempts_carry_no_charge_and_malformed_journals_refuse(self):
        f = fixture()
        f["provider_attempts"] = [attempt(id="a-err", outcome="http_error", http_status=500, terminal_at="2026-10-16T00:00:03Z")]
        r = accounting_report(counted(f))
        self.assertEqual(len(r["provider_attempt_journal"]["refused_or_invalid_attempts"]), 1)
        self.assertIsNone(r["provider_attempt_journal"]["refused_or_invalid_attempts"][0]["estimated_cents"])
        for bad, message in [
            (attempt(id="x", outcome="transport_unknown", estimated_cents="7", terminal_at="t"), "cannot carry an estimate"),
            (attempt(id="x", outcome="hit", http_status=200, estimated_cents="7", price_basis="unknown", ledger_status="recorded", terminal_at="t"), "configured estimate"),
            (attempt(id="x", outcome="hit", http_status=200, estimated_cents="7", price_basis="configured_catalog_estimate_not_invoice", ledger_status="recorded", terminal_at="t", actual_cents="7"), "actual invoice"),
            (attempt(id="x", outcome="settled"), "Unknown provider attempt outcome"),
        ]:
            g = fixture(); g["provider_attempts"] = [bad]
            with self.assertRaisesRegex(ValueError, message):
                accounting_report(counted(g))

    def test_schema_one_snapshot_reports_journal_as_not_exported_not_zero(self):
        f = fixture(schema=1)
        r = accounting_report(f)
        self.assertFalse(r["provider_attempt_journal"]["exported"])
        self.assertNotIn("by_outcome", r["provider_attempt_journal"])
        g = fixture(schema=2); del g["provider_attempts"]
        with self.assertRaisesRegex(ValueError, "Incomplete/bounded snapshot: provider_attempts"):
            accounting_report(g)


class UncertainDispatchTests(unittest.TestCase):
    def studio_row(self, **overrides):
        return ledger(id="studio1", feature="copy_assist", provider="openai", model="gpt-5.6-mini", total_cents="0.4100", units="1", unit_cost_cents="0.41",
                      meta={"kind": "edit_plan", "attempts": 1, "outcome": "uncertain", "price_estimated": True, "request_key": "req-1", "stage": "studio.edit_plan"}, **overrides)

    def test_uncertain_row_without_any_hold_is_disclosed_but_still_counted(self):
        f = fixture(); f["ledger"] = [self.studio_row()]
        r = accounting_report(counted(f)); line = r["ledger"][0]
        self.assertTrue(line["uncertain_dispatch_context"])
        self.assertTrue(line["recorded_without_matching_attempt_hold"])
        self.assertEqual(r["totals"]["recorded_ledger_cents"], "0.4100", "never discounted automatically")
        self.assertEqual(r["totals"]["recorded_in_uncertain_dispatch_context_cents"], "0.4100")
        self.assertEqual(r["totals"]["recorded_without_matching_attempt_hold_cents"], "0.4100")

    def test_uncertain_row_with_its_hold_is_disclosed_but_not_flagged_as_never_sent(self):
        f = fixture(); f["ledger"] = [self.studio_row()]
        f["serving"] = [{"id": "hold1", "org_id": "org1", "actor_id": "actor1", "request_key": "req-1", "stage": "studio.edit_plan", "provider": "openai", "model": "gpt-5.6-mini", "hold_cents": "0.4100", "state": "uncertain", "tariff_version": "copy-20261010", "ledger_id": None}]
        r = accounting_report(counted(f)); line = r["ledger"][0]
        self.assertTrue(line["uncertain_dispatch_context"])
        self.assertFalse(line["recorded_without_matching_attempt_hold"])
        self.assertNotIn("recorded_without_matching_attempt_hold_cents", r["totals"])
        # The uncertain hold reconciles to its row by exact attempt identity: not a second liability.
        self.assertEqual(r["unledgered_holds"], [])

    def test_returned_row_is_not_uncertain(self):
        f = fixture(); row = self.studio_row(); row["meta"]["outcome"] = "returned"; f["ledger"] = [row]
        line = accounting_report(counted(f))["ledger"][0]
        self.assertFalse(line["uncertain_dispatch_context"])
        self.assertFalse(line["recorded_without_matching_attempt_hold"])


class DuplicateAttemptTests(unittest.TestCase):
    def test_two_rows_with_one_attempt_identity_are_flagged_never_netted(self):
        f = fixture()
        row = ledger(id="dup1", feature="photo_helper", provider="gemini", model="gemini-3.6-flash", total_cents="0.2000", unit_cost_cents="0.2", meta={"request_key": "req-7", "stage": "photo.suggest"})
        f["ledger"] = [row, {**copy.deepcopy(row), "id": "dup2"}]
        r = accounting_report(counted(f))
        self.assertEqual(r["totals"]["recorded_ledger_cents"], "0.4000")
        self.assertEqual(len(r["possible_duplicate_attempt_rows"]), 1)
        self.assertEqual(sorted(r["possible_duplicate_attempt_rows"][0]["ledger_ids"]), ["dup1", "dup2"])
        self.assertEqual(r["possible_duplicate_attempt_rows"][0]["stage"], "photo.suggest")
        self.assertNotIn("req-7", json.dumps(r), "request keys are pseudonymised")

    def test_distinct_stages_or_requests_are_not_duplicates(self):
        f = fixture()
        a = ledger(id="r1", feature="copy_assist", provider="gemini", model="m", meta={"request_key": "req-1", "stage": "copy:initial:0"})
        b = {**copy.deepcopy(a), "id": "r2", "meta": {"request_key": "req-1", "stage": "copy:retry:0"}}
        c = {**copy.deepcopy(a), "id": "r3", "meta": {"request_key": "req-2", "stage": "copy:initial:0"}}
        f["ledger"] = [a, b, c]
        self.assertEqual(accounting_report(counted(f))["possible_duplicate_attempt_rows"], [])


if __name__ == "__main__":
    unittest.main()
