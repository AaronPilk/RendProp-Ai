#!/usr/bin/env python3
"""Compile actual reel submission/recovery bodies with synthetic API and loopback media."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import signal
import subprocess
import threading
import tempfile
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--evidence-dir', type=Path)
parser.add_argument('--choices-only', action='store_true', help='Run exact saved-quality choices and batch continuation with focused compiled controls')
parser.add_argument('--quality-only', action='store_true', help='Compile/run only the new exact quality routing controls; full gate remains default')
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-reel-request-recovery-'))
out.mkdir(parents=True, exist_ok=True)
source_path = root / 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'
api_path = root / 'apps/ios/Rendprop/Networking/APIClient.swift'
live_path = root / 'apps/ios/Rendprop/Networking/LiveAPIClient.swift'
fixture_path = root / 'apps/ios/tests/ReelRequestRecoveryTests.swift'
adoption_path = root / 'apps/ios/Rendprop/Auth/AdoptionProductionLibrary.swift'
listing_path = root / 'apps/ios/Rendprop/Models/Listing.swift'
drift_path = root / 'apps/ios/Rendprop/Render/DriftCheck.swift'
consumed = [source_path, api_path, live_path, fixture_path, adoption_path, listing_path, drift_path, Path(__file__).resolve()]
def hashes():
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in consumed}
def block(s, anchor):
    assert s.count(anchor) == 1, anchor
    start = s.index(anchor)
    opening = s.index('{', s.index(') async throws -> URL {', start)) if 'makeClip(' in anchor or 'retrieveClip(' in anchor else s.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (s[end] == '{') - (s[end] == '}')
        end += 1
    return s[start:end]
# Hosted CI exceeded the old 60s compiler cap before a control could execute.
# Match the existing complex Swift audit cap; runtimes stay bounded at 300s.
COMPILE_TIMEOUT_SECONDS = 240
receipt = {'passed': False, 'start_source_sha256': hashes(), 'compiles': [], 'runs': [], 'limitations': [
    'Actual extracted Swift bodies, Foundation filesystem/preferences and HTTP downloads execute; UIImage and API client are closed doubles.',
    'No vendor, customer media, camera, Photos write or production API.',
    'Unconfirmed submissions retain a scoped durable marker; no server receipt replay or automatic POST retry is claimed.',
    'Nonempty synthetic bytes test retention; video decoding or generation quality is not certified.',
    'OriginalPhotoMotion.render is a closed boundary here; the separate simulator AVFoundation renderer gate proves actual encoding. This gate executes actual refusal/retry routing, exact saved JPEG/shape inputs and acknowledgement fences.',
    'Only retrieveClip Date()/five-second sleep boundaries use a deterministic fixture clock; the extracted retry, identity and deadline decisions execute unchanged. Production timing and OS suspension are not certified.']}

def compile_variant(name, command):
    log_path = out / (name + '-compile.log')
    started = time.monotonic()
    timed_out = False
    cleanup_error = None
    wait_error = None
    with log_path.open('w') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            process.wait(timeout=COMPILE_TIMEOUT_SECONDS)
        except BaseException as error:
            wait_error = error
            timed_out = isinstance(error, subprocess.TimeoutExpired)
            errors = []
            # Always escalate for the originally owned group, even if its
            # leader exits or the TERM wait itself is interrupted.
            for sig, seconds in [(signal.SIGTERM, 3), (signal.SIGKILL, 5)]:
                try:
                    os.killpg(process.pid, sig)
                except ProcessLookupError:
                    pass
                except BaseException as cleanup:
                    errors.append(type(cleanup).__name__ + ': ' + str(cleanup))
                try:
                    process.wait(timeout=seconds)
                except subprocess.TimeoutExpired as cleanup:
                    if sig == signal.SIGKILL:
                        errors.append(type(cleanup).__name__ + ': ' + str(cleanup))
                except BaseException as cleanup:
                    errors.append(type(cleanup).__name__ + ': ' + str(cleanup))
            cleanup_error = '; '.join(errors) or None
    output = log_path.read_text()
    receipt['compiles'].append({
        'name': name, 'argv': command, 'timeout_seconds': COMPILE_TIMEOUT_SECONDS,
        'elapsed_seconds': time.monotonic() - started, 'exit_code': process.returncode,
        'timed_out': timed_out, 'cleanup_error': cleanup_error,
        'wait_error_type': type(wait_error).__name__ if wait_error is not None else None,
        'wait_error': str(wait_error) if wait_error is not None else None,
        'log_path': str(log_path), 'log_sha256': hashlib.sha256(log_path.read_bytes()).hexdigest()})
    if timed_out:
        raise subprocess.TimeoutExpired(command, COMPILE_TIMEOUT_SECONDS, output=output)
    if wait_error is not None:
        raise wait_error
    return subprocess.CompletedProcess(command, process.returncode, stdout='', stderr=output)

server = None
try:
    source, api, live, fixture = source_path.read_text(), api_path.read_text(), live_path.read_text(), fixture_path.read_text()
    adoption = block(adoption_path.read_text(), 'enum AdoptionOwnedIdentity {')
    review_helpers = 'enum AdoptionOwnedIdentity {\n' + '\n'.join(block(adoption, anchor) for anchor in [
        'enum Failure: Error', 'struct Card: Codable, Equatable', 'struct PaidRequest: Codable, Equatable', 'struct Journal: Codable, Equatable',
        'static func prefix(', 'static func requestKey(', 'static func requestFile(', 'private static func digest(',
        'private static func absentFile(', 'static func pathIsOccupied(', 'static func unselectedReviewFiles(', 'static func forgetUnselectedReviews(']) + '\n}\n'
    review_helpers = review_helpers.replace('defaults: UserDefaults', 'defaults: Foundation.UserDefaults')
    space = listing_path.read_text()
    cases = space[space.index('    case realEstate =',space.index('enum SpaceType:')):space.index('    var id:',space.index('enum SpaceType:'))]
    review_helpers += 'enum SpaceType: String {\n' + cases + '}\n'
    drift = drift_path.read_text()
    drift_types = block(drift, 'struct DriftVerdict: Sendable, Equatable') + '\n' + block(drift, 'struct DriftCheckRequest: Sendable') + '\n' + block(source, 'private struct ReelQualityRefusal: Error, LocalizedError').replace('private struct', 'struct', 1) + '\n'
    actual = 'import Foundation\nimport CryptoKit\n' + drift_types + block(api, 'enum APIError: Error, LocalizedError') + '\n' + block(api, 'struct AIVideoJob: Codable, Sendable') + '\n' + block(api, 'enum AIVideoStatus: Sendable') + '\n' + block(source, 'struct PendingReelRequest: Codable, Sendable').replace('private struct', 'struct', 1) + '\n' + block(source, 'struct PendingReelClips: Codable').replace('private struct', 'struct', 1) + '\n' + block(api, 'struct AIShot: Sendable, Hashable, Identifiable') + '\n' + block(source, 'struct PendingReelBatch: Codable, Sendable').replace('private struct', 'struct', 1) + '\n' + block(source, 'private enum ReelRecoveryChoice').replace('private enum', 'enum', 1) + '\n@MainActor enum ReelReceiptHarness {\n'
    for anchor in ['    nonisolated private static func makeClip(', '    nonisolated private static func isDefinitiveRefusal(', '    nonisolated static func clipPath(', '    nonisolated static func isDroppedPoll(', '    nonisolated private static func retrieveClip(', '    nonisolated private static func clipLabel(', '    nonisolated private static func retainRecoveredClip(', '    nonisolated private static func parkClips(', '    nonisolated private static func preparedReelJPEG(', '    nonisolated private static func acknowledgeRecoveredClip(', '    nonisolated private static func resolveSavedQualityRetry(', '    nonisolated private static func completeSavedBatch(']:
        extracted = block(source, anchor).replace('private static', 'static', 1)
        if 'retrieveClip(' in anchor:
            assert extracted.count('Date()') == 4 and extracted.count('try await Task.sleep(nanoseconds: 5_000_000_000)') == 1
            extracted = extracted.replace('Date()', 'ReelPollClock.now()').replace('try await Task.sleep(nanoseconds: 5_000_000_000)', 'try await ReelPollClock.pause(nanoseconds: 5_000_000_000)')
            receipt['poll_clock_boundary'] = {'production_sleep_nanoseconds': 5_000_000_000, 'date_reads': 4, 'fixture': 'ReelPollClock'}
        actual += extracted + '\n'
    actual += '''    static func generationGuard(auth: AuthStore, model: GuardModel, listingID: UUID, targetServerID: UUID?) -> (@MainActor @Sendable () throws -> Void) {
        let reelActor = auth.userID, reelRevision = auth.syncSessionRevision
        let reelWorkspace = WorkspaceContext.selectedOrgID
        let reelConsentRevision = AIConsent.shared.revocationRevision
''' + block(source, '                let requireCurrent: @MainActor @Sendable () throws -> Void = {') + '\nreturn requireCurrent\n}\n}\n'
    actual = actual.replace('import CryptoKit\n', 'import CryptoKit\n' + review_helpers, 1)
    actual += '''@MainActor final class VideoDispatchHarness {
        let base = URL(string: "https://closed.fixture.invalid/")!
        let session: URLSession
        let aiSession: URLSession
        init() { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ClosedVideoProtocol.self]; let client = URLSession(configuration: config); session = client; aiSession = client }
        func url(_ paths: [String]) -> URL { paths.reduce(base) { $0.appendingPathComponent($1) } }
        static func aiIdempotency(_ key: String?) -> String { key ?? "closed-no-key" }
        func makeRequest(url: URL, method: String, json: [String: Any], idempotency: String) -> URLRequest { var request = URLRequest(url: url); request.httpMethod = method; request.httpBody = try! JSONSerialization.data(withJSONObject: json); request.setValue(idempotency, forHTTPHeaderField: "Idempotency-Key"); return request }
        static func serverError(status: Int, data: Data) -> APIError { .server(status: status, code: "synthetic", message: "Synthetic transport failure") }
''' + block(live, '    @MainActor private func execute(_ req: URLRequest, session: URLSession? = nil,') + '\n' + block(live, '    @MainActor private func submitAIVideo(').replace('private func', 'func', 1) + '\n' + block(live, '    private func decode<T: Decodable>') + '\n' + block(live, '    private struct AIVideoJobDTO: Decodable') + '\n' + block(live, '    private struct ProvenanceEnvelopeDTO: Decodable') + '\n}\n'
    receipt['consumed_source_sha256'] = hashlib.sha256(actual.encode()).hexdigest()
    (out / 'Fixture.swift').write_text(fixture)
    assert 'clearReceiptOnDownload: false, requireCurrent: validate' in source
    assert 'reel.retry-saved-safer' in source and 'reel.use-saved-original' in source and 'reel.continue-saved-batch' in source
    assert 'Nothing is generating now.' in source
    ack = block(source, '    nonisolated private static func acknowledgeRecoveredClip(')
    assert ack.index('try batch!.save()') < ack.rindex('request.clear()')
    class Handler(BaseHTTPRequestHandler):
        calls = 0
        def do_GET(self):
            type(self).calls += 1
            self.send_response(500 if type(self).calls == 1 and not self.path.startswith('/quality') else 200)
            self.end_headers()
            self.wfile.write(b'synthetic nonempty retained clip')
        def log_message(self, *args): pass
    server = HTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    variants = [
        ('actual', actual, None),
        ('negative-quality-gate-accepts-changed-property', actual.replace(block(actual, '        guard verdict.mayUse else {'), '// omitted property gate'), 'changed property must not be retained'),
        ('negative-refusal-keeps-marker', actual.replace('if Self.isDefinitiveRefusal(error) { submission.clear() }', '// marker kept on a definitive refusal'), 'a definitive refusal retires the unconfirmed marker'),
        ('negative-tmp-download-read-as-is', actual.replace('let tmp = Self.clipPath(forDownloaded: downloaded)', 'let tmp = downloaded'), 'frames are read from an .mp4 path, never the .tmp download'),
        ('negative-empty-frames-sent', actual.replace('guard !frames.isEmpty else {', 'guard frames.isEmpty || !frames.isEmpty else {'), 'a clip this phone cannot read is held locally without a drift call'),
        ('negative-dropped-poll-fatal', actual.replace('} catch where Self.isDroppedPoll(error) && droppedPolls < 5 {', '} catch where false {'), 'one dropped poll must not fail a paid clip'),
        ('negative-dropped-poll-bound', actual.replace('droppedPolls < 5', 'droppedPolls < 6'), 'a connection that stays down surfaces after six polls'),
        ('negative-status-identity-fence', actual.replace('status = try await api.aiVideoStatus(job)\n                try await requireCurrent()', 'status = try await api.aiVideoStatus(job)\n                // omitted post-status identity fence'), 'identity switch during status cancels before terminal processing'),
        ('negative-poll-pause-deadline', actual.replace('try await requireCurrent()\n            guard ReelPollClock.now() < deadline else { throw AIImagePrep.error("The clip took too long.") }', 'try await requireCurrent()\n            // omitted post-pause deadline'), 'a polling pause past the deadline dispatches no status request'),
        ('negative-poll-response-deadline', actual.replace('try await requireCurrent()\n                guard ReelPollClock.now() < deadline else { throw AIImagePrep.error("The clip took too long.") }', 'try await requireCurrent()\n                // omitted post-response deadline'), 'late completed response must hold'),
        ('negative-download-sibling-overwrite', actual.replace('let renamed = downloaded.deletingLastPathComponent().appendingPathComponent("reel-download-\\(UUID().uuidString).mp4")', 'let renamed = downloaded.deletingPathExtension().appendingPathExtension("mp4"); try? FileManager.default.removeItem(at: renamed)'), 'download normalization uses a unique media path'),
        ('negative-duplicate-refusal-clears-marker', actual.replace(' && status != 409', ''), 'duplicate refusal preserves the already-started operation marker'),
        ('actual-lab-dispatch', actual, None),
        ('negative-dropped-receipt', actual.replace('try pending.save()', '// dropped accepted receipt'), 'pending receipt after poll failure'),
        ('negative-duplicate-submit', actual.replace('if PendingReelRequest.exists(recoveryContext) {', 'if false && PendingReelRequest.exists(recoveryContext) {'), 'existing receipt blocks second POST'),
        ('negative-early-download-ack', actual.replace('if clearReceiptOnDownload { pending?.clear() }', 'pending?.clear()'), 'temporary successful download keeps request'),
        ('negative-no-pre-dispatch-marker', actual.replace('try submission.save()', '// omitted pre-dispatch marker'), 'durable operation marker exists before POST'),
        ('negative-preparation-consent', actual.replace(block(actual, '                    guard AIConsent.shared.isGranted, AIConsent.shared.revocationRevision == reelConsentRevision else {'), '// omitted captured preparation permission'), 'revocation during preparation permits no paid POST'),
        ('negative-dispatch-consent', actual.replace(block(actual, '            guard AIConsent.shared.isGranted, AIConsent.shared.revocationRevision == consentRevision else {'), '// omitted dispatch permission fence'), 'token refresh revocation must reject'),
        ('negative-dispatch-workspace', actual.replace('guard WorkspaceContext.selectedOrgID == workspace else { throw CloudSyncError.identityChanged }', '// omitted dispatch workspace fence'), 'token refresh workspace switch must reject'),
        ('negative-401-retry-fence', actual.replace('request.setValue("Bearer \\(fresh)", forHTTPHeaderField: "Authorization")\n                try beforeSend?()', 'request.setValue("Bearer \\(fresh)", forHTTPHeaderField: "Authorization")\n                // omitted retry dispatch fence'), '401 revocation must reject retry'),
        ('negative-authoritative-marker-fallback', actual.replace('let data = AdoptionOwnedIdentity.pathIsOccupied(target)\n            ? (try? Data(contentsOf: target)) : UserDefaults.standard.data(forKey: key(context))', 'let data = (try? Data(contentsOf: target)) ?? UserDefaults.standard.data(forKey: key(context))'), 'unreadable authoritative marker never falls back to stale legacy receipt'),
        ('negative-manifest-fallback-deletes-paid-clips', actual.replace('let data = FileManager.default.fileExists(atPath: target.path)\n                ? try Data(contentsOf: target) : UserDefaults.standard.data(forKey: key(id))', 'let data = (try? Data(contentsOf: target)) ?? UserDefaults.standard.data(forKey: key(id))').replace('guard let parked = try? readRecord(for: id), !parked.clipURLs.isEmpty else { return nil }', 'guard let parked = try? readRecord(for: id) else { return nil }; guard !parked.clipURLs.isEmpty else { clear(for: id); return nil }'), 'unreadable manifest preserves previously paid clip bytes'),
        ('negative-manifest-retention-overwrite', actual.replace('var relPaths = (try PendingReelClips.readRecord(for: listingID)?.clipURLs ?? [])', 'var relPaths = ((try? PendingReelClips.readRecord(for: listingID))?.clipURLs ?? [])').replace('_ = try Self.readRecord(for: listingID)', '// omitted authoritative write admission'), 'unreadable manifest retains the only new temporary bytes'),
        ('negative-manifest-park-overwrite', actual.replace('previous = try PendingReelClips.readRecord(for: listingID)', 'previous = try? PendingReelClips.readRecord(for: listingID)').replace('_ = try Self.readRecord(for: listingID)', '// omitted authoritative write admission'), 'parking preserves unreadable manifest and unretained temporary bytes'),
        ('negative-manifest-pre-dispatch', actual.replace('_ = try PendingReelClips.readRecord(for: recoveryContext.listingID)', '// omitted authoritative history preflight'), 'unreadable history prevents any new paid POST'),
    ]
    quality_variants = [
        ('negative-selected-delivery-aspect-lost', actual.replace('let outputAspect = pending?.outputAspect ??', 'let outputAspect = nil as String? ??'), 'new request keeps selected portrait delivery for a landscape source'),
        ('negative-quality-unbounded-retry', actual.replace('for attempt in 0...1 {', 'for attempt in 0...2 {').replace('refusal.mayRetry && attempt == 0', 'refusal.mayRetry && attempt < 2'), 'quality retry is bounded to two total provider generations'),
        ('negative-quality-broad-retry', actual.replace('verdict.status == .fail && verdict.action == "retry"', '!verdict.mayUse'), 'ambiguous quality verdict must hold'),
        ('negative-quality-retry-different-jpeg', actual.replace('api.aiVideoReelClip(imageBase64: jpeg.base64EncodedString(),', 'api.aiVideoReelClip(imageBase64: (attempt == 0 ? jpeg : Data("changed retry JPEG".utf8)).base64EncodedString(),'), 'retry uses the exact same prepared and saved JPEG'),
        ('negative-quality-lost-attempt', actual.replace('attempt: pending?.qualityAttempt ?? 1', 'attempt: 1'), 'retry attempts persist and reach the real drift request'),
        ('negative-quality-lost-provenance', actual.replace('provenanceID: job.provenanceID, attempt:', 'provenanceID: nil, attempt:'), 'each drift judgement carries its exact accepted provenance'),
        ('negative-quality-refuse-without-fail', actual.replace('guard verdict.status == .fail, verdict.action == "refuse",', 'guard verdict.action == "refuse",'), 'ambiguous quality verdict must hold'),
        ('negative-quality-fail-without-refuse', actual.replace('guard verdict.status == .fail, verdict.action == "refuse",', 'guard verdict.status == .fail,'), 'confirmed drift requests exactly one paid retry'),
        ('negative-quality-original-wrong-jpeg', actual.replace('OriginalPhotoMotion.render(jpeg: jpeg, renderSize: size, output: local)', 'OriginalPhotoMotion.render(jpeg: Data("wrong source".utf8), renderSize: size, output: local)'), 'original motion renders only the exact accepted saved JPEG'),
        ('negative-quality-original-wrong-shape', actual.replace('let size = outputAspect == "9:16" ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080)', 'let size = CGSize(width: 1920, height: 1080)'), 'original portrait source selects the portrait renderer shape'),
        ('negative-quality-original-invalid-shape', actual.replace('guard let shape, shape.width > 0, shape.height > 0 else {', 'guard let shape else {'), 'invalid saved image shape must hold'),
        ('negative-quality-pre-local-fence', actual.replace('        try await requireCurrent()\n        guard verdict.mayUse else {', '        // omitted post-QC context fence\n        guard verdict.mayUse else {').replace('            try await requireCurrent()\n            let local = dir.appendingPathComponent("clip-photo-motion-', '            // omitted pre-local context fence\n            let local = dir.appendingPathComponent("clip-photo-motion-'), 'stale QC response never enters local fallback'),
        ('negative-quality-post-render-fence', actual.replace('try await OriginalPhotoMotion.render(jpeg: jpeg, renderSize: size, output: local)\n            try await requireCurrent()', 'try await OriginalPhotoMotion.render(jpeg: jpeg, renderSize: size, output: local)\n            // omitted post-render context fence'), 'post-render identity change must stop'),
        ('negative-quality-local-early-ack', actual.replace('            return local', '            pending?.clear()\n            return local'), 'local fallback keeps receipt until durable retention'),
        ('negative-quality-retention-early-ack', actual.replace('        let retained = try retainRecoveredClip(clip, for: request.context.listingID)', '        request.clear()\n        let retained = try retainRecoveredClip(clip, for: request.context.listingID)'), 'local fallback disk failure preserves its accepted receipt'),
        ('negative-quality-retention-lost-label', actual.replace('let prefix = OriginalPhotoMotion.isClip(clip) ? "clip-photo-motion-" : "clip-recovered-"', 'let prefix = "clip-recovered-"'), 'durable retention preserves original-motion bytes and label'),
        ('negative-quality-park-lost-label', actual.replace('let prefix = OriginalPhotoMotion.isClip(clip) ? "clip-photo-motion-" : "clip-"', 'let prefix = "clip-"'), 'batch parking preserves original-motion labels for every retained copy'),
    ]
    choice_variants = [
        ('negative-framing-provider-flag-lost', actual.replace('aspect: aspect, framing: framing, presetVersion: 1,', 'aspect: aspect, framing: nil, presetVersion: 1,'), 'new whole-source framing survives provider admission'),
        ('negative-framing-saved-batch-lost', actual.replace('preparedJPEG: jpeg, framing: batch.framing)', 'preparedJPEG: jpeg, framing: nil)'), 'saved whole-scene batch resumes exact full sources and framing'),
        ('negative-choice-generic-error-fallback', actual.replace('} catch let refusal as ReelQualityRefusal where refusal.mayRetry {', '} catch {'), 'unavailable recovery must remain held'),
        ('negative-choice-wrong-source', actual.replace('api.aiVideoReelClip(imageBase64: source, mime:', 'api.aiVideoReelClip(imageBase64: Data("different choice JPEG".utf8).base64EncodedString(), mime:'), 'explicit safer retry uses exact saved JPEG'),
        ('negative-choice-wrong-attempt', actual.replace('sourceSpaceType: spaceType, qualityAttempt: 1,', 'sourceSpaceType: spaceType, qualityAttempt: 2,'), 'explicit safer retry persists attempt one'),
        ('negative-choice-original-wrong-source', actual.replace('OriginalPhotoMotion.render(jpeg: jpeg,\n                renderSize:', 'OriginalPhotoMotion.render(jpeg: Data("different original".utf8),\n                renderSize:'), 'explicit original choice renders exact saved JPEG'),
        ('negative-choice-early-ack', actual.replace('        let retained = try retainRecoveredClip(clip, for: request.context.listingID)', '        request.clear()\n        let retained = try retainRecoveredClip(clip, for: request.context.listingID)'), 'explicit original disk failure keeps its paid receipt'),
        ('negative-batch-progress-not-durable', actual.replace('            try batch!.save()', '            // omitted durable batch progress'), 'batch progress is durable before receipt acknowledgement'),
        ('negative-batch-source-binding', actual.replace('saved.photos[request.photoNumber - 1].jpegBase64 == request.sourceJPEGBase64,', 'true,'), 'wrong source cannot advance progress'),
        ('negative-batch-skips-photo', actual.replace('let index = batch.completedPaths.count, photo = batch.photos[index]', 'let index = batch.completedPaths.count + 1, photo = batch.photos[index]'), 'batch continuation generates each remaining photo in order'),
    ]
    if args.choices_only:
        variants = [('actual-choices', actual, None)] + choice_variants
    elif args.quality_only:
        variants = [('actual-quality', actual, None)] + quality_variants
    else:
        variants += quality_variants + choice_variants
    for name, text, reason in variants:
        assert reason is None or text != actual, name + ' mutation anchor missing'
        path, binary = out / (name + '.swift'), out / name
        path.write_text(text)
        flags = ['-D', 'SPATIAL_CAPTURE_LAB'] if name == 'actual-lab-dispatch' else []
        compile_result = compile_variant(name, ['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', *flags, str(path), str(out / 'Fixture.swift'), '-o', str(binary)])
        assert compile_result.returncode == 0, name + ' compile failed: ' + compile_result.stderr
        Handler.calls = 0
        mode = ['--dispatch-only'] if name in ['actual-lab-dispatch', 'negative-dispatch-consent', 'negative-dispatch-workspace', 'negative-401-retry-fence'] else []
        if name.startswith('negative-manifest-'): mode = ['--manifest-only']
        if args.choices_only or name.startswith('negative-choice-') or name.startswith('negative-batch-'): mode = ['--choices-only']
        elif args.quality_only or name.startswith('negative-quality-') and name != 'negative-quality-gate-accepts-changed-property': mode = ['--quality-only']
        result = subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}', *mode], capture_output=True, text=True, timeout=300)
        log = result.stdout + result.stderr
        (out / (name + '.log')).write_text(log)
        binary.unlink()
        expected = result.returncode == 0 if reason is None else result.returncode != 0 and any(prefix + reason in log for prefix in ['Precondition failed: ', 'Fatal error: '])
        receipt['runs'].append({'name': name, 'exit_code': result.returncode, 'expected_result': expected, 'expected_failure': reason, 'compile_flags': flags, 'arguments': mode, 'loopback_gets': Handler.calls, 'output': log[:2000]})
        assert expected, name + ': ' + log
except BaseException as error:
    receipt['failure'] = str(error)
    raise
finally:
    if server:
        server.shutdown()
        server.server_close()
    receipt['end_source_sha256'] = hashes()
    receipt['source_binding_matches'] = receipt['start_source_sha256'] == receipt['end_source_sha256']
    receipt['passed'] = 'failure' not in receipt and len(receipt['runs']) == len(variants) and all(r['expected_result'] for r in receipt['runs']) and receipt['source_binding_matches']
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['passed'], 'Gate source changed during verification or a required run failed'
print(f'Evidence: {out}')
print(receipt['runs'][0]['output'].strip())
print(receipt['runs'][1]['output'].strip())
print(f"PASSED: {sum(1 for _, _, reason in variants if reason)} compiled controls failed at their exact expected invariant")
