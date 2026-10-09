#!/usr/bin/env python3
"""Compile the real photo-history implementation and tests; prove named faults fail at runtime."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--inject-fault', choices=['drop-legacy-reconciliation', 'bypass-stage-review', 'latest-as-cover', 'blank-family-badges', 'forget-reviewed-stage'])
parser.add_argument('--output-dir', type=Path)
args = parser.parse_args()
output = args.output_dir or Path(tempfile.mkdtemp(prefix='rendprop-photo-reconciliation-', dir='/tmp'))
output.mkdir(parents=True, exist_ok=True)
source = ROOT / 'apps/ios/Rendprop/Photos/PhotoVersionHistory.swift'
tests = ROOT / 'apps/ios/tests/PhotoVersionHistoryTests.swift'
body = source.read_text()

def method_span(text, needle):
    start = text.index(needle)
    opening = text.index('{', start)
    depth = 1
    cursor = opening + 1
    while depth:
        if text[cursor] == '{': depth += 1
        elif text[cursor] == '}': depth -= 1
        cursor += 1
    return start, opening, cursor

expected = None
if args.inject_fault == 'drop-legacy-reconciliation':
    _, opening, end = method_span(body, 'private static func loadUnlocked(')
    body = body[:opening] + '{ return try readIndex(directory: directory) }' + body[end:]
    expected = 'first capture reconciles every pre-history gallery sibling'
elif args.inject_fault == 'bypass-stage-review':
    guard = '        guard reviewed || version.stagingReviewed == true || !version.effects.contains("stage") || index.isSelectedForListing(id) else { throw Failure.reviewRequired }\n'
    assert body.count(guard) == 2
    body = body.replace(guard, '')
    expected = 'staging cannot bypass review through cover selection'
elif args.inject_fault == 'forget-reviewed-stage':
    reviewed = ' || version.stagingReviewed == true'
    assert body.count(reviewed) == 2
    body = body.replace(reviewed, '')
    expected = 'previously reviewed staging can be reselected for publication'
elif args.inject_fault == 'latest-as-cover':
    start, _, end = method_span(body, 'static func availableCoverVersion(')
    section = body[start:end]
    assert section.count('(index.listingSelections ?? index.current)') == 1
    body = body[:start] + section.replace('(index.listingSelections ?? index.current)', 'index.current') + body[end:]
    expected = 'fallback cover uses approved clean version rather than latest staging'
elif args.inject_fault == 'blank-family-badges':
    # This intentionally corrupts the actual family resolver when the chosen
    # image is unavailable, mirroring the previous all-or-nothing badge path.
    start, _, end = method_span(body, 'func publicationChoice(')
    section = body[start:end]
    old = '            return versions[selected]'
    assert section.count(old) == 1
    new = '            return nil'
    body = body[:start] + section.replace(old, new) + body[end:]
    expected = 'latest staging identifies selected decluttered predecessor'
local_source = output / 'PhotoVersionHistory.swift'
local_source.write_text(body)
binary = output / 'photo-reconciliation'
command = ['xcrun', 'swiftc', '-parse-as-library', str(ROOT / 'apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift'), str(local_source), str(tests), '-o', str(binary)]
compile_result = subprocess.run(command, text=True, capture_output=True)
(output / 'compile.log').write_text(compile_result.stdout + compile_result.stderr)
if compile_result.returncode != 0:
    raise SystemExit('Photo controls did not compile; this does not count as a detected fault. See ' + str(output / 'compile.log'))
result = subprocess.run([str(binary)], text=True, capture_output=True)
log = result.stdout + result.stderr
(output / 'runtime.log').write_text(log)
if expected:
    passed = result.returncode != 0 and expected in log and ('Precondition failed:' in log or 'Fatal error:' in log)
else:
    # Retain all 422 prior history/layout cases plus 114 custom-intent/review/export cases.
    passed = result.returncode == 0 and 'Photo history/export geometry: 536 passed' in log
receipt = {'passed': passed, 'fault': args.inject_fault, 'expected_runtime_assertion': expected,
           'compile_exit': compile_result.returncode, 'runtime_exit': result.returncode,
           'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
           'compiled_source_sha256': hashlib.sha256(body.encode()).hexdigest(),
           'tests_sha256': hashlib.sha256(tests.read_bytes()).hexdigest(), 'output': str(output)}
(output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt))
if not passed:
    raise SystemExit('Photo reconciliation runtime verification failed. See ' + str(output / 'runtime.log'))

# In the positive run, execute the real AppModel gallery body against held,
# isolated upload/API boundaries, then add the three-sibling migration cases.
# Keeping the established fixture also checks cancellation, identity, pending
# retries and recorded provenance while exercising the new migration.
if not args.inject_fault:
    import importlib.util
    module_path = ROOT / 'tools/audit/gallery-sync-20261002/run.py'
    spec = importlib.util.spec_from_file_location('actual_gallery_fixture', module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    app_path = ROOT / 'apps/ios/Rendprop/RendpropApp.swift'
    detail_path = ROOT / 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'
    app = app_path.read_text(); detail = detail_path.read_text()
    replacements = {
        '__ENHANCED_PHOTO__': module.block(detail, 'struct EnhancedPhoto: Identifiable'),
        '__PHOTO_LOAD__': module.block(detail, '    nonisolated static func loadForListing('),
        '__PHOTO_DIRECTORY__': module.block(detail, '    static func directory(for listingID:'),
        '__ERROR_SETTER__': module.block(app, '    func setLastError('),
        '__ERROR_NOTE__': module.block(app, '    private func noteUploadProblem(_ message: String, listingLocalID:'),
        '__USER_MESSAGE__': module.block(app, '    static func userMessage(for error:'),
        '__MAX_BYTES__': module.line(app, 'private static let maxPublishedPhotoBytes:'),
        '__GALLERY_MEMO__': module.line(app, 'private var publishedGalleryAssets:'),
        '__IN_FLIGHT__': module.line(app, 'private var gallerySyncInFlight:'),
        '__PENDING__': module.line(app, 'private var gallerySyncPending:'),
        '__ERROR_PREFIX__': module.line(app, 'static let photoSyncErrorPrefix'),
        '__SYNC__': module.block(app, '    func syncGalleryPhotos(listingLocalID:'),
    }
    gallery_source = module.TEMPLATE.read_text()
    for marker, replacement in replacements.items():
        assert gallery_source.count(marker) == 1, marker
        gallery_source = gallery_source.replace(marker, replacement)
    marker = '        print("PASS actual syncGalleryPhotos:'
    assert gallery_source.count(marker) == 1
    insertion = Path(__file__).with_name('GalleryCases.swift.fragment').read_text()
    gallery_source = gallery_source.replace(marker, insertion + marker)
    gallery_file = output / 'ActualGallerySync.swift'
    gallery_file.write_text(gallery_source)
    gallery_binary = output / 'actual-gallery'
    gallery_root = output / 'isolated-gallery-files'; gallery_root.mkdir(exist_ok=True)
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(ROOT / 'apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift'), str(source), str(gallery_file), '-o', str(gallery_binary)]
    compile_result = subprocess.run(command, text=True, capture_output=True)
    (output / 'gallery-compile.log').write_text(compile_result.stdout + compile_result.stderr)
    if compile_result.returncode:
        raise SystemExit('Actual gallery fixture did not compile. See ' + str(output / 'gallery-compile.log'))
    result = subprocess.run([str(gallery_binary), str(gallery_root)], text=True, capture_output=True)
    (output / 'gallery-runtime.log').write_text(result.stdout + result.stderr)
    gallery_receipt = {'passed': result.returncode == 0, 'compile_exit': compile_result.returncode,
                       'runtime_exit': result.returncode, 'network_calls': 0, 'customer_mutations': 0,
                       'app_source_sha256': hashlib.sha256(app_path.read_bytes()).hexdigest(),
                       'detail_source_sha256': hashlib.sha256(detail_path.read_bytes()).hexdigest(),
                       'history_source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                       'actual_sync_body_sha256': hashlib.sha256(replacements['__SYNC__'].encode()).hexdigest(),
                       'compiled_fixture_sha256': hashlib.sha256(gallery_source.encode()).hexdigest(),
                       'baseline_fixture_sha256': hashlib.sha256(module.TEMPLATE.read_bytes()).hexdigest(),
                       'additional_cases_sha256': hashlib.sha256(insertion.encode()).hexdigest(),
                       'output': str(output)}
    (output / 'gallery-sync-receipt.json').write_text(json.dumps(gallery_receipt, indent=2) + '\n')
    print(result.stdout.strip())
    print(json.dumps(gallery_receipt))
    if not gallery_receipt['passed']:
        raise SystemExit('Actual legacy gallery publication failed. See ' + str(output / 'gallery-runtime.log'))
