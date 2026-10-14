#!/usr/bin/env python3
"""Compile actual Home/detail RoomPlan branches with and without the lab flag.

Only navigation/view interfaces are closed. No UI, camera, account, upload,
provider, filesystem scan or Apple request occurs.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--evidence-dir', type=Path)
args = parser.parse_args()
out = (args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-floor-plan-boundary-'))).resolve()
out.mkdir(parents=True, exist_ok=True)
paths = [ROOT / 'apps/ios/Rendprop/RendpropApp.swift',
         ROOT / 'apps/ios/Rendprop/Screens/FlythroughDetailView.swift',
         Path(__file__).resolve()]
source_hashes = lambda: {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
before = source_hashes()
app, detail = (p.read_text() for p in paths[:2])


def block(source, anchor):
    start = source.index(anchor)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


destination = block(app, '@ViewBuilder private var routeDestination:')
route = destination[destination.index('            case .floorPlan:'):destination.index('            case .spatial:')]
grid = block(app, 'private var featureGrid:')
home = grid[grid.index('#if SPATIAL_CAPTURE_LAB'):grid.index('            if !model.isSpatialWalkthroughAvailable')]
toolbox = block(detail, 'private struct ListingToolboxGrid:')
listing = toolbox[toolbox.index('#if SPATIAL_CAPTURE_LAB'):toolbox.index('            ListingToolCard(title: "3D walkthrough"')]
assert home.count('Button { open(.floorPlan) }') == 1
assert listing.count('FloorPlanView(listing: destinationListing())') == 1
assert 'detail.measurementsComingSoon' in toolbox
assert 'comingSoonTile("Measurements"' in grid
assert 'comingSoonTile("Aerial intro"' in grid
assert 'detail.aerialComingSoon' in toolbox
assert 'if model.isSpatialWalkthroughAvailable' in destination
assert 'detail.spatialComingSoon' in toolbox and 'SpatialTourView(' not in toolbox
assert route.count('#if SPATIAL_CAPTURE_LAB') == home.count('#if SPATIAL_CAPTURE_LAB') == listing.count('#if SPATIAL_CAPTURE_LAB') == 1
assert '#else' in route and '#else' in home and '#else' in listing
fragments = {'route': route, 'home': home, 'listing': listing,
             'open': block(app, 'private func open(_ feature:'),
             'go': block(app, 'private func go(_ listing:')}

interfaces = r'''
import Foundation
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
enum ProjectFeature: Equatable { case tour, spatial, photos, photoStudio, reel, floorPlan, aerial }
struct Listing { let id: UUID; var isSample = false }
struct ProjectRoute { let listing: Listing; let feature: ProjectFeature }
enum ProjectGateSheet { case start(ProjectFeature), pick(ProjectFeature), aerial(Listing), reel(Listing) }
enum LaunchFeatureAvailability { static let canGenerateAerial = false }
enum Config { static var useLiveBackend = false }
enum WorkspaceContext { static var selectedOrgID: UUID? }
enum ChildBehavior { case combine }
struct ScalePressStyle {}
enum RPGradient { static let plan = "plan" }
struct RouteEvidence { let kind: String; let id: UUID }
var floorPlanCreations = 0
func FloorPlanView(listing: Listing) -> RouteEvidence {
    floorPlanCreations += 1
    return RouteEvidence(kind: "floor-plan", id: listing.id)
}
func FlythroughDetailView(listing: Listing) -> RouteEvidence {
    RouteEvidence(kind: "listing", id: listing.id)
}
func AnyView(_ value: RouteEvidence) -> RouteEvidence { value }
struct TileEvidence {
    var title: String
    var kind = "inert"
    var disabled = false
    var identifier = ""
    var action: (() -> Void)?
    var destination: (() -> RouteEvidence)?
    func buttonStyle(_ value: ScalePressStyle) -> Self { self }
    func accessibilityLabel(_ value: String) -> Self { self }
    func accessibilityElement(children: ChildBehavior) -> Self { self }
    func accessibilityIdentifier(_ value: String) -> Self { var v = self; v.identifier = value; return v }
    func tap() { if !disabled { action?(); _ = destination?() } }
}
func HomeShortcutCard(title: String, subtitle: String, icon: String, assetName: String) -> TileEvidence {
    TileEvidence(title: title)
}
func Button(@_implicitSelfCapture action: @escaping () -> Void, label: () -> TileEvidence) -> TileEvidence {
    var v = label(); v.kind = "button"; v.action = action; return v
}
func ListingToolCard(title: String, sub: String, icon: String, gradient: String, dimmed: Bool) -> TileEvidence {
    TileEvidence(title: title)
}
func ListingToolLinkTile(card: TileEvidence, disabled: Bool, accessibilityID: String,
                         destination: @escaping () -> RouteEvidence) -> TileEvidence {
    var v = card; v.kind = "link"; v.disabled = disabled; v.identifier = accessibilityID; v.destination = destination; return v
}
@resultBuilder enum BoundaryBuilder {
    static func buildBlock<T>(_ value: T) -> T { value }
    static func buildEither<T>(first: T) -> T { first }
    static func buildEither<T>(second: T) -> T { second }
}
@MainActor final class HomeFixture {
    var projects: [Listing] = []
    var gate: ProjectGateSheet?
    var route: ProjectRoute?
    var showRoute = false
    var listingsTrips = 0
    func goToListings() { listingsTrips += 1 }
    func comingSoonTile(_ title: String, _ sub: String, _ icon: String, id: String) -> TileEvidence {
        TileEvidence(title: title, identifier: "home.comingSoon." + id)
    }
'''
tests = r'''
@main struct FloorPlanBoundaryTests {
    @MainActor static func main() {
        let home = HomeFixture()
        let listing = Listing(id: UUID())
        let direct = home.resolve(ProjectRoute(listing: listing, feature: .floorPlan))
        let shortcut = home.planTile()
        let ordinary = ListingFixture(listing: listing)
        let detail = ordinary.planTile()
        require(direct.id == listing.id, "the actual route retains its selected listing")
#if SPATIAL_CAPTURE_LAB
        require(direct.kind == "floor-plan", "lab routes reach existing RoomPlan view")
        require(shortcut.kind == "button" && shortcut.identifier == "home.feature.3dFloorPlanLab", "lab Home exposes the scan shortcut")
        require(detail.kind == "link" && detail.identifier == "detail.floorPlanLab", "lab listing exposes the scan link")
        let beforeTap = floorPlanCreations
        require(beforeTap == 1, "listing link construction defers scanner destination")
        detail.tap()
        require(floorPlanCreations == beforeTap + 1, "real-listing tap reaches RoomPlan")
        let sample = ListingFixture(listing: Listing(id: UUID(), isSample: true)).planTile()
        sample.tap()
        require(sample.disabled && floorPlanCreations == beforeTap + 1, "sample listings cannot open a floor-plan scan")
        shortcut.tap()
        if case .start(.floorPlan) = home.gate {} else { require(false, "no-listing shortcut requests a listing before scan") }
        home.gate = nil; home.projects = [listing]
        home.planTile().tap()
        require(home.route?.listing.id == listing.id && home.route?.feature == .floorPlan && home.showRoute,
                "one-listing shortcut preserves selected listing")
        home.route = nil; home.showRoute = false; home.projects.append(Listing(id: UUID()))
        home.planTile().tap()
        if case .pick(.floorPlan) = home.gate {} else { require(false, "multiple-listing shortcut opens the existing picker") }
        require(home.route == nil && !home.showRoute, "picker does not open a scan before selection")
        print("PASS: lab RoomPlan routes retain listing identity; sample links stay disabled; Home follows zero/one/many listing gate")
#else
        require(direct.kind == "listing", "public floor-plan route stays inert")
        require(shortcut.kind == "inert" && shortcut.identifier == "home.comingSoon.3dFloorPlan", "public Home floor-plan tile stays inert")
        require(detail.kind == "inert" && detail.identifier == "detail.floorPlanComingSoon", "public listing floor-plan tile stays inert")
        shortcut.tap(); detail.tap()
        require(floorPlanCreations == 0 && home.route == nil && home.gate == nil && !home.showRoute,
                "public taps perform no RoomPlan construction or navigation")
        print("PASS: public route and both cards remain inert; no RoomPlan view is constructed")
#endif
        Config.useLiveBackend = true
        WorkspaceContext.selectedOrgID = nil
        let unselected = HomeFixture(); unselected.projects = [listing]
        unselected.planTile().tap()
#if SPATIAL_CAPTURE_LAB
        require(unselected.listingsTrips == 1 && unselected.route == nil && unselected.gate == nil,
                "live shortcut requires the existing account listing context")
#else
        require(unselected.listingsTrips == 0, "public inert tile never starts account navigation")
#endif
    }
}
'''


def composition(parts):
    return interfaces + parts['open'] + '\n' + parts['go'] + '\n' + '''
    @BoundaryBuilder func planTile() -> TileEvidence {
''' + parts['home'] + '''
    }
    @BoundaryBuilder func resolve(_ route: ProjectRoute) -> RouteEvidence {
        switch route.feature {
''' + parts['route'] + '''
        default: FlythroughDetailView(listing: route.listing)
        }
    }
}
struct ListingFixture {
    let listing: Listing
    var sample: Bool { listing.isSample }
    var createFirst: String { "Create a home first" }
    func destinationListing() -> Listing { listing }
    @BoundaryBuilder func planTile() -> TileEvidence {
''' + parts['listing'] + '\n    }\n}\n' + tests


def run(label, parts, lab, expected=None):
    source = out / (label + '.swift')
    source.write_text(composition(parts))
    binary = out / label
    command = ['xcrun', 'swiftc', '-parse-as-library'] + (['-D', 'SPATIAL_CAPTURE_LAB'] if lab else []) + [str(source), '-o', str(binary)]
    compiled = subprocess.run(command, capture_output=True, text=True)
    (out / (label + '-compile.log')).write_text(compiled.stdout + compiled.stderr)
    assert compiled.returncode == 0, (label, compiled.stderr)
    result = subprocess.run([str(binary)], capture_output=True, text=True)
    (out / (label + '.log')).write_text(result.stdout + result.stderr)
    assert result.returncode == (1 if expected else 0), (label, result.stdout, result.stderr)
    if expected:
        assert 'FAIL: ' + expected in result.stderr, (label, result.stderr)
    return {'name': label, 'compileExit': compiled.returncode, 'exit': result.returncode,
            'labFlag': lab, 'expectedRejection': expected,
            'compiledSourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest()}


runs = [run('regular', fragments, False), run('lab', fragments, True)]
for name, expected in [('route', 'public floor-plan route stays inert'),
                       ('home', 'public Home floor-plan tile stays inert'),
                       ('listing', 'public listing floor-plan tile stays inert')]:
    altered = dict(fragments)
    altered[name] = altered[name].replace('#if SPATIAL_CAPTURE_LAB', '#if true', 1)
    runs.append(run('unfenced-' + name, altered, False, expected))
altered = dict(fragments)
assert altered['listing'].count('disabled: sample,') == 1
altered['listing'] = altered['listing'].replace('disabled: sample,', 'disabled: false,', 1)
runs.append(run('enabled-sample', altered, True, 'sample listings cannot open a floor-plan scan'))
after = source_hashes()
assert before == after, 'Source changed during boundary verification'
receipt = {'passed': True, 'sourceHashes': before, 'sourceHashesAtEnd': after,
           'sourceBoundAtEnd': True, 'actualFragmentHashes': {name: hashlib.sha256(body.encode()).hexdigest() for name, body in fragments.items()},
           'runs': runs, 'compiledNegativeControls': 4,
           'scope': 'Actual Home card/route/open/go and actual listing card conditional branches. Navigation/view interfaces are closed. Normal public cards remain inert; existing capability-gated walkthrough, Measurements and Aerial placeholders are source checked.',
           'cameraCalls': 0, 'networkCalls': 0, 'AppleCalls': 0, 'UIExecutions': 0}
(out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps({'passed': True, 'twoBuildVariants': True, 'compiledNegativeControls': 4, 'receipt': str(out / 'receipt.json')}))
