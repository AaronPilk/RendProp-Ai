#!/usr/bin/env python3
"""Exercise the actual CI setup function using fake commands, never a simulator."""
import argparse
import hashlib
import importlib.util
import json
import subprocess
import tempfile
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE / 'prepare_photo_export_ci.py'
UDID = '11111111-1111-4111-8111-111111111111'


def load(path):
    spec = importlib.util.spec_from_file_location('photo_ci_setup', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fixture(module, fault=None):
    name = 'Rendprop CI Photo Exports 38647444171-1'
    inventory = {'runtimes': [{'identifier': module.RUNTIME, 'version': '26.4.1', 'isAvailable': True}],
                 'devicetypes': [{'identifier': module.DEVICE_TYPE}]}
    devices = {'devices': {module.RUNTIME: [{'udid': UDID, 'name': name,
                'state': 'Shutdown', 'isAvailable': True, 'deviceTypeIdentifier': module.DEVICE_TYPE}]}}
    version = module.XCODE_VERSION
    sdk = module.SDK
    create = UDID
    if fault == 'wrong-version': version = 'Xcode 26.6\nBuild version 17F113'
    if fault == 'wrong-sdk': sdk = '/Applications/Xcode_26.6.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk'
    if fault == 'missing-runtime': inventory['runtimes'] = []
    if fault == 'unavailable-runtime': inventory['runtimes'][0]['isAvailable'] = False
    if fault == 'wrong-runtime-version': inventory['runtimes'][0]['version'] = '26.5'
    if fault == 'runtime-inventory-first-timeout-bad-runtime': inventory['runtimes'][0]['version'] = '26.5'
    if fault == 'missing-device-type': inventory['devicetypes'] = []
    if fault == 'bad-create-id': create = 'not-one-uuid'
    if fault == 'wrong-name': devices['devices'][module.RUNTIME][0]['name'] = 'Someone else'
    if fault == 'wrong-device-type': devices['devices'][module.RUNTIME][0]['deviceTypeIdentifier'] = 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro'
    if fault == 'wrong-device-runtime': devices['devices'] = {'other-runtime': devices['devices'][module.RUNTIME]}
    if fault == 'unavailable-device': devices['devices'][module.RUNTIME][0]['isAvailable'] = False
    if fault == 'duplicate-device': devices['devices'][module.RUNTIME].append(dict(devices['devices'][module.RUNTIME][0]))
    if fault == 'already-booted': devices['devices'][module.RUNTIME][0]['state'] = 'Booted'
    outputs = {
        ('xcodebuild', '-version'): version,
        ('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'): sdk,
        ('xcrun', 'simctl', 'list', '-j'): json.dumps(inventory),
        ('xcrun', 'simctl', 'create', name, module.DEVICE_TYPE, module.RUNTIME): create,
        ('xcrun', 'simctl', 'list', 'devices', 'available', '-j'): json.dumps(devices),
    }
    calls = []

    def execute(argv, **kwargs):
        calls.append(argv)
        if kwargs['timeout'] != 30 or kwargs['env']['DEVELOPER_DIR'] != str(module.DEVELOPER):
            raise AssertionError('Exact deadline and verified-toolchain command environment required')
        if fault == 'nonzero-command': return types.SimpleNamespace(returncode=9, stdout='', stderr='refused')
        if fault == 'command-timeout': raise subprocess.TimeoutExpired(argv, 30, output=b'partial setup evidence')
        if argv == ['xcrun', 'simctl', 'list', '-j']:
            inventory_calls = sum(call == argv for call in calls)
            if fault in ['runtime-inventory-first-timeout',
                         'runtime-inventory-first-timeout-bad-runtime'] and inventory_calls == 1:
                raise subprocess.TimeoutExpired(argv, 30, output=b'CoreSimulator still starting')
            if fault == 'runtime-inventory-exhausted':
                raise subprocess.TimeoutExpired(argv, 30, output=b'CoreSimulator still unavailable')
            if fault == 'runtime-inventory-nonzero':
                return types.SimpleNamespace(returncode=9, stdout='', stderr='simctl refused')
        if tuple(argv) not in outputs: raise AssertionError('Unexpected setup command: ' + str(argv))
        return types.SimpleNamespace(returncode=0, stdout=outputs[tuple(argv)], stderr='')
    return execute, calls


def run_case(module, destination, fault=None):
    destination.mkdir()
    env = destination / 'github-env'
    env.write_text('EXISTING_VALUE=keep\n')
    execute, calls = fixture(module, fault)
    waits = []
    caught = None
    result = None
    try:
        result = module.prepare(destination / 'evidence', '38647444171', '1', env,
                  execute=execute, developer_exists=lambda: fault != 'missing-xcode',
                  architecture=lambda: 'x86_64' if fault == 'wrong-architecture' else 'arm64',
                  sleep=waits.append)
    except Exception as error:
        caught = type(error).__name__ + ': ' + str(error)
    receipt = json.loads((destination / 'evidence/receipt.json').read_text())
    recovered = fault == 'runtime-inventory-first-timeout'
    if fault and not recovered:
        if caught is None: raise AssertionError(fault + ': required setup refusal missing')
        if env.read_text() != 'EXISTING_VALUE=keep\n': raise AssertionError(fault + ': failed setup published environment')
        if receipt['passed'] or receipt['environmentPublished']: raise AssertionError(fault + ': failure claimed success')
    else:
        if caught: raise AssertionError((fault or 'positive') + ': required setup success missing: ' + caught)
        expected = 'EXISTING_VALUE=keep\nDEVELOPER_DIR=' + str(module.DEVELOPER) + '\nRENDPROP_PHOTO_EXPORT_SIMULATOR=' + UDID + '\n'
        if env.read_text() != expected: raise AssertionError((fault or 'positive') + ': exact verified environment required')
        if not result['passed'] or not result['sourceBindingMatches']:
            raise AssertionError((fault or 'positive') + ': exact source/result required')
    if len(receipt['commands']) != len(calls): raise AssertionError('Every command outcome must retain its evidence')
    if any('boot' in call or 'spawn' in call for argv in calls for call in argv): raise AssertionError('Preflight must not boot or execute renderer')
    if fault in ['missing-xcode', 'wrong-architecture'] and calls: raise AssertionError(fault + ': commands before path/architecture check')
    if fault == 'command-timeout' and len(calls) != 1: raise AssertionError('timeout: no repeated command allowed')
    if fault == 'command-timeout' and not any('partial setup evidence' in p.read_text() for p in (destination / 'evidence').glob('*.log')):
        raise AssertionError('timeout: partial evidence lost')
    inventory_calls = [argv for argv in calls if argv == ['xcrun', 'simctl', 'list', '-j']]
    if recovered:
        if len(inventory_calls) != 2 or waits != [5] or receipt['retries'] != 1:
            raise AssertionError(fault + ': exact bounded retry and wait required')
        if not receipt['commands'][2].get('timedOut') or receipt['commands'][3].get('timedOut'):
            raise AssertionError(fault + ': timed-out first inventory and ready second inventory required')
        if 'CoreSimulator still starting' not in (destination / 'evidence/runtime-inventory.log').read_text():
            raise AssertionError(fault + ': first timeout evidence lost')
    elif fault == 'runtime-inventory-exhausted':
        if len(inventory_calls) != 3 or waits != [5, 5] or receipt['retries'] != 2:
            raise AssertionError(fault + ': three attempts and two bounded waits required')
        if 'CoreSimulator inventory timed out after 3 bounded 30-second attempts' not in caught:
            raise AssertionError(fault + ': exhaustion reason lost')
        if not all(command.get('timedOut') for command in receipt['commands'][2:]):
            raise AssertionError(fault + ': all timeout events required')
        if len(list((destination / 'evidence').glob('runtime-inventory*.log'))) != 3:
            raise AssertionError(fault + ': separate timeout logs required')
    elif fault == 'runtime-inventory-first-timeout-bad-runtime':
        if len(inventory_calls) != 2 or waits != [5] or receipt['retries'] != 1:
            raise AssertionError(fault + ': warmed inventory must still receive exact runtime check')
        if 'Exact iOS26.4 runtime is absent or unavailable' not in caught:
            raise AssertionError(fault + ': wrong runtime accepted after recovery')
        if len(calls) != 4:
            raise AssertionError(fault + ': created a device from wrong runtime')
    elif inventory_calls and (len(inventory_calls) != 1 or waits or receipt['retries']):
        raise AssertionError((fault or 'positive') + ': unexpected inventory retry')
    elif not inventory_calls and (waits or receipt['retries']):
        raise AssertionError((fault or 'positive') + ': retry before inventory')
    return {'fault': fault, 'caught': caught, 'commands': len(calls), 'passed': True}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    module = load(SOURCE)
    out = args.out or Path(tempfile.mkdtemp(prefix='rendprop-ci-toolchain-controls-'))
    out.mkdir(parents=True, exist_ok=True)
    faults = ['missing-xcode', 'wrong-architecture', 'wrong-version', 'wrong-sdk',
              'missing-runtime', 'unavailable-runtime', 'wrong-runtime-version',
              'missing-device-type', 'bad-create-id', 'wrong-name', 'wrong-device-type',
              'wrong-device-runtime', 'unavailable-device', 'duplicate-device',
              'already-booted', 'nonzero-command', 'command-timeout',
              'runtime-inventory-exhausted', 'runtime-inventory-nonzero',
              'runtime-inventory-first-timeout-bad-runtime']
    cases = [run_case(module, out / 'positive'),
             run_case(module, out / 'runtime-inventory-first-timeout', 'runtime-inventory-first-timeout')]
    cases += [run_case(module, out / name, name) for name in faults]
    original = SOURCE.read_text()
    controls = [
      ('missing-install-guard', "require(developer_exists(), 'Pinned Xcode developer directory is not installed')", "require(True, 'Pinned Xcode developer directory is not installed')", 'missing-xcode', 'missing-xcode: required setup refusal missing'),
      ('wrong-version-accepted', "require(version == XCODE_VERSION, 'Pinned Xcode version/build mismatch')", "require(True, 'Pinned Xcode version/build mismatch')", 'wrong-version', 'wrong-version: required setup refusal missing'),
      ('wrong-sdk-accepted', "require(sdk == SDK, 'Pinned simulator SDK path mismatch')", "require(True, 'Pinned simulator SDK path mismatch')", 'wrong-sdk', 'wrong-sdk: required setup refusal missing'),
      ('foreign-device-accepted', "and found[0].get('name') == name and found[0].get('state') == 'Shutdown'", "and found[0].get('state') == 'Shutdown'", 'wrong-name', 'wrong-name: required setup refusal missing'),
      ('inventory-retry-disabled', 'INVENTORY_MAX_ATTEMPTS = 3', 'INVENTORY_MAX_ATTEMPTS = 1', 'runtime-inventory-first-timeout', 'runtime-inventory-first-timeout: required setup success missing: RuntimeError: CoreSimulator inventory timed out after 1 bounded 30-second attempts; see inventory logs'),
      ('inventory-exceeds-budget', 'INVENTORY_MAX_ATTEMPTS = 3', 'INVENTORY_MAX_ATTEMPTS = 4', 'runtime-inventory-exhausted', 'runtime-inventory-exhausted: three attempts and two bounded waits required'),
    ]
    rejected = []
    for name, old, new, fault, oracle in controls:
        if original.count(old) != 1: raise AssertionError(name + ': exact guard anchor missing')
        path = out / (name + '.py')
        path.write_text(original.replace(old, new, 1))
        error = None
        try: run_case(load(path), out / name, fault)
        except AssertionError as caught: error = str(caught)
        if error != oracle: raise AssertionError(name + ': named oracle required, got ' + str(error))
        rejected.append({'name': name, 'oracle': error})
    receipt = {'passed': True, 'positives': 2, 'refusals': len(faults),
               'actualGuardControls': rejected, 'cases': cases,
               'sourceSHA256': hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
               'testSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               'realSimulatorCalls': 0, 'realSubprocesses': 0,
               'rendererOraclesChanged': False, 'evidence': str(out)}
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'passed': True, 'positives': 2, 'refusals': len(faults),
                      'controls': len(rejected), 'evidence': str(out)}))


if __name__ == '__main__':
    main()
