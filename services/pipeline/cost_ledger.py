#!/usr/bin/env python3
"""
Cost ledger — one row per billable provider call, written to Supabase via its
REST (PostgREST) API with the service-role key, plus a rollup onto
`render_jobs.cost_cents`.

Columns mirror services/supabase/migrations/0001_init.sql `cost_ledger` exactly:
  job_id, org_id, feature, provider, model, units, unit_cost_cents, total_cents, meta

FAILURE POLICY (audit F-G-07 — this used to be inverted)
--------------------------------------------------------
This module records REAL MONEY: every row here is a Gemini / fal / Anthropic
call that has already been paid for. It used to `print("… continuing")` and swallow
any ledger failure, so a Supabase blip during enhancement meant provider spend
went unrecorded — uncapped, unbilled, invisible. Meanwhile the worker's *estimate*
lines failed CLOSED and killed the customer's tour. Both halves are now the right
way round:

  • Never lose a record of real money. `record()` retries with exponential
    backoff, then writes the row to a durable local spool (`cost_spool`), then
    raises `LedgerError` and latches `degraded = True`.
  • Never keep spending while blind. The router checks `ledger.degraded` BEFORE
    every metered provider call, so once the ledger is unreachable the job stops
    buying things; segments already paid for are kept, the rest ship as the
    original, and the base tour is never lost (that policy lives in the worker).
  • The rollup is retried SEPARATELY from the insert — a failed rollup used to
    send the whole `record()` through its retry loop and insert the row again,
    inflating `cost_cents` with duplicates.

Local ledger mode tallies estimates without writes. It does not authorize paid
generations: providers/base.py independently requires a current funded worker
session before any generation POST. A keyed-but-DB-less CLI cannot spend.

Auth: modern secret keys are sent only in `apikey`; the explicit legacy
compatibility path also sends a Bearer JWT. Never ship either server key to the app.
"""

from __future__ import annotations

import json
import re
import time
import uuid
from dataclasses import dataclass, field

import cost_spool
from config import SETTINGS
from providers.base import ProviderError, request_json


class LedgerError(ProviderError):
    """The ledger could not persist a row for REAL spend. Never swallowed.

    Subclasses ProviderError so the per-segment handler in `enhance.enhance_video`
    treats it like any other segment failure (ship the original) rather than
    unwinding the whole job.
    """


def _is_duplicate_key_error(err: Exception) -> bool:
    """Only an actual PostgREST 409/23505 acknowledges the same charge.

    request_json preserves HTTP status in an anchored prefix. URLs and error
    bodies are not status authority: a redirect to port 409xx is still a
    failed ledger write, even if its body mentions a duplicate-key code.
    """
    match = re.fullmatch(r"HTTP (\d{3}) from \S+: (.*)", str(err), re.DOTALL)
    if not match or match.group(1) != "409":
        return False
    try:
        body = json.loads(match.group(2))
    except (TypeError, ValueError):
        return False
    return isinstance(body, dict) and body.get("code") == "23505"


# Bounded retry — no unbounded loops anywhere near a money path.
LEDGER_RETRY_ATTEMPTS = 3
LEDGER_RETRY_BACKOFF_S = (0.5, 2.0, 5.0)   # len == ATTEMPTS; last one is unused


@dataclass
class CostLedger:
    supabase_url: str = ""
    service_key: str = ""
    verbose: bool = True
    rows: list = field(default_factory=list)   # local mirror of what we wrote
    running_cents: float = 0.0
    #: latched True once a row had to be spooled. The router refuses further
    #: metered calls while this is set — we do not spend money we cannot record.
    degraded: bool = False
    spooled_rows: int = 0

    def __post_init__(self) -> None:
        self.supabase_url = (self.supabase_url or SETTINGS.supabase_url).rstrip("/")
        self.service_key = self.service_key or SETTINGS.supabase_service_role_key

    @property
    def enabled(self) -> bool:
        """True when we can actually write to Supabase."""
        return bool(self.supabase_url and self.service_key)

    # ── headers ───────────────────────────────────────────────────────────────
    def _headers(self, prefer: str = "return=representation") -> dict:
        headers = {
            "apikey": self.service_key,
            "Prefer": prefer,
        }
        if not self.service_key.startswith("sb_secret_"):
            headers["Authorization"] = f"Bearer {self.service_key}"
        return headers

    # ── public API ────────────────────────────────────────────────────────────
    def record(
        self,
        *,
        feature: str,
        provider: str,
        model: str | None,
        units: float,
        unit_cost_cents: float,
        total_cents: float,
        job_id: str | None = None,
        org_id: str | None = None,
        meta: dict | None = None,
    ) -> dict:
        """Persist one cost_ledger row for money already spent.

        Raises `LedgerError` if the row could not reach the database — after
        retrying and after writing it to the durable spool, so the record itself
        is never lost. The caller keeps the produced media (it was paid for) and
        stops making further paid calls.
        """
        row = {
            "job_id": job_id,
            "org_id": org_id,
            "feature": feature,
            "provider": provider,
            "model": model,
            "units": round(float(units), 4),
            "unit_cost_cents": round(float(unit_cost_cents), 6),
            "total_cents": round(float(total_cents), 4),
            "meta": meta or {},
            # Generated ONCE, here, before any attempt — every retry in
            # `_insert_with_retry` and every later `flush_spool()` replay of
            # this exact row carries the SAME key, so a resubmission 409s
            # instead of double-counting REAL provider spend (audit finding 6;
            # migration 0025_cost_ledger_idempotency.sql).
            "idempotency_key": str(uuid.uuid4()),
        }
        self.rows.append(row)
        self.running_cents = round(self.running_cents + row["total_cents"], 4)

        if self.verbose:
            print(f"    ⟐ ledger {feature:9s} {provider}/{model or '-'} "
                  f"units={row['units']} → {row['total_cents']:.4f}¢")

        if not self.enabled:
            return row  # local mode — tallied + printed, nothing to persist

        try:
            self._insert_with_retry(row)
        except ProviderError as e:
            self._spool_and_alarm(row, e)
            raise LedgerError(
                f"cost_ledger unreachable after {LEDGER_RETRY_ATTEMPTS} attempts for "
                f"{feature} {provider}/{model or '-'} ({row['total_cents']:.4f}¢); "
                f"row spooled for reconciliation, no further paid calls this job: {e}"
            ) from e

        # Rollup is a CONVENIENCE aggregate, retried separately: a rollup failure
        # must never re-drive the insert (that produced duplicate ledger rows).
        if job_id:
            self._rollup_best_effort(job_id)
        return row

    def job_total_cents(self, job_id: str) -> float:
        """SUM(total_cents) for a job from the DB — hydrates a budget on restart."""
        if not self.enabled:
            return self.running_cents
        rows = request_json(
            f"{self.supabase_url}/rest/v1/cost_ledger?select=total_cents&job_id=eq.{job_id}",
            method="GET", headers=self._headers(), timeout=30, follow_redirects=False,
        )
        if isinstance(rows, list):
            return round(sum(float(r.get("total_cents", 0)) for r in rows), 4)
        return 0.0

    def flush_spool(self, *, limit: int = 200) -> tuple[int, int]:
        """Re-try previously-spooled rows. Safe to call at start/end of a job."""
        if not self.enabled:
            return 0, cost_spool.pending_count()
        sent, pending = cost_spool.flush(self._insert_once, limit=limit)
        if sent and not pending:
            self.degraded = False   # the ledger is back and the backlog is clear
        return sent, pending

    # ── internal ──────────────────────────────────────────────────────────────
    def _insert_once(self, row: dict) -> None:
        """POST one cost_ledger row. A duplicate-key response is SUCCESS.

        `row["idempotency_key"]` is stable across every retry/replay of this
        SAME charge (see `record`), so a 409/23505 here means the charge
        already landed — our own earlier attempt succeeded server-side but its
        response was lost, or `flush_spool()` is re-submitting an already-sent
        spooled row. Raising in that case would spool (or re-spool) an entry
        that can never succeed any other way, permanently wedging
        `cost_spool.flush()`'s "first failure stops the pass" loop behind it —
        this is the piece that makes the idempotency key actually PREVENT a
        double-counted charge rather than merely making one detectable later.
        """
        try:
            request_json(
                f"{self.supabase_url}/rest/v1/cost_ledger",
                method="POST", payload=row, headers=self._headers("return=minimal"),
                timeout=30, follow_redirects=False,
            )
        except ProviderError as e:
            if _is_duplicate_key_error(e):
                print(f"    · cost_ledger row already recorded "
                      f"(idempotency_key={row.get('idempotency_key')}) — treating "
                      f"the duplicate submit as success")
                return
            raise

    def _insert_with_retry(self, row: dict) -> None:
        last: ProviderError | None = None
        for attempt in range(LEDGER_RETRY_ATTEMPTS):
            try:
                self._insert_once(row)
                return
            except ProviderError as e:
                last = e
                print(f"    ⚠ cost_ledger write failed "
                      f"(attempt {attempt + 1}/{LEDGER_RETRY_ATTEMPTS}): {e}")
                if attempt < LEDGER_RETRY_ATTEMPTS - 1:
                    time.sleep(LEDGER_RETRY_BACKOFF_S[attempt])
        raise last or ProviderError("cost_ledger write failed")

    def _spool_and_alarm(self, row: dict, err: Exception) -> None:
        wrote = cost_spool.append(row, source="pipeline", error=str(err),
                                  attempts=LEDGER_RETRY_ATTEMPTS)
        self.degraded = True
        if wrote:
            self.spooled_rows += 1
            print(f"    ⚠ ALARM real provider spend ({row['total_cents']:.4f}¢, "
                  f"{row['feature']}/{row['provider']}) could NOT be recorded — "
                  f"spooled to {cost_spool.spool_path()} for reconciliation. "
                  f"No further paid calls will be made for this job.")
        else:
            print(f"    ⚠⚠ ALARM real provider spend ({row['total_cents']:.4f}¢, "
                  f"{row['feature']}/{row['provider']}) could NOT be recorded AND "
                  f"could not be spooled. This money is only in this process's stdout.")

    def _rollup_best_effort(self, job_id: str) -> None:
        """Recompute render_jobs.cost_cents = round(SUM(total_cents))."""
        try:
            total = self.job_total_cents(job_id)
            request_json(
                f"{self.supabase_url}/rest/v1/render_jobs?id=eq.{job_id}",
                method="PATCH", payload={"cost_cents": int(round(total))},
                headers=self._headers("return=minimal"), timeout=30, follow_redirects=False,
            )
        except ProviderError as e:
            # The authoritative rows are in cost_ledger; the rollup can be
            # recomputed at any time. Not worth a retry storm or a raise.
            print(f"    ⚠ cost rollup for job {job_id} failed (ledger rows are "
                  f"safe; cost_cents will be stale until the next write): {e}")
