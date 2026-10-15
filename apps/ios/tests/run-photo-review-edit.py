#!/usr/bin/env python3
"""Execute actual per-photo review routing and persisted Original lineage, offline."""
import argparse, hashlib, json, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser(); p.add_argument('--evidence-dir', type=Path); args = p.parse_args()
OUT = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-photo-review-edit-'))
OUT.mkdir(parents=True, exist_ok=True)
VIEW = ROOT / 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'
HISTORY = ROOT / 'apps/ios/Rendprop/Photos/PhotoVersionHistory.swift'
CAPTURE = ROOT / 'apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift'
FIXTURE = ROOT / 'apps/ios/tests/PhotoReviewEditTests.swift'
source = VIEW.read_text(); history = HISTORY.read_text()

def block(text, anchor):
    assert text.count(anchor) == 1, anchor
    start = text.index(anchor); i = text.index('{', start) + 1; depth = 1
    while depth:
        depth += (text[i] == '{') - (text[i] == '}'); i += 1
    return text[start:i]

review = block(source, 'struct PhotoCompareView: View {')
sheet = block(source, 'private struct PhotoReviewEditSheet: View {')
for required in ['SecondaryButton(title: "Edit"', '.accessibilityLabel("Edit original photo")', 'action: openSinglePhotoEdit',
                 '.onReceive(photoJobs.$job) { receiveSinglePhotoWork($0) }',
                 '.sheet(isPresented: $showEditActions, onDismiss: continueSinglePhotoEdit)',
                 '.aiConsentGate()', 'job.phase?.title', 'photoVersion.edit.progress',
                 'startSinglePhotoWork(.stage(setup.pending.style ?? "modern")',
                 'startSinglePhotoWork(.custom, prompt: prompt)', 'clearSinglePhotoEdit()']:
    assert required in review, required
for required in ['PrimaryButton(title: "Declutter this photo"', 'SecondaryButton(title: space == .realEstate ? "Stage this photo"',
                 'ForEach(StagingStyle.all)', 'select(.stage(style.id))', 'select(.twilight)', 'select(.sky)',
                 'select(.lawn)', 'select(.custom)', 'No other photos are selected or changed.',
                 'Your saved edits stay in history.', 'fixedSize(horizontal: false, vertical: true)']:
    assert required in sheet, required
for forbidden in ['batchSelection', 'startEdit(', 'model.api', 'PhotoEditService', 'selectForPublication', 'setMainPhoto']:
    assert forbidden not in sheet, forbidden
for forbidden in ['batchSelection', 'startEdit(', 'applyBatchSelection', 'selectForPublication', 'setMainPhoto']:
    assert forbidden not in ''.join(block(review, x) for x in ['private func openSinglePhotoEdit()', 'private func continueSinglePhotoEdit()', 'private func startSinglePhotoWork(', 'private func receiveSinglePhotoWork(']), forbidden

enum = block(source, 'private enum PhotoReviewEdit: Equatable {').replace('private enum', 'enum', 1)
context = block(source, '@MainActor private struct NativeMediaExportContext {').replace('private struct', 'struct', 1)
methods = '\n'.join(block(review, x).replace('private ', '', 1) for x in [
    'private var reviewListing:', 'private func openSinglePhotoEdit()', 'private func continueSinglePhotoEdit()',
    'private func startSinglePhotoWork(', 'private func receiveSinglePhotoWork(', 'private func clearSinglePhotoEdit()'])
actual = enum + '\n' + context + '\n' + methods
fixture = FIXTURE.read_text()
variants = [
    ('actual', methods, history, None),
    ('wrong-family', methods, history.replace('$0.familyID == viewed.familyID && $0.isRetainedOriginalSource', 'true && $0.isRetainedOriginalSource'), 'another family cannot impersonate this Original'),
    ('unverified-source', methods, history.replace('&& $0.originalVerified && $0.imageFile == file', '&& true && $0.imageFile == file'), 'unverified earlier source cannot become Original'),
    ('stale-start', methods.replace('let context = editContext, context.isCurrent,', 'let context = editContext, true,'), history, 'actor change cannot dispatch from retained sheet'),
    ('revoked-regrant', methods.replace('editConsentRevision == AIConsent.shared.revocationRevision,', 'true,'), history, 'revoked and regranted consent cannot revive old action'),
    ('wrong-job', methods.replace('job.id == singleEditJobID,', 'true,'), history, 'another job cannot replace this photo review'),
    ('drop-edit-cleanup', methods.replace('        editContext = nil', '        // retained stale edit context'), history, 'dismissing choices releases family navigation fence'),
]
results = []
for name, body, h, expected in variants:
    folder = OUT / name; folder.mkdir(exist_ok=True)
    swift = folder / 'Checks.swift'
    swift.write_text(fixture.replace('__ENUM__', enum).replace('__CONTEXT__', context).replace('__METHODS__', body))
    hp = folder / 'History.swift'; hp.write_text(h)
    binary = folder / 'checks'
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
        '-module-cache-path', str(OUT / 'module-cache'), str(CAPTURE), str(hp), str(swift), '-o', str(binary)], capture_output=True, text=True, timeout=120)
    (folder / 'compile.log').write_text(build.stdout + build.stderr)
    assert build.returncode == 0, name + ': ' + build.stderr
    run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=45)
    log = run.stdout + run.stderr; (folder / 'runtime.log').write_text(log)
    assert (run.returncode == 0 and 'PASS ' in log) if expected is None else (run.returncode != 0 and expected in log), name + ': ' + log
    results.append({'name': name, 'compiled': True, 'exit': run.returncode, 'expectedFailure': expected})
    print(name + ': PASS', flush=True)

paths = [HISTORY, CAPTURE, FIXTURE, Path(__file__).resolve()]
assert block(VIEW.read_text(), 'struct PhotoCompareView: View {') == review, 'review changed during proof'
assert HISTORY.read_text() == history, 'history changed during proof'
receipt = {'passed': True, 'sourceHashes': {str(x.relative_to(ROOT)): hashlib.sha256(x.read_bytes()).hexdigest() for x in paths},
           'photoCompareSha256': hashlib.sha256(review.encode()).hexdigest(), 'editSheetSha256': hashlib.sha256(sheet.encode()).hexdigest(),
           'actualLogicSha256': hashlib.sha256(actual.encode()).hexdigest(), 'controls': len(variants)-1, 'results': results,
           'scope': 'Actual review Original lookup/open/consent/session/start/completion/cleanup and real persisted history; closed service/queue/session/consent/provider/UI boundaries. No paid or network call, UIKit execution or phone/SDK claim. Bulk routing is unchanged and not entered by this path.'}
(OUT / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(OUT / 'receipt.json')
