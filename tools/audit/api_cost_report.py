#!/usr/bin/env python3
"""Private owner accounting report; no provider calls, writes or price inference.

Run with --snapshot FILE, or explicitly --collect-project for Supabase's
read-only Management API export. Customer prose and media capabilities are never
copied to reports. Money stays Decimal cents. A ledger is not a supplier invoice.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.request
from collections import defaultdict
from decimal import Decimal, InvalidOperation

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
TABLES = ("ledger", "serving", "video", "photo_scope", "video_scope", "spatial", "other_journals")
ZERO = Decimal("0")


def unpriced_usage(value):
    """Closed nonnegative counters only; no tariffs or dollar conversion."""
    keys = {"metering_watch_ms", "media_delivery_requests", "media_delivery_bytes",
            "owner_testing_media_requests", "owner_testing_media_bytes",
            "product_media_serving_requests", "product_media_serving_bytes"}
    if not isinstance(value, dict) or set(value) - keys:
        raise ValueError("Unknown unpriced usage fields")
    result = {}
    for key, count in value.items():
        if isinstance(count, bool) or not re.fullmatch(r"[0-9]{1,40}", str(count)):
            raise ValueError("Invalid unpriced usage counter")
        result[key] = str(int(count))
    return result


def money(value):
    try:
        number = Decimal(str(value))
    except InvalidOperation as exc:
        raise ValueError("Invalid recorded money") from exc
    if not number.is_finite() or number < ZERO:
        raise ValueError("Invalid recorded money")
    return number


def cents(value):
    return format(value.quantize(Decimal(".0001")), "f")


def token(value, limit=240):
    """Closed accounting vocabulary only; URLs/prose/JWTs cannot escape."""
    return value if isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_:/@+.-]{1," + str(limit) + "}", value) and "://" not in value else None


def request_id(value):
    # A signed app job token is a capability, not a supplier request identifier.
    return value if isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,128}", value) else None


def csv_cell(value):
    # CSV is an export, not permission to execute a spreadsheet formula.
    return "'" + value if isinstance(value, str) and value[:1] in ("=", "+", "-", "@", "\t", "\r") else value


def scope(value):
    return "unknown" if not value else "scope-" + hashlib.sha256(str(value).encode()).hexdigest()[:20]


def basis(row):
    meta = row.get("meta") or {}
    label = str(meta.get("cost_basis") or "")
    if row.get("feature") in ("render", "stream_store", "stream_deliver"):
        return "infrastructure_estimate"
    if "bound" in label:
        return "published_bound"
    if "token" in label or meta.get("provider_usage") or "input_tokens" in meta:
        return "usage_priced_estimate"
    if meta.get("price_estimated") is True or "estimate" in label:
        return "catalog_estimate"
    return "unclassified_recorded_cost"


def unique(rows):
    """Repeated identical exported rows are harmless; conflicting IDs refuse."""
    found = {}
    for row in rows:
        if not row.get("id"):
            raise ValueError("Accounting row is missing its immutable ID")
        key = row["id"]
        if key in found and found[key] != row:
            raise ValueError("Conflicting immutable accounting ID")
        found[key] = row
    return list(found.values())


def accounting_report(snapshot, events=(), spool=()):
    if snapshot.get("schema") != 1 or snapshot.get("currency") != "USD":
        raise ValueError("Unsupported accounting snapshot/currency")
    if snapshot.get("authority", {}).get("bypass_rls") is not True:
        raise ValueError("Owner accounting export requires verified all-account read authority")
    for name in TABLES:
        rows = snapshot.get(name)
        if not isinstance(rows, list) or len(rows) != snapshot.get("counts", {}).get(name) or len(rows) > snapshot.get("max_rows_per_table", 0):
            raise ValueError("Incomplete/bounded snapshot: " + name)
    ledger = unique(snapshot["ledger"])
    serving, videos = unique(snapshot["serving"]), unique(snapshot["video"])
    ids = {r["id"] for r in ledger}
    idempotency = {r["idempotency_key"] for r in ledger if r.get("idempotency_key")}
    aliases, checks = {}, {}
    for row in snapshot["photo_scope"]:
        aliases[(row["org_id"], row["request_key"])] = row
        if row.get("check_id"):
            checks[row["check_id"]] = row
    for row in snapshot["video_scope"]:
        aliases[(row["org_id"], row["request_key"])] = row
    by_receipt = {r["id"]: r for r in videos}
    by_ledger = defaultdict(list)
    for row in videos:
        if row.get("cost_ledger_id"):
            by_ledger[row["cost_ledger_id"]].append(row)
    matches = defaultdict(list)
    for row in ledger:
        meta = row.get("meta") or {}
        if meta.get("request_key") and meta.get("stage"):
            matches[(row.get("org_id"), meta["request_key"], meta["stage"], row.get("provider"), row.get("model"))].append(row)
    hold_links = {}
    for hold in serving:
        candidates = [r for r in ledger if r["id"] == hold.get("ledger_id")]
        if candidates and any(r.get("org_id") != hold.get("org_id") or r.get("provider") != hold.get("provider") or r.get("model") != hold.get("model") for r in candidates):
            raise ValueError("Foreign immutable ledger link")
        if not candidates:
            candidates = matches.get((hold.get("org_id"), hold.get("request_key"), hold.get("stage"), hold.get("provider"), hold.get("model")), [])
        if len(candidates) == 1:
            hold_links[hold["id"]] = candidates[0]
    linked_tariffs = defaultdict(set)
    for hold in serving:
        if hold["id"] in hold_links:
            linked_tariffs[hold_links[hold["id"]]["id"]].add(token(hold.get("tariff_version")) or "unknown")

    lines, totals, group = [], defaultdict(lambda: ZERO), defaultdict(lambda: ZERO)
    provider_groups = defaultdict(list)
    for row in ledger:
        meta = row.get("meta") or {}
        related = aliases.get((row.get("org_id"), meta.get("request_key")), {})
        related = checks.get(meta.get("photo_check_id"), related)
        payments = by_ledger.get(row["id"], [])
        if meta.get("app_video_reservation_id") in by_receipt:
            payments = [by_receipt[meta["app_video_reservation_id"]]]
        supplier_ids = sorted({v for v in [request_id(meta.get("request_id")), request_id(meta.get("provider_request_id")), *[request_id(p.get("provider_request_id")) for p in payments]] if v})
        amount = money(row["total_cents"])
        kind = basis(row)
        listing = row.get("listing_id") or related.get("listing_id")
        job = row.get("job_id") or related.get("job_id")
        failed = row.get("job_state") == "failed" or related.get("job_state") == "failed" or meta.get("failed") is True or meta.get("outcome") in ("failed", "refused") or meta.get("verdict") in ("fail", "regen")
        stage = token(meta.get("stage"))
        line = {"ledger_id": row["id"], "created_at": row.get("created_at"),
                "account": scope(row.get("billing_org_id") or row.get("org_id")), "library": scope(row.get("org_id")),
                "listing": scope(listing), "job": scope(job), "feature": token(row.get("feature")),
                "provider": token(row.get("provider")), "model": token(row.get("model")),
                "units": str(money(row.get("units", "0"))), "unit_cost_cents": str(money(row.get("unit_cost_cents", "0"))),
                "recorded_cents": cents(amount), "cost_basis": kind, "supplier_request_ids": supplier_ids,
                "stage": stage, "retry": "retry" in (stage or "") or meta.get("attempt") == "retry",
                "failed_or_refused_context": failed,
                "tariff_versions": sorted(linked_tariffs[row["id"]] | {v for v in [token(meta.get("tariff")), token(meta.get("price_version"))] if v}),
                "price_recorded_at": row.get("created_at"), "price_effective_date": None, "invoice_verified": False}
        usage = meta.get("provider_usage")
        usage_items = dict(usage) if isinstance(usage, dict) else {}
        usage_items.update({k: meta[k] for k in ("input_tokens", "output_tokens") if k in meta})
        line["provider_usage"] = {k: str(v) for k, v in usage_items.items() if k in ("inputTokens", "outputTokens", "input_tokens", "output_tokens", "cacheReadInputTokens", "cacheCreationInputTokens") and isinstance(v, (int, float)) and not isinstance(v, bool) and money(v) >= ZERO}
        lines.append(line)
        totals["recorded_ledger_cents"] += amount
        totals[kind + "_cents"] += amount
        if failed:
            totals["recorded_in_failed_or_refused_context_cents"] += amount
        for dimension in ("account", "library", "listing", "job", "feature", "provider", "cost_basis"):
            group[(dimension, line[dimension] or "unknown")] += amount
        for ident in supplier_ids:
            provider_groups[(line["provider"], line["model"], ident, line["feature"])].append(row["id"])

    holds = []
    for row in serving:
        if row["id"] not in hold_links and row["state"] != "rejected":
            holds.append({"journal": "serving", "id": row["id"], "state": row["state"], "hold_cents": cents(money(row["hold_cents"])), "account": scope(row.get("billing_org_id") or row.get("org_id")), "provider": token(row["provider"]), "model": token(row["model"]), "tariff_version": token(row.get("tariff_version")), "created_at": row.get("created_at"), "invoice_verified": False})
    overlap = []
    tombstones = []
    for row in videos:
        if row.get("cost_ledger_id"):
            if row["cost_ledger_id"] not in ids:
                tombstones.append({"reservation_id": row["id"], "ledger_id": row["cost_ledger_id"], "priced_cents": cents(money(row["total_cents"])), "supplier_request_id": request_id(row.get("provider_request_id"))})
            continue
        if row.get("released_at"):
            continue
        candidates = [h for h in serving if h.get("org_id") == row.get("org_id") and h.get("actor_id") == row.get("actor_id") and h.get("request_key") == row.get("idempotency_key") and h.get("provider") == row.get("provider") and h.get("model") == row.get("model") and h.get("state") != "rejected" and (h.get("stage") == row.get("feature") or h.get("stage") == str((row.get("meta") or {}).get("task")) + ":0")]
        if len(candidates) == 1:
            overlap.append({"video_reservation_id": row["id"], "serving_reservation_id": candidates[0]["id"], "already_counted_in_ledger": candidates[0]["id"] in hold_links})
            # A higher app reserve still contributes its unmatched excess.
            other = hold_links.get(candidates[0]["id"])
            covered = money(other["total_cents"]) if other else money(candidates[0]["hold_cents"])
            excess = max(ZERO, money(row["hold_cents"]) - covered)
            if excess:
                holds.append({"journal": "app_video_excess", "id": row["id"], "state": "unsettled", "hold_cents": cents(excess), "account": scope(row.get("billing_org_id") or row.get("org_id")), "provider": token(row["provider"]), "model": token(row["model"]), "invoice_verified": False})
        else:
            holds.append({"journal": "app_video", "id": row["id"], "state": "unsettled", "hold_cents": cents(money(row["hold_cents"])), "account": scope(row.get("billing_org_id") or row.get("org_id")), "provider": token(row["provider"]), "model": token(row["model"]), "supplier_request_id": request_id(row.get("provider_request_id")), "ambiguous_serving_overlap": len(candidates) > 1, "created_at": row.get("created_at"), "invoice_verified": False})
    spool_lines, spool_seen = [], {}
    for entry in spool:
        row = entry.get("row", entry)
        key = row.get("idempotency_key")
        if not key:
            raise ValueError("Spool record needs its immutable idempotency key")
        if key in idempotency:
            persisted = [r for r in ledger if r.get("idempotency_key") == key]
            if any(money(r["total_cents"]) != money(row["total_cents"]) or any(k in row and k in r and row[k] != r[k] for k in ("provider", "model", "feature", "org_id", "job_id")) for r in persisted):
                raise ValueError("Spool conflicts with recorded charge")
            continue
        if key in spool_seen:
            if spool_seen[key] != row:
                raise ValueError("Conflicting spooled idempotency key")
            continue
        spool_seen[key] = row
        spool_lines.append({"idempotency_key_hash": scope(key), "provider": token(row.get("provider")), "priced_cents": cents(money(row["total_cents"]))})
    external, event_ids = [], set()
    for event in events:
        event = {k: event.get(k) for k in ("id", "kind", "provider", "currency", "amount_cents", "observed_at", "occurred_at", "evidence", "supplier_transaction_id", "supplier_invoice_id")}
        if event.get("id") in event_ids:
            if event != next(e for e in external if e["id"] == event["id"]):
                raise ValueError("Conflicting external accounting event")
            continue
        if event.get("kind") not in ("provider_credit_funding", "supplier_usage_invoice", "fixed_infrastructure_invoice") or event.get("currency") != "USD" or not request_id(event.get("id")):
            raise ValueError("Invalid external accounting event")
        money(event.get("amount_cents"))
        if event["kind"] != "provider_credit_funding" and (event.get("evidence") != "supplier_invoice" or not request_id(event.get("supplier_invoice_id"))):
            raise ValueError("Invoice event needs explicit supplier invoice evidence")
        for key in ("id", "provider", "supplier_transaction_id", "supplier_invoice_id"):
            if event.get(key) and not request_id(event[key]):
                raise ValueError("Invalid external accounting identifier")
        event_ids.add(event["id"])
        external.append(event)
    return {"schema": 1, "currency": "USD", "exported_at": snapshot.get("exported_at"),
            "note": "Recorded costs are internal priced accounting, not verified supplier charges. Holds, credit funding, invoice totals and spool rows are separate and must not be added as duplicate consumption.",
            "totals": {k: cents(v) for k, v in sorted(totals.items())},
            "scope_totals": [{"dimension": k[0], "scope": k[1], "recorded_cents": cents(v)} for k, v in sorted(group.items())],
            "ledger": lines, "unledgered_holds": holds,
            "unledgered_hold_cents": cents(sum((money(h["hold_cents"]) for h in holds), ZERO)),
            "cross_journal_overlaps_not_added_twice": overlap,
            "settled_receipts_without_retained_ledger": tombstones,
            "possible_duplicate_supplier_ids": [{"provider": k[0], "model": k[1], "supplier_request_id": k[2], "feature": k[3], "ledger_ids": v} for k, v in provider_groups.items() if len(v) > 1],
            "pending_spool_not_added_to_ledger": spool_lines,
            "external_events_separate_from_consumption": external,
            "provider_credit_funding_cents": cents(sum((money(e["amount_cents"]) for e in external if e["kind"] == "provider_credit_funding"), ZERO)),
            "external_supplier_usage_invoice_cents_not_added": cents(sum((money(e["amount_cents"]) for e in external if e["kind"] == "supplier_usage_invoice"), ZERO)),
            "external_fixed_infrastructure_invoice_cents_separate": cents(sum((money(e["amount_cents"]) for e in external if e["kind"] == "fixed_infrastructure_invoice"), ZERO)),
            "spatial_cost_rollups_not_added_to_ledger": [{"job": scope(r["id"]), "status": token(r.get("status")), "reported_cents": cents(money(r["cost_cents"])), "invoice_verified": False} for r in snapshot["spatial"]],
            "other_accounting_journals_not_added_to_ledger": [{"kind": token(r["kind"]), "job": scope(r["id"]), "account": scope(r.get("org_id")), "listing": scope(r.get("listing_id")), "state": token(r.get("state")), "priced_cents": cents(money(r["priced_cents"])), "held_cents": cents(money(r["held_cents"])), "charged_cents": cents(money(r["charged_cents"])) if r.get("charged_cents") is not None else None, "ledger_id": r.get("ledger_id"), "supplier_request_id": request_id(r.get("supplier_request_id")), "price_version": token(r.get("price_version")), "has_billing_reference": r.get("has_billing_reference") is True} for r in snapshot["other_journals"]],
            "unpriced_usage": unpriced_usage(snapshot.get("unpriced_usage", {})),
            "coverage": {"source_rows": snapshot["counts"], "unique_ledger_rows": len(ledger), "serving_rows_reconciled_to_ledger": len(hold_links), "ledger_rows_without_listing": sum(x["listing"] == "unknown" for x in lines), "ledger_rows_without_supplier_id": sum(not x["supplier_request_ids"] for x in lines), "ledger_rows_without_tariff": sum(not x["tariff_versions"] for x in lines), "supplier_invoice_reconciliation": "not supplied; no recorded cost labeled invoice verified", "spool_visibility": "supplied local spool only; other running workers unknown", "infrastructure": "vendor invoices/account telemetry not automatically imported", "hold_total_scope": "unreconciled serving/app-video holds; presenter/erase journals and spatial rollups separate to prevent duplicate summation", "failed_context": "current job/source state or retained ledger refusal flag; resumed jobs can change context without changing any recorded cost", "history": "account deletion can remove ledger rows; retained reservation tombstones are reported separately"}}


def private_write(path, body):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(body)


def collect(project, token_env="SUPABASE_ACCESS_TOKEN", opener=urllib.request.urlopen):
    """One explicit read-only API call; no credential argument, retry or fallback.

    Official contract: /docs/reference/api/v1-read-only-query. This endpoint
    executes as supabase_read_only_user; it is never the migration/write API.
    """
    if not re.fullmatch(r"[a-z]{20}", project) or not re.fullmatch(r"[A-Z][A-Z0-9_]{0,79}", token_env):
        raise ValueError("Invalid accounting project/credential selector")
    credential = os.environ.get(token_env)
    if not credential:
        raise ValueError("Accounting management credential unavailable; use a private snapshot")
    req = urllib.request.Request("https://api.supabase.com/v1/projects/" + project + "/database/query/read-only",
                                 data=json.dumps({"query": (HERE / "api_cost_snapshot.sql").read_text()}).encode(),
                                 headers={"Authorization": "Bearer " + credential, "Content-Type": "application/json"}, method="POST")
    try:
        with opener(req, timeout=60) as response:
            body = response.read(16 * 1024 * 1024 + 1)
            if len(body) > 16 * 1024 * 1024:
                raise ValueError("Accounting export exceeded safe response bound")
            return json.loads(body)[0]["snapshot"]
    except Exception:
        raise ValueError("Read-only accounting export failed; no retry or provider call") from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--snapshot", type=Path)
    source.add_argument("--collect-project", help="Explicit Supabase read-only Management API query; never a provider call")
    parser.add_argument("--token-env", default="SUPABASE_ACCESS_TOKEN", help="Management credential environment-variable NAME; never its value")
    parser.add_argument("--events", type=Path)
    parser.add_argument("--spool", type=Path, help="Read local spool only; never flush it")
    parser.add_argument("--out", type=Path, required=True, help="NEW private directory; never overwrites prior evidence")
    args = parser.parse_args()
    args.out.mkdir(mode=0o700, parents=True, exist_ok=False)
    if args.collect_project:
        snapshot = collect(args.collect_project, args.token_env)
    else:
        snapshot = json.loads(args.snapshot.read_text())
    events = json.loads(args.events.read_text())["events"] if args.events else []
    spool = [json.loads(s) for s in args.spool.read_text().splitlines() if s.strip()] if args.spool else []
    report = accounting_report(snapshot, events, spool)
    private_write(args.out / "snapshot.private.json", json.dumps(snapshot, indent=2) + "\n")
    private_write(args.out / "report.private.json", json.dumps(report, indent=2) + "\n")
    import io
    text = io.StringIO()
    columns = ("ledger_id", "created_at", "account", "library", "listing", "job", "provider", "model", "feature", "units", "unit_cost_cents", "recorded_cents", "cost_basis", "stage", "retry", "failed_or_refused_context", "supplier_request_ids", "tariff_versions", "price_effective_date", "invoice_verified")
    writer = csv.DictWriter(text, fieldnames=columns, extrasaction="ignore")
    writer.writeheader()
    for row in report["ledger"]:
        writer.writerow({k: csv_cell(v) for k, v in {**row, "supplier_request_ids": "|".join(row["supplier_request_ids"]), "tariff_versions": "|".join(row["tariff_versions"])}.items()})
    private_write(args.out / "ledger.private.csv", text.getvalue())
    manifest = {"source_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path(__file__), HERE / "api_cost_snapshot.sql"]}, "snapshot_sha256": hashlib.sha256((args.out / "snapshot.private.json").read_bytes()).hexdigest(), "report_sha256": hashlib.sha256((args.out / "report.private.json").read_bytes()).hexdigest(), "live_mutations": False, "provider_calls": False}
    private_write(args.out / "manifest.json", json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"report": str(args.out / "report.private.json"), "ledger_rows": len(report["ledger"]), "read_only": True}))


if __name__ == "__main__":
    main()
