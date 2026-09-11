"""Offline continuation gates: all Modal calls are strict synthetic mocks."""
from copy import deepcopy
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import Mock, patch

import modal_retry as retry
import modal_room as room


class RetryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.patch_root = patch.object(retry, 'PRIVATE_ROOT', self.root)
        self.patch_root.start(); self.addCleanup(self.patch_root.stop)
        self.prior, self.dataset = self.root/'prior', self.root/'dataset'
        self.prior.mkdir(); self.dataset.mkdir()
        self.marker = self.root/retry.ORIGINAL_MARKER
        room.save(self.marker, {'state': str(self.prior), 'status': 'rental_attempt_reserved', 'reserved_usd': '25.00'})
        room.save(self.prior/'provider-receipt.json', {'sandbox_id': retry.EXPECTED_PRIOR_SANDBOX,
                  'app_id': retry.EXPECTED_PRIOR_APP, 'outcome': 'failed'})
        room.save(self.prior/'provider-terminal-readback.json', {'sandbox_id': retry.EXPECTED_PRIOR_SANDBOX,
                  'exit_code': 137, 'actual_provider_report_usd': '1.09974939',
                  'explicit_remote_directory_deletion_confirmed': False})
        self.files = [{'path': f'images/{i:06d}.jpg', 'bytes': 3, 'sha256': 'a'*64} for i in range(153)]
        self.patch_inventory = patch.object(room, 'inventory', return_value=self.files)
        self.patch_inventory.start(); self.addCleanup(self.patch_inventory.stop)
        self.plan = self.root/'plan.json'
        room.save(self.plan, retry.prepare(self.dataset, self.prior))
        self.modal = Mock(); self.modal.__version__ = '1.5.3'
        self.modal.App.lookup.return_value = SimpleNamespace(app_id=retry.EXPECTED_PRIOR_APP)
        self.modal.Sandbox.list.return_value = []
        self.modal.Sandbox.from_id.return_value.poll.return_value = 137
        self.state = self.root/'fresh-state'

    def test_plan_retains_prior_cost_and_unconfirmed_deletion(self):
        value = json.loads(self.plan.read_text())
        self.assertEqual(value['prior_spent_usd'], '1.09974939')
        self.assertEqual(value['remaining_before_retry_usd'], '23.90025061')
        self.assertEqual(value['combined_prior_plus_fresh_bound_usd'], '6.0107829900')
        self.assertFalse(value['prior_remote_directory_deletion_confirmed'])
        self.assertEqual(value['allocation_eligibility'], 'unknown_until_one_create_attempt')

    def test_original_marker_preserved_and_second_call_cannot_allocate(self):
        before = self.marker.read_bytes()
        with patch.object(room, 'source_binding', return_value={}), patch.object(room, 'run') as run:
            retry.run_retry(self.modal, self.plan, self.state)
            run.assert_called_once_with(self.modal, self.dataset, self.state)
            with self.assertRaisesRegex(ValueError, 'already been attempted'):
                retry.run_retry(self.modal, self.plan, self.root/'second')
            run.assert_called_once()
        self.assertEqual(self.marker.read_bytes(), before)
        saved = json.loads((self.root/retry.RETRY_MARKER).read_text())
        self.assertEqual(saved['prior_spent_usd'], '1.09974939')
        self.assertEqual(saved['scoped_active_sandboxes_before_create'], 0)

    def test_changed_evidence_cannot_reach_provider(self):
        value = json.loads(self.plan.read_text()); value['prior_spent_usd'] = '0'
        room.save(self.plan, value)
        with self.assertRaisesRegex(ValueError, 'changed since review'):
            retry.run_retry(self.modal, self.plan, self.state)
        self.modal.App.lookup.assert_not_called()

    def test_active_sandbox_or_unconfirmed_old_termination_blocks_retry(self):
        for active, old_code in [([object()], 137), ([], None)]:
            with self.subTest(active=bool(active), old_code=old_code):
                self.modal.Sandbox.list.return_value = active
                self.modal.Sandbox.from_id.return_value.poll.return_value = old_code
                with patch.object(room, 'source_binding', return_value={}), patch.object(room, 'run') as run:
                    with self.assertRaises(ValueError):
                        retry.run_retry(self.modal, self.plan, self.state)
                    run.assert_not_called()
                self.assertFalse((self.root/retry.RETRY_MARKER).exists())

    def test_unknown_create_outcome_keeps_retry_marker(self):
        with patch.object(room, 'source_binding', return_value={}), patch.object(room, 'run', side_effect=TimeoutError()) as run:
            with self.assertRaises(TimeoutError):
                retry.run_retry(self.modal, self.plan, self.state)
            with self.assertRaisesRegex(ValueError, 'already been attempted'):
                retry.run_retry(self.modal, self.plan, self.state)
            run.assert_called_once()
        self.assertTrue((self.root/retry.RETRY_MARKER).exists())

    def test_wrong_capture_count_or_unreconciled_usage_cannot_plan(self):
        self.files.pop()
        with self.assertRaisesRegex(ValueError, '153-frame'):
            retry.prepare(self.dataset, self.prior)
        self.files.append({'path': 'images/000152.jpg', 'bytes': 3, 'sha256': 'a'*64})
        billing = json.loads((self.prior/'provider-terminal-readback.json').read_text())
        billing['actual_provider_report_usd'] = '0'
        room.save(self.prior/'provider-terminal-readback.json', billing)
        with self.assertRaisesRegex(ValueError, 'not reconciled'):
            retry.prepare(self.dataset, self.prior)


if __name__ == '__main__':
    unittest.main(verbosity=2)
