#!/usr/bin/env bash
set -euo pipefail
shipping_boundary_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
shipping_boundary_dir="$(mktemp -d /tmp/rendprop-app-store-boundaries-XXXXXX)"
python3 - "$shipping_boundary_root" "$shipping_boundary_dir" <<'PY'
import hashlib, json, pathlib, sys, xml.etree.ElementTree as ET
root, output = map(pathlib.Path, sys.argv[1:])
app = (root/'apps/ios/Rendprop/RendpropApp.swift').read_text()
config = (root/'apps/ios/Rendprop/Config.swift').read_text()
settings = (root/'apps/ios/Rendprop/Screens/SettingsView.swift').read_text()
uploader = (root/'apps/ios/Rendprop/Upload/SpatialUploadCoordinator.swift').read_text()
def block(source, anchor):
    start = source.index(anchor)
    opening = source.index('{', start)
    depth = 0
    for position in range(opening, len(source)):
        if source[position] == '{': depth += 1
        elif source[position] == '}':
            depth -= 1
            if depth == 0: return source[start:position+1]
    raise AssertionError('Unclosed actual shipping boundary')
flag = block(config, '    static var isUITesting: Bool {')
availability = block(app, '    var isSpatialWalkthroughAvailable: Bool {')
refresh = block(app, '    func refreshSpatialCapability() {')
footer = block(settings, '    private var aiProcessingFooter: String {')
route = app[app.index('            case .spatial:', app.index('@ViewBuilder private var routeDestination')):]
route = route[:route.index('            case .tour:')]
assert route.index('if model.isSpatialWalkthroughAvailable') < route.index('SpatialTourView(')
assert 'else {' in route and 'FlythroughDetailView(listing: route.listing)' in route
assert sum(p.read_text().count('SpatialTourView(') for p in (root/'apps/ios/Rendprop').rglob('*.swift')) == 1, 'Every spatial route must reach the sole guarded constructor'
assert 'case .spatial' not in (root/'apps/ios/Rendprop/Coach/CoachModel.swift').read_text()
deep_link = (root/'apps/ios/Rendprop/DeepLink/DeepLink.swift').read_text()
assert 'case spatial' not in deep_link and 'case "s":' not in deep_link, 'Deep links must not create experimental capture routes'
assert '#if SPATIAL_CAPTURE_LAB\n            .task { SpatialUploadCoordinator.shared.reconnect() }\n#endif' in app
assert 'AIConsent.processors.map(\\.name)' in footer, 'Settings must use the actual disclosed processor names'
assert 'Google (Gemini, Veo, Seedance)' not in footer, 'Do not attribute other providers to Google'
normal_project = (root/'apps/ios/Rendprop.xcodeproj/project.pbxproj').read_text()
assert 'SPATIAL_CAPTURE_LAB' not in normal_project, 'Regular project must not compile the lab condition'
scheme = ET.parse(root/'apps/ios/Rendprop.xcodeproj/xcshareddata/xcschemes/Rendprop.xcscheme').getroot()
assert scheme.find('ArchiveAction').get('buildConfiguration') == 'Release'
entries = scheme.findall('./BuildAction/BuildActionEntries/BuildActionEntry')
app_entries = [e for e in entries if e.find('BuildableReference').get('BuildableName') == 'Rendprop.app']
test_entries = [e for e in entries if e.find('BuildableReference').get('BuildableName').endswith('.xctest')]
assert len(app_entries) == 1 and app_entries[0].get('buildForArchiving') == 'YES'
assert len(test_entries) == 1 and test_entries[0].get('buildForArchiving') == 'NO'
header = '''import Foundation
enum Config {
'''
body = '''
}
struct SpatialCapability { let enabled: Bool }
@MainActor final class BoundaryAPI {
    var calls = 0
    func spatialCapability() async throws -> SpatialCapability {
        calls += 1
        return SpatialCapability(enabled: true)
    }
}
@MainActor final class AppModel {
    var spatialCapability: SpatialCapability?
    var spatialCapabilityFetch: Task<Void, Never>?
    let api = BoundaryAPI()
'''
test = '''
}
@main struct ShippingBoundaryTests {
    @MainActor static func waitFor(_ message: String, until ready: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !ready() {
            precondition(Date() < deadline, message)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @MainActor static func main() async {
        precondition(!Config.isUITesting, "Physical/host builds must ignore injected UI-test arguments")
        let model = AppModel()
        precondition(!model.isSpatialWalkthroughAvailable, "Unknown capability must stay hidden")
        model.spatialCapability = SpatialCapability(enabled: true)
#if SPATIAL_CAPTURE_LAB
        precondition(model.isSpatialWalkthroughAvailable, "Lab must preserve enabled capture")
#else
        precondition(!model.isSpatialWalkthroughAvailable, "Server-enabled cannot expose capture in App Store")
#endif
        model.spatialCapability = SpatialCapability(enabled: false)
        precondition(!model.isSpatialWalkthroughAvailable, "Disabled capability must stay hidden")
        model.refreshSpatialCapability()
        model.refreshSpatialCapability()
#if SPATIAL_CAPTURE_LAB
        await waitFor("Lab capability fetch must finish before deadline", until: { model.spatialCapabilityFetch == nil })
        precondition(model.api.calls == 1, "Lab fetch must coalesce")
        precondition(model.isSpatialWalkthroughAvailable, "Lab fetch must update availability")
        precondition(model.spatialCapabilityFetch == nil, "Lab fetch must release its task")
        print("PASS: TestFlight lab retains server-gated, coalesced capture")
#else
        await Task.yield()
        precondition(model.api.calls == 0, "Regular app must not fetch the experimental capability")
        precondition(model.spatialCapabilityFetch == nil, "Regular app must not create a capability task")
        precondition(!model.isSpatialWalkthroughAvailable, "Regular app must remain hidden")
        print("PASS: App Store capture remains unavailable even with enabled server capability")
#endif
    }
}
'''
(output/'ShippingBoundary.swift').write_text(header+flag+body+availability+'\n'+refresh+test)
(output/'UITestingBoundary.swift').write_text(header+flag+'\n}\n@inline(never) public func compiledUITestFlag() -> Bool { Config.isUITesting }\n')
policy = block(uploader, '    private static var permitsSpatialWork: Bool {')
reconnect = block(uploader, '    func reconnect() {')
drain = block(uploader, '    fileprivate func eventsDrained() {')
finish = block(uploader, '    private func finishDrain() {')
parse = block(uploader, '    private static func parse(')
# Execute the actual transport-admission guards without real API, OS session,
# filesystem or GPU work. Existing lab transport tests cover the remainder.
pump = block(uploader, '    private func pump() {').split('        for record in records')[0] + '        pumpCalls += 1\n    }'
advance = block(uploader, '    private func advanceJob(').split('        do {')[0] + '        generationCalls += 1\n    }'
background_header = (root/'apps/ios/tests/SpatialBackgroundAdmissionTests.swift').read_text()
(output/'BackgroundAdmission.swift').write_text(background_header+'\nextension SpatialUploadCoordinator {\n'+'\n'.join([policy,reconnect,drain,finish,parse,pump,advance])+'''\n
    func probeAdvance(_ id: UUID) async { starting.insert(id); await advanceJob(id) }
}
@main struct BackgroundAdmissionTests {
    @MainActor static func waitFor(_ message: String, until ready: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !ready() {
            precondition(Date() < deadline, message)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @MainActor static func main() async {
        let id = UUID()
        let running = BoundaryTransfer(.running, key: "spatial:\\(id.uuidString):0")
        let suspended = BoundaryTransfer(.suspended, key: "spatial:\\(id.uuidString):0")
        let finished = BoundaryTransfer(.completed, key: "spatial:\\(id.uuidString):0")
        let cancelled = BoundaryTransfer(.canceling, key: "spatial:\\(id.uuidString):0")
        // A repeated transport callback deliberately arrives after the former
        // 250 ms observation. The real drain must finish before it is inspected.
        let coordinator = SpatialUploadCoordinator(tasks: [running,suspended,finished,cancelled], id: id,
            repeatedCallbackDelay: 400_000_000)
        coordinator.reconnect()
        await waitFor("Transport reconnect must finish before deadline", until: { !coordinator.reconnecting })
        await coordinator.probeAdvance(id)
#if SPATIAL_CAPTURE_LAB
        precondition(running.suspends == 0 && suspended.resumes == 1, "Lab must resume its owned suspended upload")
        precondition(coordinator.generationCalls == 1 && coordinator.pumpCalls > 0, "Lab must admit generation")
#else
        precondition(running.suspends == 1 && running.state == .suspended, "Production must pause old running lab tasks")
        precondition(suspended.resumes == 0, "Production must never resume a paused lab task")
        precondition(coordinator.generationCalls == 0 && coordinator.pumpCalls == 0, "Production must admit no new transfer or GPU work")
#endif
        precondition(finished.suspends == 0 && cancelled.suspends == 0, "Finished/canceling tasks must stay untouched")
        precondition(coordinator.records.count == 1 && coordinator.records[0].id == id, "Journal and retained capture record must remain intact")
        var completions = 0
        coordinator.finishBackgroundEvents = { completions += 1 }
        coordinator.eventsDrained()
#if SPATIAL_CAPTURE_LAB
        await waitFor("Lab drain must deliver actual OS completion before deadline",
            until: { completions == 1 && coordinator.finishBackgroundEvents == nil })
        precondition(UIApplication.shared.begins == 1 && UIApplication.shared.ends == 1, "Lab must balance its bounded background drain")
#else
        precondition(UIApplication.shared.begins == 0 && UIApplication.shared.ends == 0, "Production must not start a cloud receipt drain")
#endif
        precondition(completions == 1 && coordinator.finishBackgroundEvents == nil, "OS completion must be delivered and cleared exactly once")
        coordinator.eventsDrained()
        precondition(completions == 1, "Repeated callbacks must not deliver completion twice")
        precondition(coordinator.journalFlushes >= 1, "Received transport receipts must be flushed before OS completion")
        print("PASS: actual spatial background admission preserves journals, obeys build scope and completes OS callbacks once")
    }
}
''')
print('PASS: regular scheme archives only the app in Release; Settings mirrors consent processors')
inputs = ['apps/ios/Rendprop/RendpropApp.swift', 'apps/ios/Rendprop/Config.swift',
    'apps/ios/Rendprop/Screens/SettingsView.swift', 'apps/ios/Rendprop/Upload/SpatialUploadCoordinator.swift',
    'apps/ios/Rendprop/Coach/CoachModel.swift', 'apps/ios/Rendprop/DeepLink/DeepLink.swift',
    'apps/ios/Rendprop.xcodeproj/project.pbxproj',
    'apps/ios/Rendprop.xcodeproj/xcshareddata/xcschemes/Rendprop.xcscheme',
    'apps/ios/tests/run-app-store-boundaries.sh', 'apps/ios/tests/SpatialBackgroundAdmissionTests.swift']
receipt = {'sourceHashes': {p: hashlib.sha256((root/p).read_bytes()).hexdigest() for p in inputs},
    'actualBodyHashes': {name: hashlib.sha256(value.encode()).hexdigest() for name, value in
        {'policy': policy, 'reconnect': reconnect, 'drain': drain, 'finish': finish}.items()},
    'transportCallbackDelayNanoseconds': 400_000_000, 'observationDeadlineSeconds': 3,
    'networkCalls': 0, 'cameraCalls': 0, 'realOSBackgroundTasks': 0, 'runtimeMutations': 0}
(output/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
PY
xcrun swiftc --version > "$shipping_boundary_dir/compiler-version.log" 2>&1
xcrun swiftc -parse-as-library "$shipping_boundary_dir/ShippingBoundary.swift" -o "$shipping_boundary_dir/regular-boundaries" 2> "$shipping_boundary_dir/regular-boundaries-compile.log"
"$shipping_boundary_dir/regular-boundaries" -uiTesting | tee "$shipping_boundary_dir/regular-boundaries.log"
xcrun swiftc -parse-as-library -D SPATIAL_CAPTURE_LAB "$shipping_boundary_dir/ShippingBoundary.swift" -o "$shipping_boundary_dir/lab-boundaries" 2> "$shipping_boundary_dir/lab-boundaries-compile.log"
"$shipping_boundary_dir/lab-boundaries" -uiTesting | tee "$shipping_boundary_dir/lab-boundaries.log"
xcrun swiftc -parse-as-library "$shipping_boundary_dir/BackgroundAdmission.swift" -o "$shipping_boundary_dir/regular-background" 2> "$shipping_boundary_dir/regular-background-compile.log"
"$shipping_boundary_dir/regular-background" | tee "$shipping_boundary_dir/regular-background.log"
xcrun swiftc -parse-as-library -D SPATIAL_CAPTURE_LAB "$shipping_boundary_dir/BackgroundAdmission.swift" -o "$shipping_boundary_dir/lab-background" 2> "$shipping_boundary_dir/lab-background-compile.log"
"$shipping_boundary_dir/lab-background" | tee "$shipping_boundary_dir/lab-background.log"
python3 - "$shipping_boundary_dir" <<'PY'
import pathlib, sys
output = pathlib.Path(sys.argv[1])
source = (output/'BackgroundAdmission.swift').read_text()
for name, before, after in [
    ('missing-drain-completion', '        finished?()', '        _ = finished // altered-source missing OS completion'),
    ('missing-background-end', '            UIApplication.shared.endBackgroundTask(backgroundDrain)',
        '            // altered-source missing background assertion end')]:
    assert source.count(before) == 1, name
    (output/(name+'.swift')).write_text(source.replace(before, after))
PY
for shipping_boundary_fault in missing-drain-completion missing-background-end; do
  xcrun swiftc -parse-as-library -D SPATIAL_CAPTURE_LAB "$shipping_boundary_dir/$shipping_boundary_fault.swift" \
    -o "$shipping_boundary_dir/$shipping_boundary_fault" 2> "$shipping_boundary_dir/$shipping_boundary_fault-compile.log"
  if "$shipping_boundary_dir/$shipping_boundary_fault" > "$shipping_boundary_dir/$shipping_boundary_fault.log" 2>&1; then
    shipping_boundary_status=0
  else
    shipping_boundary_status=$?
  fi
  printf '%s\n' "$shipping_boundary_status" > "$shipping_boundary_dir/$shipping_boundary_fault.status"
  case "$shipping_boundary_fault" in
    missing-drain-completion) shipping_boundary_expected='Lab drain must deliver actual OS completion before deadline' ;;
    missing-background-end) shipping_boundary_expected='Lab must balance its bounded background drain' ;;
  esac
  if [ "$shipping_boundary_status" -eq 0 ] || ! grep -F -q "$shipping_boundary_expected" "$shipping_boundary_dir/$shipping_boundary_fault.log"; then
    cat "$shipping_boundary_dir/$shipping_boundary_fault.log"
    echo "FAIL: $shipping_boundary_fault must compile and fail its named assertion"
    exit 1
  fi
  echo "PASS: compiled $shipping_boundary_fault failed its named assertion"
done
shipping_device_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
shipping_simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun swiftc -parse-as-library -O -emit-silgen -sdk "$shipping_device_sdk" -target arm64-apple-ios16.0 \
  "$shipping_boundary_dir/UITestingBoundary.swift" > "$shipping_boundary_dir/device.sil" 2> "$shipping_boundary_dir/device-compile.log"
xcrun swiftc -parse-as-library -O -emit-silgen -sdk "$shipping_simulator_sdk" -target arm64-apple-ios16.0-simulator \
  "$shipping_boundary_dir/UITestingBoundary.swift" > "$shipping_boundary_dir/simulator.sil" 2> "$shipping_boundary_dir/simulator-compile.log"
python3 - "$shipping_boundary_dir" <<'PY'
import pathlib, sys
output = pathlib.Path(sys.argv[1])
assert 'string_literal utf8 "-uiTesting"' not in (output/'device.sil').read_text(), 'Physical iOS test switch must compile to false'
assert 'string_literal utf8 "-uiTesting"' in (output/'simulator.sil').read_text(), 'Release simulator UI suite must retain explicit offline test switch'
print('PASS: actual iOS compiler removes the physical test switch and retains it for Release simulators')
PY
python3 - "$shipping_boundary_root" "$shipping_boundary_dir" <<'PY'
import hashlib, json, pathlib, sys
root, output = map(pathlib.Path, sys.argv[1:])
receipt = json.loads((output/'receipt.json').read_text())
receipt['sourceHashesAtEnd'] = {p: hashlib.sha256((root/p).read_bytes()).hexdigest() for p in receipt['sourceHashes']}
receipt['sourceBoundAtEnd'] = receipt['sourceHashes'] == receipt['sourceHashesAtEnd']
receipt['harnessHashes'] = {p: digest for p, digest in receipt['sourceHashes'].items() if p.startswith('apps/ios/tests/')}
receipt['harnessHashesAtEnd'] = {p: receipt['sourceHashesAtEnd'][p] for p in receipt['harnessHashes']}
receipt['harnessBoundAtEnd'] = receipt['harnessHashes'] == receipt['harnessHashesAtEnd']
receipt['compilerVersion'] = (output/'compiler-version.log').read_text().strip()
receipt['compiledSourceHashes'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in output.glob('*.swift')}
receipt['positiveCases'] = ['regular-boundaries', 'lab-boundaries', 'regular-background', 'lab-background-delayed-callback', 'physical-iOS-and-Release-simulator-SIL']
receipt['alteredSourceControls'] = {name: {'compileExit': 0,
    'executableExit': int((output/(name+'.status')).read_text()), 'expectedRejection': expected}
    for name, expected in [('missing-drain-completion', 'Lab drain must deliver actual OS completion before deadline'),
        ('missing-background-end', 'Lab must balance its bounded background drain')]}
receipt['logHashes'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in output.glob('*.log')}
receipt['passed'] = receipt['sourceBoundAtEnd'] and receipt['harnessBoundAtEnd']
(output/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
assert receipt['passed'], 'Boundary source or harness changed during execution'
print('PASS: exact boundary production and harness hashes match at completion')
PY
echo "Boundary evidence: $shipping_boundary_dir"
