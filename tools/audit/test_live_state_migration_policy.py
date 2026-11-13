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


# Review names and bytes independently of the runner classification. Preserve
# all six historical entries when adding the release148 controller adoption.
EXPECTED_LIVE_STATE_ADOPTIONS = {
    "20261023044520_photo_motion_bfb1_fixed_recovery_controller.sql": "127ff57bfac508e47d32bda54719bbb69e261136d6d8f96a85c83da020622b25",
    "20261023141755_photo_motion_c74_terminal_reconciliation_controller.sql": "aa95bcc947c7aa60367f0e15bf7b883c2b101676d415808529237b944c132ef4",
    "20261023144319_photo_motion_a1bb_empty_queue_terminal_cleanup_controller.sql": "a58465b97a5f36f82ff951591f1af4563be40008c5d39a396fa861e2a2458bd0",
    "20261023173823_aerial_omni_reference_prospective_route_20261023.sql": "9f63c1faeae5cbf8bc81a19dfcba7336132e634f9afd99fcfa889db8bf5c1fef",
    "20261023185845_photo_motion_cf7_concurrent_scheduler_history_20261023.sql": "13456ba634895717892380a556f51b734e394df1381d43cbd51c0dd065494c9a",
    "20261023215829_studio_current_reviewed_photo_motion_kit_20261023.sql": "f93481224aa3a93331a20e028097507e263650064c514380a414a65d7801d0e0",
    "20261113011309_photo_motion_release148_controller_adoption.sql": "c99e4e9258d3d5e31f55b7051c7fb26e1bb4d586ded3ec1171586f5c8e425327",
}


class LiveStateMigrationPolicyTests(unittest.TestCase):
    def setUp(self):
        self.paths = sorted(MIGRATIONS.glob("*.sql"))

    def test_only_seven_pinned_live_adoptions_are_excluded(self):
        self.assertEqual(LIVE_STATE_ONLY_MIGRATIONS, EXPECTED_LIVE_STATE_ADOPTIONS)
        schema, live_state = partition_fresh_migrations(self.paths)
        self.assertEqual({path.name for path in live_state}, set(LIVE_STATE_ONLY_MIGRATIONS))
        self.assertEqual(len(schema) + len(live_state), len(self.paths))
        self.assertEqual(len(live_state), 7)
        for path in live_state:
            self.assertFalse(replayable_migration(path.name))
        self.assertTrue(replayable_migration("20261023999999_future_schema_change.sql"))

    def test_changed_classified_sql_is_rejected(self):
        for source in (path for path in self.paths if path.name in EXPECTED_LIVE_STATE_ADOPTIONS):
            with self.subTest(migration=source.name), tempfile.TemporaryDirectory(prefix="rp-migration-policy-") as owned:
                changed = Path(owned) / source.name
                changed.write_bytes(source.read_bytes() + b"\n-- deliberate source change\n")
                paths = [changed if path == source else path for path in self.paths]
                with self.assertRaisesRegex(RuntimeError, "Classified live-state migration changed"):
                    partition_fresh_migrations(paths)

    def test_missing_classified_sql_is_rejected(self):
        for source in (path for path in self.paths if path.name in EXPECTED_LIVE_STATE_ADOPTIONS):
            with self.subTest(migration=source.name), self.assertRaisesRegex(RuntimeError, "Classified live-state migrations missing"):
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
        # Keep the historical inventory pinned while later guarded migrations
        # can be added without changing this policy test's total.
        self.assertEqual(sum(name < "20261028000000" for name in GUARDED_ONE_SHOT_MIGRATIONS), 39)
        self.assertIn("20261028010346_reviewer_sandbox_shared_credit_budget.sql",
                      GUARDED_ONE_SHOT_MIGRATIONS)
        self.assertLessEqual(set(GUARDED_ONE_SHOT_MIGRATIONS), names)
        self.assertFalse(set(GUARDED_ONE_SHOT_MIGRATIONS) & {path.name for path in live_state})
        self.assertTrue(all(not replayable_migration(name) for name in GUARDED_ONE_SHOT_MIGRATIONS))
        # Pin the historical inventory while allowing later migrations to enter
        # the mandatory replay gate without changing this unrelated policy test.
        self.assertEqual(sum(replayable_migration(path.name) for path in schema
                             if path.name < "20261027000000"), 164)
        self.assertTrue(replayable_migration("20261027161200_credit_serving_photo_declutter.sql"))
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
