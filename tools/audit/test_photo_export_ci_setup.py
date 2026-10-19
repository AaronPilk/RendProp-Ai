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
    if fault == 'missing-device-type': inventory['devicetypes'] = []
    if fault == 'bad-create-id': create = 'not-one-uuid'
    if fault == 'wrong-name': devices['devices'][module.RUNTIME][0]['name'] = 'Someone else'
    if fault == 'wrong-device-type': devices['devices'][module.RUNTIME][0]['deviceTypeIdentifier'] = 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro'
    if fault == 'wrong-device-runtime': devices['devices'] = {'other-runtime': devices['devices'][module.RUNTIME]}
    if fault == 'unavailable-device': devices['devices'][module.RUNTIME][0]['isAvailable'] = False
    if fault == 'duplicate-device': devices['devices'][module.RUNTIME].append(dict(devices['devices'][module.RUNTIME][0]))
    if fault == 'already-booted': devices['devices'][module.RUNTIME][0]['state'] = 'Booted'
    output = [version, sdk, json.dumps(inventory), create, json.dumps(devices)]
    calls = []

    def execute(argv, **kwargs):
        index = len(calls)
        calls.append(argv)
        if kwargs['timeout'] != 30 or kwargs['env']['DEVELOPER_DIR'] != str(module.DEVELOPER):
            raise AssertionError('Exact deadline and verified-toolchain command environment required')
        if fault == 'nonzero-command': return types.SimpleNamespace(returncode=9, stdout='', stderr='refused')
        if fault == 'command-timeout': raise subprocess.TimeoutExpired(argv, 30, output=b'partial setup evidence')
        if index >= len(output): raise AssertionError('No automatic retry or extra command allowed')
        return types.SimpleNamespace(returncode=0, stdout=output[index], stderr='')
    return execute, calls


def run_case(module, destination, fault=None):
    destination.mkdir()
    env = destination / 'github-env'
    env.write_text('EXISTING_VALUE=keep\n')
    execute, calls = fixture(module, fault)
    caught = None
    result = None
    try:
        result = module.prepare(destination / 'evidence', '38647444171', '1', env,
                  execute=execute, developer_exists=lambda: fault != 'missing-xcode',
                  architecture=lambda: 'x86_64' if fault == 'wrong-architecture' else 'arm64')
    except Exception as error:
        caught = type(error).__name__ + ': ' + str(error)
    receipt = json.loads((destination / 'evidence/receipt.json').read_text())
    if fault:
        if caught is None: raise AssertionError(fault + ': required setup refusal missing')
        if env.read_text() != 'EXISTING_VALUE=keep\n': raise AssertionError(fault + ': failed setup published environment')
        if receipt['passed'] or receipt['environmentPublished']: raise AssertionError(fault + ': failure claimed success')
    else:
        if caught: raise AssertionError('positive: ' + caught)
        expected = 'EXISTING_VALUE=keep\nDEVELOPER_DIR=' + str(module.DEVELOPER) + '\nRENDPROP_PHOTO_EXPORT_SIMULATOR=' + UDID + '\n'
        if env.read_text() != expected: raise AssertionError('positive: exact verified environment required')
        if not result['passed'] or not result['sourceBindingMatches']: raise AssertionError('positive: exact source/result required')
    if len(receipt['commands']) != len(calls): raise AssertionError('Every command outcome must retain its evidence')
    if any('boot' in call or 'spawn' in call for argv in calls for call in argv): raise AssertionError('Preflight must not boot or execute renderer')
    if fault in ['missing-xcode', 'wrong-architecture'] and calls: raise AssertionError(fault + ': commands before path/architecture check')
    if fault == 'command-timeout' and len(calls) != 1: raise AssertionError('timeout: no repeated command allowed')
    if fault == 'command-timeout' and not any('partial setup evidence' in p.read_text() for p in (destination / 'evidence').glob('*.log')):
        raise AssertionError('timeout: partial evidence lost')
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
              'already-booted', 'nonzero-command', 'command-timeout']
    cases = [run_case(module, out / 'positive')] + [run_case(module, out / name, name) for name in faults]
    original = SOURCE.read_text()
    controls = [
      ('missing-install-guard', "require(developer_exists(), 'Pinned Xcode developer directory is not installed')", "require(True, 'Pinned Xcode developer directory is not installed')", 'missing-xcode'),
      ('wrong-version-accepted', "require(version == XCODE_VERSION, 'Pinned Xcode version/build mismatch')", "require(True, 'Pinned Xcode version/build mismatch')", 'wrong-version'),
      ('wrong-sdk-accepted', "require(sdk == SDK, 'Pinned simulator SDK path mismatch')", "require(True, 'Pinned simulator SDK path mismatch')", 'wrong-sdk'),
      ('foreign-device-accepted', "and found[0].get('name') == name and found[0].get('state') == 'Shutdown'", "and found[0].get('state') == 'Shutdown'", 'wrong-name'),
    ]
    rejected = []
    for name, old, new, fault in controls:
        if original.count(old) != 1: raise AssertionError(name + ': exact guard anchor missing')
        path = out / (name + '.py')
        path.write_text(original.replace(old, new, 1))
        error = None
        try: run_case(load(path), out / name, fault)
        except AssertionError as caught: error = str(caught)
        if error != fault + ': required setup refusal missing': raise AssertionError(name + ': named oracle required, got ' + str(error))
        rejected.append({'name': name, 'oracle': error})
    receipt = {'passed': True, 'positives': 1, 'refusals': len(faults),
               'actualGuardControls': rejected, 'cases': cases,
               'sourceSHA256': hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
               'testSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               'realSimulatorCalls': 0, 'realSubprocesses': 0,
               'rendererOraclesChanged': False, 'evidence': str(out)}
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({'passed': True, 'positives': 1, 'refusals': len(faults),
                      'controls': len(rejected), 'evidence': str(out)}))


if __name__ == '__main__':
    main()
