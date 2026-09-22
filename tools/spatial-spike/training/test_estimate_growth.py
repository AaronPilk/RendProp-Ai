"""Hermetic arithmetic/CLI regressions; no gsplat/CUDA execution or quality proof."""

import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest

from estimate_growth import (
    DISCLAIMER, GSPLAT_COMMIT, GrowthInputError, _refines_at, estimate_growth, main,
)
from prepare_capture import GSPLAT_COMMIT as ADAPTER_COMMIT
from run_training import training_command


class HostileInteger(int):
    def __mul__(self, other):
        raise AssertionError("unvalidated arithmetic")


class GrowthPlanningTests(unittest.TestCase):
    def test_source_pin_and_wrapper_assumptions_match(self):
        self.assertEqual(GSPLAT_COMMIT, ADAPTER_COMMIT)
        command = training_command("python", "gsplat", "dataset", "output", 3000, 500000)
        self.assertIn("mcmc", command)
        self.assertEqual(command[command.index("--init-type") + 1], "sfm")
        self.assertNotIn("--steps-scaler", command)
        for option in ("--max-steps", "--save-steps", "--ply-steps"):
            self.assertEqual(command[command.index(option) + 1], "3000")
        result = estimate_growth(100)
        self.assertEqual(result["interpretation"], DISCLAIMER)
        self.assertEqual(result["status"], "provisional_offline_arithmetic_only")
        self.assertEqual(result["assumptions"]["steps_scaler"], 1.0)
        for url in result["sources"].values():
            self.assertIn(GSPLAT_COMMIT, url)

    def test_exact_refinement_start_stop_and_period(self):
        # Stop is beyond the current 7000-step runner limit: test the fixed
        # predicate directly, without authorizing a longer run via the API.
        for step, expected in ((0, False), (499, False), (500, False),
                               (501, False), (599, False), (600, True),
                               (601, False), (24900, True), (24999, False),
                               (25000, False), (25100, False)):
            with self.subTest(step=step):
                self.assertEqual(_refines_at(step), expected)

    def test_first_refinement_happens_after_final_save_at_601_steps(self):
        for steps in (1, 500, 501, 600):
            with self.subTest(steps=steps):
                result = estimate_growth(100, steps)
                self.assertEqual(result["refinement_events"], 0)
                self.assertEqual(result["training_peak_gaussians_upper_bound"], 100)
                self.assertEqual(result["final_artifact_gaussians_upper_bound"], 100)
        result = estimate_growth(100, 601)
        self.assertEqual(result["refinement_events"], 1)
        self.assertEqual(result["final_artifact_refinement_events"], 0)
        self.assertEqual(result["training_peak_gaussians_upper_bound"], 105)
        self.assertEqual(result["final_artifact_gaussians_upper_bound"], 100)
        self.assertEqual(result["final_artifact_step_zero_based"], 600)
        self.assertEqual(estimate_growth(100, 602)["final_artifact_gaussians_upper_bound"], 105)

    def test_24_events_seed_examples_use_repeated_truncation(self):
        for seeds, expected in ((100, 302), (1000, 3204), (10000, 32230)):
            with self.subTest(seeds=seeds):
                result = estimate_growth(seeds, 3000, 500000)
                self.assertEqual(result["refinement_events"], 24)
                self.assertEqual(result["effective_growth_events"], 24)
                self.assertEqual(result["final_artifact_refinement_events"], 24)
                self.assertEqual(result["training_peak_gaussians_upper_bound"], expected)
                self.assertEqual(result["final_artifact_gaussians_upper_bound"], expected)
                self.assertEqual([e["step_zero_based"] for e in result["events"]],
                                 list(range(600, 3000, 100)))
        # Flooring only at the end would incorrectly give 322 for 100 seeds.
        self.assertNotEqual(estimate_growth(100)["training_peak_gaussians_upper_bound"],
                            int(100 * 1.05 ** 24))

    def test_final_iteration_order_applies_at_later_boundary(self):
        result = estimate_growth(100, 2901)
        self.assertEqual(result["refinement_events"], 24)
        self.assertEqual(result["final_artifact_refinement_events"], 23)
        self.assertEqual(result["final_artifact_gaussians_upper_bound"], 288)
        self.assertEqual(result["training_peak_gaussians_upper_bound"], 302)

    def test_cap_can_truncate_an_addition_or_prevent_all_growth(self):
        result = estimate_growth(100, 3000, 110)
        self.assertEqual([e["after_upper_bound"] for e in result["events"][:3]], [105, 110, 110])
        self.assertEqual(result["effective_growth_events"], 2)
        self.assertEqual(result["training_peak_gaussians_upper_bound"], 110)
        self.assertEqual(estimate_growth(100, 602, 103)["final_artifact_gaussians_upper_bound"], 103)
        for cap in (100, 500000):
            with self.subTest(cap=cap):
                result = estimate_growth(cap, 7000, cap)
                self.assertEqual(result["refinement_events"], 64)
                self.assertEqual(result["effective_growth_events"], 0)
                self.assertEqual(result["training_peak_gaussians_upper_bound"], cap)
                self.assertTrue(all(e["added_upper_bound"] == 0 for e in result["events"]))

    def test_count_bounds_and_timeline_hold_at_maximum_steps(self):
        for seeds, cap in ((100, 500000), (499999, 500000), (10000, 12345)):
            with self.subTest(seeds=seeds, cap=cap):
                result = estimate_growth(seeds, 7000, cap)
                self.assertEqual(result["refinement_events"], 64)
                self.assertEqual(result["events"][-1]["step_zero_based"], 6900)
                previous = seeds
                for event in result["events"]:
                    self.assertEqual(event["before"], previous)
                    self.assertLessEqual(previous, event["after_upper_bound"])
                    self.assertLessEqual(event["after_upper_bound"], cap)
                    self.assertEqual(event["added_upper_bound"], event["after_upper_bound"] - previous)
                    previous = event["after_upper_bound"]

    def test_invalid_bounds_and_seed_over_cap_fail(self):
        cases = ((99, 3000, 500000), (500001, 3000, 500000),
                 (100, 0, 500000), (100, -1, 500000), (100, 7001, 500000),
                 (100, 3000, 99), (100, 3000, 500001), (101, 3000, 100),
                 (10 ** 1000, 3000, 500000), (100, 10 ** 1000, 500000))
        for values in cases:
            with self.subTest(values=values), self.assertRaises(GrowthInputError):
                estimate_growth(*values)

    def test_hostile_types_fail_before_arithmetic(self):
        for value in (True, False, 100.0, float("nan"), float("inf"),
                      -float("inf"), "100", None, [], {}, HostileInteger(100)):
            for index in range(3):
                args = [100, 3000, 500000]
                args[index] = value
                with self.subTest(value=value, index=index), self.assertRaises(GrowthInputError):
                    estimate_growth(*args)

    def test_invalid_cli_inputs_return_one_without_json_success(self):
        for argv in ([], ["--initial-seeds", "99"], ["--initial-seeds", "nan"],
                     ["--initial-seeds", "inf"], ["--initial-seeds", "100.0"],
                     ["--initial-seeds", "9" * 1000], ["--initial-seeds", "١٠٠"],
                     ["--initial-seeds", "100", "--max-steps", "7001"],
                     ["--initial-seeds", "100", "--max-gaussians", "99"],
                     ["--initial-seeds", "100", "--unknown"], ["--initial", "100"]):
            stdout, stderr = io.StringIO(), io.StringIO()
            with self.subTest(argv=argv), contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                self.assertEqual(main(argv), 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertTrue(stderr.getvalue().startswith("FAIL:"))

    def test_real_cli_exit_codes_and_optimized_python(self):
        script = str(Path(__file__).with_name("estimate_growth.py"))
        for options in ([], ["-O"]):
            with self.subTest(options=options):
                invalid = subprocess.run([sys.executable, *options, script, "--initial-seeds", "99"],
                                         capture_output=True, text=True, timeout=5)
                self.assertEqual(invalid.returncode, 1)
                self.assertEqual(invalid.stdout, "")
                self.assertIn("FAIL:", invalid.stderr)
                valid = subprocess.run([sys.executable, *options, script, "--initial-seeds", "1000"],
                                       capture_output=True, text=True, timeout=5)
                self.assertEqual(valid.returncode, 0, valid.stderr)
                result = json.loads(valid.stdout)
                self.assertEqual(result["final_artifact_gaussians_upper_bound"], 3204)
                self.assertEqual(result["interpretation"], DISCLAIMER)


if __name__ == "__main__":
    unittest.main()
