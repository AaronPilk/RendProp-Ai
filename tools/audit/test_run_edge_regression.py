"""The audit runner must distinguish executed, skipped and unloaded tests."""
import unittest
from run_edge_regression import summary_counts


class SummaryTests(unittest.TestCase):
    def test_test_name_ignored_is_not_a_skip(self):
        self.assertEqual(summary_counts("unknown fields are ignored ... ok\nok | 526 passed | 0 failed (932ms)\n"), (526, 0, 0))

    def test_real_skips_are_counted(self):
        self.assertEqual(summary_counts("ok | 524 passed | 0 failed | 2 ignored (1s)\n"), (524, 0, 2))

    def test_actual_failures_are_counted(self):
        self.assertEqual(summary_counts("FAILED | 7 passed | 3 failed (1s)\n"), (7, 3, 0))

    def test_loader_errors_are_not_test_execution(self):
        with self.assertRaises(RuntimeError):
            summary_counts("error: unexpected argument\n")

    def test_ambiguous_summaries_are_refused(self):
        with self.assertRaises(RuntimeError):
            summary_counts("ok | 1 passed | 0 failed\nok | 2 passed | 0 failed\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
