#!/usr/bin/env python3
"""Closed helper controls only: no browser, codec, Git, network or subprocess."""
from pathlib import Path
import runpy
import unittest

API = runpy.run_path(str(Path(__file__).with_name("hosted_proof.py")), run_name="closed_controls")


def valid_receipt():
    return {"status": "prototype-case-passed", "partialSuite": True, "sourceBoundAtEnd": True,
            "externalRequests": [], "errors": [], "audioOutput": {"mode": "default-device"},
            "dependencyTreeBefore": "same-pin", "dependencyTreeAfter": "same-pin",
            "webCodecs": {"requested": 90, "encoded": [{}] * 90, "finalized": True, "failed": False},
            "frameTimes": list(range(90)), "proofDownloads": 1, "mutedSourceConfirmed": True}


class ClosedControls(unittest.TestCase):
    def test_receipt_accepts_only_explicit_partial_success(self):
        API["check_receipt"](valid_receipt())
        for field, value in (("partialSuite", False), ("sourceBoundAtEnd", False),
                             ("externalRequests", ["unexpected"]), ("proofDownloads", 0),
                             ("mutedSourceConfirmed", False), ("frameTimes", []),
                             ("dependencyTreeAfter", "changed")):
            receipt = valid_receipt()
            receipt[field] = value
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                API["check_receipt"](receipt)

    def test_receipt_refuses_incomplete_actual_encoded_evidence(self):
        for field, value in (("requested", 89), ("encoded", [{}] * 89),
                             ("finalized", False), ("failed", True)):
            receipt = valid_receipt()
            receipt["webCodecs"][field] = value
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                API["check_receipt"](receipt)

    def test_separate_evidence_cannot_overlap_either_checkout(self):
        for base in ("/shipping", "/shipping/evidence", "/payload", "/payload/output", "/"):
            with self.subTest(base=base), self.assertRaises(RuntimeError):
                API["assert_separate"](Path(base), Path("/shipping"), Path("/payload"))
        API["assert_separate"](Path("/runner-temp/proof"), Path("/shipping"), Path("/payload"))

    def test_owned_process_selection_excludes_unrelated_browser(self):
        table = {10: {"ppid": 1, "identity": "node A"},
                 11: {"ppid": 10, "identity": "chrome A"},
                 12: {"ppid": 11, "identity": "renderer A"},
                 20: {"ppid": 1, "identity": "unrelated chrome"}}
        self.assertEqual(API["descendant_identities"](table, 10),
                         {10: "node A", 11: "chrome A", 12: "renderer A"})

    def test_timeout_signals_only_original_owned_identities(self):
        namespace = API["stop_owned_tree"].__globals__
        original_table = namespace["process_table"]
        original_kill = namespace["os"].kill
        tables = [{10: {"ppid": 1, "identity": "node A"},
                   11: {"ppid": 10, "identity": "chrome A"}},
                  {10: {"ppid": 1, "identity": "node A"},
                   11: {"ppid": 1, "identity": "reused PID B"}},
                  {10: {"ppid": 1, "identity": "node A"},
                   11: {"ppid": 1, "identity": "reused PID B"}}]
        observed = []
        class Child:
            pid = 10
            def wait(self, timeout):
                return 1
        try:
            namespace["process_table"] = lambda: tables.pop(0)
            namespace["os"].kill = lambda pid, sig: observed.append((pid, sig))
            journal = {}
            API["stop_owned_tree"](Child(), journal)
        finally:
            namespace["process_table"] = original_table
            namespace["os"].kill = original_kill
        self.assertEqual(journal["timeoutOwnedPids"], [10, 11])
        self.assertEqual([pid for pid, _ in observed], [10, 10])


if __name__ == "__main__":
    unittest.main()
