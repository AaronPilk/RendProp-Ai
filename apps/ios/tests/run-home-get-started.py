#!/usr/bin/env python3
"""Execute Home's actual new-home and retained tool-routing bodies at closed boundaries."""
import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--evidence-dir', type=Path)
args = parser.parse_args()
out = (args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-home-entry-'))).resolve()
out.mkdir(parents=True, exist_ok=True)
app_path = ROOT / 'apps/ios/Rendprop/RendpropApp.swift'
listing_path = ROOT / 'apps/ios/Rendprop/Screens/NewListingView.swift'
ui_path = ROOT / 'apps/ios/RendpropUITests/HomeProjectCreationUITests.swift'
paths = [app_path, listing_path, ui_path, Path(__file__).resolve()]
hashes = lambda: {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}


def block(source, needle):
    assert source.count(needle) == 1, needle
    start = source.index(needle)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


start_hashes = hashes()
app = app_path.read_text()
home = block(app, 'struct HomeDashboardView: View {')
hero = block(home, 'private var heroCard: some View {')
assert 'Button { startNewHome() } label:' in hero
assert '.navigationDestination(isPresented: $showNewListing) { NewListingView() }' in home
assert 'Button { open(feature) } label:' in block(home, 'private func featureButton(')
new = block(listing_path.read_text(), 'struct NewListingView: View {')
assert 'ListingFieldsForm(form: $form,' in new
assert 'onPhotosFirst: { startWithPhotos() }' in new
assert 'form.isValid && formContextIsCurrent' in new
assert 'testGetStartedOpensFullNewHomeFormWithoutChoosingAnExistingHome' in ui_path.read_text()
parts = {name: block(home, needle) for name, needle in [
    ('startNewHome', 'private func startNewHome()'),
    ('open', 'private func open(_ feature:'),
    ('go', 'private func go(_ listing:'),
    ('flushQueuedRoute', 'private func flushQueuedRoute()'),
]}
template = r'''
import Foundation
enum Config { static var useLiveBackend = false }
enum WorkspaceContext { static var selectedOrgID: UUID? }
enum LaunchFeatureAvailability { static let canGenerateAerial = false }
enum ProjectFeature: Equatable { case tour, photos, photoStudio, reel, aerial }
struct Listing: Equatable { let id: UUID }
struct ProjectRoute: Equatable { let listing: Listing; let feature: ProjectFeature }
enum ProjectGateSheet: Equatable { case start(ProjectFeature), pick(ProjectFeature), aerial(Listing), reel(Listing) }
@MainActor final class HomeHarness {
    var projects: [Listing] = []
    var gate: ProjectGateSheet?
    var route: ProjectRoute?
    var queued: ProjectRoute?
    var queuedStart: ProjectFeature?
    var showRoute = false
    var showNewListing = false
    var listingsTrips = 0
    func goToListings() { listingsTrips += 1 }
    // __METHODS__
    func mainTap() { startNewHome() }
    func toolTap(_ feature: ProjectFeature) { open(feature) }
    func dismissPicker() { gate = nil; flushQueuedRoute() }
}
@main struct EntryChecks {
    @MainActor static func main() {
        var assertions = 0
        func check(_ value: Bool, _ message: String) {
            guard value else { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
            assertions += 1
        }
        let first = Listing(id: UUID()), second = Listing(id: UUID())
        for homes in [[], [first], [first, second]] {
            Config.useLiveBackend = false; WorkspaceContext.selectedOrgID = nil
            let h = HomeHarness(); h.projects = homes
            h.mainTap()
            check(h.showNewListing, "main action opens full new-home route regardless of existing home count")
            check(h.gate == nil && h.route == nil && !h.showRoute, "main action never chooses an existing home or opens the tool name sheet")
            check(h.projects == homes, "opening full form does not create or mutate a listing")
            h.showNewListing = false // NavigationStack's pop boundary; no creation callback occurred.
            check(h.projects == homes && h.queued == nil && h.queuedStart == nil, "backing out has no queued tool or newly created home")
        }
        Config.useLiveBackend = true; WorkspaceContext.selectedOrgID = nil
        let unready = HomeHarness(); unready.mainTap()
        check(!unready.showNewListing && unready.listingsTrips == 1, "missing live library routes to Listings without opening a form")
        WorkspaceContext.selectedOrgID = UUID()
        let ready = HomeHarness(); ready.mainTap()
        check(ready.showNewListing && ready.listingsTrips == 0, "selected live library opens the full form")
        Config.useLiveBackend = false
        let empty = HomeHarness(); empty.toolTap(.tour)
        check(empty.gate == .start(.tour) && !empty.showNewListing, "tour shortcut retains its name-first entry")
        let single = HomeHarness(); single.projects = [first]; single.toolTap(.photos)
        check(single.route == ProjectRoute(listing: first, feature: .photos) && single.showRoute && !single.showNewListing, "one-home photo shortcut retains exact listing identity")
        let many = HomeHarness(); many.projects = [first, second]; many.toolTap(.tour)
        check(many.gate == .pick(.tour) && !many.showNewListing, "multi-home tour shortcut retains the picker")
        many.dismissPicker()
        check(many.gate == nil && many.route == nil && !many.showRoute, "canceled tool picker does not navigate")
        let chosen = HomeHarness(); chosen.queued = ProjectRoute(listing: second, feature: .photoStudio)
        chosen.dismissPicker()
        check(chosen.route == ProjectRoute(listing: second, feature: .photoStudio) && chosen.queued == nil, "tool choice keeps its identity after sheet dismissal")
        let newTool = HomeHarness(); newTool.queuedStart = .tour; newTool.dismissPicker()
        check(newTool.gate == .start(.tour) && newTool.queuedStart == nil, "tool's new-home shortcut still waits for picker dismissal")
        print("PASSED: \(assertions) actual Home route/state assertions")
    }
}
'''
actual = template.replace('// __METHODS__', '\n'.join(parts.values()))
controls = [
    ('missing-live-library-fence',
     'guard !Config.useLiveBackend || WorkspaceContext.selectedOrgID != nil else {\n            goToListings(); return\n        }', '',
     'missing live library routes to Listings without opening a form'),
    ('main-still-tour-first', 'showNewListing = true', 'open(.tour)',
     'main action opens full new-home route regardless of existing home count'),
    ('lost-tool-identity', 'route = ProjectRoute(listing: listing, feature: feature)',
     'route = ProjectRoute(listing: Listing(id: UUID()), feature: feature)',
     'one-home photo shortcut retains exact listing identity'),
]
receipt = {'passed': False, 'source_sha256': start_hashes,
           'actual_method_sha256': {k: hashlib.sha256(v.encode()).hexdigest() for k, v in parts.items()},
           'runs': [], 'limitations': ['Actual Home state methods execute with closed listing, config and workspace interfaces.',
               'SwiftUI navigation/rendering and camera/photo creation are not executed; separate XCUITest cases are updated but not run here.']}
try:
    for name, old, replacement, expected in [('actual', None, None, None)] + controls:
        text = actual
        if old:
            # The missing-library guard occurs in both main and tool entry; remove ONLY main entry's guard.
            assert old in text, name
            text = text.replace(old, replacement, 1)
        path = out / (name + '.swift'); path.write_text(text)
        binary = out / name
        built = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(path), '-o', str(binary)], capture_output=True, text=True, timeout=90)
        (out / (name + '-compile.log')).write_text(built.stdout + built.stderr)
        assert built.returncode == 0, name + ': compile failure is not an accepted control'
        ran = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
        (out / (name + '.log')).write_text(ran.stdout + ran.stderr)
        correct = ran.returncode == 0 if expected is None else ran.returncode == 1 and ('FAIL: ' + expected) in ran.stderr
        receipt['runs'].append({'name': name, 'exit_code': ran.returncode, 'expected_failure': expected, 'expected_result': correct})
        assert correct, name + ': ' + ran.stdout + ran.stderr
        if expected is None: receipt['assertions'] = int(re.search(r'PASSED: (\d+)', ran.stdout)[1])
        binary.unlink()
    receipt['passed'] = True
finally:
    receipt['end_source_sha256'] = hashes()
    receipt['source_binding_matches'] = start_hashes == receipt['end_source_sha256']
    receipt['passed'] = receipt['passed'] and receipt['source_binding_matches']
    receipt['compiled_negative_controls'] = len(controls)
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
assert receipt['passed']
print(json.dumps({'passed': True, 'assertions': receipt['assertions'], 'compiled_negative_controls': len(controls), 'receipt': str(out / 'receipt.json')}))
