#!/usr/bin/env python3
"""Execute actual moving-photo method against account changes at async boundaries."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--evidence-dir', type=Path)
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-moving-photo-'))
out.mkdir(parents=True, exist_ok=True)
source = root / 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'
fixture = root / 'apps/ios/tests/MovingPhotoIdentityTests.swift'
recovery = source
api = root / 'apps/ios/Rendprop/Networking/APIClient.swift'
live = root / 'apps/ios/Rendprop/Networking/LiveAPIClient.swift'
paths = [source, fixture, api, live, Path(__file__).resolve()]
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
screen = source.read_text()
method = block(screen, '    private func animateWithSession(').replace('private func', 'func', 1)
helper = block(recovery.read_text(), 'enum PhotoAnimationRecovery {')
helper = helper.replace('now: () -> Date = Date.init', 'now: () -> Date = MovingPhotoClock.now').replace('try await Task.sleep(nanoseconds: 6_000_000_000)', 'try await MovingPhotoClock.pause(nanoseconds: 6_000_000_000)')
body = 'import Foundation\nimport CryptoKit\n' + block(api.read_text(), 'struct AIVideoJob: Codable, Sendable') + '\n' + block(api.read_text(), 'enum AIVideoStatus: Sendable') + '\n' + helper + '\n'
body += '''@MainActor final class MovingPhotoHarness {
    let model: AnimationModel, listing: AnimationListing, dir: URL
    let auth = AuthStore.shared, space = AnimationSpace()
    var localProcessing = false, processingText = "", busyPhotoIDs = Set<String>()
    var animateTask: Task<Void, Never>?, clips: [SavedClip] = [], animatedClip: AnimatedClip?, aiFailure: AIFailure?
    var isProcessing: Bool { localProcessing }
    func refreshSavedAnimations() {}
    init(model: AnimationModel, listing: AnimationListing, dir: URL) { self.model = model; self.listing = listing; self.dir = dir }
''' + method + '\n}\n'
body += '''@MainActor final class OperationWireHarness {
    let aiSession = URLSession.shared
    var reply: Data = Data(), captured: URLRequest?, onReply: (() -> Void)?
    func url(_ path: [String], query: [URLQueryItem]) -> URL {
        var u = URLComponents(string: "https://example.test/functions/v1/" + path.joined(separator: "/"))!
        u.queryItems = query; return u.url!
    }
    func makeRequest(url: URL) -> URLRequest { URLRequest(url: url) }
    func execute(_ request: URLRequest, session: URLSession, beforeSend: () throws -> Void) async throws -> Data {
        try beforeSend(); captured = request; await Task.yield(); onReply?(); return reply
    }
    func decode<T: Decodable>(_ data: Data) throws -> T {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return try d.decode(T.self, from: data)
    }
''' + block(live.read_text(), '    @MainActor func aiVideoOperation(') + '\n' + block(live.read_text(), '    private struct AIVideoOperationDTO: Decodable') + '\n' + block(live.read_text(), '    private struct ProvenanceEnvelopeDTO: Decodable') + '\n}\n'
variants = [
    ('actual', body, None),
    ('negative-prepared-owner', body.replace('auth.userID == animationOwner,', 'true,'), 'prepared photo cannot submit under a replacement owner'),
    ('negative-prepared-revision', body.replace('auth.syncSessionRevision == animationRevision,', 'true,'), 'same-owner session replacement cannot animate earlier prepared media'),
    ('negative-prepared-consent', body.replace('AIConsent.shared.revocationRevision == animationConsentRevision,', 'true,'), 'revoked and regranted consent cannot animate earlier prepared media'),
    ('negative-prepared-library', body.replace('WorkspaceContext.selectedOrgID == animationLibrary,', 'true,'), 'library switch cannot animate earlier prepared media'),
    ('negative-post-preparation-fence', body.replace('                try requireCurrent()\n                // Generated motion', '                // omitted preparation fence\n                // Generated motion'), 'stale prepared photo cannot enter listing sync'),
    ('negative-post-quality-fence', body.replace('        try requireCurrent()\n        guard entry.qualityPassed == true', '        // omitted quality fence\n        guard entry.qualityPassed == true'), 'stale quality reply cannot save media into the earlier listing'),
    ('negative-submission-journal', body.replace('entry.dispatched = true; try save(entry, directory: directory)', 'entry.dispatched = true'), 'ambiguous or duplicate submission never rotates its operation or POSTs again'),
    ('negative-accepted-receipt', body.replace('try save(entry, directory: directory) // Retain202', '// omitted receipt save // Retain202'), 'moving photo quality check forwards its exact provenance receipt'),
    ('negative-quality-journal', body.replace('entry.qualityDispatched = true; try save(entry, directory: directory)', 'entry.qualityDispatched = true'), 'lost quality reply cannot purchase another quality check'),
    ('negative-context-binding', body.replace('entry.schema == 1, entry.context == context,', 'entry.schema == 1, true,'), 'changed source bytes cannot adopt an earlier video receipt'),
    ('negative-quality-pass', body.replace('guard entry.qualityPassed == true else', 'guard true else'), 'quality-held motion clip cannot become a usable saved result'),
    ('negative-refusal-record', body.replace('entry.refusedBeforeAcceptance = true', 'entry.refusedBeforeAcceptance = nil'), 'definitive refusal is retained as verified unaccepted evidence'),
    ('negative-conflict-retirement', body.replace('status != 409', 'true'), 'ambiguous or duplicate submission never rotates its operation or POSTs again'),
    ('negative-known-receipt-lookup', body.replace('entry.dispatched, entry.job == nil, let listing', 'entry.dispatched, let listing'), 'leaving after acceptance resumes the exact receipt without another generation'),
    ('negative-server-anchor', body.replace('guard isSample || serverListingID != nil else', 'guard true else'), 'normal standalone video requires a recoverable server listing before payment'),
    ('negative-retained-clip-hash', body.replace('entry.clipSHA256 == nil || entry.clipSHA256 == downloadedSHA', 'true'), 'quality-bound clip cannot adopt changed redownload bytes'),
    ('negative-final-source', body.replace('        try validateSource()\n        if clip != finished', '        // omitted final source verification\n        if clip != finished'), 'source change during quality cannot promote a usable clip'),
    ('negative-operation-echo', body.replace('dto.operationId == operationID.uuidString,', 'true,'), 'operation lookup rejects a different saved key'),
    ('negative-listing-echo', body.replace('dto.listingId.flatMap(UUID.init(uuidString:)) == listingServerID,', 'true,'), 'operation lookup rejects another listing'),
    ('negative-library-echo', body.replace('(workspace == nil ? raw["selected_library_org_id"] is NSNull\n                  : dto.selectedLibraryOrgId.flatMap(UUID.init(uuidString:)) == workspace)', 'true'), 'operation lookup rejects another library'),
    ('negative-post-lookup-identity', body.replace('        try current()\n        let dto: AIVideoOperationDTO', '        // omitted response identity check\n        let dto: AIVideoOperationDTO'), 'operation lookup cannot expose a reply after account replacement'),
    ('negative-provenance-forwarding', body.replace('provenanceID: job.provenanceID', 'provenanceID: nil'), 'moving photo quality check forwards its exact provenance receipt'),
]
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(503 if self.path.endswith("/gone") else 200); self.end_headers(); self.wfile.write(b'changed moving clip bytes' if self.path.endswith('/different') else b'synthetic moving clip bytes')
    def log_message(self, *args): pass
server = HTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
receipt = {'passed': False, 'start_source_sha256': before, 'runs': [], 'limitations': [
    'Actual animateWithSession body and PhotoAnimationRecovery persistence/phase fences execute with Foundation filesystem and loopback download; image prep, API, frame decoder and UI are closed boundaries. Only clock/sleep defaults use the deterministic fixture clock.',
    'The actual Live operation GET builder/echo decoder executes with captured URLRequest and a closed request executor; JWT refresh and the production transport are independently covered by existing network gates. No vendor call, customer media, real OS suspension, UIKit rendering or SDK build. Known accepted receipts recover with GET only; ambiguous202 remains held unless an authenticated operation lookup resolves it.']}
try:
    for name, text, reason in variants:
        assert reason is None or text != body, name + ' mutation anchor missing'
        path, binary = out / (name + '.swift'), out / name
        path.write_text(text)
        compile = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(path), str(fixture), '-o', str(binary)], capture_output=True, text=True, timeout=180)
        (out / (name + '-compile.log')).write_text(compile.stdout + compile.stderr)
        assert compile.returncode == 0, name + ' compile failed: ' + compile.stderr
        run = subprocess.run([str(binary), f'http://127.0.0.1:{server.server_port}/video'], capture_output=True, text=True, timeout=60)
        log = run.stdout + run.stderr
        (out / (name + '.log')).write_text(log)
        expected = run.returncode == 0 if reason is None else run.returncode != 0 and 'Precondition failed: ' + reason in log
        receipt['runs'].append({'name': name, 'exit_code': run.returncode, 'expected_result': expected, 'expected_failure': reason, 'output': log[:3000]})
        binary.unlink()
        assert expected, name + ': ' + log
except BaseException as error:
    receipt['failure'] = str(error)
    raise
finally:
    server.shutdown(); server.server_close()
    receipt['end_source_sha256'] = hashes()
    receipt['source_binding_matches'] = before == receipt['end_source_sha256']
    receipt['passed'] = 'failure' not in receipt and len(receipt['runs']) == len(variants) and all(r['expected_result'] for r in receipt['runs']) and receipt['source_binding_matches']
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['passed'], 'Source changed during moving-photo verification'
print(receipt['runs'][0]['output'])
print(f'PASS: {len(variants) - 1} negative controls; receipt: {out / "receipt.json"}')
