#!/usr/bin/env python3
"""Compile actual UIKit export code plus synthetic boundary fixtures and fault controls."""
import argparse
import hashlib
import json
import platform
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--simulator', help='Existing available iOS simulator UUID')
parser.add_argument('--evidence-dir', type=Path)
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-photo-export-renderer-'))
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
for name, (text, reason) in variants.items():
    assert name == 'actual' or text != base, f'{name} mutation anchor missing'

sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], text=True))['devices']
ios = [d for runtime, rows in devices.items() if 'iOS' in runtime for d in rows if d.get('isAvailable') and 'iPhone' in d['name']]
assert ios, 'No available iPhone simulator'
device = next((d for d in ios if d['udid'] == args.simulator), None) if args.simulator else next((d for d in ios if d['state'] == 'Booted'), ios[0])
assert device, 'Requested simulator is not available'
if device['state'] != 'Booted':
    subprocess.run(['xcrun', 'simctl', 'boot', device['udid']], check=True, capture_output=True)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', device['udid'], '-b'], check=True, capture_output=True, timeout=180)
architecture = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
fixture = root / 'apps/ios/tests/PhotoExportRendererTests.swift'
stubs = root / 'apps/ios/tests/PhotoExportPlatformStubs.swift'
consumed = [source, fixture, stubs, Path(__file__).resolve(), root / 'apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift', root / 'apps/ios/Rendprop/Photos/PhotoVersionHistory.swift']
receipt = {
    'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
    'consumed_sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in consumed},
    'passed': False,
    'start_source_sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in consumed},
    'simulator': {'uuid': device['udid'], 'name': device['name'], 'sdk': sdk},
    'runs': [],
    'limitations': ['Actual UIKit renderer and filesystem delivery tested using synthetic images.', 'No vendor calls, camera, Apple account or Photos-library writes.', 'SwiftUI app context dependencies are fixture doubles; full app compilation is separate.', 'The level adjustment rotates and crops a JPEG copy; it cannot recover unseen room geometry.'],
}
try:
    for name, (text, reason) in variants.items():
        path = out / f'{name}-PhotoExport.swift'
        path.write_text(text)
        binary = out / name
        compile_result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-target', f'{architecture}-apple-ios16.0-simulator', '-sdk', sdk, str(stubs), str(root / 'apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift'), str(root / 'apps/ios/Rendprop/Photos/PhotoVersionHistory.swift'), str(path), str(fixture), '-o', str(binary)], capture_output=True, text=True, timeout=60)
        (out / f'{name}-compile.log').write_text(compile_result.stdout + compile_result.stderr)
        assert compile_result.returncode == 0, f'{name} compile failed: {compile_result.stderr}'
        result = subprocess.run(['xcrun', 'simctl', 'spawn', device['udid'], str(binary)], capture_output=True, text=True, timeout=30)
        log = result.stdout + result.stderr
        (out / f'{name}.log').write_text(log)
        binary.unlink()
        passed = result.returncode == 0 if name == 'actual' else result.returncode != 0 and f'Precondition failed: {reason}' in log
        receipt['runs'].append({'name': name, 'exit_code': result.returncode, 'expected_result': passed, 'expected_failure': reason, 'output': log.strip()})
        assert passed, f'{name} unexpected result: {log}'
finally:
    receipt['end_source_sha256'] = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in consumed}
    receipt['source_binding_matches'] = receipt['start_source_sha256'] == receipt['end_source_sha256']
    receipt['passed'] = len(receipt['runs']) == len(variants) and all(r['expected_result'] for r in receipt['runs']) and receipt['source_binding_matches']
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['passed'], 'Gate source changed during verification or a required run failed'
print(f'Evidence: {out}')
print(receipt['runs'][0]['output'])
print(f'PASSED: {len(receipt["runs"])-1} compiled controls failed at their exact expected invariant')
