#!/usr/bin/env python3
"""Exercise the actual UIKit runner's discovery helper without a simulator."""
import argparse
import ast
import hashlib
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'apps/ios/tests/run-photo-export-renderer.py'


def need(condition, message):
    if not condition:
        raise RuntimeError(message)


def extracted(text):
    module = ast.parse(text)
    functions = [node for node in module.body
                 if isinstance(node, ast.FunctionDef) and node.name in {'command', 'discover_simulator'}]
    need({node.name for node in functions} == {'command', 'discover_simulator'}, 'Actual helper extraction missing')
    return ast.unparse(ast.Module(body=functions, type_ignores=[])) + '\n'


def inventory(*devices):
    return json.dumps({'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-0': list(devices)}})


def device(identifier, state='Shutdown', available=True):
    return {'udid': identifier, 'name': 'iPhone 17', 'state': state, 'isAvailable': available}


ONE = '11111111-1111-4111-8111-111111111111'
TWO = '22222222-2222-4222-8222-222222222222'
VALID = inventory(device(ONE), device(TWO, 'Booted'))


def case(name, events, *, expected_id=None, requested=None, failure=None,
         count=1, second_timeout=None, validation_elapsed=0):
    return dict(name=name, events=events, expected_id=expected_id, requested=requested,
                failure=failure, count=count, second_timeout=second_timeout,
                validation_elapsed=validation_elapsed)


CASES = [
    case('initial-prefers-booted', [(0.01, 0, VALID)], expected_id=TWO),
    case('requested-exact-device', [(0.01, 0, VALID)], requested=ONE, expected_id=ONE),
    case('named-task-owned-iphone', [(0.01, 0, inventory(dict(device(ONE), name='Rendprop Custom Acceptance', deviceTypeIdentifier='com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro')))], requested=ONE, expected_id=ONE),
    case('timeout-then-valid-read', [(30, 'timeout', ''), (1, 0, VALID)], expected_id=TWO, count=2, second_timeout=90),
    case('remaining-budget-is-recomputed', [(119, 'timeout', ''), (0.5, 0, VALID)], expected_id=TWO, count=2, second_timeout=1),
    case('empty-inventory', [(0, 0, inventory())], failure='No available iPhone simulator'),
    case('invalid-json', [(0, 0, '{')], failure='JSONDecodeError'),
    case('missing-devices', [(0, 0, '{}')], failure='requires a devices object'),
    case('invalid-runtime-list', [(0, 0, '{"devices":{"iOS":{}}}')], failure='invalid runtime inventory'),
    case('invalid-availability-type', [(0, 0, inventory(device(ONE, available=1)))], failure='invalid device inventory'),
    case('missing-device-state', [(0, 0, inventory({'udid': ONE, 'name': 'iPhone 17', 'isAvailable': True}))], failure='invalid device inventory'),
    case('duplicate-device-id', [(0, 0, inventory(device(ONE), device(ONE)))], failure='duplicate available device IDs'),
    case('unavailable-device', [(0, 0, inventory(device(ONE, available=False)))], failure='No available iPhone simulator'),
    case('requested-device-absent', [(0, 0, VALID)], requested='not-listed', failure='Requested simulator is not available'),
    case('nonzero-read-is-terminal', [(0, 9, VALID), (0, 0, VALID)], failure='nonzero exit code'),
    case('other-exception-is-terminal', [(0, 'error', ''), (0, 0, VALID)], failure='synthetic transport refusal'),
    case('late-initial-result', [(120, 0, VALID)], failure='completed after its overall deadline'),
    case('late-device-validation', [(0, 0, VALID)], failure='validation completed after its overall deadline', validation_elapsed=120),
    case('post-timeout-expiry-no-dispatch', [(120, 'timeout', '')], failure='before reconciliation'),
    case('repeated-timeout-no-third-read', [(30, 'timeout', ''), (90, 'timeout', ''), (0, 0, VALID)], failure='TimeoutExpired', count=2, second_timeout=90),
    case('late-reconciliation-result', [(30, 'timeout', ''), (90, 0, VALID)], failure='completed after its overall deadline', count=2, second_timeout=90),
    case('reconciliation-nonzero-is-terminal', [(30, 'timeout', ''), (0, 9, VALID), (0, 0, VALID)], failure='nonzero exit code', count=2, second_timeout=90),
    case('reconciliation-invalid-json', [(30, 'timeout', ''), (0, 0, '{')], failure='JSONDecodeError', count=2, second_timeout=90),
]


def execute_case(spec, helper_source, destination):
    destination.mkdir(parents=True)
    clock_value = [0.0]
    clock_reads = [0]
    calls = []
    receipt = {'commands': []}

    def run(argv, **kwargs):
        index = len(calls)
        need(index < len(spec['events']), 'Unexpected extra simulator read')
        elapsed, result, stdout = spec['events'][index]
        calls.append({'argv': argv, 'timeout': kwargs['timeout']})
        clock_value[0] += elapsed
        if result == 'timeout':
            raise subprocess.TimeoutExpired(argv, kwargs['timeout'], output=b'partial-discovery-output')
        if result == 'error':
            raise RuntimeError('synthetic transport refusal')
        return subprocess.CompletedProcess(argv, result, stdout, '')

    namespace = {'json': json, 'time': SimpleNamespace(monotonic=lambda: clock_value[0]),
                 'subprocess': SimpleNamespace(run=run, TimeoutExpired=subprocess.TimeoutExpired),
                 'out': destination, 'receipt': receipt, 'decoded': lambda value: value.decode() if isinstance(value, bytes) else value or ''}
    exec(compile(helper_source, str(SOURCE), 'exec'), namespace)
    diagnostics = {}
    caught = None
    selected = None
    def discovery_clock():
        clock_reads[0] += 1
        if clock_reads[0] == 3:
            clock_value[0] += spec['validation_elapsed']
        return clock_value[0]
    try:
        # Keep the actual command wrapper's subprocess and timeout-log behavior.
        # The helper itself must also refuse nonzero exits under optimized Python.
        selected = namespace['discover_simulator'](
            lambda name, argv, timeout: namespace['command'](name, argv, timeout, check=False),
            spec['requested'], diagnostics, clock=discovery_clock)
    except Exception as error:
        caught = f'{type(error).__name__}: {error}'
    if spec['failure']:
        need(caught is not None and spec['failure'] in caught,
             f"{spec['name']}: expected exact refusal {spec['failure']}, got {caught}")
    else:
        need(caught is None and selected['udid'] == spec['expected_id'], f"{spec['name']}: expected exact available device")
    need(len(calls) == spec['count'], f"{spec['name']}: wrong dispatch count")
    need(calls[0]['timeout'] == 30, 'Initial discovery remains bounded to30 seconds')
    need(all(c['argv'] == ['xcrun', 'simctl', 'list', 'devices', 'available', '-j'] for c in calls), 'Only exact read-only inventory command permitted')
    if spec['second_timeout'] is not None:
        need(calls[1]['timeout'] == spec['second_timeout'], f"{spec['name']}: remaining deadline not honored")
    logs = list(destination.glob('*.log'))
    need(len(logs) == len(calls), f"{spec['name']}: unique command logs must survive")
    need(len(receipt['commands']) == len(calls), 'All command outcomes must be retained')
    if spec['events'][0][1] == 'timeout':
        need(receipt['commands'][0].get('timed_out') is True, 'Initial timeout event must be retained')
        need('partial-discovery-output' in logs[0].read_text() or any('partial-discovery-output' in p.read_text() for p in logs), 'Partial timeout output must be retained')
    return {'name': spec['name'], 'passed': True, 'expectedFailure': spec['failure'],
            'calls': calls, 'diagnostics': diagnostics, 'caught': caught,
            'commandEvents': receipt['commands']}


def exercise_boot_readiness(source_text):
    """Execute the runner's actual cold-boot branch with bounded fake commands."""
    module = ast.parse(source_text)
    branches = [node for top in module.body if isinstance(top, ast.Try)
                for node in top.body if isinstance(node, ast.If)
                and ast.unparse(node.test) == "device['state'] != 'Booted'"]
    need(len(branches) == 1, 'Actual cold-boot branch extraction missing')
    branch = compile(ast.Module(body=branches, type_ignores=[]), str(SOURCE), 'exec')
    cases = [
        ('cold-migration-after-old-limit', 'Shutdown', ['ok', 'ready-after-183s'],
         ['simulator-boot', 'simulator-bootstatus'], None),
        ('diagnostic-timeout-then-ready', 'Shutdown', ['ok', 'timeout', 'timeout', 'ok'],
         ['simulator-boot', 'simulator-bootstatus', 'simulator-cold-boot-state', 'simulator-bootstatus-retry'], None),
        ('diagnostic-nonzero-then-ready', 'Shutdown', ['ok', 'timeout', 'nonzero', 'ok'],
         ['simulator-boot', 'simulator-bootstatus', 'simulator-cold-boot-state', 'simulator-bootstatus-retry'], None),
        ('retry-timeout-refused', 'Shutdown', ['ok', 'timeout', 'timeout', 'timeout'],
         ['simulator-boot', 'simulator-bootstatus', 'simulator-cold-boot-state', 'simulator-bootstatus-retry'], 'TimeoutExpired'),
        ('readiness-error-refused', 'Shutdown', ['ok', 'error'],
         ['simulator-boot', 'simulator-bootstatus'], 'RuntimeError'),
        ('already-booted', 'Booted', [], [], None),
    ]
    rows = []
    for name, state, outcomes, expected_names, expected_failure in cases:
        calls = []
        receipt = {}
        def run_command(command_name, argv, timeout, check=True):
            index = len(calls)
            need(index < len(outcomes), f'{name}: unexpected extra simulator command')
            calls.append({'name': command_name, 'argv': argv, 'timeout': timeout, 'check': check})
            outcome = outcomes[index]
            if outcome == 'ready-after-183s' and timeout < 183:
                raise subprocess.TimeoutExpired(argv, timeout, output=b'still-migrating')
            if outcome == 'timeout':
                raise subprocess.TimeoutExpired(argv, timeout, output=b'partial-boot-output')
            if outcome == 'error':
                raise RuntimeError('readiness unavailable')
            return subprocess.CompletedProcess(argv, 1 if outcome == 'nonzero' else 0, '', '')
        caught = None
        try:
            exec(branch, {'device': device(ONE, state), 'command': run_command,
                          'subprocess': subprocess, 'receipt': receipt, 'json': json})
        except Exception as error:
            caught = type(error).__name__
        need([call['name'] for call in calls] == expected_names, f'{name}: wrong boot/readiness sequence')
        need([call['timeout'] for call in calls] ==
             [{'simulator-boot': 60, 'simulator-bootstatus': 240,
               'simulator-cold-boot-state': 30, 'simulator-bootstatus-retry': 180}[item]
              for item in expected_names], f'{name}: cold boot is not bounded as expected')
        need(all(call['argv'] == (['xcrun', 'simctl', 'list', 'devices', 'available', '-j']
                 if call['name'] == 'simulator-cold-boot-state'
                 else ['xcrun', 'simctl', 'boot' if call['name'] == 'simulator-boot' else 'bootstatus', ONE]
                 + ([] if call['name'] == 'simulator-boot' else ['-b']))
                 for call in calls), f'{name}: command used the wrong simulator or operation')
        need(all(call['check'] is (call['name'] != 'simulator-cold-boot-state') for call in calls),
             f'{name}: diagnostic must not gate readiness')
        need(caught == expected_failure, f'{name}: expected {expected_failure}, got {caught}')
        if 'simulator-bootstatus-retry' in expected_names:
            need(receipt.get('cold_boot_retry') is True, f'{name}: retry must be recorded')
        if name == 'diagnostic-timeout-then-ready':
            need('TimeoutExpired' in receipt.get('cold_boot_state_diagnostic_failure', ''),
                 f'{name}: timed-out diagnostic must be recorded')
        rows.append({'name': name, 'passed': True, 'expectedFailure': expected_failure,
                     'commands': calls, 'caught': caught, 'receipt': receipt})
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    out = args.out or Path(tempfile.mkdtemp(prefix='rendprop-sim-discovery-controls-', dir=os.environ.get('RUNNER_TEMP')))
    out.mkdir(parents=True, exist_ok=True)
    before = SOURCE.read_bytes()
    source_text = before.decode()
    generated = extracted(source_text)
    (out / 'actual-extracted-helper.py').write_text(generated)
    rows = [execute_case(spec, generated, out / spec['name']) for spec in CASES]
    boot_rows = exercise_boot_readiness(source_text)
    controls = [
        ('removed-completion-deadline', generated.replace('if clock() >= deadline:', 'if False:'), 'late-initial-result'),
        ('retry-nontimeout-errors', generated.replace('except subprocess.TimeoutExpired:', 'except Exception:'), 'other-exception-is-terminal'),
        ('removed-availability-filter', generated.replace("if device['isAvailable']:", 'if True:'), 'unavailable-device'),
        ('removed-remaining-budget', generated.replace('min(90, remaining)', '90'), 'remaining-budget-is-recomputed'),
    ]
    mutant_rows = []
    for name, changed, case_name in controls:
        need(changed != generated, f'{name}: guard-removal anchor missing')
        failure = None
        try:
            execute_case(next(spec for spec in CASES if spec['name'] == case_name), changed, out / name)
        except RuntimeError as error:
            failure = str(error)
        need(failure is not None and case_name in failure, f'{name}: must reject at its named behavioral oracle')
        mutant_rows.append({'name': name, 'passed': True, 'actualNamedOracle': failure})
    need(SOURCE.read_bytes() == before, 'Actual runner changed during controls')
    result = {'schema': 'rendprop.actual-simulator-discovery-controls.v1', 'passed': True,
              'sourcePath': str(SOURCE), 'sourceSHA256': hashlib.sha256(before).hexdigest(),
              'testSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'extractedSHA256': hashlib.sha256(generated.encode()).hexdigest(),
              'positives': sum(not row['expectedFailure'] for row in rows),
              'refusalCases': sum(bool(row['expectedFailure']) for row in rows),
              'guardRemovals': len(mutant_rows), 'cases': rows, 'controls': mutant_rows,
              'bootReadinessCases': boot_rows,
              'realSubprocesses': 0, 'realSimulatorCalls': 0, 'networkCalls': 0,
              'UIKitRenderingOrPhysicalCameraClaimed': False}
    (out / 'receipt.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in ['passed', 'positives', 'refusalCases', 'guardRemovals']}))
    print(f'Boot readiness scenarios: {len(boot_rows)} passed')


if __name__ == '__main__':
    main()
