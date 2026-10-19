#!/usr/bin/env python3
"""Optional photo feedback: source gates, compiled offline checks and guard-removal controls.

The compiled part builds the actual PhotoFeedback.swift with the actual
PhotoVersionHistory/PhotoCaptureStorage and apps/ios/tests/PhotoFeedbackTests.swift
(macOS, xcrun swiftc). Each control removes one guard and must make a named check
fail. No network, provider, UI, simulator or customer media. --source-only runs
the static gates alone (any OS); it is not behavioral evidence.
"""
import argparse, hashlib, json, shutil, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--evidence-dir', type=Path)
p.add_argument('--source-only', action='store_true')
args = p.parse_args()
OUT = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-photo-feedback-'))
OUT.mkdir(parents=True, exist_ok=True)
APP = ROOT / 'apps/ios/Rendprop'
paths = {
    'feedback': APP / 'Photos/PhotoFeedback.swift', 'queue': APP / 'Photos/PhotoFeedbackQueue.swift',
    'control': APP / 'Photos/PhotoFeedbackControl.swift', 'history': APP / 'Photos/PhotoVersionHistory.swift',
    'capture': APP / 'Capture/PhotoCaptureStorage.swift', 'service': APP / 'Photos/PhotoEditService.swift',
    'export': APP / 'Photos/PhotoExport.swift', 'detail': APP / 'Screens/FlythroughDetailView.swift',
    'live': APP / 'Networking/LiveAPIClient.swift', 'app': APP / 'RendpropApp.swift',
    'project': ROOT / 'apps/ios/Rendprop.xcodeproj/project.pbxproj',
    'tests': ROOT / 'apps/ios/tests/PhotoFeedbackTests.swift', 'runner': Path(__file__).resolve()}
src = {key: path.read_text() for key, path in paths.items()}
digest = lambda: {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths.values()}
before = digest()


def block(text, anchor):
    assert text.count(anchor) == 1, anchor
    start = text.index(anchor); i = text.index('{', start) + 1; depth = 1
    while depth:
        depth += (text[i] == '{') - (text[i] == '}'); i += 1
    return text[start:i]


gates = []
def gate(condition, message):
    assert condition, message
    gates.append(message)


# --- Mandatory reviews and publication safeguards never consult feedback -----
gate('feedback' not in src['history'].lower(), 'PhotoVersionHistory (review flags, selection, publication) has no feedback dependency')
review = block(src['detail'], 'struct PhotoCompareView: View {')
for anchor in ['private func changeListingSelection()', 'private var savePhotoButton: some View {',
               'private var listingSelectionDisabled:', 'private var savePhotoDisabled:', 'private var needsStagingReview:',
               'private var needsCustomReview:', '.task(id: viewed.id) {', 'private var stagingReviewChecklist: some View {',
               'private var customReviewChecklist: some View {', 'private func actionFooter(',
               '@ViewBuilder private var useOnListingButton: some View {']:
    gate('Feedback' not in block(review, anchor), 'review gate or action never consults feedback: ' + anchor)
details = block(review, 'private var reviewDetails: some View {')
gate(details.index('stagingReviewChecklist') < details.index('customReviewChecklist') < details.index('PhotoFeedbackControl('),
     'the optional control sits after the required review checks')
gate('if !showOriginal, let feedbackVersion = viewed.savedVersion, PhotoFeedbackQueue.shared.canRecord(feedbackVersion) {' in details
     and '.id(feedbackVersion.id)' in details, 'the control is bound to the exact displayed version and hidden without it')
gate(src['detail'].count('PhotoFeedbackControl(') == 1, 'the control appears only in the result review')
for anchor in ['private func beginCloudSelection(', 'private func setMain(']:
    body = src['detail'][src['detail'].index(anchor):]
    body = block(body, anchor)
    for required in ['try await model.']:
        gate(body.index(required) < body.index('PhotoFeedbackQueue.shared.'), 'signals are recorded after the action: ' + anchor)

# --- Attribution to the exact output; unknown provenance stays unknown -------
fb, queue, control = src['feedback'], src['queue'], src['control']
gate('guard version.provenanceRecorded else { return nil }' in block(fb, 'init?(version: PhotoVersionHistory.Version) {')
     and 'let id = UUID(uuidString: raw)' in block(fb, 'init?(provenanceID: String?, outputSHA256: String? = nil) {'),
     'only a recorded UUID provenance row qualifies')
for anchor in ['func canRecord(', 'func savedFeedback(', 'func submit(', 'func recordSignal(', 'nonisolated static func recordAutomaticSelection(']:
    gate('PhotoFeedback.Output(version: version)' in block(queue, anchor), 'every record path requires the exact output: ' + anchor)
gate('static func newClientKey() -> String { "ios-" + UUID().uuidString.lowercased() }' in fb, 'client keys are random UUID-based')
gate('Date' not in block(fb, 'static func newClientKey()'), 'client keys never use the clock')
gate('existing.clientKey' not in block(fb, 'func record(_ draft: PhotoFeedback.Draft'), 'a revision never changes the key')
for forbidden in ['aiPhotoEdit', 'PhotoEditService(', 'ai-photo', 'aiVideo', 'PhotoWorkQueue', 'saveEdit(', 'selectForPublication(',
                  'confirmCustomReview(', 'removeFromPublication(', 'changeCloudPhotoSelection(', 'makeCloudPhotoCover(']:
    gate(forbidden not in fb + queue + control, 'feedback never generates, pays or changes photo history: ' + forbidden)

# --- Transport, headers and account fences -----------------------------------
transport = block(src['live'], 'extension LiveAPIClient: PhotoFeedbackAPI {')
for required in ['makeRequest(url: url(route.pathSegments), method: "POST", json: body)',
                 'request.setValue(library, forHTTPHeaderField: "X-Org-Id")',
                 'guard let token = await AuthStore.validAccessToken()',
                 'AnonymousAdoptionRecovery.identity(token)?.id == actorUUID',
                 'let (data, response) = try await session.data(for: request)',
                 'guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision else {']:
    gate(required in transport, 'feedback transport keeps the account fence and library headers: ' + required)
gate('x-rendprop-org' not in transport, 'contract A1: the library travels as X-Org-Id only')
gate(src['live'].rstrip().endswith(transport.rstrip()), 'the transport is a trailing same-file extension, outside every extracted client method')
gate('case .feedback: return ["photo-feedback"]' in fb and 'case .signal: return ["photo-feedback", "signal"]' in fb, 'contract routes')

# --- Signal hooks, compile boundaries of other harnesses ---------------------
service = src['service']
post = 'NotificationCenter.default.post(name: Notification.Name("rendprop.photoEditSaved"), object: nil,'
gate(service.count(post) == 1 and service.index('PhotoVersionHistory.saveEdit(') < service.index(post),
     'the edit service announces a saved version after saving it')
gate('static let rendpropPhotoEditSaved = Notification.Name("rendprop.photoEditSaved")' in fb, 'one notification name on both sides')
gate('PhotoFeedback' not in service, 'PhotoEditService stays Foundation-only (tests/phase1 compiles it with its own doubles)')
gate('PhotoFeedback' not in src['export'] and 'if currentContext { onExported(input, options.original, coordinator || !packageExtras.isEmpty) }' in src['export'],
     'PhotoExport reports a finished export through a plain callback (the renderer harness compiles it with stubs)')
gate(src['detail'].count('onExported: PhotoFeedbackQueue.recordExport') == 3, 'all three export sheets report finished exports')
gate(src['detail'].count('PhotoFeedbackQueue.shared.recordPublication(listingID: id, model: model)') == 2, 'publish and republish report publication')
gate('.task { PhotoFeedbackQueue.shared.start() }' in src['app'], 'the queue starts at launch to retry earlier items')
for name in ['PhotoFeedback.swift', 'PhotoFeedbackControl.swift', 'PhotoFeedbackQueue.swift']:
    gate(src['project'].count('/* ' + name + ' */') == 3 and src['project'].count('/* ' + name + ' in Sources */') == 2,
         'the app target compiles ' + name)

results = []
if not args.source_only:
    assert shutil.which('xcrun'), 'xcrun is required for the compiled checks; use --source-only for static gates'
    def run(name, feedback_text, expected):
        folder = OUT / name; folder.mkdir(exist_ok=True)
        actual = folder / 'PhotoFeedback.swift'; actual.write_text(feedback_text)
        binary = folder / 'checks'
        build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(paths['capture']),
                                str(paths['history']), str(actual), str(paths['tests']), '-o', str(binary)],
                               capture_output=True, text=True, timeout=240)
        (folder / 'compile.log').write_text(build.stdout + build.stderr)
        assert build.returncode == 0, name + ': compile failure is not behavioral evidence\n' + build.stderr[-4000:]
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
        log = result.stdout + result.stderr; (folder / 'runtime.log').write_text(log)
        if expected is None:
            assert result.returncode == 0 and 'PASS ' in log, name + ': ' + log[-4000:]
        else:
            assert result.returncode != 0 and expected in log, name + ' was not refused as expected: ' + log[-4000:]
        results.append({'name': name, 'compileExit': build.returncode, 'runtimeExit': result.returncode, 'expectedFailure': expected})
        print(name + ': PASS', flush=True)
        return log

    actual = src['feedback']
    controls = [
        ('unrecorded-provenance-accepted',
         '        init?(version: PhotoVersionHistory.Version) {\n            guard version.provenanceRecorded else { return nil }\n',
         '        init?(version: PhotoVersionHistory.Version) {\n',
         'unrecorded provenance stays unknown'),
        ('key-rotates-on-revision',
         '            existing.revision += 1\n            existing.verdict = draft.verdict',
         '            existing.revision += 1\n            existing.clientKey = PhotoFeedback.newClientKey()\n            existing.verdict = draft.verdict',
         'a changed opinion bumps the revision under the same key'),
        ('library-retargeted',
         '.filter { !$0.delivered && $0.libraryOrgID == library && due($0.nextAttemptAt) }',
         '.filter { !$0.delivered && due($0.nextAttemptAt) }',
         'queued items are sent only while their own library is selected'),
        ('offline-keeps-sending',
         '                progress()\n                if outcome == .retryLater { return .deferred }\n            case .signal(let record):',
         '                progress()\n            case .signal(let record):',
         'a request was sent that the scenario did not expect'),
        ('late-answer-applied',
         '                    guard isCurrent() else { return .interrupted }\n                    outcome = PhotoFeedback.classifyFeedback(reply, sent: record)',
         '                    outcome = PhotoFeedback.classifyFeedback(reply, sent: record)',
         'an answer arriving after an account change is not applied'),
        ('foreign-answer-accepted',
         '                    return .drop("provenance_mismatch")',
         '                    return .accepted(fallback)',
         'an answer naming another image never settles this one'),
        ('older-revision-overwrites',
         'if receipt.revision > current.revision, let held = receipt.content {',
         'if false, let held = receipt.content {',
         'an older revision never replaces the newer opinion the server already holds'),
        ('adoption-ignored',
         '            current.clientKey = key\n',
         '',
         '409 feedback_exists: adopt the server key and resend above its stored revision'),
        ('foreign-key-adopted',
         '!snapshot.feedback.contains(where: { $0.clientKey == key && $0.provenanceID != current.provenanceID }) else {',
         'true else {',
         'adopting a key never displaces a newer queued opinion that holds it'),
        ('signal-dedupe-removed',
         '        guard !snapshot.signals.contains(where: { $0.dedupeKey == key }) else { return false }\n',
         '',
         'repeating an action queues nothing new'),
        ('cloud-selection-from-local-history',
         'if !cloudListing && !old.selectedForListing && new.selectedForListing {',
         'if !old.selectedForListing && new.selectedForListing {',
         "a cloud listing's choice is recorded where the server accepts it, not from local history"),
        ('automatic-rule-ignored',
         'version.canAutomaticallySelectForListing, index.isSelectedForListing(versionID) else { return nil }',
         'version.canAutomaticallySelectForListing else { return nil }',
         'an edit in a family the person removed is not an automatic selection'),
        ('missing-route-drops',
         'case 404 where errorCode(body) != "output_not_found":',
         'case 404 where false:',
         'a 404 other than output_not_found (function not deployed yet) keeps the item queued'),
        ('unsent-never-expires',
         '        snapshot.feedback.removeAll { !$0.delivered && $0.changedAt < cutoff }\n',
         '',
         'unsent items expire quietly after 30 days; delivered opinions stay'),
    ]
    run('actual', actual, None)
    for name, old, new, expected in controls:
        assert actual.count(old) == 1, (name, actual.count(old))
        run(name, actual.replace(old, new), expected)

assert digest() == before, 'Consumed source changed during the proof'
receipt = {
    'passed': True, 'sourceOnly': args.source_only, 'sourceHashes': before, 'gates': gates, 'results': results,
    'compiledControls': max(0, len(results) - 1), 'networkCalls': 0, 'providerCalls': 0, 'UIExecutions': 0,
    'scope': 'Actual PhotoFeedback model/queue/delivery rules with actual photo history on the local filesystem and a '
             'scripted transport; static gates for the review screen, edit service, exports, publication hooks, '
             'transport fences and project membership. SwiftUI rendering, LiveAPIClient networking and the phone '
             'are not exercised here.'}
(OUT / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps({'passed': True, 'gates': len(gates), 'compiled': len(results), 'receipt': str(OUT / 'receipt.json')}))
