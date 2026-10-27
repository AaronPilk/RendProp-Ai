#!/usr/bin/env python3
"""Compile actual narration readiness, button, permission and creation seams.

The paid remainder of generateWithSession is replaced after its real entry guard
by a snapshot spy. Framing and reconnect callbacks are delayed closed boundaries.
No SDK, UI, microphone, authentication, provider or media generation is invoked.
"""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parents[3]
p = argparse.ArgumentParser()
p.add_argument('--evidence-dir', type=Path, required=True)
args = p.parse_args()
out = args.evidence_dir.resolve()
out.mkdir(parents=True, exist_ok=False)
source = ROOT / 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'
capacity = ROOT / 'apps/ios/Rendprop/Render/VideoAspectChoice.swift'
framing = ROOT / 'apps/ios/Rendprop/Capture/VideoPhotoFramingReview.swift'
fixture = ROOT / 'apps/ios/tests/VideoNarrationReadinessTests.swift'
paths = [source, capacity, framing, fixture, Path(__file__).resolve()]
hashes = lambda: {str(x.relative_to(ROOT)): hashlib.sha256(x.read_bytes()).hexdigest() for x in paths}
before = hashes()
text = source.read_text()
view = text[text.index('struct ReelStudioView:'):]


def block(s, anchor):
    assert s.count(anchor) == 1, anchor
    start = s.index(anchor)
    begin = s.index('{', start)
    depth, end = 1, begin + 1
    while depth:
        depth += (s[end] == '{') - (s[end] == '}')
        end += 1
    return s[start:end]


anchors = ['private var aiCameraAvailable:', 'private var totalSelected:', 'private var narrationPreparationMessage:',
           'private var canGenerate:', 'private var generateTitle:',
           'private var makeButton:', '@ViewBuilder private var scriptLengthNote:',
           'private func recordTapped()', 'private func beginTake()',
           'private var framingSelectionKey:', 'private func generate()']
parts = [block(view, x) for x in anchors]
parts += [block(view, 'nonisolated private static func wholeSeconds(')]
entry = block(view, 'private func generateWithSession()')
entry = entry[:entry.index('        if photoMotion, let saved =')]
assert 'guard phase == .setup, canGenerate, selectedExtras.isEmpty else { return }' in entry
snapshot_lines = [line.strip() for line in block(view, 'private func generateWithSession()').splitlines()
                  if line.strip().startswith('let voiceover: Voiceover?') or line.strip().startswith('let captionStyle: CaptionStyle')]
assert len(snapshot_lines) == 2
entry += '\n' + '\n'.join(snapshot_lines) + '\n snapshotSpy.capture(voiceover, captionStyle: captionStyle)\n}\n'
parts += [entry]
# Select narration's existing cleanup, separately from processor withdrawal.
disappear = block(view, '.onDisappear {\n            // Execution belongs to the app queue.')
parts += ['func disappear() ' + disappear[disappear.index('{'):]]
mode_change = block(view, '.onChange(of: voiceMode)')
parts += ['func changeVoiceMode(_ mode: VoiceMode) { voiceMode = mode\n' + mode_change[mode_change.index('mode in') + len('mode in'):]]
program_parts = '\n\n'.join(parts).replace('private ', '')
program_parts = program_parts.replace('@ViewBuilder', '@ClosedViewBuilder')

# Reviewed fragments from cc1c89e, excluding only the new permission
# retirement. Fixed hashes work from a shallow checkout or a source-only export;
# HEAD is never a baseline. The actual cleanup methods also execute below.
reviewed_baseline_sha256 = {
    'mode_switch_cleanup': 'c70168103238486881f6f8b5c66b0d5c927e808bd310e2a7d36c79ef99303c15',
    'disappear_cleanup': '5192d39fe7306d38b83337ef7dbfb4f7d91a8b87a982ce05b389bf60f050d458',
    'voice_off_ready_row': '2039b097f8be76e962f0a60c7806b690f7902fa00095119f059e5816034000c9',
    'audio_snapshot': '1641727a466bcddc5b41d75a3919faa9a132172e7cd9be67a5035e2d8cd25607',
}
reviewed_fragments = {
    'mode_switch_cleanup': mode_change.replace('            if mode != .myVoice { voicePermissionID = nil; requestingVoicePermission = false }\n', '').replace('            musicPreview.stop()\n', ''),
    'disappear_cleanup': disappear.replace('            voicePermissionID = nil; requestingVoicePermission = false\n', '').replace('musicPreview.stop()', 'musicPreviewPlayer?.pause()'),
    'voice_off_ready_row': block(view, '@ViewBuilder private var voiceoverReadyRow:'),
    'audio_snapshot': json.dumps(snapshot_lines, separators=(',', ':')),
}
unchanged = {
    name: hashlib.sha256(fragment.encode()).hexdigest() == reviewed_baseline_sha256[name]
    for name, fragment in reviewed_fragments.items()
}
assert all(unchanged.values()), unchanged
assert '.disabled(isTranscribing || requestingVoicePermission)' in block(view, 'private func recordButton(')
assert 'The video will freeze on its last picture' not in block(view, '@ViewBuilder private var scriptLengthNote:')

interfaces = r'''
import Foundation
@propertyWrapper struct FixtureState<Value> {
 final class Box { var value: Value; init(_ value: Value) { self.value = value } }
 let box: Box
 init(wrappedValue: Value) { box = Box(wrappedValue) }
 var wrappedValue: Value { get { box.value } nonmutating set { box.value = newValue } }
}
protocol View { var strings: [String] { get } }
struct Text: View { var value: String; init(_ value: String) { self.value = value }; var strings: [String] { [value] } }
typealias Label = Text
extension Text { init(_ value: String, systemImage: String) { self.init(value) } }
struct GroupedView: View { let strings: [String] }
@resultBuilder enum ClosedViewBuilder {
 static func buildExpression<T: View>(_ v: T) -> GroupedView { GroupedView(strings: v.strings) }
 static func buildBlock(_ v: GroupedView...) -> GroupedView { GroupedView(strings: v.flatMap(\.strings)) }
 static func buildEither(first: GroupedView) -> GroupedView { first }
 static func buildEither(second: GroupedView) -> GroupedView { second }
 static func buildOptional(_ v: GroupedView?) -> GroupedView { v ?? GroupedView(strings: []) }
}
struct Font { static let rpBody = Font(); static let rpCaption = Font(); func weight(_ weight: Weight) -> Self { self } }
enum Weight { case semibold }
enum Color { case white, accent, fillSubtle, inkDim, warn }
enum Theme { static let accent = Color.accent; static let fillSubtle = Color.fillSubtle; static let inkDim = Color.inkDim; static let warn = Color.warn }
enum Edge { case vertical }
enum ShapeStyle { case continuous }
struct RoundedRectangle { init(cornerRadius: Double, style: ShapeStyle) {} }
extension View {
 func font(_ font: Font) -> Self { self }
 func foregroundStyle(_ color: Color) -> Self { self }
 func frame(maxWidth: Double) -> Self { self }
 func frame(minHeight: Double) -> Self { self }
 func modifier(_ appearance: RendpropActionAppearance) -> Self { self }
 func padding(_ edge: Edge, _ value: Double) -> Self { self }
 func background(_ color: Color) -> Self { self }
 func clipShape(_ shape: RoundedRectangle) -> Self { self }
 func fixedSize(horizontal: Bool, vertical: Bool) -> Self { self }
}
@MainActor final class Button<Content: View>: View {
 let action: () -> Void; let strings: [String]; var isDisabled = false; var identifier = ""
 init(action: @escaping () -> Void, label: () -> Content) { self.action = action; self.strings = label().strings }
 func disabled(_ value: Bool) -> Self { isDisabled = value; return self }
 func accessibilityIdentifier(_ value: String) -> Self { identifier = value; return self }
 func tap() { if !isDisabled { action() } }
}
struct Voiceover: Equatable { let id: String; var transcript = ""; var duration = 0.0 }
struct ClosedProcessorSnapshot {}
struct ClosedProcessorContext {}
enum CaptionStyle { case standard, off }
@MainActor final class ClosedPlayer { var pauses = 0; func pause() { pauses += 1 }; func stop() { pauses += 1 } }
struct RendpropActionAppearance {}
@MainActor final class ClosedRecorder {
 var isRecording = false; var hasMicrophonePermission = false; var requests = 0; var returns = 0; var starts = 0; var cancels = 0
 var replies: [CheckedContinuation<Bool, Never>] = []
 func requestPermissions() async -> Bool { requests += 1; let value = await withCheckedContinuation { replies.append($0) }; returns += 1; return value }
 func reply(_ both: Bool) { let reply = replies.removeFirst(); reply.resume(returning: both) }
 func start() throws { starts += 1; isRecording = true }
 func cancel() { cancels += 1; isRecording = false }
}
@MainActor enum Haptics { static func selection() {}; static func success() {} }
@MainActor final class ClosedAuth { var userID: String? = "actor"; var syncSessionRevision: UInt64 = 1 }
@MainActor enum WorkspaceContext { static var selectedOrgID: UUID? = UUID(uuidString: "10000000-0000-0000-0000-000000000001") }
@MainActor final class AIConsent { static let shared = AIConsent(); var revocationRevision: UInt64 = 1 }
struct ClosedReply { var isTerminal = false }
struct ClosedServerJob { var reply: ClosedReply? }
enum ClosedPhotoMotionQuoteMode { case credits, plan }
struct ClosedPhotoMotionQuote { let mode: ClosedPhotoMotionQuoteMode; let credits: Int? = nil; let affordable: Bool? = true; let canMake: Bool = true }
@MainActor final class ClosedWork { var serverJob: ClosedServerJob?; var isPresented = true; var isContextCurrent = true }
@MainActor final class ClosedConnection {
 var calls = 0; var cancellations = 0; var deferred = false; var action: (() -> Void)?
 func run(_ action: @escaping @MainActor () -> Void) { calls += 1; if deferred { self.action = action } else { action() } }
 func deliver() { let saved = action; action = nil; saved?() }
 func cancel() { cancellations += 1; action = nil }
}
@MainActor final class SnapshotSpy {
 var count = 0; var voice: Voiceover?; var captions = CaptionStyle.off
 func capture(_ voice: Voiceover?, captionStyle: CaptionStyle) { count += 1; self.voice = voice; captions = captionStyle }
}
struct ClosedPhoto: Sendable { let id: String; let enhancedURL: URL }
struct ClosedListing { let isSample = false }
struct ClosedOpening { struct Reference { let visibleFrames = 0 }; let reference = Reference() }
struct PhotoGeometryInput: Hashable { let id: String; let url: URL }
enum ClosedTransition { case cut, fade }
enum ClosedPhotoMotionProfile: String { case current; var endScale: Double { 1 } }
enum ClosedPhotoMotionDirection: String { case pushIn = "push_in" }
struct VideoPhotoFramingAssessment: Sendable { let isMajorCrop = false }
final class FramingControl: @unchecked Sendable {
 private let lock = NSLock(); private var count = 0; private var blocked = false; private var gate = DispatchSemaphore(value: 0)
 var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
 func reset(block: Bool = false) { lock.lock(); count = 0; blocked = block; gate = DispatchSemaphore(value: 0); lock.unlock() }
 func read() { lock.lock(); count += 1; let wait = blocked; let gate = self.gate; lock.unlock(); if wait { gate.wait() } }
 func release() { lock.lock(); blocked = false; let gate = self.gate; lock.unlock(); gate.signal(); gate.signal() }
}
enum VideoPhotoFramingReader {
 static let control = FramingControl()
 static func read(photoID: String, url: URL, aspect: Double, photoMotion: Bool = false,
                  photoMotionScale: Double = 1, photoMotionDirection: String = "push_in") -> VideoPhotoFramingAssessment? { control.read(); return .init() }
}
@MainActor struct NarrationFixture {
 enum Phase { case setup, generating }
 enum VoiceMode { case off, myVoice, aiVoice }
 @FixtureState var phase = Phase.setup
 @FixtureState var selected = ["first", "second"]
 @FixtureState var selectedExtras: [URL] = []
 @FixtureState var requestingVoicePermission = false
 @FixtureState var voicePermissionID: UUID?
 @FixtureState var isTranscribing = false
 @FixtureState var scriptInFlight = false
 @FixtureState var ttsInFlight = false
 @FixtureState var voiceMode = VoiceMode.off
 @FixtureState var photoMotion = true
 @FixtureState var photoMotionTimingRestorePending = false
 @FixtureState var includeAcceptedOpening = false
 @FixtureState var acceptedOpening: ClosedOpening?
 @FixtureState var chosenOpening: ClosedOpening?
 @FixtureState var reelTransition = ClosedTransition.cut
 @FixtureState var bigCaptionsOn = false
 @FixtureState var photoMotionProfile = ClosedPhotoMotionProfile.current
 @FixtureState var photoMotionDirection = ClosedPhotoMotionDirection.pushIn
 @FixtureState var photoMotionDigests: [PhotoGeometryInput: String] = [:]
 @FixtureState var voiceover: Voiceover?
 @FixtureState var voiceError: String?
 @FixtureState var voiceNote: String?
 @FixtureState var speechDenied = false
 @FixtureState var wordCaptionsOn = true
 @FixtureState var pendingRequest: Bool?
 @FixtureState var unreadablePendingContext: Bool?
 @FixtureState var pendingBatch: Bool?
 @FixtureState var unreadableBatch = false
 @FixtureState var refreshingPhotoMotionQuote = false
 @FixtureState var showPhotoMotionWallet = false
 @FixtureState var checkingFraming = false
 @FixtureState var portrait = false
 @FixtureState var framingAssessments: [VideoPhotoFramingAssessment] = []
 @FixtureState var savedPhotoError: String?
 @FixtureState var pendingFramingKey: String?
 @FixtureState var acknowledgedFramingKey: String?
 @FixtureState var showFramingReview = false
 @FixtureState var aiScript = ""
 @FixtureState var scriptOverrunsReel = false
 @FixtureState var scriptReadSeconds = 0.0
 @FixtureState var reelSeconds = 10
 @FixtureState var catalogueLoads = 0
 let model = "closed-model"; let auth = ClosedAuth(); let work = ClosedWork(); let recorder = ClosedRecorder(); let listing = ClosedListing()
 let currentPhotoMotionQuote: ClosedPhotoMotionQuote? = .init(mode: .plan)
 let connection = ClosedConnection(); let snapshotSpy = SnapshotSpy()
 let musicPreview = ClosedPlayer()
 @FixtureState var player: ClosedPlayer?
 @FixtureState var voPlayer: ClosedPlayer? = ClosedPlayer()
 let reelPhotos = [ClosedPhoto(id: "first", enhancedURL: URL(fileURLWithPath: "/closed/first.jpg")), ClosedPhoto(id: "second", enhancedURL: URL(fileURLWithPath: "/closed/second.jpg"))]
 static let captionsOffNote = "Captions are off — Speech Recognition is turned off in Settings."
 static let scriptCharacterCap = 1000
 // Processor authorization is a closed boundary in this narration-only gate;
 // run-property-video-processors.py executes the real permission lifecycle.
 let preparedProcessorPermission: ClosedProcessorSnapshot? = nil
 let preparedProcessorContext: ClosedProcessorContext? = nil
 let preparedProcessorRevision: UInt64 = 0
 func requirePreparedProcessor() throws {}
 func authorizeVideoPreparation(_ action: () -> Void) { action() }
 func stopAndTranscribe() { recorder.isRecording = false; isTranscribing = true }
 func loadVoices() { catalogueLoads += 1 }
 var openingSelectionIsResolved: Bool { true }
 func photoMotionKey(_ id: String) -> String? { "closed-photo-version" }
 func photoMotionFrameCount(_ id: String) -> Int { 120 }
'''
tail = r'''
 var button: Button<Text> { makeButton as! Button<Text> }
 var scriptNote: String { scriptLengthNote.strings.joined(separator: " ") }
}
'''
helper = capacity.read_text() + '\n' + block(framing.read_text(), 'enum VideoFramingReviewPolicy {')
variants = [
    ('actual', None, None, None),
    ('missing-shared-readiness', 'narrationPreparationMessage == nil && (work.serverJob', '(work.serverJob', 'busy state blocks readiness'),
    ('missing-first-entry-guard', 'guard phase == .setup, canGenerate, !checkingFraming else', 'guard phase == .setup, !checkingFraming else', 'busy tap cannot start framing'),
    ('missing-after-framing-guard', 'guard work.isPresented, phase == .setup, canGenerate, framingSelectionKey', 'guard work.isPresented, phase == .setup, framingSelectionKey', 'busy after framing cannot enter session'),
    ('missing-session-entry-guard', 'guard phase == .setup, canGenerate, selectedExtras.isEmpty else', 'guard phase == .setup, selectedExtras.isEmpty else', 'busy session callback cannot freeze audio'),
    ('missing-permission-marker', 'requestingVoicePermission = true', '// missing permission marker', 'permission await blocks creation'),
    ('missing-permission-retirement', 'defer {\n                if voicePermissionID == permissionID {\n                    voicePermissionID = nil; requestingVoicePermission = false\n                }\n            }', '// missing permission retirement', 'denied permission releases readiness'),
    ('missing-permission-presentation-fence', 'voicePermissionID == permissionID, work.isPresented,', 'voicePermissionID == permissionID,', 'departed permission callback cannot start microphone'),
    ('missing-permission-mode-fence', 'phase == .setup, voiceMode == .myVoice,', 'phase == .setup,', 'changed mode permission callback cannot start microphone'),
    ('missing-permission-context-fence', 'work.isContextCurrent else { return }', 'true else { return }', 'changed context permission callback cannot start microphone'),
    ('deleted-take-before-entry', 'let model = self.model, auth = self.auth\n        guard phase', 'let model = self.model, auth = self.auth\n        if recorder.isRecording { recorder.cancel() }\n        guard phase', 'busy session callback preserves recording'),
    ('stale-busy-label', 'if let narrationPreparationMessage { return narrationPreparationMessage }', '// missing busy title', 'busy title identifies pending work'),
    ('voice-off-uses-cached-audio', '(voiceMode == .off) ? nil : self.voiceover', 'self.voiceover', 'Voice Off cannot include cached narration'),
    ('missing-permission-view-token', 'guard voicePermissionID == permissionID, work.isPresented,', 'guard work.isPresented,', 'reopened job cannot revive old permission intent'),
    ('stale-permission-clears-current', 'if voicePermissionID == permissionID {', 'if true {', 'old callback cannot retire newer permission intent'),
    ('mode-reentry-revives-permission', 'if mode != .myVoice { voicePermissionID = nil; requestingVoicePermission = false }', '// lost mode permission retirement', 'leaving My voice explicitly retires permission intent'),
]
receipt = {'passed': False, 'start_source_sha256': before, 'unchanged_behavior': unchanged,
           'reviewed_baseline_sha256': reviewed_baseline_sha256, 'git_history_required': False, 'runs': [],
           'limitations': ['Actual source-derived readiness, Create button wiring, complete generate framing flow, permission callback and pre-paid generateWithSession guard/snapshot execute.',
                           'The paid generation remainder is replaced at the first selected-photo read by a counter; no upload, plan, enqueue, microphone, TTS, auth, UIKit or provider runs.',
                           'Processor preparation authorization and its frozen values are inert closed boundaries here; this gate does not prove processor consent or paid admission.',
                           'Foundation/UI-value boundaries are closed; this is not physical UI or media quality acceptance.']}
try:
    cache = out / 'module-cache'; cache.mkdir()
    for name, old, new, expected in variants:
        mutated_parts = program_parts
        if old:
            assert mutated_parts.count(old) == 1, (name, mutated_parts.count(old))
            mutated_parts = mutated_parts.replace(old, new, 1)
        body = interfaces + mutated_parts + tail + helper + fixture.read_text()
        case = out / name; case.mkdir()
        swift = case / 'main.swift'; swift.write_text(body)
        binary = case / 'tests'
        result = subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6', '-module-cache-path', str(cache), str(swift), '-o', str(binary)], capture_output=True, text=True, timeout=120)
        (case / 'compile.log').write_text(result.stdout + result.stderr)
        assert result.returncode == 0, name + ': compile failure: ' + result.stderr[-5000:]
        result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
        log = result.stdout + result.stderr; (case / 'run.log').write_text(log)
        passed = result.returncode == 0 and 'PASSED:' in log if expected is None else result.returncode != 0 and 'FAIL: ' + expected in log
        receipt['runs'].append({'name': name, 'exit_code': result.returncode, 'expected_failure': expected, 'expected_result': passed})
        assert passed, name + ': ' + log[-4000:]
        if expected is None: receipt['actual_output'] = log.strip()
except BaseException as error:
    receipt['failure'] = str(error)
    raise
finally:
    receipt['end_source_sha256'] = hashes()
    receipt['source_binding_matches'] = before == receipt['end_source_sha256']
    receipt['passed'] = 'failure' not in receipt and len(receipt['runs']) == len(variants) and all(x['expected_result'] for x in receipt['runs']) and receipt['source_binding_matches']
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['passed']
print(receipt['actual_output'])
print('PASS: 15 compiled negative controls; receipt:', out / 'receipt.json')
