#!/usr/bin/env bash
set -euo pipefail
shipping_boundary_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
shipping_boundary_dir="$(mktemp -d)"
trap 'rm -rf "$shipping_boundary_dir"' EXIT
python3 - "$shipping_boundary_root" "$shipping_boundary_dir" <<'PY'
import pathlib, sys, xml.etree.ElementTree as ET
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
        for _ in 0..<1000 where model.spatialCapabilityFetch != nil { await Task.yield() }
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
    @MainActor static func main() async {
        let id = UUID()
        let running = BoundaryTransfer(.running, key: "spatial:\\(id.uuidString):0")
        let suspended = BoundaryTransfer(.suspended, key: "spatial:\\(id.uuidString):0")
        let finished = BoundaryTransfer(.completed, key: "spatial:\\(id.uuidString):0")
        let cancelled = BoundaryTransfer(.canceling, key: "spatial:\\(id.uuidString):0")
        let coordinator = SpatialUploadCoordinator(tasks: [running,suspended,finished,cancelled], id: id)
        coordinator.reconnect()
        for _ in 0..<1000 where coordinator.reconnecting { await Task.yield() }
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
        try? await Task.sleep(nanoseconds: 250_000_000)
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
PY
xcrun swiftc -parse-as-library "$shipping_boundary_dir/ShippingBoundary.swift" -o "$shipping_boundary_dir/regular-boundaries"
"$shipping_boundary_dir/regular-boundaries" -uiTesting
xcrun swiftc -parse-as-library -D SPATIAL_CAPTURE_LAB "$shipping_boundary_dir/ShippingBoundary.swift" -o "$shipping_boundary_dir/lab-boundaries"
"$shipping_boundary_dir/lab-boundaries" -uiTesting
xcrun swiftc -parse-as-library "$shipping_boundary_dir/BackgroundAdmission.swift" -o "$shipping_boundary_dir/regular-background"
"$shipping_boundary_dir/regular-background"
xcrun swiftc -parse-as-library -D SPATIAL_CAPTURE_LAB "$shipping_boundary_dir/BackgroundAdmission.swift" -o "$shipping_boundary_dir/lab-background"
"$shipping_boundary_dir/lab-background"
shipping_device_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
shipping_simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun swiftc -parse-as-library -O -emit-silgen -sdk "$shipping_device_sdk" -target arm64-apple-ios16.0 \
  "$shipping_boundary_dir/UITestingBoundary.swift" > "$shipping_boundary_dir/device.sil"
xcrun swiftc -parse-as-library -O -emit-silgen -sdk "$shipping_simulator_sdk" -target arm64-apple-ios16.0-simulator \
  "$shipping_boundary_dir/UITestingBoundary.swift" > "$shipping_boundary_dir/simulator.sil"
python3 - "$shipping_boundary_dir" <<'PY'
import pathlib, sys
output = pathlib.Path(sys.argv[1])
assert 'string_literal utf8 "-uiTesting"' not in (output/'device.sil').read_text(), 'Physical iOS test switch must compile to false'
assert 'string_literal utf8 "-uiTesting"' in (output/'simulator.sil').read_text(), 'Release simulator UI suite must retain explicit offline test switch'
print('PASS: actual iOS compiler removes the physical test switch and retains it for Release simulators')
PY
