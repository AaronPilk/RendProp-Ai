#!/usr/bin/env python3
"""
Cost ledger — one row per billable provider call, written to Supabase via its
REST (PostgREST) API with the service-role key, plus a rollup onto
`render_jobs.cost_cents`.

Columns mirror services/supabase/migrations/0001_init.sql `cost_ledger` exactly:
  job_id, org_id, feature, provider, model, units, unit_cost_cents, total_cents, meta

Design notes:
  • The rollup recomputes `render_jobs.cost_cents` as SUM(total_cents) for the job
    (rounded to whole cents — the column is integer) instead of a read-modify-add,
    so concurrent workers converge on the true total rather than racing an
    increment. For very high write concurrency, move this to a Postgres RPC /
    trigger; the interface here stays the same.
  • Local mode: if SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY aren't set, the ledger
    runs offline — it still tallies and prints every row, so the CLI cost-test and
    a keyed-but-DB-less run both work. `enabled` tells callers which mode it's in.

Auth: PostgREST needs BOTH `apikey` and `Authorization: Bearer` set to the
service-role key. Never ship this key to the app (see BACKEND-ARCHITECTURE §4).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from config import SETTINGS
from providers.base import ProviderError, request_json


@dataclass
class CostLedger:
    supabase_url: str = ""
    service_key: str = ""
    verbose: bool = True
    rows: list = field(default_factory=list)   # local mirror of what we wrote
    running_cents: float = 0.0

    def __post_init__(self) -> None:
        self.supabase_url = (self.supabase_url or SETTINGS.supabase_url).rstrip("/")
        self.service_key = self.service_key or SETTINGS.supabase_service_role_key

    @property
    def enabled(self) -> bool:
        """True when we can actually write to Supabase."""
        return bool(self.supabase_url and self.service_key)

    # ── headers ───────────────────────────────────────────────────────────────
    def _headers(self, prefer: str = "return=representation") -> dict:
        return {
            "apikey": self.service_key,
            "Authorization": f"Bearer {self.service_key}",
            "Prefer": prefer,
        }

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
        """Write one cost_ledger row and bump the job rollup. Returns the row."""
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
        }
        self.rows.append(row)
        self.running_cents = round(self.running_cents + row["total_cents"], 4)

        if self.verbose:
            print(f"    ⟐ ledger {feature:9s} {provider}/{model or '-'} "
                  f"units={row['units']} → {row['total_cents']:.4f}¢")

        if not self.enabled:
            return row  # local mode — tallied + printed, nothing to persist

        try:
            request_json(
                f"{self.supabase_url}/rest/v1/cost_ledger",
                method="POST", payload=row, headers=self._headers(), timeout=30,
            )
            if job_id:
                self._rollup_job(job_id)
        except ProviderError as e:
            # Never let a ledger hiccup kill a render — log and continue.
            print(f"    ⚠ cost_ledger write failed (continuing): {e}")
        return row

    def job_total_cents(self, job_id: str) -> float:
        """SUM(total_cents) for a job from the DB — hydrates a budget on restart."""
        if not self.enabled:
            return self.running_cents
        rows = request_json(
            f"{self.supabase_url}/rest/v1/cost_ledger?select=total_cents&job_id=eq.{job_id}",
            method="GET", headers=self._headers(), timeout=30,
        )
        if isinstance(rows, list):
            return round(sum(float(r.get("total_cents", 0)) for r in rows), 4)
        return 0.0

    # ── internal ──────────────────────────────────────────────────────────────
    def _rollup_job(self, job_id: str) -> None:
        """Recompute render_jobs.cost_cents = round(SUM(total_cents))."""
        total = self.job_total_cents(job_id)
        request_json(
            f"{self.supabase_url}/rest/v1/render_jobs?id=eq.{job_id}",
            method="PATCH", payload={"cost_cents": int(round(total))},
            headers=self._headers("return=minimal"), timeout=30,
        )
