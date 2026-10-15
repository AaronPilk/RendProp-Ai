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
detail = root / 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'
fixture = root / 'apps/ios/tests/OriginalPhotoMotionTests.swift'
framing_policy = root / 'apps/ios/Rendprop/Capture/VideoPhotoFramingReview.swift'
wire_runner = root / 'apps/ios/tests/run-video-drift-wire.py'
wire_fixture = root / 'apps/ios/tests/VideoDriftWireTests.swift'
paths = [source, detail, fixture, framing_policy, wire_runner, wire_fixture, Path(__file__).resolve()]
def hashes(): return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
def block(text, anchor):
    assert text.count(anchor) == 1, anchor
    start = text.index(anchor); opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[start:end]
text, view = source.read_text(), detail.read_text()
prep = 'enum AIImagePrep {\n' + '\n'.join(block(view, anchor) for anchor in ['    static func error(_ message:', '    static func downscaled(', '    static func reelSource(']) + '\n}\n'
prep += 'struct EnhancedPhoto { let enhancedURL: URL }\nenum ReelQualityPrep {\n'
prep += block(view, '    nonisolated private static func preparedReelJPEG(').replace('private static', 'static', 1) + '\n'
prep += block(view, '    nonisolated private static func reelDisplayAspect(').replace('private static', 'static', 1) + '\n}\n'
body = 'import AVFoundation\nimport CoreImage\nimport Foundation\nimport UIKit\n' + block(text, 'enum OriginalPhotoMotion {') + '\n' + prep
# Source preparation now validates its actual JPEG before returning. Include
# that production ImageIO boundary instead of an unchecked fixture replacement.
policy = framing_policy.read_text()
body += '\nimport ImageIO\nenum VideoFramingReviewPolicy {\n' + block(policy, '    static func displayedSize(') + '\n}\n'
body += block(policy, 'enum VideoPreparedSourcePolicy {') + '\n'
variants = [
    ('actual', body, None),
    ('negative-wrong-photo', body.replace('context.draw(cg, in:', 'context.setFillColor(UIColor.magenta.cgColor); context.fill(CGRect(origin: .zero, size: renderSize)); if false { context.draw(cg, in:').replace('CVPixelBufferUnlockBaseAddress(buffer, [])\n                guard adaptor.append', '}\n                CVPixelBufferUnlockBaseAddress(buffer, [])\n                guard adaptor.append'), 'fallback uses one centered cover crop of the selected photo without a backdrop'),
    ('negative-stretched-geometry', body.replace('let size = CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)', 'let size = renderSize'), 'fallback cover crop stays centered on the original geometry'),
    ('negative-fitted-bars', body.replace('let scale = max(renderSize.width / CGFloat(cg.width), renderSize.height / CGFloat(cg.height))', 'let scale = min(renderSize.width / CGFloat(cg.width), renderSize.height / CGFloat(cg.height))'), 'fallback encodes source pixels to every edge without black bars'),
    ('negative-extra-zoom', body.replace('let size = CGSize(width: CGFloat(cg.width) * scale, height: CGFloat(cg.height) * scale)', 'let size = CGSize(width: CGFloat(cg.width) * scale * 1.12, height: CGFloat(cg.height) * scale * 1.12)'), 'fallback cover crop stays centered on the original geometry'),
    ('negative-source-1280', body.replace('maxDimension: 2048)', 'maxDimension: 1280)'), 'source JPEG retains the available full-resolution pixels up to 2048'),
    ('negative-source-low-quality', body.replace('compressionQuality: 0.95)', 'compressionQuality: 0.85)'), 'source JPEG uses the actual high-quality 0.95 encoder'),
    ('negative-source-upscale', body.replace('let scale = min(1, maxDimension / longest)', 'let scale = maxDimension / longest'), 'small source JPEG is never upscaled to pretend detail'),
    ('negative-source-crop', body.replace('static func reelSource(_ image: UIImage, aspect: String) -> UIImage { image }', '''static func reelSource(_ image: UIImage, aspect: String) -> UIImage {
        let ratio: CGFloat = aspect == "9:16" ? 9.0 / 16.0 : 16.0 / 9.0
        let width = image.size.width, height = image.size.height
        let size = width / height > ratio ? CGSize(width: floor(height * ratio), height: height)
            : CGSize(width: width, height: floor(width / ratio))
        let format = UIGraphicsImageRendererFormat.default(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height))
        }
    }'''), 'conditioning preserves the complete selected photo aspect before delivery formatting'),
    ('negative-review-boundary-removed', body.replace('try PhotoVersionHistory.requireReelReview(imageURL: photo.enhancedURL)', '/* closed review boundary omitted */'), 'source preparation invokes closed review before encoding'),
]
receipt = {'passed': False, 'start_source_sha256': hashes(), 'consumed_source_sha256': hashlib.sha256(body.encode()).hexdigest(), 'runs': [], 'limitations': ['Actual production UIKit source preparation/downsampling/JPEG encoder, AVAssetWriter renderer and AVFoundation frame decoding with synthetic source JPEGs. PhotoVersionHistory is a closed review boundary here; the separate photo-reel-egress gate executes the real persisted history policy. No provider, physical TestFlight device, Photos export or real listing pixels. Admission/account/receipt paths are checked separately by the actual-body reel request gate. Preview layout source is inspected separately; extracted measured display aspect runs on actual encoded tracks. No claim of invented detail or provider output quality.']}
def command(name, argv, timeout=120, check=True):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    (out / (name + '.log')).write_text(result.stdout + result.stderr)
    if check: assert result.returncode == 0, name + ': ' + result.stdout + result.stderr
    return result
try:
    sdk = command('sdk', ['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], 30).stdout.strip()
    inventory = json.loads(command('simulators', ['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], 30).stdout)['devices']
    # An owned iPhone simulator may have a project-specific display name.
    devices = [d for rt, rows in inventory.items() if 'iOS' in rt for d in rows
        if d['isAvailable'] and ('iPhone' in d.get('deviceTypeIdentifier', '') or 'iPhone' in d['name'])]
    device = next(d for d in devices if d['udid'] == args.simulator) if args.simulator else next(d for d in devices if d['state'] == 'Booted')
    receipt['simulator'] = device
    architecture = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
    for name, code, failure in variants:
        assert failure is None or code != body
        path, binary = out / (name + '.swift'), out / name
        path.write_text(code)
        command(name + '-compile', ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-target', architecture + '-apple-ios16.0-simulator', '-sdk', sdk, str(path), str(fixture), '-o', str(binary)], 180)
        media = out / (name + '-media')
        mode = ['--prep-only'] if name.startswith('negative-source-') else []
        result = command(name, ['xcrun', 'simctl', 'spawn', device['udid'], str(binary), str(media)] + mode, 180, False)
        log = result.stdout + result.stderr
        expected = result.returncode == 0 if failure is None else result.returncode != 0 and 'Precondition failed: ' + failure in log
        receipt['runs'].append({'name': name, 'exit_code': result.returncode, 'expected_result': expected, 'expected_failure': failure, 'output': log[:2000]})
        binary.unlink()
        assert expected, name + ': ' + log
        if name == 'actual': receipt['observation'] = json.loads((media / 'result.json').read_text())
    # Bind the actual UIImage-encoded, high-detail source through the real QC
    # serializer/request/executor. The server source guard is tested separately
    # against this same file; URLProtocol keeps this transport proof offline.
    wire_out = out / 'actual-jpeg-wire'
    command('actual-jpeg-wire', ['python3', str(wire_runner), '--source-jpeg', str(out / 'actual-media/source-high-detail-prepared.jpg'), '--evidence-dir', str(wire_out)], 180)
    wire_receipt = json.loads((wire_out / 'receipt.json').read_text())
    assert wire_receipt['passed'] and wire_receipt['source_jpeg_binding_matches']
    receipt['actual_jpeg_wire_receipt'] = str(wire_out / 'receipt.json')
    receipt['actual_jpeg_wire_sha256'] = hashlib.sha256((wire_out / 'receipt.json').read_bytes()).hexdigest()
except BaseException as error:
    receipt['failure'] = str(error); raise
finally:
    receipt['end_source_sha256'] = hashes()
    receipt['source_binding_matches'] = receipt['start_source_sha256'] == receipt['end_source_sha256']
    receipt['passed'] = 'failure' not in receipt and len(receipt['runs']) == len(variants) and all(r['expected_result'] for r in receipt['runs']) and receipt['source_binding_matches']
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(receipt['runs'][0]['output'].strip())
print(f'PASS: {len(variants) - 1} compiled pixel/geometry/source-quality controls; receipt: {out / "receipt.json"}')
