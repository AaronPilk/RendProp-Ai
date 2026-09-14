"""D3 tests use generated cameras/features only; no room media or provider calls."""
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import shutil
import sqlite3
import struct
import tempfile
import unittest
from unittest.mock import patch

import refine_sfm as d1
import refine_sfm_incremental as d2
import refine_sfm_expanded_pairs as d3
from prepare_capture import CaptureError
import test_refine_sfm_incremental as fixture


def sparse_cache(database, zero_pair=False):
    keep = {2 * 2147483647 + 3}
    if zero_pair:
        keep.add(3 * 2147483647 + 4)
    with sqlite3.connect(database) as db:
        for table in ("matches", "two_view_geometries"):
            db.execute(f'DELETE FROM "{table}" WHERE pair_id NOT IN ({",".join("?" for _ in keep)})', sorted(keep))
        if zero_pair:
            db.execute("UPDATE two_view_geometries SET rows=0,data=x'',config=0 WHERE pair_id=?", (3 * 2147483647 + 4,))
        db.commit()
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    db.close()


@unittest.skipUnless(fixture.OFFICIAL, "requires separate official pycolmap==4.2.0 environment")
class ExpandedPairTests(unittest.TestCase):
    def test_actual_cached_matching_adds_pairs_without_features_and_registers_cameras(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d3-matching-synthetic-") as directory:
            root = Path(directory)
            truth, source = fixture.synthetic(root)
            sparse_cache(source, zero_pair=True)
            source_hash = d2.file_sha(source)
            expected = {i: im.name for i, im in truth.images.items()}
            database = root / "expanded.db"
            with patch.object(fixture.p, "extract_features", side_effect=AssertionError("must use cached descriptors")):
                receipt = d3.expand_pairs(source, database, root / "all-pairs.txt", expected, fixture.p)
            self.assertEqual(receipt["candidate_pairs"], 66)
            self.assertEqual(receipt["before"]["verification_row_count"], 2)
            self.assertEqual(receipt["before"]["pairs_with_inliers"], 1)
            self.assertEqual(receipt["after"]["pairs_with_inliers"], 65)
            self.assertEqual(receipt["added_candidate_pairs"], 64)
            self.assertEqual(receipt["added_pairs_with_inliers"], 64)
            self.assertTrue(receipt["original_match_rows_unchanged"])
            self.assertTrue(receipt["original_verification_rows_unchanged"])
            self.assertEqual(d2.file_sha(source), source_hash)
            images, work = root / "images", root / "work"
            images.mkdir()
            work.mkdir()
            fixture.p.synthesize_images(fixture.p.SyntheticImageOptions(), truth, images)
            model, registration = d2.register_cached(database, images, work, expected.values(), fixture.p)
            self.assertEqual(len(model.reg_image_ids()), 12)
            self.assertEqual(model.num_points3D(), 300)
            self.assertFalse(registration["options"]["ba_use_gpu"])

    def test_complete_153_cohort_supervisor_preserves_heldout_and_source(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d3-full-synthetic-") as directory:
            root = Path(directory)
            source, cached = fixture.synthetic_fixed_cohort(root)
            sparse_cache(cached / "work/features.db")
            expected_source = d2.validate_inputs(source, cached)[-1]
            output = root / "output"
            with redirect_stdout(io.StringIO()):
                code = d3.main(["--dataset", str(source), "--cached-sfm", str(cached), "--output", str(output),
                                "--max-seconds", "60", "--execute"])
            if code:
                self.fail((output / "sfm.log").read_text()[-3000:])
            report, run = d1.read_json(output / "sfm-report.json"), d1.read_json(output / "sfm-run.json")
            self.assertEqual((report["status"], run["status"]), ("prepared", "prepared"))
            self.assertEqual(report["matching"]["candidate_pairs"], 8778)
            self.assertEqual(len(report["registered_training_ids"]), 133)
            self.assertEqual(report["original_pose_fallback_ids"], [])
            self.assertFalse(report["feature_extraction_performed"])
            self.assertFalse(report["scene_quality_accepted"])
            self.assertEqual(report["profile"]["geometry_profile"], d2.PROFILE)
            self.assertEqual(report["matching"]["matching_options"], run["matching_options"])
            self.assertEqual(report["matching"]["verification_options"], run["verification_options"])
            self.assertEqual(report["registration"]["options"], run["mapping_options"])
            self.assertEqual(report["alignment"]["options"], run["alignment_options"])
            self.assertEqual(d2.validate_inputs(source, cached)[-1], expected_source)
            original = d2.validate_dataset(source, 500000)
            derived = d2.validate_dataset(output / "dataset", 500000)
            self.assertEqual(original["image_sha256"], derived["image_sha256"])
            before = d1.image_records(source / "sparse/0/images.bin")
            after = d1.image_records(output / "dataset/sparse/0/images.bin")
            self.assertEqual(set(before), set(after))
            for image_id in range(1, 154, 8):
                self.assertEqual(before[image_id], after[image_id])
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            self.assertLess(run["elapsed_seconds"], 60)

    def test_rejects_changed_cached_rows_features_schema_and_excluded_pairs(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d3-rejection-synthetic-") as directory:
            root = Path(directory)
            truth, source = fixture.synthetic(root)
            expected = {i: im.name for i, im in truth.images.items()}
            before = d3.database_tables(source)
            destination = root / "copy.db"
            statements = ["UPDATE keypoints SET data=zeroblob(LENGTH(data)) WHERE image_id=2",
                "UPDATE two_view_geometries SET data=zeroblob(LENGTH(data)) WHERE pair_id=4294967297",
                "UPDATE matches SET data=zeroblob(LENGTH(data)) WHERE pair_id=4294967297",
                "CREATE TABLE unexpected (id INTEGER)",
                "UPDATE matches SET pair_id=99999999999 WHERE pair_id=4294967297"]
            for statement in statements:
                shutil.copyfile(source, destination)
                with sqlite3.connect(destination) as db:
                    db.execute(statement)
                    db.commit()
                    db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                db.close()
                with self.subTest(statement=statement), self.assertRaises(CaptureError):
                    d3.validate_expansion(source, destination, expected, before, d3.database_tables(destination))

    def test_explicit_fallback_preserves_original_record_for_unmatched_camera(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d3-fallback-synthetic-") as directory:
            root = Path(directory)
            source, cached = fixture.synthetic_fixed_cohort(root)
            database = cached / "work/features.db"
            sparse_cache(database)
            # Synthetic input intentionally has no useful descriptor for image88.
            # The D3 run itself must preserve even this defective cached feature.
            with sqlite3.connect(database) as db:
                db.execute("UPDATE descriptors SET data=zeroblob(LENGTH(data)) WHERE image_id=88")
                db.commit()
                db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            db.close()
            expected_hash = d2.file_sha(database)
            output = root / "output"
            with redirect_stdout(io.StringIO()):
                code = d3.main(["--dataset", str(source), "--cached-sfm", str(cached), "--output", str(output),
                    "--max-seconds", "60", "--allow-original-pose-fallback", "--execute"])
            if code:
                self.fail((output / "sfm.log").read_text()[-3000:])
            report = d1.read_json(output / "sfm-report.json")
            self.assertEqual(len(report["registered_training_ids"]), 132)
            self.assertEqual(report["original_pose_fallback_ids"], [88])
            self.assertEqual(report["missing_from_selected_model_ids"], [88])
            self.assertEqual(report["unregistered_training_ids"], [88])
            self.assertEqual(report["observations_by_training_image"]["88"], 0)
            self.assertTrue(report["fallback_authorized"])
            before = d1.image_records(source / "sparse/0/images.bin")
            after = d1.image_records(output / "dataset/sparse/0/images.bin")
            self.assertEqual(before[88], after[88])
            self.assertEqual(d2.file_sha(database), expected_hash)

    def test_incomplete_existing_cache_rejected_before_matching(self):
        with tempfile.TemporaryDirectory(prefix="sfm-d3-incomplete-synthetic-") as directory:
            root = Path(directory)
            truth, source = fixture.synthetic(root)
            with sqlite3.connect(source) as db:
                db.execute("DELETE FROM matches WHERE pair_id=(SELECT MIN(pair_id) FROM matches)")
                db.commit()
                db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            db.close()
            with patch.object(fixture.p, "match_image_pairs") as match, self.assertRaisesRegex(CaptureError, "incomplete"):
                d3.expand_pairs(source, root / "expanded.db", root / "pairs.txt",
                                {i: im.name for i, im in truth.images.items()}, fixture.p)
            match.assert_not_called()

    def test_frozen_options_pair_cohort_plan_only_and_cpu_bounds(self):
        matching, verification = d3.matching_options(fixture.p)
        self.assertEqual(matching.todict(), fixture.p.FeatureMatchingOptions(num_threads=4, use_gpu=False).todict())
        expected = fixture.p.TwoViewGeometryOptions()
        expected.ransac.random_seed = 0
        expected.ransac.num_threads = 1
        self.assertEqual(verification.todict(), expected.todict())
        names = {i: f"{i:06d}.jpg" for i in range(1, 154) if (i - 1) % 8}
        pairs = d3.all_pairs(names)
        self.assertEqual(len(pairs), 8778)
        self.assertTrue(all(a < b and a in names and b in names for a, b in pairs))
        with tempfile.TemporaryDirectory(prefix="sfm-d3-plan-synthetic-") as directory:
            root = Path(directory)
            source, cached = fixture.synthetic_fixed_cohort(root)
            base = ["--dataset", str(source), "--cached-sfm", str(cached), "--output", str(root / "output")]
            with patch.object(fixture.p, "match_image_pairs") as match, redirect_stdout(io.StringIO()) as stdout:
                self.assertEqual(d3.main(base), 0)
            match.assert_not_called()
            self.assertFalse(json.loads(stdout.getvalue())["fallback_authorized"])
            self.assertFalse((root / "output").exists())
            for bound in ("0", "1801"):
                self.assertEqual(d3.main(base + ["--max-seconds", bound]), 1)


if __name__ == "__main__":
    unittest.main()
