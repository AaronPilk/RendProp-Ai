#!/usr/bin/env python3
"""Fail closed when an exact live-state adoption is mistaken for fresh schema SQL."""

from pathlib import Path
import tempfile
import unittest

from run_database_regression import (
    LIVE_STATE_ONLY_MIGRATIONS,
    partition_fresh_migrations,
    replayable_migration,
)


MIGRATIONS = Path(__file__).resolve().parents[2] / "services/supabase/migrations"


class LiveStateMigrationPolicyTests(unittest.TestCase):
    def setUp(self):
        self.paths = sorted(MIGRATIONS.glob("*.sql"))

    def test_only_six_pinned_live_adoptions_are_excluded(self):
        schema, live_state = partition_fresh_migrations(self.paths)
        self.assertEqual({path.name for path in live_state}, set(LIVE_STATE_ONLY_MIGRATIONS))
        self.assertEqual(len(schema) + len(live_state), len(self.paths))
        self.assertEqual(len(live_state), 6)
        for path in live_state:
            self.assertFalse(replayable_migration(path.name))
        self.assertTrue(replayable_migration("20261023999999_future_schema_change.sql"))

    def test_changed_classified_sql_is_rejected(self):
        source = next(path for path in self.paths if path.name in LIVE_STATE_ONLY_MIGRATIONS)
        with tempfile.TemporaryDirectory(prefix="rp-migration-policy-") as owned:
            changed = Path(owned) / source.name
            changed.write_bytes(source.read_bytes() + b"\n-- deliberate source change\n")
            paths = [changed if path == source else path for path in self.paths]
            with self.assertRaisesRegex(RuntimeError, "Classified live-state migration changed"):
                partition_fresh_migrations(paths)

    def test_missing_classified_sql_is_rejected(self):
        source = next(path for path in self.paths if path.name in LIVE_STATE_ONLY_MIGRATIONS)
        with self.assertRaisesRegex(RuntimeError, "Classified live-state migrations missing"):
            partition_fresh_migrations(path for path in self.paths if path != source)


if __name__ == "__main__":
    unittest.main()
