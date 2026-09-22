from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from provider_journal import APP_NAME, ProviderJournal, sandbox_name
from test_worker import LEASE_ID, job
from worker import JobFailure


class JournalTests(unittest.TestCase):
    def test_no_allocation_receipt_carries_the_lease_only_provider_name(self):
        j = job(); api = Mock()
        api.job_call.return_value = {"ok": True, "job_id": j["id"], "lease_token": j["lease_token"],
            "attempt_key": j["attempt_key"], "allocation_state": "not_created", "files_removed": True, "terminated": True}
        ProviderJournal(SimpleNamespace(api=api), j).no_allocation()
        data = api.job_call.call_args.kwargs["data"]
        # Same bytes the DB check constraint and the CREATE request use.
        self.assertEqual(data["sandbox_name"], "spatial-" + LEASE_ID)
        self.assertEqual(data["app_name"], APP_NAME)
        self.assertLessEqual(len(data["sandbox_name"]), 64)

    def test_provider_name_needs_the_canonical_lease_token_the_db_keys_on(self):
        # Uppercase and non-uuid tokens would pass Modal's character rule but
        # can never equal the uuid-derived name the 0041 constraint requires.
        for token in ("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", LEASE_ID + "-" + "3" * 24, "not/a token", "", None):
            with self.subTest(token=token):
                with self.assertRaisesRegex(JobFailure, "invalid_sandbox_name"):
                    sandbox_name({"lease_token": token})

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
