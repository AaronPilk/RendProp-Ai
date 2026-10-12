#!/usr/bin/env python3
"""Source-bound iOS AVFoundation proof using identical synthetic MP4/.tmp bytes."""
from pathlib import Path
import argparse
import hashlib
import json
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--simulator')
parser.add_argument('--evidence-dir', type=Path)
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-clip-frames-'))
out.mkdir(parents=True, exist_ok=True)
source = root / 'apps/ios/Rendprop/Render/DriftCheck.swift'
screen = root / 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'
fixture = root / 'apps/ios/tests/ClipFramesTests.swift'
paths = [source, screen, fixture, Path(__file__).resolve()]
hashes = lambda: {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}

def block(text, anchor):
    assert text.count(anchor) == 1, anchor
    start = text.index(anchor)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

before = hashes()
body = 'import AVFoundation\nimport Foundation\nimport UIKit\n' + block(source.read_text(), 'enum ClipFrames {')
body += '\nenum ReelClipPathHarness {\n' + block(screen.read_text(), '    nonisolated static func clipPath(') + '\n}\n'
variants = [
    ('actual', body, None),
    ('negative-no-decoded-frames', body.replace('let asset = AVURLAsset(url: url)', 'return []; let asset = AVURLAsset(url: url)'), 'known-good mp4 yields all three actual AVFoundation frames'),
    ('negative-overwrite-existing-sibling', body.replace('let renamed = downloaded.deletingLastPathComponent().appendingPathComponent("reel-download-\\(UUID().uuidString).mp4")', 'let renamed = downloaded.deletingPathExtension().appendingPathExtension("mp4"); try? FileManager.default.removeItem(at: renamed)'), 'normalizing a download never overwrites its existing mp4 sibling'),
]
receipt = {'passed': False, 'start_source_sha256': before, 'runs': [], 'limitations': ['Actual iOS AVFoundation/UIImage and actual ClipFrames body decode a local AVAssetWriter H.264 fixture. No provider response, TestFlight physical-device codec, generation quality or network proof. Raw .tmp decoding is measured and is not forced to fail.']}
def command(name, argv, timeout, check=True):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    (out / (name + '.log')).write_text(result.stdout + result.stderr)
    if check:
        assert result.returncode == 0, name + ': ' + result.stdout + result.stderr
    return result

try:
    sdk = command('sdk', ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], 30).stdout.strip()
    inventory = json.loads(command('simulators', ['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], 30).stdout)['devices']
    devices = [d for runtime, rows in inventory.items() if 'iOS' in runtime for d in rows if d['isAvailable'] and 'iPhone' in d['name']]
    device = next(d for d in devices if d['udid'] == args.simulator) if args.simulator else next((d for d in devices if d['state'] == 'Booted'), devices[0])
    receipt['simulator'] = device
    if device['state'] != 'Booted':
        command('boot', ['xcrun', 'simctl', 'boot', device['udid']], 60)
        command('bootstatus', ['xcrun', 'simctl', 'bootstatus', device['udid'], '-b'], 180)
    architecture = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
    for name, text, reason in variants:
        assert reason is None or text != body, name + ' mutation anchor missing'
        path, binary = out / (name + '.swift'), out / name
        path.write_text(text)
        command(name + '-compile', ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-target', architecture + '-apple-ios16.0-simulator', '-sdk', sdk, str(path), str(fixture), '-o', str(binary)], 300)
        media = out / (name + '-media')
        run = command(name, ['xcrun', 'simctl', 'spawn', device['udid'], str(binary), str(media)], 120, check=False)
        log = run.stdout + run.stderr
        expected = run.returncode == 0 if reason is None else run.returncode != 0 and 'Precondition failed: ' + reason in log
        receipt['runs'].append({'name': name, 'exit_code': run.returncode, 'expected_result': expected, 'expected_failure': reason, 'output': log[:4000]})
        binary.unlink()
        if name == 'actual' and run.returncode == 0:
            receipt['decoder_observation'] = json.loads((media / 'result.json').read_text())
        assert expected, name + ': ' + log
except BaseException as error:
    receipt['failure'] = str(error)
    raise
finally:
    receipt['end_source_sha256'] = hashes()
    receipt['source_binding_matches'] = before == receipt['end_source_sha256']
    receipt['passed'] = 'failure' not in receipt and len(receipt['runs']) == len(variants) and all(r['expected_result'] for r in receipt['runs']) and receipt['source_binding_matches']
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['passed'], 'Source changed during the AVFoundation gate'
print(receipt['runs'][0]['output'])
print(json.dumps(receipt['decoder_observation'], sort_keys=True))
print(f'PASS: {len(variants) - 1} negative controls; receipt: {out / "receipt.json"}')
