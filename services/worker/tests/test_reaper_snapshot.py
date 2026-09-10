"""Reaper must fail only the expired ownership snapshot it selected.

Actual db.py + loopback fake PostgREST; no provider or production connection.
The injected change occurs after SELECT returns but before PATCH evaluates.
These cases deliberately fail against the old id+status-only PATCH.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_job_lease import fresh_db, iso, load_db_module
import fake_postgrest


class ReaperSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.store = fresh_db()
        self.server, url = fake_postgrest.start(self.store)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.db = load_db_module(url)
        self.row = {"id": "J-reap", "status": "processing", "attempts": 3,
                    "worker_id": "owner-A", "lease_expires_at": iso(-60)}
        self.store.tables["render_jobs"] = [self.row]

    def race(self, **change):
        real_patch = self.db.patch

        def changed_before_patch(table, filters, values, **kw):
            self.row.update(change)
            return real_patch(table, filters, values, **kw)

        self.db.patch = changed_before_patch
        self.assertEqual(self.db.reap_stale_jobs(), 0)
        self.assertEqual(self.row["status"], "processing")
        self.assertNotIn("error", self.row)

    def test_heartbeat_renewal_wins_before_patch(self):
        self.race(lease_expires_at=iso(600))

    def test_changed_owner_is_not_failed_even_if_lease_still_expired(self):
        self.race(worker_id="owner-B")

    def test_changed_attempt_is_not_failed_even_if_lease_still_expired(self):
        self.race(attempts=4)

    def test_changed_expiry_is_not_failed_even_if_both_expired(self):
        self.race(lease_expires_at=iso(-10))

    def test_unchanged_poison_is_failed(self):
        self.assertEqual(self.db.reap_stale_jobs(), 1)
        self.assertEqual(self.row["status"], "failed")
        self.assertEqual(self.row["error"]["type"], "poison")

    def test_legacy_null_owner_can_be_reaped(self):
        self.row["worker_id"] = None
        self.assertEqual(self.db.reap_stale_jobs(), 1)
        self.assertEqual(self.row["status"], "failed")


if __name__ == "__main__":
    unittest.main(verbosity=2)
