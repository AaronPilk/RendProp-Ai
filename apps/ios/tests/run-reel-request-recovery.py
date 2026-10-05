#!/usr/bin/env python3
"""Compile actual reel submission/recovery bodies with synthetic API and loopback media."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import threading
import tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--evidence-dir', type=Path)
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-reel-request-recovery-'))
out.mkdir(parents=True, exist_ok=True)
source_path = root / 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'
api_path = root / 'apps/ios/Rendprop/Networking/APIClient.swift'
live_path = root / 'apps/ios/Rendprop/Networking/LiveAPIClient.swift'
fixture_path = root / 'apps/ios/tests/ReelRequestRecoveryTests.swift'
adoption_path = root / 'apps/ios/Rendprop/Auth/AdoptionProductionLibrary.swift'
listing_path = root / 'apps/ios/Rendprop/Models/Listing.swift'
consumed = [source_path, api_path, live_path, fixture_path, adoption_path, listing_path, Path(__file__).resolve()]
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
receipt = {'passed': False, 'start_source_sha256': hashes(), 'runs': [], 'limitations': [
    'Actual extracted Swift bodies, Foundation filesystem/preferences and HTTP downloads execute; UIImage and API client are closed doubles.',
    'No vendor, customer media, camera, Photos write or production API.',
    'Unconfirmed submissions retain a scoped durable marker; no server receipt replay or automatic POST retry is claimed.',
    'Nonempty synthetic bytes test retention; video decoding or generation quality is not certified.']}
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
    actual = 'import Foundation\nimport CryptoKit\n' + block(api, 'enum APIError: Error, LocalizedError') + '\n' + block(api, 'struct AIVideoJob: Codable, Sendable') + '\n' + block(api, 'enum AIVideoStatus: Sendable') + '\n' + block(source, 'private struct PendingReelRequest: Codable, Sendable').replace('private struct', 'struct', 1) + '\n' + block(source, 'private struct PendingReelClips: Codable').replace('private struct', 'struct', 1) + '\n@MainActor enum ReelReceiptHarness {\n'
    for anchor in ['    nonisolated private static func makeClip(', '    nonisolated private static func retrieveClip(', '    nonisolated private static func clipLabel(', '    nonisolated private static func retainRecoveredClip(', '    nonisolated private static func parkClips(']:
        actual += block(source, anchor).replace('private static', 'static', 1) + '\n'
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
    assert source.index('try Self.retainRecoveredClip(clip, for: request.context.listingID)') < source.index('request.clear()', source.index('private func recoverPendingRequest'))
    class Handler(BaseHTTPRequestHandler):
        calls = 0
        def do_GET(self):
            type(self).calls += 1
            self.send_response(500 if type(self).calls == 1 else 200)
            self.end_headers()
            self.wfile.write(b'synthetic nonempty retained clip')
        def log_message(self, *args): pass
    server = HTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    variants = [
        ('actual', actual, None),
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
    for name, text, reason in variants:
        assert reason is None or text != actual, name + ' mutation anchor missing'
        path, binary = out / (name + '.swift'), out / name
        path.write_text(text)
        flags = ['-D', 'SPATIAL_CAPTURE_LAB'] if name == 'actual-lab-dispatch' else []
        compile_result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', *flags, str(path), str(out / 'Fixture.swift'), '-o', str(binary)], capture_output=True, text=True, timeout=60)
        (out / (name + '-compile.log')).write_text(compile_result.stdout + compile_result.stderr)
        assert compile_result.returncode == 0, name + ' compile failed: ' + compile_result.stderr
        Handler.calls = 0
        mode = ['--dispatch-only'] if name in ['actual-lab-dispatch', 'negative-dispatch-consent', 'negative-dispatch-workspace', 'negative-401-retry-fence'] else []
        if name.startswith('negative-manifest-'): mode = ['--manifest-only']
        result = subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}', *mode], capture_output=True, text=True, timeout=120)
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
    receipt['passed'] = len(receipt['runs']) == 15 and all(r['expected_result'] for r in receipt['runs']) and receipt['source_binding_matches']
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['passed'], 'Gate source changed during verification or a required run failed'
print(f'Evidence: {out}')
print(receipt['runs'][0]['output'].strip())
print(receipt['runs'][1]['output'].strip())
print('PASSED: 13 compiled controls failed at their exact expected invariant')
