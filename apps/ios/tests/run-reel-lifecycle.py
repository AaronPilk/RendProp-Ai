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
queue = root / 'apps/ios/Rendprop/Render/ReelWorkQueue.swift'
paths = [source, push, queue, fixture, Path(__file__).resolve()]
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
# Remove imports and expose private stored grant identifiers/methods to the
# fixture. This changes no production task, identity, expiry or resume decision.
body = '\n'.join(line for line in queue.read_text().splitlines() if not line.startswith('import '))
body = 'import Foundation\n' + body.replace('private(set)', '').replace('private var backgroundHold', 'var backgroundHold').replace('private func beginBackgroundHold()', 'func beginBackgroundHold()').replace('private func endBackgroundHold()', 'func endBackgroundHold()')
body += '\n' + block(push.read_text(), 'enum ReelCompletionNotice {')
reel_view = screen[screen.index('struct ReelStudioView:'):screen.index('// MARK: Sections', screen.index('struct ReelStudioView:'))]
cleanup = block(reel_view, '        .onDisappear {')
body += '\n@MainActor final class ReelPresentationHarness {\nlet job: ReelWorkJob; let work: ReelWorkJob; let connection = ClosedConnection(); var player: ClosedPlayer? { get { work.player } set { work.setPlaybackPlayer(newValue) } }; var voPlayer: ClosedPlayer? = ClosedPlayer(); let recorder = ClosedRecorder()\ninit(job: ReelWorkJob) { self.job = job; self.work = job; job.isPresented = true; job.setPlaybackPlayer(ClosedPlayer()) }\nfunc onDisappearCleanup() ' + cleanup[cleanup.index('{'):] + '\n}\n'
assert '@ObservedObject private var work: ReelWorkJob' in reel_view
assert '@State private var workTask' not in reel_view
assert 'workTask?.cancel()' not in cleanup and 'endBackgroundHold()' not in cleanup
assert screen.count('work.start(identityIsCurrent:') == 5
assert screen.count('identityIsCurrent: { [model, id = listing.id] in') == 5
assert 'work.isPresented = true' in reel_view
assert 'try requireCurrent()\n                let wasPlanned' in screen
assert 'resumeBatch: true' in screen and 'work.afterCurrentOperation { continueSavedBatch(saved) }' in screen
assert 'work.configuration ?? snapshotReelConfiguration()' in screen
variants = [
    ('actual', body, None),
    ('negative-dismissal-cancels-paid-work', body.replace('            connection.cancel()', '            work.cancel()\n            connection.cancel()'), 'dismissing the sheet leaves the paid app-owned job running'),
    ('negative-retained-terminal-callback', body.replace('            self.resumeAction = nil; self.identityCheck = nil\n', '            self.identityCheck = nil // omitted terminal callback release\n'), 'terminal work releases the captured resume callback'),
    ('negative-retained-dismissed-player', body.replace('player?.pause(); player = nil;', 'player?.pause();'), 'a dismissed studio releases its decoded playback session'),
    ('negative-late-player-while-closed', body.replace('player = isPresented ? value : nil', 'player = value'), 'completion while the studio is closed cannot retain a decoded player'),
    ('negative-duplicate-job-admission', body.replace('guard task == nil, scope.isCurrent, identityIsCurrent()', 'guard scope.isCurrent, identityIsCurrent()'), 'an already-running job admits no duplicate task'),
    ('negative-failed-attempt-progress', body.replace('completedClips - clipIssues.count', 'completedClips'), 'progress counts retained shots rather than failed attempts'),
    ('negative-premature-100', body.replace('min(99, Int((fraction * 100).rounded(.down)))', 'Int((fraction * 100).rounded(.down))'), 'clip completion never claims the composed video is finished'),
    ('negative-async-expiry', body.replace('            self.endBackgroundHold()\n        }', '            Task { @MainActor in self.endBackgroundHold() }\n        }'), 'expiry ends the background grant synchronously'),
    ('negative-stale-expiry', body.replace('guard let self, self.backgroundHoldOperation == operation else { return }', 'guard let self else { return }'), 'stale expiry cannot end a newer background grant'),
    ('negative-expiry-poll-continues', body.replace('            self.task?.cancel()\n            self.endBackgroundHold()', '            // omitted interrupted local polling cancellation\n            self.endBackgroundHold()'), 'expiry pauses and cancels only local execution'),
    ('negative-background-resume', body.replace('UIApplication.shared.applicationState == .active,', 'true,'), 'background expiry cannot dispatch a foreground continuation'),
    ('negative-resume-before-retention', body.replace('            await previous?.value', '            // omitted retention wait'), 'foreground continuation waits for the interrupted task to retain paid files'),
    ('negative-resume-post-wait-owner', body.replace('guard self.paused, self.isContextCurrent, UIApplication.shared.applicationState == .active,', 'guard self.paused, UIApplication.shared.applicationState == .active,').replace('guard self.isContextCurrent else { self.resumeAction = nil; self.followUp = nil; self.identityCheck = nil; return }', 'guard self.isContextCurrent else { self.followUp = nil; return }'), 'an account switch while cleanup awaits cannot resume the old operation'),
    ('negative-scope-owner', body.replace('owner == AuthStore.shared.userID && revision', 'true && revision'), 'owner switch cancels its captured job'),
    ('negative-scope-revision', body.replace('revision == AuthStore.shared.syncSessionRevision', 'true'), 'session replacement cancels its captured job'),
    ('negative-scope-workspace', body.replace('workspace == WorkspaceContext.selectedOrgID', 'true'), 'workspace switch cancels its captured job'),
    ('negative-scope-consent-grant', body.replace('consentRevision == AIConsent.shared.revocationRevision', 'true'), 'revoked then granted consent cancels its captured job'),
    ('negative-listing-permission', body.replace('scope.isCurrent && (identityCheck?() ?? true)', 'scope.isCurrent'), 'listing removal cancels its captured job'),
    ('negative-notice-owner-fence', body.replace('guard PushManager.currentIdentity == identity,', 'guard true,'), "owner switch during notification settings cannot enqueue the old owner's banner"),
    ('negative-notice-revision-fence', body.replace('guard PushManager.currentIdentity == identity,', 'guard PushManager.currentIdentity?.owner == identity.owner,'), "same-owner session replacement cannot enqueue an earlier session's banner"),
    ('negative-notice-foreground-fence', body.replace('UIApplication.shared.applicationState != .active else { return }\n                let content', 'true else { return }\n                let content'), 'returning to the foreground while settings load suppresses the banner'),
]
receipt = {'passed': False, 'start_source_sha256': before, 'runs': [], 'limitations': ['Actual app-level queue/task/identity/expiry/resume and notice methods execute with synthetic observable/UIApplication/UNUserNotificationCenter boundaries. No APNs delivery, OS grant duration, suspension, real composition or killed-process execution proof.']}
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
