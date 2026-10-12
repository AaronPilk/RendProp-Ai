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
paths = [source, fixture, Path(__file__).resolve()]
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
assert method.count('Date()') == 4 and method.count('try await Task.sleep(nanoseconds: 6_000_000_000)') == 1
method = method.replace('Date()', 'MovingPhotoClock.now()').replace('try await Task.sleep(nanoseconds: 6_000_000_000)', 'try await MovingPhotoClock.pause(nanoseconds: 6_000_000_000)')
body = 'import Foundation\nenum ReelStudioView {\n' + block(screen, '    nonisolated static func clipPath(') + '\n}\n'
body += '''@MainActor final class MovingPhotoHarness {
    let model: AnimationModel, listing: AnimationListing, dir: URL
    let auth = AuthStore.shared, space = AnimationSpace()
    var localProcessing = false, processingText = "", busyPhotoIDs = Set<String>()
    var animateTask: Task<Void, Never>?, clips: [SavedClip] = [], animatedClip: AnimatedClip?, aiFailure: AIFailure?
    var isProcessing: Bool { localProcessing }
    init(model: AnimationModel, listing: AnimationListing, dir: URL) { self.model = model; self.listing = listing; self.dir = dir }
''' + method + '\n}\n'
variants = [
    ('actual', body, None),
    ('negative-prepared-owner', body.replace('auth.userID == animationOwner,', 'true,'), 'prepared photo cannot submit under a replacement owner'),
    ('negative-prepared-revision', body.replace('auth.syncSessionRevision == animationRevision,', 'true,'), 'same-owner session replacement cannot animate earlier prepared media'),
    ('negative-prepared-consent', body.replace('AIConsent.shared.revocationRevision == animationConsentRevision,', 'true,'), 'revoked and regranted consent cannot animate earlier prepared media'),
    ('negative-prepared-library', body.replace('WorkspaceContext.selectedOrgID == animationLibrary,', 'true,'), 'library switch cannot animate earlier prepared media'),
    ('negative-post-preparation-fence', body.replace('                try requireCurrent()\n                // Generated motion', '                // omitted preparation fence\n                // Generated motion'), 'stale prepared photo cannot enter listing sync'),
    ('negative-post-quality-fence', body.replace('                try requireCurrent()\n                guard verdict.mayUse', '                // omitted quality fence\n                guard verdict.mayUse'), 'stale quality reply cannot save media into the earlier listing'),
]
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'synthetic moving clip bytes')
    def log_message(self, *args): pass
server = HTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
receipt = {'passed': False, 'start_source_sha256': before, 'runs': [], 'limitations': [
    'Actual full animateWithSession body and filesystem/URLSession execute with closed image prep, API, frame decoder and UI boundaries; fixed six-second pauses/Date use a deterministic test clock.',
    'No vendor call or customer media. This legacy moving-photo path has no durable accepted receipt/recovery pipeline; receipt retention claims apply to Reel Studio only.']}
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
