from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from provider_journal import ProviderJournal
from test_worker import job
from worker import JobFailure


class JournalTests(unittest.TestCase):
    def test_no_allocation_requires_explicit_atomic_absence_not_an_existing_unknown(self):
        j = job(); api = Mock()
        api.job_call.return_value = {"ok": True, "job_id": j["id"], "lease_token": j["lease_token"],
            "attempt_key": j["attempt_key"], "allocation_state": "unknown", "files_removed": False, "terminated": False}
        journal = ProviderJournal(SimpleNamespace(api=api), j)
        with self.assertRaisesRegex(JobFailure, "provider_no_allocation_unconfirmed"):
            journal.no_allocation()
        api.job_call.return_value.update(allocation_state="not_created", files_removed=True, terminated=True)
        journal.no_allocation()

    def test_monotonic_cleanup_accepts_stronger_proof_but_never_loses_true(self):
        j = job()
        api = Mock()
        reply = {"ok": True, "job_id": j["id"], "lease_token": j["lease_token"],
                 "attempt_key": j["attempt_key"], "files_removed": True, "terminated": True}
        api.job_call.return_value = reply
        journal = ProviderJournal(SimpleNamespace(api=api), j)
        journal.cleanup({"private_files_removed": False, "terminated": False})
        reply["files_removed"] = False
        with self.assertRaisesRegex(JobFailure, "provider_cleanup_receipt_unconfirmed"):
            journal.cleanup({"private_files_removed": True, "terminated": True})
        reply["files_removed"] = "true"
        with self.assertRaisesRegex(JobFailure, "provider_cleanup_receipt_unconfirmed"):
            journal.cleanup({"private_files_removed": False, "terminated": False})


if __name__ == '__main__':
    unittest.main(verbosity=2)
