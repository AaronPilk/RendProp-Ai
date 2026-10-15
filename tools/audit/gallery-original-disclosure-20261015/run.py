#!/usr/bin/env python3
"""Execute actual gallery sync + retained-original certification, without network/UI."""
from pathlib import Path
import argparse, datetime, hashlib, importlib.util, json, re, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--output-dir', type=Path)
args = parser.parse_args()
out = args.output_dir or Path(tempfile.mkdtemp(prefix='rendprop-gallery-original-'))
out.mkdir(parents=True, exist_ok=True)
fixture_module = ROOT / 'tools/audit/gallery-sync-20261002/run.py'
spec = importlib.util.spec_from_file_location('gallery_fixture', fixture_module)
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
paths = [
    'apps/ios/Rendprop/RendpropApp.swift', 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift',
    'apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift', 'apps/ios/Rendprop/Photos/PhotoVersionHistory.swift',
    'apps/ios/Rendprop/Photos/PhotoImportSequence.swift', 'apps/ios/Rendprop/Photos/PhotoGalleryDisclosure.swift',
    'tools/audit/gallery-sync-20261002/Fixture.swift.template',
    'tools/audit/gallery-original-disclosure-20261015/Cases.swift.fragment',
    'tools/audit/gallery-original-disclosure-20261015/run.py',
    'tools/audit/gallery-sync-20261002/run.py',
    'apps/ios/Rendprop/Photos/PhotoGalleryMutationFence.swift',
]
sha = lambda value: hashlib.sha256(value).hexdigest()
before = {p: sha((ROOT / p).read_bytes()) for p in paths}
app = (ROOT / paths[0]).read_text(); detail = (ROOT / paths[1]).read_text()
sync = module.block(app, '    func syncGalleryPhotos(listingLocalID:')
helper = (ROOT / paths[5]).read_text()
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
    '__REMOVAL_FENCE__': module.removal_fence(app),
    '__ERROR_PREFIX__': module.line(app, 'static let photoSyncErrorPrefix'),
    '__SYNC__': sync,
}
source = module.TEMPLATE.read_text()
for key, value in replacements.items():
    assert source.count(key) == 1; source = source.replace(key, value)
cases = Path(__file__).with_name('Cases.swift.fragment').read_text()
assert cases.count('__ORIGINAL_SHA__') == 1
cases = cases.replace('__ORIGINAL_SHA__', sha(b'actual-original-original'))
marker = '        print("PASS actual syncGalleryPhotos:'
assert source.count(marker) == 1; source = source.replace(marker, cases + marker)
controls = [
    ('old-original-guard', 'sync', ' && original == nil', '', 'Verified retained Original publishes without AI disclosure'),
    ('ignore-original-effects', 'helper', 'version.effects.isEmpty', 'true', 'Altered metadata never earns a retained Original exemption: 0'),
    ('ignore-original-parent', 'helper', 'version.parentID == nil', 'true', 'Altered metadata never earns a retained Original exemption: 2'),
    ('ignore-original-sha', 'helper', 'maxBytes: maxBytes) == original', 'maxBytes: maxBytes) != nil', 'Same-size source mutation during upload cannot publish'),
]
receipt = {'checkedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'sourceHashes': before,
           'networkCalls': 0, 'hostedMutations': 0, 'paidCalls': 0, 'UIExecutions': 0,
           'actualSyncSHA256': sha(sync.encode()), 'controls': []}
for name, target, old, new, expected in [('positive', None, None, None, None), *controls]:
    folder = out / name; folder.mkdir(exist_ok=True)
    projected_source, projected_helper = source, helper
    if target == 'sync':
        assert sync.count(old) == 1; projected_source = source.replace(sync, sync.replace(old, new))
    if target == 'helper':
        assert helper.count(old) == 1; projected_helper = helper.replace(old, new)
    main = folder / 'Main.swift'; main.write_text(projected_source)
    local_helper = folder / 'PhotoGalleryDisclosure.swift'; local_helper.write_text(projected_helper)
    binary = folder / 'checks'; data = folder / 'owned-documents'; data.mkdir(exist_ok=True)
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
               *[str(ROOT / p) for p in paths[2:5]], str(ROOT / paths[-1]), str(local_helper), str(main), '-o', str(binary)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=90)
    (folder / 'compile.log').write_text(result.stdout + result.stderr)
    assert result.returncode == 0, f'{name}: compilation is not a runtime control; see {folder}'
    result = subprocess.run([str(binary), str(data)], capture_output=True, text=True, timeout=90)
    log = result.stdout + result.stderr; (folder / 'runtime.log').write_text(log)
    if expected is None:
        assert result.returncode == 0, f'Positive failed: {folder}'
        count = re.search(r'(\d+) assertions', log); assert count
        receipt['assertions'] = int(count[1])
    else:
        assert result.returncode != 0 and expected in log, f'Fault not rejected at named assertion: {folder}'
        receipt['controls'].append({'name': name, 'compiled': True, 'runtimeRejected': True, 'oracle': expected})
    print(name, 'PASS', flush=True)
assert before == {p: sha((ROOT / p).read_bytes()) for p in paths}, 'Consumed source changed during proof'
receipt['passed'] = True
(out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps({'passed': True, 'receipt': str(out / 'receipt.json'), 'assertions': receipt['assertions'], 'compiledControls': len(receipt['controls'])}))
