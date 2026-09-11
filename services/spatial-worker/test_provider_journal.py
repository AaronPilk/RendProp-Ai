from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from provider_journal import ProviderJournal
from test_worker import job
from worker import JobFailure


class JournalTests(unittest.TestCase):
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
