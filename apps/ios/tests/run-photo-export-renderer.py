#!/usr/bin/env python3
"""Compile actual UIKit export code plus synthetic boundary fixtures and fault controls."""
import argparse
import hashlib
import json
import os
import platform
import subprocess
import tempfile
import time
from pathlib import Path

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--simulator', help='Existing available iOS simulator UUID')
parser.add_argument('--evidence-dir', type=Path)
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-photo-export-renderer-', dir=os.environ.get('RUNNER_TEMP')))
out.mkdir(parents=True, exist_ok=True)
source = root / 'apps/ios/Rendprop/Photos/PhotoExport.swift'
base = source.read_text()
variants = {
    'actual': (base, None),
    'negative-original-added-last': (base.replace('images: urls,', 'images: urls.sorted { $0.lastPathComponent < $1.lastPathComponent },'), 'Photos receives original before current edit'),
    'negative-mls-overlay': (base.replace('options.destination != .mls && options.includeLabel', 'options.includeLabel'), 'MLS file is clean with no banned text overlay'),
    'negative-web-label-missing': (base.replace('options.destination != .mls && options.includeLabel', 'false && options.destination != .mls && options.includeLabel'), 'web label burns into exported copy'),
    'negative-original-mutated': (base.replace('try FileManager.default.copyItem(at: photo.originalURL, to: originalURL)', 'try Data("mutated-original".utf8).write(to: originalURL, options: .atomic)'), 'exported retained original byte exact'),
    'negative-jpeg-is-png': (base.replace('rendered.jpegData(compressionQuality: 0.97)', 'rendered.pngData()'), 'PNG input is encoded as actual JPEG bytes'),
    'negative-level-no-crop': (base.replace('let cropScale = min(', 'let cropScale = 1.0; let unusedCropScale = min('), 'manual level crops without enlarging the photograph'),
    'negative-crop-stretches': (base.replace('let drawWidth = CGFloat(fullWidth) * scale, drawHeight = CGFloat(fullHeight) * scale', 'let drawWidth = size.width, drawHeight = size.height'), 'center crop actually excludes left red strip'),
}
architecture = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
fixture = root / 'apps/ios/tests/PhotoExportRendererTests.swift'
stubs = root / 'apps/ios/tests/PhotoExportPlatformStubs.swift'
consumed = [source, fixture, stubs, Path(__file__).resolve(), root / 'apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift', root / 'apps/ios/Rendprop/Photos/PhotoVersionHistory.swift']
receipt = {
    'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
    'consumed_sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in consumed},
    'passed': False,
    'start_source_sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in consumed},
    'simulator': None,
    'toolchain': None,
    'compile_deadlines_seconds': {'cold_actual': 300, 'warm_controls': 60},
    'commands': [],
    'runs': [],
    'limitations': ['Actual UIKit renderer and filesystem delivery tested using synthetic images.', 'No vendor calls, camera, Apple account or Photos-library writes.', 'SwiftUI app context dependencies are fixture doubles; full app compilation is separate.', 'The level adjustment rotates and crops a JPEG copy; it cannot recover unseen room geometry.'],
}

def decoded(value):
    return value.decode(errors='replace') if isinstance(value, bytes) else value or ''

def command(name, argv, timeout, check=True):
    """Every subprocess is bounded and keeps diagnostics, including timeouts."""
    print(f'{name} (deadline {timeout}s)', flush=True)
    started = time.monotonic()
    event = {'name': name, 'argv': list(map(str, argv)), 'timeout_seconds': timeout}
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        event['exit_code'] = result.returncode
        log = result.stdout + result.stderr
    except subprocess.TimeoutExpired as error:
        event.update(exit_code=None, timed_out=True)
        log = decoded(error.stdout) + decoded(error.stderr) + f'\nCommand timed out after {timeout}s.\n'
        raise
    except Exception as error:
        event.update(exit_code=None, error=f'{type(error).__name__}: {error}')
        log = event['error'] + '\n'
        raise
    finally:
        event['elapsed_seconds'] = round(time.monotonic() - started, 3)
        event['log'] = str(out / f'{name}.log')
        (out / f'{name}.log').write_text(log)
        receipt['commands'].append(event)
    if check:
        assert result.returncode == 0, f'{name} failed: {log}'
    return result

print(f'Evidence: {out}', flush=True)
try:
    for name, (text, reason) in variants.items():
        assert name == 'actual' or text != base, f'{name} mutation anchor missing'
    sdk = command('sdk-discovery', ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], 30).stdout.strip()
    receipt['toolchain'] = {
        'architecture': architecture,
        'sdk': sdk,
        'swift': command('swift-version', ['xcrun', 'swiftc', '--version'], 30).stdout.strip(),
        'xcode': command('xcode-version', ['xcodebuild', '-version'], 30).stdout.strip(),
    }
    devices = json.loads(command('simulator-discovery', ['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], 30).stdout)['devices']
    ios = [d for runtime, rows in devices.items() if 'iOS' in runtime for d in rows if d.get('isAvailable') and 'iPhone' in d['name']]
    assert ios, 'No available iPhone simulator'
    device = next((d for d in ios if d['udid'] == args.simulator), None) if args.simulator else next((d for d in ios if d['state'] == 'Booted'), ios[0])
    assert device, 'Requested simulator is not available'
    receipt['simulator'] = {'uuid': device['udid'], 'name': device['name'], 'sdk': sdk, 'initial_state': device['state']}
    if device['state'] != 'Booted':
        try:
            command('simulator-boot', ['xcrun', 'simctl', 'boot', device['udid']], 60)
        except subprocess.TimeoutExpired:
            # The boot request can time out after CoreSimulator accepted it.
            # Observe that exact device; readiness still requires bootstatus.
            snapshot = json.loads(command('simulator-boot-timeout-state', ['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], 30).stdout)['devices']
            assert any(d['udid'] == device['udid'] and d['state'] == 'Booted' for rows in snapshot.values() for d in rows), 'Simulator boot timed out before the selected device started'
        try:
            command('simulator-bootstatus', ['xcrun', 'simctl', 'bootstatus', device['udid'], '-b'], 180)
        except subprocess.TimeoutExpired:
            # Cold CI runtimes can still be migrating device data. Preserve
            # the first timeout and permit exactly one bounded readiness wait.
            command('simulator-cold-boot-state', ['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], 30)
            receipt['cold_boot_retry'] = True
            command('simulator-bootstatus-retry', ['xcrun', 'simctl', 'bootstatus', device['udid'], '-b'], 180)
    for name, (text, reason) in variants.items():
        path = out / f'{name}-PhotoExport.swift'
        path.write_text(text)
        binary = out / name
        # The first UIKit import builds the cold SDK module cache on hosted
        # runners. CI reached this compile after successful boot readiness but
        # exhausted the old 60-second limit. Keep a bounded first compile and
        # the existing warm deadlines; a timeout still fails the entire gate.
        compile_timeout = receipt['compile_deadlines_seconds']['cold_actual' if name == 'actual' else 'warm_controls']
        compile_result = command(f'{name}-compile', ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-target', f'{architecture}-apple-ios16.0-simulator', '-sdk', sdk, str(stubs), str(root / 'apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift'), str(root / 'apps/ios/Rendprop/Photos/PhotoVersionHistory.swift'), str(path), str(fixture), '-o', str(binary)], compile_timeout)
        result = command(name, ['xcrun', 'simctl', 'spawn', device['udid'], str(binary)], 30, check=False)
        log = result.stdout + result.stderr
        (out / f'{name}.log').write_text(log)
        binary.unlink()
        passed = result.returncode == 0 if name == 'actual' else result.returncode != 0 and f'Precondition failed: {reason}' in log
        receipt['runs'].append({'name': name, 'exit_code': result.returncode, 'expected_result': passed, 'expected_failure': reason, 'output': log.strip()})
        assert passed, f'{name} unexpected result: {log}'
except Exception as error:
    receipt['failure'] = f'{type(error).__name__}: {error}'
    raise
finally:
    receipt['end_source_sha256'] = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in consumed}
    receipt['source_binding_matches'] = receipt['start_source_sha256'] == receipt['end_source_sha256']
    receipt['passed'] = len(receipt['runs']) == len(variants) and all(r['expected_result'] for r in receipt['runs']) and receipt['source_binding_matches']
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['passed'], 'Gate source changed during verification or a required run failed'
print(f'Evidence: {out}')
print(receipt['runs'][0]['output'])
print(f'PASSED: {len(receipt["runs"])-1} compiled controls failed at their exact expected invariant')
