#!/usr/bin/env python3
"""Fail closed when an exact live-state adoption is mistaken for fresh schema SQL."""

from pathlib import Path
import re
import tempfile
import unittest

from run_database_regression import (
    GUARDED_ONE_SHOT_MIGRATIONS,
    LIVE_STATE_ONLY_MIGRATIONS,
    partition_fresh_migrations,
    replayable_migration,
)


MIGRATIONS = Path(__file__).resolve().parents[2] / "services/supabase/migrations"
ROOT = MIGRATIONS.parents[2]


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

    def test_photo_publication_is_once_per_fresh_database(self):
        name = "20261020212328_accepted_photo_publication_host_compatible.sql"
        schema, live_state = partition_fresh_migrations(self.paths)
        self.assertIn(name, {path.name for path in schema})
        self.assertNotIn(name, {path.name for path in live_state})
        self.assertFalse(replayable_migration(name))

    def test_exact_guarded_one_shot_inventory_still_applies_once(self):
        schema, live_state = partition_fresh_migrations(self.paths)
        names = {path.name for path in schema}
        self.assertEqual(len(GUARDED_ONE_SHOT_MIGRATIONS), 22)
        self.assertLessEqual(set(GUARDED_ONE_SHOT_MIGRATIONS), names)
        self.assertFalse(set(GUARDED_ONE_SHOT_MIGRATIONS) & {path.name for path in live_state})
        self.assertTrue(all(not replayable_migration(name) for name in GUARDED_ONE_SHOT_MIGRATIONS))
        self.assertEqual(sum(replayable_migration(path.name) for path in schema), 164)
        for digest, refusal in GUARDED_ONE_SHOT_MIGRATIONS.values():
            self.assertEqual(len(digest), 64)
            self.assertTrue(refusal)

    def test_changed_guarded_one_shot_sql_is_rejected(self):
        source = next(path for path in self.paths if path.name in GUARDED_ONE_SHOT_MIGRATIONS)
        with tempfile.TemporaryDirectory(prefix="rp-one-shot-policy-") as owned:
            changed = Path(owned) / source.name
            changed.write_bytes(source.read_bytes() + b"\n-- deliberate source change\n")
            paths = [changed if path == source else path for path in self.paths]
            with self.assertRaisesRegex(RuntimeError, "Guarded one-shot migration changed"):
                partition_fresh_migrations(paths)

    def test_missing_guarded_one_shot_sql_is_rejected(self):
        source = next(path for path in self.paths if path.name in GUARDED_ONE_SHOT_MIGRATIONS)
        with self.assertRaisesRegex(RuntimeError, "Guarded one-shot migrations missing"):
            partition_fresh_migrations(path for path in self.paths if path != source)

    def test_publication_ci_full_schema_runners_use_the_pinned_policy(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job = workflow.split("  db-publication-regression:\n", 1)[1]
        job = re.split(r"(?m)^  [a-z][a-z0-9-]*:\n", job, maxsplit=1)[0]
        runners = {
            ROOT / path for path in re.findall(
                r"python3 ((?:services/supabase/tests|tools/audit)/[\w./-]+\.py)", job
            )
        }
        # Check the complete disposable-PostgreSQL job, including audit runners
        # that do not have a _pg.py suffix. Source-only scanners are excluded.
        database_runners = {
            runner for runner in runners
            if "initdb" in runner.read_text() and ".glob(" in runner.read_text()
        }
        self.assertGreaterEqual(len(database_runners), 45)
        # These proofs stop at an explicit historical migration boundary before
        # the 2026-10-23 adoptions, so the full-set policy cannot apply.
        historical_only = {
            "bounded_subscription_trial_pg.py",
            "subscription_trial_video_duration_pg.py",
            "run_internal_testing_grants.py",
            "run_spatial_regression.py",
            "run_spatial_provider_regression.py",
        }
        self.assertLessEqual(historical_only, {runner.name for runner in database_runners})
        for runner in database_runners:
            with self.subTest(runner=runner.name):
                source = runner.read_text()
                if runner.name in historical_only:
                    continue
                self.assertIn("partition_fresh_migrations", source)
                # This runner also has a separately bounded October 5 proof.
                if runner.name != "run_private_internal_testing.py":
                    self.assertNotRegex(source, r"for \w+ in MIGRATIONS:")
                self.assertNotRegex(source, r"for \w+ in MIGS:")
                self.assertNotRegex(source, r"for \w+ in sorted\(\(SQL\s*/\s*['\"]migrations['\"]\)\.glob\(['\"]\*\.sql['\"]\)\):")


if __name__ == "__main__":
    unittest.main()
