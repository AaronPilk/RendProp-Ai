#!/usr/bin/env python3
"""Actual UIKit/AVFoundation fallback renderer with synthetic image fault controls."""
from pathlib import Path
import argparse, hashlib, json, platform, subprocess, tempfile

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--simulator')
parser.add_argument('--evidence-dir', type=Path)
args = parser.parse_args()
out = (args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-original-photo-motion-'))).resolve()
out.mkdir(parents=True, exist_ok=True)
source = root / 'apps/ios/Rendprop/Render/ReelComposer.swift'
fixture = root / 'apps/ios/tests/OriginalPhotoMotionTests.swift'
paths = [source, fixture, Path(__file__).resolve()]
def hashes(): return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
text = source.read_text(); start = text.index('enum OriginalPhotoMotion {'); opening = text.index('{', start)
depth, end = 1, opening + 1
while depth:
    depth += (text[end] == '{') - (text[end] == '}'); end += 1
body = 'import AVFoundation\nimport Foundation\nimport UIKit\n' + text[start:end] + '\n'
variants = [
    ('actual', body, None),
    ('negative-wrong-photo', body.replace('context.draw(cg, in:', 'context.setFillColor(UIColor.magenta.cgColor); context.fill(CGRect(origin: .zero, size: renderSize)); if false { context.draw(cg, in:').replace('CVPixelBufferUnlockBaseAddress(buffer, [])\n                guard adaptor.append', '}\n                CVPixelBufferUnlockBaseAddress(buffer, [])\n                guard adaptor.append'), 'fallback uses the same selected photo pixels and orientation'),
    ('negative-stretched-geometry', body.replace('let size = CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)', 'let size = renderSize'), 'fallback aspect fits the source without stretching or inventing geometry'),
]
receipt = {'passed': False, 'start_source_sha256': hashes(), 'runs': [], 'limitations': ['Actual production UIKit/AVAssetWriter renderer and actual AVFoundation frame decoding with synthetic source JPEGs. No provider, physical TestFlight device, Photos export or real listing pixels. Admission/account/receipt paths are checked separately by the actual-body reel request gate.']}
def command(name, argv, timeout=120, check=True):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    (out / (name + '.log')).write_text(result.stdout + result.stderr)
    if check: assert result.returncode == 0, name + ': ' + result.stdout + result.stderr
    return result
try:
    sdk = command('sdk', ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], 30).stdout.strip()
    inventory = json.loads(command('simulators', ['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], 30).stdout)['devices']
    devices = [d for rt, rows in inventory.items() if 'iOS' in rt for d in rows if d['isAvailable'] and 'iPhone' in d['name']]
    device = next(d for d in devices if d['udid'] == args.simulator) if args.simulator else next(d for d in devices if d['state'] == 'Booted')
    receipt['simulator'] = device
    architecture = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
    for name, code, failure in variants:
        assert failure is None or code != body
        path, binary = out / (name + '.swift'), out / name
        path.write_text(code)
        command(name + '-compile', ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-target', architecture + '-apple-ios16.0-simulator', '-sdk', sdk, str(path), str(fixture), '-o', str(binary)], 180)
        media = out / (name + '-media')
        result = command(name, ['xcrun', 'simctl', 'spawn', device['udid'], str(binary), str(media)], 120, False)
        log = result.stdout + result.stderr
        expected = result.returncode == 0 if failure is None else result.returncode != 0 and 'Precondition failed: ' + failure in log
        receipt['runs'].append({'name': name, 'exit_code': result.returncode, 'expected_result': expected, 'expected_failure': failure, 'output': log[:2000]})
        binary.unlink()
        assert expected, name + ': ' + log
        if name == 'actual': receipt['observation'] = json.loads((media / 'result.json').read_text())
except BaseException as error:
    receipt['failure'] = str(error); raise
finally:
    receipt['end_source_sha256'] = hashes()
    receipt['source_binding_matches'] = receipt['start_source_sha256'] == receipt['end_source_sha256']
    receipt['passed'] = 'failure' not in receipt and len(receipt['runs']) == len(variants) and all(r['expected_result'] for r in receipt['runs']) and receipt['source_binding_matches']
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(receipt['runs'][0]['output'].strip())
print(f'PASS: 2 compiled pixel/geometry controls; receipt: {out / "receipt.json"}')
