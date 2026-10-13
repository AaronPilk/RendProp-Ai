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
parser.add_argument('--actual-only', action='store_true', help='Compile/run the current actual UIKit fixture only; controls remain required for the full gate')
parser.add_argument('--coordinator-only', action='store_true', help='Run actual fixture and new coordinator controls only')
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-photo-export-renderer-', dir=os.environ.get('RUNNER_TEMP')))
out.mkdir(parents=True, exist_ok=True)
source = root / 'apps/ios/Rendprop/Photos/PhotoExport.swift'
base = source.read_text()
variants = {
    'actual': (base, None),
    'negative-custom-review-removed': (base.replace('try PhotoVersionHistory.requireDownloadReview(imageURL: source)', '/* review guard removed */'), 'unreviewed custom cannot be exported by the actual renderer'),
    'negative-paired-source-review-removed': (base.replace('try PhotoVersionHistory.requireDownloadReview(imageURL: photo.originalURL)', '/* paired source review guard removed */'), 'paired-original export cannot expose an unreviewed custom ancestor'),
    'negative-original-added-last': (base.replace('images: urls,', 'images: urls.sorted { $0.lastPathComponent < $1.lastPathComponent },'), 'other versions sit between the original and the current edit'),
    'negative-mls-overlay': (base.replace('options.destination != .mls && options.includeLabel', 'options.includeLabel'), 'MLS file is clean with no banned text overlay'),
    'negative-web-label-missing': (base.replace('options.destination != .mls && options.includeLabel', 'false && options.destination != .mls && options.includeLabel'), 'web label burns into exported copy'),
    'negative-original-mutated': (base.replace('try retained.data.write(to: originalURL, options: .atomic)', 'try Data("mutated-original".utf8).write(to: originalURL, options: .atomic)'), 'exported retained original byte exact'),
    'negative-jpeg-is-png': (base.replace('rendered.jpegData(compressionQuality: 0.97)', 'rendered.pngData()'), 'PNG input is encoded as actual JPEG bytes'),
    'negative-level-no-crop': (base.replace('let cropScale = min(', 'let cropScale = 1.0; let unusedCropScale = min('), 'manual level crops without enlarging the photograph'),
    'negative-archive-drops-disclosures': (base.replace('for file in prepared.files { entries.append(ZipArchive.Entry(name: file.lastPathComponent, url: file)) }', 'for file in prepared.images { entries.append(ZipArchive.Entry(name: file.lastPathComponent, url: file)) }'), 'ZIP carries every prepared file including disclosure notes'),
    'negative-archive-drops-extras': (base.replace('entries.append(ZipArchive.Entry(name: name, url: extra.url))', '/* omitted non-photo extra */'), 'listing ZIP includes exact walkthrough bytes'),
    'negative-video-only-refused': (base.replace('guard !prepared.files.isEmpty || !extras.isEmpty else', 'guard !prepared.files.isEmpty else'), 'video-only listing must package without photos'),
    'negative-versions-dropped': (base.replace('for (position, other) in savedVersions.enumerated() {', 'for (position, other) in savedVersions.enumerated() where false {'), 'reviewed custom exports with its original, every stored version and each disclosure'),
    'negative-current-version-dropped': (base.replace('for (position, other) in savedVersions.enumerated() {', 'for (position, other) in savedVersions.enumerated() where other.id != version.id {'), 'reviewed custom exports with its original, every stored version and each disclosure'),
    'negative-unreviewed-version-exported': (base.replace('if other.needsCustomReview { withheld += 1; continue }', '/* custom review bypassed */').replace('try PhotoVersionHistory.requireDownloadReview(imageURL: stored)', '/* stored-file review bypassed */'), 'an unreviewed custom descendant is withheld from the package'),
    'negative-version-bytes-mutated': (base.replace('try retained.data.write(to: copy, options: .atomic)', 'try Data("mutated-version".utf8).write(to: copy, options: .atomic)'), 'an exported version is the exact stored bytes'),
    'negative-retained-format-guessed': (base.replace('return (data, ext == "jpeg" ? "jpg" : ext)', 'return (data, source.pathExtension)'), 'retained PNG filenames describe their real bytes despite stored jpg names'),
    'negative-version-chronology-unpadded': (base.replace('let versionWidth = max(1, String(savedVersions.count).count)', 'let versionWidth = 1'), 'ten or more retained versions sort in the actual chronological order'),
    'negative-missing-version-skipped': (base.replace('let retained = try retainedImage(at: stored, read: readRetained)', 'guard let retained = try? retainedImage(at: stored, read: readRetained) else { continue }'), 'a missing retained version cannot be silently omitted'),
    'negative-history-race-accepted': (base.replace('try PhotoVersionHistory.requireUnchanged(history, directory: photoDirectory)', '/* changed history accepted */'), 'a history change during export prevents mixed version delivery'),
    'negative-crop-stretches': (base.replace('let drawWidth = CGFloat(fullWidth) * scale, drawHeight = CGFloat(fullHeight) * scale', 'let drawWidth = size.width, drawHeight = size.height'), 'center crop actually excludes left red strip'),
}
def mutate_coordinator(old, new):
    start = base.index('    static func prepareCoordinator(')
    end = base.index('    /// Explicit nested allowlist;', start)
    return base[:start] + base[start:end].replace(old, new) + base[end:]

coordinator_variants = {
    'negative-coordinator-original-mutated': (base.replace('write(retained.data, "Originals/"', 'write(Data("mutated".utf8), "Originals/"'), 'coordinator original master preserves exact bytes and real format'),
    'negative-coordinator-master-mutated': (base.replace('let master = try write(retained.data, category', 'let master = try write(Data("mutated".utf8), category'), 'coordinator declutter master retains the full saved bytes'),
    'negative-coordinator-custom-exported': (mutate_coordinator('if version.needsCustomReview { continue }', '/* custom bypass */').replace('                        try PhotoVersionHistory.requireDownloadReview(imageURL: source)', '                        /* file review bypass */'), 'coordinator never exports unreviewed custom versions or descendants'),
    'negative-coordinator-fallback-not-named': (base.replace('var notes = try coordinatorSelectionNotes(photos)', 'var notes: [String] = []'), 'coordinator distinguishes current preview from recorded listing selection in README'),
    'negative-coordinator-listing-current': (base.replace('publication?.id == version.id', 'selected.id == version.id'), 'coordinator labels staging preview without granting publication approval'),
    'negative-coordinator-stage-preview-uploaded': (base.replace('let category = version.needsStagingReview ? "StagingPreviews" : version.effects.contains("stage") ? "Staged"', 'let category = version.effects.contains("stage") ? "Staged"').replace('if version.needsStagingReview { return }', '/* preview uploaded without review */'), 'coordinator withholds pending staging platform copies'),
    'negative-coordinator-stage-preview-label-removed': (base.replace('STAGING PREVIEW — review is not recorded. Not approved for publication; no platform copies are included.', 'Saved staging.'), 'coordinator labels staging preview without granting publication approval'),
    'negative-coordinator-fit-borders': (base.replace('let cropped = render(image, aspect: aspect, framing: .crop, label: nil)', 'let cropped = render(image, aspect: aspect, framing: .fit, label: nil)'), 'coordinator upload dimensions use the intended ratio without fake upscaling'),
    'negative-coordinator-low-quality': (base.replace('cropped.jpegData(compressionQuality: 0.97)', 'cropped.jpegData(compressionQuality: 0.50)'), 'coordinator upload JPEG is the actual clean centered crop at quality 0.97'),
    'negative-coordinator-missing-disclosures': (base.replace('_ = try write(Data((disclosure + "\\n" + resolution', '_ = try write(Data((disclosure + "\\n" + resolution').replace('platform + "/" + category + "/" + stem + "-disclosure.txt")', 'platform + "/" + category + "/" + stem + "-missing.txt")'), 'coordinator platform JPEG carries its matching disclosure'),
    'negative-coordinator-video-dropped': (base.replace('used.insert(name.lowercased()); entries.append(ZipArchive.Entry(name: name, url: extra.url))', 'used.insert(name.lowercased()); /* extra omitted */'), 'coordinator preserves every video with deterministic collision names'),
    'negative-coordinator-path-allowlist-removed': (base.replace('guard validFolder, let leaf = parts.last', 'guard true, let leaf = parts.last'), 'coordinator explicit path allowlist rejects traversal and unknown folders'),
    'negative-coordinator-missing-predecessor-skipped': (base.replace('let retained = try retainedImage(at: source, read: readRetained)\n                        guard let image', 'guard let retained = try? retainedImage(at: source, read: readRetained) else { return }\n                        guard let image'), 'coordinator missing approved predecessor must refuse partial delivery'),
}
variants = {'actual': (base, None), **coordinator_variants} if args.coordinator_only else {**variants, **coordinator_variants}
if args.actual_only: variants = {'actual': (base, None)}
architecture = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
fixture = root / 'apps/ios/tests/PhotoExportRendererTests.swift'
stubs = root / 'apps/ios/tests/PhotoExportPlatformStubs.swift'
coordinator_fixture = root / 'apps/ios/tests/CoordinatorExportTests.swift'
consumed = [source, fixture, coordinator_fixture, stubs, Path(__file__).resolve(), root / 'apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift', root / 'apps/ios/Rendprop/Photos/PhotoVersionHistory.swift', root / 'apps/ios/Rendprop/Support/ZipArchive.swift']
receipt = {
    'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
    'consumed_sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in consumed},
    'passed': False,
    'start_source_sha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in consumed},
    'simulator': None,
    'toolchain': None,
    'compile_deadlines_seconds': {'cold_actual': 300, 'warm_controls': 180},
    'execution_deadline_seconds': 180,
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

def discover_simulator(run_command, requested_uuid, diagnostics, clock=time.monotonic):
    """Observe cold CoreSimulator once more only after a timed-out read."""
    started = clock()
    deadline = started + 120
    argv = ['xcrun', 'simctl', 'list', 'devices', 'available', '-j']
    diagnostics.update(total_deadline_seconds=120, initial_deadline_seconds=30,
                       reconciliation_cap_seconds=90, initial_timed_out=False,
                       attempts=[], passed=False)
    try:
        diagnostics['attempts'].append('simulator-discovery')
        try:
            result = run_command('simulator-discovery', argv, 30)
        except subprocess.TimeoutExpired:
            diagnostics['initial_timed_out'] = True
            remaining = deadline - clock()
            if remaining <= 0:
                raise TimeoutError('Simulator discovery exhausted its overall deadline before reconciliation')
            diagnostics['attempts'].append('simulator-discovery-reconciliation')
            result = run_command('simulator-discovery-reconciliation', argv, min(90, remaining))
        if clock() >= deadline:
            raise TimeoutError('Simulator discovery completed after its overall deadline')
        if type(result.returncode) is not int or result.returncode != 0:
            raise RuntimeError('Simulator discovery returned a nonzero exit code')
        inventory = json.loads(result.stdout)
        if type(inventory) is not dict or type(inventory.get('devices')) is not dict:
            raise ValueError('Simulator discovery requires a devices object')
        ios = []
        available_ids = set()
        for runtime, rows in inventory['devices'].items():
            if type(runtime) is not str or type(rows) is not list:
                raise ValueError('Simulator discovery returned an invalid runtime inventory')
            for device in rows:
                if (type(device) is not dict or type(device.get('isAvailable')) is not bool
                        or any(type(device.get(field)) is not str or not device[field]
                               for field in ['name', 'udid', 'state'])):
                    raise ValueError('Simulator discovery returned an invalid device inventory')
                if device['isAvailable']:
                    if device['udid'] in available_ids:
                        raise ValueError('Simulator discovery returned duplicate available device IDs')
                    available_ids.add(device['udid'])
                    if 'iOS' in runtime and ('iPhone' in device['name'] or str(device.get('deviceTypeIdentifier', '')).startswith('com.apple.CoreSimulator.SimDeviceType.iPhone-')):
                        ios.append(device)
        if not ios:
            raise RuntimeError('No available iPhone simulator')
        device = (next((d for d in ios if d['udid'] == requested_uuid), None)
                  if requested_uuid else next((d for d in ios if d['state'] == 'Booted'), ios[0]))
        if device is None:
            raise RuntimeError('Requested simulator is not available')
        if clock() >= deadline:
            raise TimeoutError('Simulator discovery validation completed after its overall deadline')
        diagnostics['passed'] = True
        return device
    finally:
        diagnostics['elapsed_seconds'] = round(clock() - started, 3)

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
    receipt['simulator_discovery'] = {}
    device = discover_simulator(command, args.simulator, receipt['simulator_discovery'])
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
        # exhausted the old 60-second limit. A warm control then required 49s
        # on that runner. Keep bounded cold/warm deadlines with headroom;
        # a timeout still fails the entire gate.
        compile_timeout = receipt['compile_deadlines_seconds']['cold_actual' if name == 'actual' else 'warm_controls']
        compile_result = command(f'{name}-compile', ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-target', f'{architecture}-apple-ios16.0-simulator', '-sdk', sdk, str(stubs), str(root / 'apps/ios/Rendprop/Capture/PhotoCaptureStorage.swift'), str(root / 'apps/ios/Rendprop/Photos/PhotoVersionHistory.swift'), str(root / 'apps/ios/Rendprop/Support/ZipArchive.swift'), str(path), str(coordinator_fixture), str(fixture), '-o', str(binary)], compile_timeout)
        # A successful actual run does not bound later process startup or
        # crash reporting on a cold hosted simulator. Await the real result;
        # neither a timeout nor partial assertion text can satisfy a control.
        try:
            result = command(name, ['xcrun', 'simctl', 'spawn', device['udid'], str(binary)], receipt['execution_deadline_seconds'], check=False)
        except subprocess.TimeoutExpired:
            try:
                command(f'{name}-timeout-state', ['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], 30, check=False)
            except Exception as diagnostic_error:
                receipt['execution_timeout_diagnostic_failure'] = f'{type(diagnostic_error).__name__}: {diagnostic_error}'
            raise
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
