#!/usr/bin/env python3
"""Offline control-flow tests: every database command is mocked, never executed.

Run this file directly. --runner selects the actual runner source to review;
--source-ref loads a committed version for a negative-before control. These
checks do NOT execute SQL, prove PostgreSQL shutdown, or certify a hosted DB.
Small synthetic logs/receipts are retained in the printed temporary directory.
"""
import argparse
import contextlib
import hashlib
import io
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

NAMES = [
    'all three explicit Astra writing seats keep their 0030/0034 paid-plan gates',
    'no gpt-6-astra row is reachable on the free or trial tier',
    'plan_entitlements match paid plans and 0032 trial/free for every metered feature',
] + [f'synthetic invariant {n:03d}' for n in range(4, 199)]
PAID_MARKER = ('PASS: exact paid-plan predicates registered 6 expected outcomes across baseline '
               'and 2 negative fixtures; all mutations rolled back.')
TARGET = Path(__file__).with_name('run_database_regression.py')
SOURCE = None
EVIDENCE = None


def table(names=None, states=None, footer=None, ids=None):
    names = list(NAMES if names is None else names)
    states = ['t'] * len(names) if states is None else list(states)
    ids = list(range(1, len(names) + 1)) if ids is None else list(ids)
    if not (len(names) == len(states) == len(ids)):
        raise ValueError('Malformed synthetic fixture')
    lines = [f' {seq} | {name} | {state} | team' for seq, name, state in zip(ids, names, states)]
    failed = sum(state != 't' for state in states)
    if footer is None:
        footer = (f'ERROR: INVARIANTS FAILED: {failed} assertion(s)' if failed
                  else f'NOTICE: All {len(names)} invariants passed.')
    return '\n'.join(lines + [footer]) + '\n'


def subject_module():
    module = types.ModuleType('database_runner_under_test')
    module.__file__ = str(TARGET)
    # Actual reviewed source, with its __main__ entry point intentionally inert.
    # Fail closed if future source starts a subprocess while being imported.
    with patch.object(subprocess, 'Popen', side_effect=AssertionError('Import-time process spawn forbidden')), \
         patch.object(subprocess, 'run', side_effect=AssertionError('Import-time command forbidden')), \
         patch.object(subprocess, 'check_output', side_effect=AssertionError('Import-time command forbidden')):
        exec(compile(SOURCE, str(TARGET), 'exec'), module.__dict__)
    return module


class RunnerCase(unittest.TestCase):
    def invoke(self, **scenario):
        subject = subject_module()
        case = Path(tempfile.mkdtemp(prefix='case-', dir=EVIDENCE))
        calls = []
        invariant_count = 0
        prior = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGHUP)}
        disk_paths = []

        def disk(path):
            disk_paths.append(str(path))
            return types.SimpleNamespace(free=2 * 1024**3)

        def git(command, **kwargs):
            if command == ['git', 'status', '--porcelain']:
                return ' M synthetic-dirty-file\n' if scenario.get('dirty') else ''
            if command == ['git', 'rev-parse', 'HEAD']:
                return '0' * 40 + '\n'
            raise AssertionError(f'Unexpected subprocess.check_output: {command}')

        def fake(command, **kwargs):
            nonlocal invariant_count
            calls.append((list(command), dict(kwargs['env'])))
            self.assertTrue(command[0].startswith('/FAKE-NO-EXEC/'))
            self.assertEqual(kwargs['timeout'], 300)
            output, rc = '', 0
            sqlfile = Path(command[command.index('-f') + 1]).name if '-f' in command else None
            if '--version' in command:
                output = 'psql (synthetic mock, not an installed DB)\n'
            elif '-Atc' in command:
                output = scenario.get('identity', str(case / 'cluster') + '||rendprop_audit\n')
            elif sqlfile == 'ci-bootstrap.sql':
                if 'timeout' in scenario:
                    raise subprocess.TimeoutExpired(command, 300, output=scenario['timeout'])
                if 'signal' in scenario:
                    handler = signal.getsignal(scenario['signal'])
                    self.assertTrue(callable(handler), 'Runner did not install a scoped signal handler')
                    handler(scenario['signal'], None)  # no real OS signal is sent
                rc = scenario.get('bootstrap_exit', 0)
            elif sqlfile == 'invariants.sql':
                invariant_count += 1
                if invariant_count <= 2:
                    phase = 'initial' if invariant_count == 1 else 'replayed'
                    output, rc = scenario.get(phase, (table(), 0))
                else:
                    states = ['t'] * 198
                    states[2] = 'f'
                    output, rc = table(states=states), 3
            elif sqlfile == 'negative_astra_paid_gates.sql':
                output, rc = scenario.get('paid', (PAID_MARKER + '\n', 0))
            elif command[-1] == 'stop':
                if scenario.get('stop_timeout'):
                    raise subprocess.TimeoutExpired(command, 300, output=b'partial synthetic stop\n')
                if scenario.get('stale_pid'):
                    (case / 'cluster').mkdir()
                    (case / 'cluster/postmaster.pid').write_text('synthetic-not-a-real-pid\n')
                rc = scenario.get('stop_exit', 0)
            elif (command[0].endswith('/initdb') or command[0].endswith('/createdb')
                  or command[-1] == 'start' or sqlfile is not None or '-c' in command):
                pass  # synthetic migration/create/update acknowledgements only
            else:
                raise AssertionError(f'Unexpected database command: {command}')
            return subprocess.CompletedProcess(command, rc, stdout=output)

        failure = None
        with patch.object(subject.shutil, 'which', side_effect=lambda name: '/FAKE-NO-EXEC/' + name), \
             patch.object(subject.shutil, 'disk_usage', side_effect=disk), \
             patch.object(subject.tempfile, 'mkdtemp', return_value=str(case)), \
             patch.object(subject.subprocess, 'check_output', side_effect=git), \
             patch.object(subject.subprocess, 'run', side_effect=fake), \
             patch.object(subject.subprocess, 'Popen', side_effect=AssertionError('Unmocked process spawn forbidden')), \
             contextlib.redirect_stdout(io.StringIO()):
            try:
                subject.main()
            except BaseException as error:
                failure = error
        for sig, handler in prior.items():
            self.assertEqual(signal.getsignal(sig), handler, 'Signal handler leaked out of main')
        receipt_file = case / 'receipt.json'
        receipt = json.loads(receipt_file.read_text()) if receipt_file.exists() else None
        return types.SimpleNamespace(case=case, failure=failure, calls=calls,
                                     receipt=receipt, disk_paths=disk_paths)

    def rejected(self, **scenario):
        result = self.invoke(**scenario)
        self.assertIsNotNone(result.failure, 'Fault was accepted')
        self.assertIsNotNone(result.receipt, 'Failure receipt missing')
        self.assertFalse(result.receipt['accepted'])
        self.assertIn('finishedAt', result.receipt)
        return result


class CoreRegressionTests(RunnerCase):
    def test_shortened_inventory_rejected(self):
        result = self.invoke(initial=(table(names=NAMES[:1]), 0),
                             replayed=(table(names=NAMES[:1]), 0))
        self.assertIsNotNone(result.receipt)
        self.assertFalse(result.receipt['accepted'], 'FALSE GREEN: shortened suite accepted')
        self.assertIsNotNone(result.failure)

    def test_stop_failure_receipt_preserved(self):
        result = self.invoke(stop_exit=1)
        self.assertIsNotNone(result.failure)
        self.assertIsNotNone(result.receipt, 'Stop failure suppressed the entire receipt')
        self.assertFalse(result.receipt['accepted'])
        self.assertIn('cleanupFailure', result.receipt)

    def test_timeout_command_and_partial_output_preserved(self):
        result = self.invoke(timeout=b'partial synthetic bootstrap\n')
        self.assertIsNotNone(result.failure)
        self.assertIsNotNone(result.receipt)
        commands = {row['name']: row for row in result.receipt['commands']}
        self.assertIn('bootstrap', commands, 'Timed-out command lost from receipt')
        self.assertTrue(commands['bootstrap']['timedOut'])
        self.assertIsNone(commands['bootstrap']['exit'])
        log = Path(commands['bootstrap']['log'])
        self.assertEqual(log.read_text(), 'partial synthetic bootstrap\n')
        self.assertEqual(hashlib.sha256(log.read_bytes()).hexdigest(), commands['bootstrap']['logSHA256'])
        self.assertFalse(result.receipt['accepted'])


class InventoryTests(RunnerCase):
    def test_full_198_suite_accepts(self):
        result = self.invoke()
        self.assertIsNone(result.failure)
        self.assertTrue(result.receipt['accepted'])
        self.assertTrue(result.receipt['clusterStopped'])
        self.assertEqual([row['count'] for row in result.receipt['invariantRuns']], [198, 198])
        self.assertEqual(result.receipt['invariantRuns'][0]['names'], NAMES)

    def test_197_and_199_counts_reject(self):
        for names in (NAMES[:-1], NAMES + ['extra synthetic assertion']):
            with self.subTest(count=len(names)):
                self.rejected(initial=(table(names=names), 0))

    def test_noncontiguous_sequence_rejects(self):
        self.rejected(initial=(table(ids=list(range(1, 198)) + [199]), 0))

    def test_duplicate_name_rejects(self):
        self.rejected(initial=(table(names=NAMES[:-1] + [NAMES[-2]]), 0))

    def test_each_required_name_rejects_when_absent(self):
        for index in range(3):
            names = NAMES.copy()
            names[index] = 'replacement synthetic assertion'
            with self.subTest(index=index):
                self.rejected(initial=(table(names=names), 0))

    def test_null_result_is_retained_as_real_red(self):
        states = ['t'] * 198
        states[-1] = ''
        result = self.rejected(initial=(table(states=states), 3), replayed=(table(states=states), 3))
        self.assertEqual(len(result.receipt['invariantRuns']), 2)
        self.assertEqual(result.receipt['invariantRuns'][0]['failed'], [NAMES[-1]])
        self.assertIn('paidGateNegativeControl', result.receipt)

    def test_null_with_green_exit_and_footer_rejects(self):
        states = ['t'] * 198
        states[-1] = ''
        self.rejected(initial=(table(states=states, footer='All 198 invariants passed.'), 0))

    def test_false_result_with_zero_exit_rejects(self):
        states = ['t'] * 198
        states[-1] = 'f'
        self.rejected(initial=(table(states=states), 0))

    def test_passing_table_with_error_exit_rejects(self):
        for code in (1, 2, 3):
            with self.subTest(exit=code):
                self.rejected(initial=(table(), code))

    def test_failure_footer_count_mismatch_rejects(self):
        states = ['t'] * 198
        states[-1] = 'f'
        self.rejected(initial=(table(states=states, footer='INVARIANTS FAILED: 2 assertion(s)'), 3))

    def test_missing_success_footer_rejects(self):
        self.rejected(initial=(table(footer=''), 0))

    def test_same_count_changed_replay_identity_rejects(self):
        self.rejected(replayed=(table(names=NAMES[:-1] + ['renamed synthetic assertion']), 0))

    def test_same_names_changed_replay_order_rejects(self):
        self.rejected(replayed=(table(names=NAMES[:-2] + [NAMES[-1], NAMES[-2]]), 0))


class EvidenceTests(RunnerCase):
    def test_stop_timeout_retains_receipt(self):
        result = self.rejected(stop_timeout=True)
        self.assertIn('cleanupFailure', result.receipt)
        stop = result.receipt['commands'][-1]
        self.assertEqual(stop['name'], 'stop')
        self.assertTrue(stop['timedOut'])
        self.assertEqual(Path(stop['log']).read_text(), 'partial synthetic stop\n')

    def test_both_original_and_cleanup_failures_retained(self):
        result = self.rejected(bootstrap_exit=1, stop_exit=1)
        self.assertIn('bootstrap exited 1', result.receipt['failure'])
        self.assertIn('stop exited 1', result.receipt['cleanupFailure'])

    def test_stale_pid_prevents_accepted_receipt(self):
        result = self.rejected(stale_pid=True)
        self.assertFalse(result.receipt['clusterStopped'])
        self.assertIn('cleanupFailure', result.receipt)

    def test_sigterm_and_sighup_handlers_cleanup_and_restore(self):
        for sig in (signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=sig):
                result = self.rejected(signal=sig)
                self.assertIn('Audit interrupted by signal', result.receipt['failure'])
                self.assertEqual(result.receipt['commands'][-1]['name'], 'stop')

    def test_text_and_empty_timeout_output_are_recorded(self):
        for partial in ('text partial\n', None):
            with self.subTest(partial=partial):
                result = self.rejected(timeout=partial)
                row = next(row for row in result.receipt['commands'] if row['name'] == 'bootstrap')
                self.assertEqual(Path(row['log']).read_text(), partial or '')

    def test_missing_paid_fixture_marker_rejects(self):
        self.rejected(paid=('ROLLBACK\n', 0))

    def test_paid_marker_cannot_override_nonzero_exit(self):
        self.rejected(paid=(PAID_MARKER + '\n', 3))

    def test_dirty_source_refuses_before_database_commands(self):
        result = self.invoke(dirty=True)
        self.assertIsNotNone(result.failure)
        self.assertEqual(result.calls, [])

    def test_identity_mismatch_refuses_before_bootstrap(self):
        result = self.rejected(identity='/not-the-owned-cluster||rendprop_audit\n')
        self.assertNotIn('bootstrap', [row['name'] for row in result.receipt['commands']])

    def test_all_sql_and_runner_bytes_are_hashed(self):
        result = self.invoke()
        self.assertIsNone(result.failure)
        hashes = result.receipt['sourceHashes']
        root = TARGET.parents[2]
        for path in [TARGET, *sorted((root / 'services/supabase/tests').glob('*.sql'))]:
            self.assertEqual(hashes[str(path.relative_to(root))], hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertEqual(result.receipt['paidGateNegativeControl'],
                         {'outcomes': 6, 'fixtures': 2, 'rolledBack': True})

    def test_evidence_disk_and_connection_environment_are_scoped(self):
        result = self.invoke()
        self.assertIsNone(result.failure)
        self.assertEqual(result.disk_paths, ['/tmp'])
        for command, env in result.calls:
            self.assertTrue(set(env).issubset({'PATH', 'LC_ALL', 'TZ', 'PGOPTIONS'}))
            if '-h' in command:
                self.assertEqual(command[command.index('-h') + 1], str(result.case / 'socket'))
                self.assertIn('--no-password', command)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--runner', type=Path, default=TARGET)
    parser.add_argument('--source-ref')
    args, remaining = parser.parse_known_args()
    TARGET = args.runner.resolve(strict=True)
    SOURCE = (subprocess.check_output(['git', 'show', args.source_ref + ':tools/audit/run_database_regression.py'],
                                    cwd=TARGET.parents[2], text=True)
              if args.source_ref else TARGET.read_text())
    EVIDENCE = Path(tempfile.mkdtemp(prefix='rendprop-db-runner-tests-', dir='/tmp'))
    print('SOURCE_SHA256:', hashlib.sha256(SOURCE.encode()).hexdigest(), flush=True)
    print('SOURCE_REF:', args.source_ref or 'actual file bytes', flush=True)
    print('EVIDENCE:', EVIDENCE, flush=True)
    program = unittest.main(argv=[sys.argv[0], *remaining], verbosity=2, exit=False)
    if program.result.testsRun == 0 or program.result.skipped:
        print('FAIL: this gate requires at least one test and zero skips', flush=True)
        sys.exit(1)
    sys.exit(0 if program.result.wasSuccessful() else 1)
