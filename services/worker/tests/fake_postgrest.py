#!/usr/bin/env python3
"""
A tiny in-memory stand-in for PostgREST, enough to exercise services/worker/db.py.

Not a general implementation — it supports exactly the operators the worker uses:
`eq.`, `in.(a,b)`, `lt.`, `gte.`, `is.true`, plus `select`, `order`, `limit` and
`Prefer: return=representation|minimal`, and the one embedded-resource filter the
claim query needs (`capture_assets.bucket=eq.uploads`).

`lease_columns=False` reproduces a database where migration 0015 has not been
applied: any request naming lease_expires_at / attempts / worker_id comes back as
PostgREST does — HTTP 400 with SQLSTATE 42703 — so the worker's degradation path
is tested against the real error shape rather than a guess.

Stdlib only; no pytest (the repo has no Python test runner installed).
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

LEASE_COLUMNS = ("lease_expires_at", "attempts", "worker_id")


class FakeDB:
    def __init__(self, *, lease_columns: bool = True,
                 unknown_columns: tuple[str, ...] = ()) -> None:
        self.lease_columns = lease_columns
        #: extra columns this database does NOT have (e.g. pre-0015
        #: enhancement_result / hero_key), so the worker's degradation paths can
        #: be tested against a real 42703 rather than a guess.
        self.unknown_columns = tuple(unknown_columns)
        self.tables: dict[str, list[dict]] = {
            "render_jobs": [], "capture_assets": [], "listings": [],
            "renders": [], "photos": [], "cost_ledger": [],
        }
        self.requests: list[tuple[str, str]] = []
        self.lock = threading.Lock()

    # ── filtering ────────────────────────────────────────────────────────────
    def _match(self, row: dict, table: str, key: str, spec: str) -> bool:
        if "." in key:                      # embedded resource filter
            rel, col = key.split(".", 1)
            fk = {"capture_assets": "capture_asset_id"}.get(rel)
            target = next((r for r in self.tables.get(rel, [])
                           if fk and r.get("id") == row.get(fk)), None)
            if target is None:
                return False
            return self._match(target, rel, col, spec)
        value = row.get(key)
        op, _, arg = spec.partition(".")
        if op == "eq":
            return str(value) == arg
        if op == "in":
            return str(value) in arg.strip("()").split(",")
        if op == "is":
            return {"true": True, "false": False, "null": None}.get(arg) is value
        if op == "lt":
            return value is not None and str(value) < arg
        if op == "gte":
            try:
                return value is not None and float(value) >= float(arg)
            except (TypeError, ValueError):
                return False
        if op == "lt" or op == "gt":
            return False
        raise AssertionError(f"fake_postgrest: unsupported operator {spec!r}")

    def select(self, table: str, params: dict) -> list[dict]:
        rows = [r for r in self.tables[table]
                if all(self._match(r, table, k, v[0]) for k, v in params.items()
                       if k not in ("select", "order", "limit"))]
        order = params.get("order", [None])[0]
        if order:
            field = order.split(".")[0]
            rows.sort(key=lambda r: str(r.get(field) or ""),
                      reverse=order.endswith(".desc"))
        limit = params.get("limit", [None])[0]
        return rows[: int(limit)] if limit else rows


class _Handler(BaseHTTPRequestHandler):
    db: FakeDB

    def log_message(self, *_a) -> None:          # keep test output clean
        pass

    # ── helpers ──────────────────────────────────────────────────────────────
    def _reply(self, code: int, body) -> None:
        payload = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _missing_column(self, name: str) -> None:
        self._reply(400, {"code": "42703", "message": f'column "{name}" does not exist',
                          "details": None, "hint": None})

    def _guard_lease(self, blob: str) -> bool:
        """True when the request names a column this fake database lacks."""
        missing = list(self.db.unknown_columns)
        if not self.db.lease_columns:
            missing += list(LEASE_COLUMNS)
        for col in missing:
            if col in blob:
                self._missing_column(col)
                return True
        return False

    def _parse(self):
        u = urlparse(self.path)
        table = u.path.rsplit("/", 1)[-1]
        return table, parse_qs(u.query), u.query

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or "{}") if n else {}

    # ── verbs ────────────────────────────────────────────────────────────────
    def do_GET(self) -> None:
        table, params, raw = self._parse()
        self.db.requests.append(("GET", self.path))
        if self._guard_lease(raw):
            return
        with self.db.lock:
            self._reply(200, self.db.select(table, params))

    def do_POST(self) -> None:
        table, _params, raw = self._parse()
        body = self._body()
        self.db.requests.append(("POST", self.path))
        if self._guard_lease(raw + json.dumps(body)):
            return
        with self.db.lock:
            row = dict(body)
            row.setdefault("id", f"row-{len(self.db.tables[table]) + 1}")
            self.db.tables[table].append(row)
            minimal = "return=minimal" in (self.headers.get("Prefer") or "")
            self._reply(201, [] if minimal else [row])

    def do_PATCH(self) -> None:
        table, params, raw = self._parse()
        body = self._body()
        self.db.requests.append(("PATCH", self.path))
        if self._guard_lease(raw + json.dumps(body)):
            return
        with self.db.lock:
            hit = self.db.select(table, params)
            for row in hit:
                row.update(body)
            minimal = "return=minimal" in (self.headers.get("Prefer") or "")
            self._reply(200, [] if minimal else hit)


def start(db: FakeDB) -> tuple[HTTPServer, str]:
    handler = type("H", (_Handler,), {"db": db})
    server = HTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_port}"
