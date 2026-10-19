#!/usr/bin/env python3
"""Verify the installed CI toolchain, then create one owned headless kernel.

No renderer oracle, timeout or automatic retry is changed. This is intended for
an ephemeral GitHub runner; it never opens Simulator or launches the app.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import time
from pathlib import Path

DEVELOPER = Path('/Applications/Xcode_26.4.1.app/Contents/Developer')
XCODE_VERSION = 'Xcode 26.4.1\nBuild version 17E202'
SDK = str(DEVELOPER / 'Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.4.sdk')
RUNTIME = 'com.apple.CoreSimulator.SimRuntime.iOS-26-4'
DEVICE_TYPE = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def decoded(value):
    return value.decode(errors='replace') if isinstance(value, bytes) else value or ''


def prepare(out, run_id, attempt, github_env, *, execute=subprocess.run,
            developer_exists=lambda: DEVELOPER.is_dir(), architecture=platform.machine):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    github_env = Path(github_env)
    source = Path(__file__)
    source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
    receipt = {'passed': False, 'scope': 'CI setup only; no UIKit render result',
               'sourceSHA256': source_sha, 'commands': [], 'createdDevice': None,
               'environmentPublished': False, 'SimulatorUIOpened': False,
               'AppLaunched': False, 'retries': 0, 'commandDeadlineSeconds': 30}
    # Explicit per-command selection happens only after the directory check.
    command_env = dict(os.environ)
    command_env['DEVELOPER_DIR'] = str(DEVELOPER)

    def command(name, argv):
        started = time.monotonic()
        event = {'name': name, 'argv': argv, 'deadlineSeconds': 30}
        log = ''
        try:
            result = execute(argv, capture_output=True, text=True, timeout=30, env=command_env)
            event['exitCode'] = result.returncode
            log = decoded(result.stdout) + decoded(result.stderr)
            require(result.returncode == 0, name + ' command refused')
            return result.stdout
        except subprocess.TimeoutExpired as error:
            event['timedOut'] = True
            log = decoded(error.stdout) + decoded(error.stderr)
            raise
        finally:
            event['elapsedSeconds'] = round(time.monotonic() - started, 3)
            path = out / (name + '.log')
            path.write_text(log)
            event['log'] = str(path)
            receipt['commands'].append(event)

    try:
        require(architecture() == 'arm64', 'Pinned UIKit runner requires arm64')
        require(developer_exists(), 'Pinned Xcode developer directory is not installed')
        require(re.fullmatch(r'[0-9]+', str(run_id)) is not None
                and re.fullmatch(r'[0-9]+', str(attempt)) is not None,
                'CI run and attempt must be numeric')
        require(github_env.is_file(), 'GitHub environment output file is absent')
        version = command('xcode-version', ['xcodebuild', '-version']).strip()
        require(version == XCODE_VERSION, 'Pinned Xcode version/build mismatch')
        sdk = command('sdk-path', ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path']).strip()
        require(sdk == SDK, 'Pinned simulator SDK path mismatch')
        inventory = json.loads(command('runtime-inventory', ['xcrun', 'simctl', 'list', '-j']))
        require(type(inventory) is dict and type(inventory.get('runtimes')) is list
                and type(inventory.get('devicetypes')) is list, 'Invalid runtime/type inventory')
        matching = [r for r in inventory['runtimes'] if type(r) is dict and r.get('identifier') == RUNTIME]
        require(len(matching) == 1 and matching[0].get('isAvailable') is True
                and matching[0].get('version') in ['26.4', '26.4.1'],
                'Exact iOS26.4 runtime is absent or unavailable')
        require(sum(type(d) is dict and d.get('identifier') == DEVICE_TYPE
                    for d in inventory['devicetypes']) == 1, 'Exact iPhone17Pro device type is absent')
        name = 'Rendprop CI Photo Exports ' + str(run_id) + '-' + str(attempt)
        udid = command('create-owned-kernel', ['xcrun', 'simctl', 'create', name, DEVICE_TYPE, RUNTIME]).strip()
        require(re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', udid) is not None,
                'Create did not return one exact device UUID')
        receipt['createdDevice'] = {'name': name, 'uuid': udid, 'runtime': RUNTIME}
        devices = json.loads(command('verify-owned-kernel', ['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
        require(type(devices) is dict and type(devices.get('devices')) is dict
                and type(devices['devices'].get(RUNTIME)) is list, 'Invalid created-device inventory')
        found = [d for d in devices['devices'][RUNTIME] if type(d) is dict and d.get('udid') == udid]
        require(len(found) == 1 and found[0].get('isAvailable') is True
                and found[0].get('name') == name and found[0].get('state') == 'Shutdown'
                and found[0].get('deviceTypeIdentifier') == DEVICE_TYPE,
                'Owned kernel identity/runtime/availability mismatch')
        # Only now may subsequent renderer commands inherit the verified pin.
        with github_env.open('a') as file:
            file.write('DEVELOPER_DIR=' + str(DEVELOPER) + '\n')
            file.write('RENDPROP_PHOTO_EXPORT_SIMULATOR=' + udid + '\n')
        receipt.update(passed=True, environmentPublished=True, verifiedXcode=version,
                       verifiedSDK=sdk, verifiedRuntime=matching[0])
        return receipt
    except Exception as error:
        receipt['failure'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        receipt['sourceSHA256AtEnd'] = hashlib.sha256(source.read_bytes()).hexdigest()
        receipt['sourceBindingMatches'] = receipt['sourceSHA256AtEnd'] == source_sha
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence-dir', type=Path, required=True)
    parser.add_argument('--run-id', default=os.environ.get('GITHUB_RUN_ID'))
    parser.add_argument('--run-attempt', default=os.environ.get('GITHUB_RUN_ATTEMPT'))
    parser.add_argument('--github-env', type=Path, default=os.environ.get('GITHUB_ENV'))
    args = parser.parse_args()
    require(args.github_env is not None, 'GitHub environment output is required')
    result = prepare(args.evidence_dir, args.run_id, args.run_attempt, args.github_env)
    print(json.dumps({'passed': result['passed'], 'createdDevice': result['createdDevice'],
                      'evidence': str(args.evidence_dir), 'renderChecksStarted': False}))


if __name__ == '__main__':
    main()
