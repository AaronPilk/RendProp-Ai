#!/usr/bin/env python3
"""Closed-fixture checks for the CI setup retries (no simulator, no network).

Covers simulator warm-up, clip-frame SDK discovery, and apt retry: transient setup
faults are retried a fixed number of times, exhausted retries fail and are
labelled as infrastructure, and nothing malformed or unverified is accepted.
"""
import ast
import importlib.util
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('warm_simulator', ROOT / 'tools/ci/warm-simulator.py')
warm_simulator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(warm_simulator)

# Extract the pure setup helper without importing the AVFoundation harness,
# whose module intentionally runs the actual simulator proof at top level.
clip_source = ROOT / 'apps/ios/tests/run-clip-frames.py'
clip_tree = ast.parse(clip_source.read_text())
clip_helper = next(node for node in clip_tree.body
                   if isinstance(node, ast.FunctionDef) and node.name == 'discover_sdk')
clip_namespace = {'subprocess': subprocess}
exec(compile(ast.Module(body=[clip_helper], type_ignores=[]), str(clip_source), 'exec'), clip_namespace)
discover_sdk = clip_namespace['discover_sdk']

UDID = '11111111-2222-3333-4444-555555555555'


def inventory(state='Shutdown', kind='iPhone-17-Pro'):
    return json.dumps({'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-4': [{
        'udid': UDID, 'name': 'iPhone', 'state': state, 'isAvailable': True,
        'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.' + kind}]}})


class Done:
    def __init__(self, returncode=0, stdout='', stderr=''):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


class WarmSimulator(unittest.TestCase):
    def run_warm(self, answers):
        """answers: per-call Done, or 'timeout'. Returns (receipt|error, calls, sleeps)."""
        calls, sleeps, queue = [], [], list(answers)

        def execute(argv, **kwargs):
            calls.append((argv[2], kwargs['timeout']))
            answer = queue.pop(0)
            if answer == 'timeout':
                raise subprocess.TimeoutExpired(argv, kwargs['timeout'])
            return answer

        with tempfile.TemporaryDirectory() as out:
            try:
                result = warm_simulator.warm(out, execute=execute, sleep=sleeps.append)
            except Exception as error:
                result = error
            saved = json.loads((Path(out) / 'receipt.json').read_text())
        return result, calls, sleeps, saved

    def test_cold_start_is_absorbed_then_one_kernel_boots(self):
        result, calls, sleeps, saved = self.run_warm(
            ['timeout', Done(1, stderr='CoreSimulatorService connection became invalid'),
             Done(0, inventory()), Done(0), Done(0)])
        self.assertTrue(result['passed'] and saved['passed'])
        self.assertEqual(calls, [('list', 120), ('list', 180), ('list', 240), ('boot', 120), ('bootstatus', 300)])
        self.assertEqual(sleeps, [10, 20])
        self.assertEqual(result['device']['udid'], UDID)

    def test_already_booted_kernel_is_reused_without_boot(self):
        result, calls, _, _ = self.run_warm([Done(0, inventory('Booted'))])
        self.assertTrue(result['passed'])
        self.assertEqual(calls, [('list', 120)])

    def test_inventory_never_answering_is_a_bounded_infrastructure_miss(self):
        result, calls, sleeps, saved = self.run_warm(['timeout', 'timeout', 'timeout'])
        self.assertIsInstance(result, warm_simulator.InfrastructureMiss)
        self.assertEqual(len(calls), 3)
        self.assertEqual(sleeps, [10, 20])
        self.assertTrue(saved['infrastructureMiss'] and not saved['passed'])

    def test_boot_that_never_finishes_is_a_bounded_infrastructure_miss(self):
        result, calls, _, saved = self.run_warm([Done(0, inventory()), Done(0), 'timeout', Done(1)])
        self.assertIsInstance(result, warm_simulator.InfrastructureMiss)
        self.assertEqual([c[0] for c in calls], ['list', 'boot', 'bootstatus', 'bootstatus'])
        self.assertFalse(saved['passed'])

    def test_malformed_successful_inventory_is_refused_not_retried(self):
        result, calls, _, saved = self.run_warm([Done(0, 'not json')])
        self.assertNotIsInstance(result, (dict, warm_simulator.InfrastructureMiss))
        self.assertEqual(len(calls), 1)
        self.assertFalse(saved['infrastructureMiss'])

    def test_image_without_an_iphone_kernel_fails(self):
        result, _, _, _ = self.run_warm([Done(0, inventory(kind='iPad-Pro'))])
        self.assertIsInstance(result, warm_simulator.InfrastructureMiss)


class ClipFramesSDKDiscovery(unittest.TestCase):
    def test_first_timeout_retries_once_with_separate_bounded_deadline(self):
        calls, attempts = [], []
        def run(name, argv, deadline):
            calls.append((name, tuple(argv), deadline))
            if len(calls) == 1:
                raise subprocess.TimeoutExpired(argv, deadline, output=b'first partial output')
            return Done(stdout='/Applications/Xcode.app/SDKs/iPhoneSimulator.sdk\n')
        with tempfile.TemporaryDirectory() as folder:
            sdk = discover_sdk(run, Path(folder), attempts)
            self.assertEqual((Path(folder) / 'sdk-timeout.log').read_text(), 'first partial output')
        self.assertEqual(sdk, '/Applications/Xcode.app/SDKs/iPhoneSimulator.sdk')
        self.assertEqual([(name, deadline) for name, _, deadline in calls], [('sdk', 30), ('sdk-retry', 90)])
        self.assertEqual(attempts, [{'name': 'sdk', 'deadlineSeconds': 30, 'timedOut': True},
                                    {'name': 'sdk-retry', 'deadlineSeconds': 90, 'exitCode': 0}])

    def test_non_timeout_refusal_is_terminal(self):
        calls, attempts = [], []
        def run(name, argv, deadline):
            calls.append(name)
            raise AssertionError('xcrun returned nonzero')
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(AssertionError, 'nonzero'):
                discover_sdk(run, Path(folder), attempts)
        self.assertEqual(calls, ['sdk'])
        self.assertEqual(attempts, [])

    def test_second_timeout_is_terminal_and_recorded(self):
        calls, attempts = [], []
        def run(name, argv, deadline):
            calls.append((name, deadline))
            raise subprocess.TimeoutExpired(argv, deadline, stderr=b'partial setup diagnostic')
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(subprocess.TimeoutExpired):
                discover_sdk(run, Path(folder), attempts)
            self.assertEqual((Path(folder) / 'sdk-timeout.log').read_text(), 'partial setup diagnostic')
            self.assertEqual((Path(folder) / 'sdk-retry-timeout.log').read_text(), 'partial setup diagnostic')
        self.assertEqual(calls, [('sdk', 30), ('sdk-retry', 90)])
        self.assertEqual(attempts, [{'name': 'sdk', 'deadlineSeconds': 30, 'timedOut': True},
                                    {'name': 'sdk-retry', 'deadlineSeconds': 90, 'timedOut': True}])


class AptRetry(unittest.TestCase):
    def run_script(self, update_exits, install_exits, arguments=('postgresql-17',)):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            log = temp / 'calls.log'
            (temp / 'update').write_text(' '.join(map(str, update_exits)))
            (temp / 'install').write_text(' '.join(map(str, install_exits)))
            stubs = {
                # Pops the next scripted exit code for `apt-get update|install`.
                'apt-get': '#!/usr/bin/env bash\nmode=$1\necho "apt-get $*" >> "$LOG"\n'
                           'read -r first rest < "$STATE/$mode" || true\necho "$rest" > "$STATE/$mode"\nexit "${first:-0}"\n',
                'timeout': '#!/usr/bin/env bash\nshift\nexec "$@"\n',
                'find': '#!/usr/bin/env bash\necho "find $*" >> "$LOG"\n',
                'nap': '#!/usr/bin/env bash\necho "sleep $*" >> "$LOG"\n',
            }
            for name, body in stubs.items():
                path = temp / name
                path.write_text(body)
                path.chmod(path.stat().st_mode | stat.S_IEXEC)
            env = dict(os.environ, PATH=f'{temp}:{os.environ["PATH"]}', LOG=str(log), STATE=str(temp),
                       APT_RETRY_ELEVATE='', APT_RETRY_SLEEP='nap')
            result = subprocess.run(['bash', str(ROOT / 'tools/ci/apt-retry.sh'), *arguments],
                                    capture_output=True, text=True, env=env, timeout=30)
            return result, log.read_text().splitlines() if log.exists() else []

    def test_index_mismatch_is_retried_after_clearing_lists(self):
        result, calls = self.run_script([100, 0], [0])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        kinds = [c.split()[0] + ' ' + c.split()[1] for c in calls]
        self.assertEqual(kinds, ['apt-get update', 'find /var/lib/apt/lists', 'sleep 10',
                                 'apt-get update', 'apt-get install'])
        self.assertIn('Package mirror retry', result.stdout)

    def test_failed_install_refreshes_indexes_before_retrying(self):
        result, calls = self.run_script([0, 0], [100, 0])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(sum(c.startswith('apt-get update') for c in calls), 2)
        self.assertEqual(sum(c.startswith('apt-get install') for c in calls), 2)

    def test_exhausted_attempts_fail_and_are_labelled_infrastructure(self):
        result, calls = self.run_script([100, 100, 100, 100], [])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(sum(c.startswith('apt-get update') for c in calls), 4)
        self.assertEqual([c for c in calls if c.startswith('sleep')], ['sleep 10', 'sleep 30', 'sleep 60'])
        self.assertIn('::error title=Infrastructure miss (package mirror)::', result.stdout)
        self.assertFalse(any(c.startswith('apt-get install') for c in calls))

    def test_verification_is_never_relaxed(self):
        for option in ('--allow-unauthenticated', '--allow-insecure-repositories',
                       '-oAcquire::AllowInsecureRepositories=true'):
            result, calls = self.run_script([0], [0], (option, 'postgresql-17'))
            self.assertEqual(result.returncode, 64)
            self.assertEqual(calls, [])
        result, calls = self.run_script([0], [0])
        self.assertFalse(any('allow' in c.lower() or 'trusted' in c.lower() for c in calls))

    def test_no_packages_is_a_usage_error(self):
        result, calls = self.run_script([0], [0], ())
        self.assertEqual(result.returncode, 64)
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
