#!/usr/bin/env python3
"""Execute actual background expiry and notice bodies with delayed closed OS callbacks."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--evidence-dir', type=Path)
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-reel-lifecycle-'))
out.mkdir(parents=True, exist_ok=True)
source = root / 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'
push = root / 'apps/ios/Rendprop/Push/PushManager.swift'
fixture = root / 'apps/ios/tests/ReelLifecycleTests.swift'
paths = [source, push, fixture, Path(__file__).resolve()]
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
body = 'import Foundation\n' + block(push.read_text(), 'enum ReelCompletionNotice {')
body += '\n@MainActor final class ReelBackgroundHarness {\nvar backgroundHold = UIBackgroundTaskIdentifier.invalid\nvar backgroundHoldOperation: UUID?\n'
body += 'var idleHeld = false; let connection = ClosedConnection(); var workTask: Task<Void, Never>?; var player: ClosedPlayer? = ClosedPlayer(); var voPlayer: ClosedPlayer? = ClosedPlayer(); let recorder = ClosedRecorder()\n'
for anchor in ['    private func beginBackgroundHold()', '    private func endBackgroundHold()']:
    body += block(screen, anchor).replace('private func', 'func', 1) + '\n'
reel_view = screen[screen.index('struct ReelStudioView:'):screen.index('// MARK: Sections', screen.index('struct ReelStudioView:'))]
cleanup = block(reel_view, '        .onDisappear {')
body += 'func onDisappearCleanup() ' + cleanup[cleanup.index('{'):] + '\n'
body += '}\n'
assert 'let reelNoticeIdentity = PushManager.currentIdentity' in screen
assert 'ReelCompletionNotice.post(success: true, identity: reelNoticeIdentity)' in screen
assert 'ReelCompletionNotice.post(success: false, identity: reelNoticeIdentity)' in screen
assert 'try requireCurrent()\n                let wasPlanned' in screen
assert 'endBackgroundHold()' in cleanup
variants = [
    ('actual', body, None),
    ('negative-async-expiry', body.replace('            self.endBackgroundHold()', '            Task { @MainActor in self.endBackgroundHold() }'), 'expiry ends the background grant synchronously'),
    ('negative-stale-expiry', body.replace('guard self.backgroundHoldOperation == operation else { return }', '// omitted operation token'), 'stale expiry cannot end a newer background grant'),
    ('negative-dismissal-grant-leak', body.replace('            endBackgroundHold()\n        }', '            // omitted dismissal cleanup\n        }'), 'dismissing the reel ends its background grant'),
    ('negative-notice-owner-fence', body.replace('guard PushManager.currentIdentity == identity,', 'guard true,'), "owner switch during notification settings cannot enqueue the old owner's banner"),
    ('negative-notice-revision-fence', body.replace('guard PushManager.currentIdentity == identity,', 'guard PushManager.currentIdentity?.owner == identity.owner,'), "same-owner session replacement cannot enqueue an earlier session's banner"),
    ('negative-notice-foreground-fence', body.replace('UIApplication.shared.applicationState != .active else { return }\n                let content', 'true else { return }\n                let content'), 'returning to the foreground while settings load suppresses the banner'),
]
receipt = {'passed': False, 'start_source_sha256': before, 'runs': [], 'limitations': ['Actual source-extracted methods execute with synthetic UIApplication/UNUserNotificationCenter. No APNs delivery, OS grant duration, suspension or killed-process execution proof.']}
try:
    for name, text, reason in variants:
        assert reason is None or text != body, name + ' mutation anchor missing'
        path, binary = out / (name + '.swift'), out / name
        path.write_text(text)
        compile = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(path), str(fixture), '-o', str(binary)], capture_output=True, text=True, timeout=180)
        (out / (name + '-compile.log')).write_text(compile.stdout + compile.stderr)
        assert compile.returncode == 0, name + ' compile failed: ' + compile.stderr
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
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
    receipt['end_source_sha256'] = hashes()
    receipt['source_binding_matches'] = before == receipt['end_source_sha256']
    receipt['passed'] = 'failure' not in receipt and len(receipt['runs']) == len(variants) and all(r['expected_result'] for r in receipt['runs']) and receipt['source_binding_matches']
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['passed'], 'Source changed during the lifecycle gate'
print(receipt['runs'][0]['output'])
print(f'PASS: {len(variants) - 1} negative controls; receipt: {out / "receipt.json"}')
