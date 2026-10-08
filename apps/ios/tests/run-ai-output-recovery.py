#!/usr/bin/env python3
"""Execute actual native recovery bodies against closed API/image/download boundaries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--evidence-dir', type=Path)
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-ai-output-recovery-'))
out.mkdir(parents=True, exist_ok=True, mode=0o700)
paths = {name: ROOT / path for name, path in {
    'photo': 'apps/ios/Rendprop/Photos/PhotoEditService.swift',
    'detail': 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift',
    'model': 'apps/ios/Rendprop/RendpropApp.swift',
    'api': 'apps/ios/Rendprop/Networking/APIClient.swift',
    'history': 'apps/ios/Rendprop/Photos/PhotoVersionHistory.swift',
    'capture': 'apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift',
    'fixture': 'apps/ios/tests/AIOutputRecoveryTests.swift',
    'video': 'apps/ios/Rendprop/Resources/player/demo.mp4',
    'runner': 'apps/ios/tests/run-ai-output-recovery.py',
}.items()}
def hashes():
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths.values()}
def block(source, anchor):
    if source.count(anchor) != 1:
        raise RuntimeError('Ambiguous actual source anchor: ' + anchor)
    start = source.index(anchor)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
def descriptor(path):
    return {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'bytes': path.stat().st_size}
def execute(name, argv, timeout):
    target = out / (name + '.log')
    started = time.monotonic()
    timed_out = False
    error = None
    with target.open('x') as log:
        process = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            process.wait(timeout=timeout)
        except BaseException as failure:
            error = failure
            timed_out = isinstance(failure, subprocess.TimeoutExpired)
            for sig, wait in [(signal.SIGTERM, 3), (signal.SIGKILL, 5)]:
                try: os.killpg(process.pid, sig)
                except ProcessLookupError: pass
                try: process.wait(timeout=wait)
                except subprocess.TimeoutExpired:
                    if sig == signal.SIGKILL: raise
    row = {'name': name, 'argv': argv, 'exit_code': process.returncode, 'timeout_seconds': timeout,
           'timed_out': timed_out, 'elapsed_seconds': time.monotonic() - started, 'log': descriptor(target)}
    receipt['commands'].append(row)
    if error is not None: raise error
    return process.returncode, target.read_text()
receipt = {'accepted': False, 'synthetic_boundaries': True, 'network_requests': 0, 'provider_calls': 0,
    'start_source_hashes': hashes(), 'commands': [], 'controls': [], 'limitations': [
        'Actual photo request/history/filesystem and aerial poll/save predicates execute with closed API, UIImage preparation, clock and download doubles.',
        'Actual AVFoundation inspects a retained local demo video, HTML and empty local files; no generated-model fidelity or physical-device acceptance is claimed.',
        'Initial aerial POST lost before an accepted receipt is not recovered by this patch; legacy unbound receipts are preserved for support.',
        'No automatic provider retry, cloud actions, camera, Photos write or production account is used.']}
try:
    photo, detail, api, model = [paths[n].read_text() for n in ['photo', 'detail', 'api', 'model']]
    actual = 'import Foundation\nimport CryptoKit\nimport AVFoundation\n'
    actual += '\n'.join(block(api, anchor) for anchor in ['struct AIPhotoEditRequest:', 'struct AIPhotoEditResult:', 'struct AIVideoJob:', 'enum AIVideoStatus:']) + '\n'
    actual += block(photo, 'struct PendingPhotoEdit:') + '\n'
    service = photo[photo.index('@MainActor\nfinal class PhotoEditService'):photo.index('    func start(title:')]
    actual += service + '\n}\n'
    actual += block(detail, 'private struct PendingAerialJob:').replace('private struct', 'struct', 1) + '\n'
    actual += block(detail, 'private struct AerialMeta:').replace('private struct', 'struct', 1) + '\n'
    poll = block(detail, '    private func pollAndStore(_ pending: PendingAerialJob, api: APIClient, revision: UInt64)')
    poll = poll.replace('private func', 'func', 1).replace('Date()', 'RecoveryClock.now')
    poll = poll.replace('Task.sleep(nanoseconds: 6_000_000_000)', 'RecoveryClock.sleep()')
    poll = poll.replace('URLSession.shared.download(from: remoteURL)', 'DownloadBoundary.download(from: remoteURL)')
    fixture = paths['fixture'].read_text().replace('// ACTUAL_SET_AERIAL', block(model, '    func setAerial(relPath:'))
    fixture = fixture.replace('// ACTUAL_POLL_AND_STORE', poll)
    human_start = detail.index('    static func humanReadable(')
    human = detail[human_start:detail.index('\n    }', human_start) + 6]
    fixture = fixture.replace('// ACTUAL_HUMAN_READABLE', human)
    fixture = fixture.replace('// ACTUAL_PHOTO_REQUEST_CONTEXT', block(detail, '    private var photoRequestContext:').replace('private var', 'var', 1))
    forget_start = detail.index('.confirmationDialog("Forget this pending photo request?"')
    action = block(detail[forget_start:detail.index('            Button("Cancel"', forget_start)], '            Button("Forget request", role: .destructive) {')
    fixture = fixture.replace('// ACTUAL_FORGET_ACTION', action[action.index('{') + 1:-1])
    # Exact UI admission/capture and billing copy are checked against the real View.
    generate = block(detail, '    private func generateWithSession() {\n        guard phase != .generating, !listing.isSample, !isSavingPhoto')
    if generate.index('PendingAerialJob.load') >= generate.index('api.aiVideoAerial'): raise RuntimeError('Existing aerial must recover before submit')
    if 'Nothing was charged' in detail or 'Nothing charged' in detail: raise RuntimeError('Unsupported billing claim remains')
    if 'auth.syncSessionRevision == photoForgetRevision' not in detail: raise RuntimeError('Forget confirmation revision fence missing')
    if 'stored images' not in detail.lower() and 'saved images and originals are not deleted' not in detail: raise RuntimeError('Forget disclosure missing')
    receipt['actual_body_sha256'] = hashlib.sha256(actual.encode()).hexdigest()
    receipt['synthetic_fixture_sha256'] = hashlib.sha256(fixture.encode()).hexdigest()
    # These controls alter real production predicates, not test doubles.
    changes = [
        ('actual', actual, fixture, None),
        ('negative-no-durable-intent', actual.replace('if existing == nil { try pending.saveBeforeDispatch() }', '// omitted intent'), fixture, 'durable photo intent exists before dispatch'),
        ('negative-new-replay-key', actual.replace('api.aiPhotoEdit(pending.request.value)', 'api.aiPhotoEdit(PendingPhotoEdit.Request(request, key: UUID().uuidString).value)'), fixture, 'lost response recovery uses one provider operation'),
        ('negative-no-source-fingerprint', actual.replace('if let existing, existing.source != source { throw PendingPhotoEdit.Failure.differentIntent }', '// omitted source binding'), fixture, 'different intent must not dispatch'),
        ('negative-download-retirement', actual, fixture.replace('statusText = "Downloading your aerial…"', 'try pending.clear(); statusText = "Downloading your aerial…"'), 'local aerial failure retains receipt except confirmed terminal failure'),
        ('negative-video-validation', actual, fixture[:fixture.index('        let asset = AVURLAsset(url: tmp)')] + fixture[fixture.index('        let dest = FileStore.aerialsDir', fixture.index('        let asset = AVURLAsset(url: tmp)')):], 'unconfirmed or failed aerial must not be presented as saved'),
        ('negative-aerial-scope', actual, fixture.replace(block(fixture, '        let requireCurrent: @MainActor () throws -> Void = {'), '        let requireCurrent: @MainActor () throws -> Void = { try Task.checkCancellation() }'), 'unconfirmed or failed aerial must not be presented as saved'),
        ('negative-early-retirement', actual, fixture.replace('        let previous = model.listings.first', '        try pending.clear()\n        let previous = model.listings.first'), 'local aerial failure retains receipt except confirmed terminal failure'),
        ('negative-forget-revision', actual, fixture.replace('auth.syncSessionRevision == photoForgetRevision, !isProcessing', '!isProcessing'), 'stale or replaced confirmation cannot forget another request'),
    ]
    for name, body, doubles, reason in changes:
        if reason and body == actual and doubles == fixture: raise RuntimeError('Missing control anchor: ' + name)
        generated, boundary, binary = out / (name + '.swift'), out / (name + '-fixture.swift'), out / name
        generated.write_text(body); boundary.write_text(doubles)
        code, log = execute(name + '-compile', ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(generated), str(boundary), str(paths['history']), str(paths['capture']), '-o', str(binary)], 240)
        if code != 0: raise RuntimeError(name + ' compile failed; see retained log')
        code, log = execute(name + '-run', [str(binary), str(out / (name + '-files')), str(paths['video'])], 120)
        matched = code == 0 if reason is None else code != 0 and 'Fatal error: ' + reason in log
        receipt['controls'].append({'name': name, 'expected_failure': reason, 'accepted': matched, 'generated': descriptor(generated), 'fixture': descriptor(boundary), 'binary': descriptor(binary)})
        if not matched: raise RuntimeError(name + ' did not meet the exact runtime oracle')
    receipt['end_source_hashes'] = hashes()
    if receipt['end_source_hashes'] != receipt['start_source_hashes']: raise RuntimeError('Consumed source changed during execution')
    receipt['accepted'] = True
except BaseException as error:
    receipt['failure'] = type(error).__name__ + ': ' + str(error)
    raise
finally:
    target = out / 'receipt.json'
    with target.open('x') as stream:
        os.chmod(target, 0o600); json.dump(receipt, stream, indent=2); stream.flush(); os.fsync(stream.fileno())
    print('EVIDENCE=' + str(out), flush=True)
