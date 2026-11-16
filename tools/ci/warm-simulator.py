#!/usr/bin/env python3
"""Warm CoreSimulator and boot one iPhone kernel before the simulator gates.

A fresh hosted Mac can take minutes to start CoreSimulator the first time
`xcrun simctl` is called. The native gates each allow that first call a single
fixed window, so a slow start failed a whole job before any test ran. This
step absorbs the cold start instead: the inventory is retried a fixed number
of times with growing, finite deadlines, then one iPhone kernel is booted and
waited for, again with finite deadlines.

It selects the kernel exactly as apps/ios/tests/run-clip-frames.py does (an
already booted iPhone, otherwise the first available one), so the gates that
follow see the same device they would have chosen themselves. It changes no
test, threshold or assertion. If the simulator never becomes ready the step
fails and labels the failure as infrastructure.
"""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

INVENTORY = ['xcrun', 'simctl', 'list', 'devices', 'available', '-j']
INVENTORY_DEADLINES_SECONDS = [120, 180, 240]
INVENTORY_BACKOFF_SECONDS = [10, 20]
BOOT_DEADLINE_SECONDS = 120
BOOTSTATUS_DEADLINES_SECONDS = [300, 240]
IPHONE_PREFIX = 'com.apple.CoreSimulator.SimDeviceType.iPhone-'


class InfrastructureMiss(RuntimeError):
    pass


def decoded(value):
    return value.decode(errors='replace') if isinstance(value, bytes) else value or ''


def warm(out, *, execute=subprocess.run, sleep=time.sleep, clock=time.monotonic):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    receipt = {'passed': False, 'scope': 'CI setup only; no test result',
               'commands': [], 'inventoryAttempts': 0, 'bootstatusAttempts': 0,
               'inventoryDeadlinesSeconds': INVENTORY_DEADLINES_SECONDS,
               'bootstatusDeadlinesSeconds': BOOTSTATUS_DEADLINES_SECONDS}

    def command(name, argv, deadline):
        """Returns the completed process, or None when the deadline passed."""
        started = clock()
        event = {'name': name, 'argv': argv, 'deadlineSeconds': deadline}
        log = ''
        try:
            result = execute(argv, capture_output=True, text=True, timeout=deadline)
            event['exitCode'] = result.returncode
            log = decoded(result.stdout) + decoded(result.stderr)
            return result
        except subprocess.TimeoutExpired as error:
            event['timedOut'] = True
            log = decoded(error.stdout) + decoded(error.stderr)
            return None
        finally:
            event['elapsedSeconds'] = round(clock() - started, 3)
            (out / (name + '.log')).write_text(log)
            receipt['commands'].append(event)
            print(f"{name}: {json.dumps({k: v for k, v in event.items() if k != 'argv'})}", flush=True)

    try:
        inventory = None
        for index, deadline in enumerate(INVENTORY_DEADLINES_SECONDS):
            receipt['inventoryAttempts'] = index + 1
            result = command(f'inventory-attempt-{index + 1}', INVENTORY, deadline)
            if result is not None and result.returncode == 0:
                # A successful answer must be well formed; that is never retried.
                inventory = json.loads(result.stdout)['devices']
                break
            if index < len(INVENTORY_BACKOFF_SECONDS):
                sleep(INVENTORY_BACKOFF_SECONDS[index])
        if inventory is None:
            raise InfrastructureMiss(
                'CoreSimulator did not answer `simctl list` in '
                + str(len(INVENTORY_DEADLINES_SECONDS)) + ' bounded attempts')
        devices = [d for runtime, rows in inventory.items() if 'iOS' in runtime for d in rows
                   if d.get('isAvailable') and d.get('deviceTypeIdentifier', '').startswith(IPHONE_PREFIX)]
        if not devices:
            raise InfrastructureMiss('The runner image has no available iPhone simulator')
        device = next((d for d in devices if d.get('state') == 'Booted'), devices[0])
        receipt['device'] = {key: device.get(key) for key in ('udid', 'name', 'state', 'deviceTypeIdentifier')}
        if device.get('state') != 'Booted':
            # `boot` on a kernel that is already starting exits non-zero; the
            # readiness wait below is the authority, so its exit is recorded only.
            command('boot', ['xcrun', 'simctl', 'boot', device['udid']], BOOT_DEADLINE_SECONDS)
            ready = False
            for index, deadline in enumerate(BOOTSTATUS_DEADLINES_SECONDS):
                receipt['bootstatusAttempts'] = index + 1
                result = command(f'bootstatus-attempt-{index + 1}',
                                 ['xcrun', 'simctl', 'bootstatus', device['udid'], '-b'], deadline)
                if result is not None and result.returncode == 0:
                    ready = True
                    break
            if not ready:
                raise InfrastructureMiss(
                    'The iPhone simulator did not finish booting in '
                    + str(len(BOOTSTATUS_DEADLINES_SECONDS)) + ' bounded waits')
        receipt['passed'] = True
        return receipt
    except Exception as error:
        receipt['failure'] = type(error).__name__ + ': ' + str(error)
        receipt['infrastructureMiss'] = isinstance(error, InfrastructureMiss)
        raise
    finally:
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')


def publish(name, value):
    path = os.environ.get('GITHUB_OUTPUT')
    if path:
        with open(path, 'a') as file:
            file.write(f'{name}={value}\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence-dir', required=True)
    args = parser.parse_args()
    try:
        receipt = warm(args.evidence_dir)
    except InfrastructureMiss as error:
        publish('infrastructure-miss', 'true')
        print(f'::error title=Infrastructure miss (CoreSimulator)::{error}. '
              'No simulator test ran in this job; re-run the failed job.', flush=True)
        return 1
    publish('ready', 'true')
    print('CoreSimulator ready: ' + json.dumps(receipt['device']), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
