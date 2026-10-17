#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("security_status", Path(__file__).with_name("dependency_security_status.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SecurityStatusTests(unittest.TestCase):
    def test_pull_request_requires_review(self):
        self.assertTrue(module.accepted("pull_request", "success", "success", "success"))
        for result in ["skipped", "failure", "cancelled", "timed_out", None, ""]:
            with self.subTest(result=result):
                self.assertFalse(module.accepted("pull_request", "success", "success", result))

    def test_non_pr_review_is_explicitly_skipped(self):
        for event in ["push", "schedule", "workflow_dispatch"]:
            self.assertTrue(module.accepted(event, "success", "success", "skipped"))
            for result in ["failure", "cancelled", None, ""]:
                self.assertFalse(module.accepted(event, "success", "success", result))

    def test_inventory_and_every_matrix_audit_must_succeed(self):
        for event, review in [("pull_request", "success"), ("push", "skipped")]:
            for result in ["skipped", "failure", "cancelled", "timed_out", None, ""]:
                self.assertFalse(module.accepted(event, result, "success", review))
                self.assertFalse(module.accepted(event, "success", result, review))

    def test_unknown_event_fails_closed(self):
        for event in [None, "", "pull_request_target", "other"]:
            self.assertFalse(module.accepted(event, "success", "success", "skipped"))


if __name__ == "__main__":
    unittest.main()
