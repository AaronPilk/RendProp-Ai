#!/usr/bin/env python3
"""Compile actual Home/detail plan and tour branches with/without the lab flag.

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
route_plan = destination[destination.index('            case .floorPlan:'):destination.index('            case .spatial:')]
route_spatial = destination[destination.index('            case .spatial:'):destination.index('            case .tour:')]
grid = block(app, 'private var featureGrid:')
home = grid[grid.index('#if SPATIAL_CAPTURE_LAB'):grid.index('#endif', grid.index('#if SPATIAL_CAPTURE_LAB')) + len('#endif')]
toolbox = block(detail, 'private struct ListingToolboxGrid:')
listing = toolbox[toolbox.index('#if SPATIAL_CAPTURE_LAB'):toolbox.index('#endif', toolbox.index('#if SPATIAL_CAPTURE_LAB')) + len('#endif')]
assert home.count('featureButton(.floorPlan)') == home.count('featureButton(.spatial)') == 1
assert listing.count('FloorPlanView(listing: destinationListing())') == 1
assert listing.count('SpatialTestingHubView(listing: destinationListing())') == 1
assert 'detail.measurementsComingSoon' in toolbox
assert home.count('comingSoonTile("Floor plans & measurements"') == home.count('comingSoonTile("3D tours"') == 1
assert '3dFloorPlan' not in grid and '3D floor plan' not in grid and '3D plans' not in grid
assert 'GuidedPanoramaEntryCard()' not in block(app, 'struct HomeDashboardView:')
assert 'detail.floorPlanComingSoon' not in toolbox
assert 'isSpatialWalkthroughAvailable' not in grid and 'isSpatialWalkthroughAvailable' not in route_spatial
assert 'SpatialTourView(' not in app and 'SpatialTourView(' not in toolbox
assert 'comingSoonTile("Aerial intro"' in grid
assert 'detail.aerialComingSoon' in toolbox
assert 'detail.spatialComingSoon' in toolbox
assert all(part.count('#if SPATIAL_CAPTURE_LAB') == 1 and '#else' in part for part in [route_plan, route_spatial, home, listing])
floor_view = block(detail, 'struct FloorPlanView:')
floor_body = block(floor_view, '    var body: some View {')
assert floor_body.index('if RoomCaptureSession.isSupported') < floor_body.index('                measurementsSection') < floor_body.index('Label("Upload an existing plan"')
assert '.navigationTitle("Floor plans & measurements")' in floor_body
assert 'Phone scanning needs LiDAR' in floor_body
baseline = subprocess.check_output(['git', 'show', '8b1f090cb9edc7167841b2179c8a47955aecb63f:apps/ios/Rendprop/Screens/FlythroughDetailView.swift'], cwd=ROOT).decode()
baseline_floor = block(baseline, 'struct FloorPlanView:')
preserved = {}
for anchor in ['private func existingUpload()', 'private func refreshState()', 'private func handleImport(',
               '@ViewBuilder private var uploadSection:', 'private var measurementsSection:',
               'struct RoomScanView:', 'final class RoomScanController:', 'struct FloorPlan2DView:']:
    expected = block(baseline_floor if anchor in baseline_floor else baseline, anchor)
    actual = block(floor_view if anchor in floor_view else detail, anchor)
    assert actual == expected, 'Existing scan/measurement function changed: ' + anchor
    preserved[anchor] = hashlib.sha256(actual.encode()).hexdigest()
baseline_body = block(baseline_floor, '    var body: some View {')
callbacks = floor_body[floor_body.index('        .askAI('):]
assert callbacks == baseline_body[baseline_body.index('        .askAI('):], 'Saved scan, 2D/USDZ, import, rescan or presentation callback changed'
preserved['FloorPlanView presentation/scan/import callbacks'] = hashlib.sha256(callbacks.encode()).hexdigest()
fragments = {'routePlan': route_plan, 'routeSpatial': route_spatial, 'home': home, 'listing': listing,
             'open': block(app, 'private func open(_ feature:'),
             'go': block(app, 'private func go(_ listing:'),
             'featureButton': block(app, 'private func featureButton(').replace('-> some View', '-> TileEvidence')}

interfaces = r'''
import Foundation
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}
enum ProjectFeature: String { case tour, spatial, photos, photoStudio, reel, floorPlan, aerial
    var actionTitle: String { self == .floorPlan ? "Floor plans & measurements" : "3D tours" }
    var promise: String { "Captured rooms and plans" }
    var systemImage: String { "ruler" }
    var gradient: String { "plan" }
    var usesAI: Bool { false }
}
struct Listing { let id: UUID; var isSample = false }
struct ProjectRoute { let listing: Listing; let feature: ProjectFeature }
enum ProjectGateSheet { case start(ProjectFeature), pick(ProjectFeature), aerial(Listing), reel(Listing) }
enum LaunchFeatureAvailability { static let canGenerateAerial = false }
enum Config { static var useLiveBackend = false }
enum WorkspaceContext { static var selectedOrgID: UUID? }
enum ChildBehavior { case combine }
struct ScalePressStyle {}
enum RPGradient { static let plan = "plan"; static let drone = "drone" }
struct RouteEvidence { let kind: String; let id: UUID }
var floorPlanCreations = 0
var spatialHubCreations = 0
func FloorPlanView(listing: Listing) -> RouteEvidence {
    floorPlanCreations += 1
    return RouteEvidence(kind: "floor-plan", id: listing.id)
}
func SpatialTestingHubView(listing: Listing) -> RouteEvidence {
    spatialHubCreations += 1
    return RouteEvidence(kind: "spatial-hub", id: listing.id)
}
func FlythroughDetailView(listing: Listing) -> RouteEvidence {
    RouteEvidence(kind: "listing", id: listing.id)
}
func AnyView(_ value: RouteEvidence) -> RouteEvidence { value }
func Text(_ value: String) -> String { value }
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
@resultBuilder enum TileListBuilder {
    static func buildBlock(_ values: TileEvidence...) -> [TileEvidence] { values }
    static func buildEither(first: [TileEvidence]) -> [TileEvidence] { first }
    static func buildEither(second: [TileEvidence]) -> [TileEvidence] { second }
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
    func featureTile(_ title: String, _ promise: String, _ icon: String, _ gradient: String, ai: Bool) -> TileEvidence {
        TileEvidence(title: title)
    }
'''
tests = r'''
@main struct FloorPlanBoundaryTests {
    @MainActor static func main() {
        let home = HomeFixture()
        let listing = Listing(id: UUID())
        let direct = home.resolve(ProjectRoute(listing: listing, feature: .floorPlan))
        let directTour = home.resolve(ProjectRoute(listing: listing, feature: .spatial))
        let tiles = home.toolTiles()
        let ordinary = ListingFixture(listing: listing)
        let detailTiles = ordinary.toolTiles()
        require(tiles.count == 2 && detailTiles.count == 2, "Home and listing each expose exactly one plan entry and one tour entry")
        require(tiles[0].title == "Floor plans & measurements" && tiles[1].title == "3D tours" && detailTiles[0].title == tiles[0].title && detailTiles[1].title == tiles[1].title,
                "Home and listing use the same two spatial names")
        let shortcut = tiles[0], detail = detailTiles[0]
        let tourShortcut = tiles[1], tourDetail = detailTiles[1]
        require(direct.id == listing.id, "the actual route retains its selected listing")
        require(directTour.id == listing.id, "the actual hub route retains its selected listing")
#if SPATIAL_CAPTURE_LAB
        require(direct.kind == "floor-plan", "lab routes reach existing RoomPlan view")
        require(directTour.kind == "spatial-hub", "lab local hub remains available without cloud capability")
        require(shortcut.kind == "button" && shortcut.identifier == "home.feature.floorPlan", "lab Home exposes the scan shortcut")
        require(tourShortcut.kind == "button" && tourShortcut.identifier == "home.feature.spatial", "lab Home exposes the local tour hub")
        require(detail.kind == "link" && detail.identifier == "detail.floorPlanLab", "lab listing exposes the scan link")
        require(tourDetail.kind == "link" && tourDetail.identifier == "detail.spatialLab", "lab listing exposes the local tour hub")
        let beforeTap = floorPlanCreations
        require(beforeTap == 1 && spatialHubCreations == 1, "listing link construction defers scanner and hub destinations")
        detail.tap()
        tourDetail.tap()
        require(floorPlanCreations == beforeTap + 1, "real-listing tap reaches RoomPlan")
        require(spatialHubCreations == 2, "real-listing tap reaches local tour hub")
        let samples = ListingFixture(listing: Listing(id: UUID(), isSample: true)).toolTiles()
        let sample = samples[0], sampleTour = samples[1]
        sample.tap()
        sampleTour.tap()
        require(sample.disabled && floorPlanCreations == beforeTap + 1, "sample listings cannot open a floor-plan scan")
        require(sampleTour.disabled && spatialHubCreations == 2, "sample listings cannot open a room-tour hub")
        for (index, feature) in [ProjectFeature.floorPlan, .spatial].enumerated() {
            let flow = HomeFixture()
            flow.toolTiles()[index].tap()
            if case .start(let pending) = flow.gate { require(pending == feature, "empty Home uses chosen feature") }
            else { require(false, "no-listing shortcut requests a listing before scan") }
            flow.gate = nil; flow.projects = [listing]
            flow.toolTiles()[index].tap()
            require(flow.route?.listing.id == listing.id && flow.route?.feature == feature && flow.showRoute,
                    "one-listing shortcut preserves selected listing")
            flow.route = nil; flow.showRoute = false; flow.projects.append(Listing(id: UUID()))
            flow.toolTiles()[index].tap()
            if case .pick(let pending) = flow.gate { require(pending == feature, "picker uses chosen feature") }
            else { require(false, "multiple-listing shortcut opens the existing picker") }
            require(flow.route == nil && !flow.showRoute, "picker does not open a scan before selection")
        }
        print("PASS: lab RoomPlan and local hub routes retain listing identity; sample links disabled; both Home shortcuts follow zero/one/many gate")
#else
        require(direct.kind == "listing", "public floor-plan route stays inert")
        require(directTour.kind == "listing", "public tour hub route stays inert")
        require(shortcut.kind == "inert" && shortcut.identifier == "home.comingSoon.floorPlan", "public Home floor-plan tile stays inert")
        require(tourShortcut.kind == "inert" && tourShortcut.identifier == "home.comingSoon.spatial", "public Home tour tile stays inert")
        require(detail.kind == "inert" && detail.identifier == "detail.measurementsComingSoon", "public listing floor-plan tile stays inert")
        require(tourDetail.kind == "inert" && tourDetail.identifier == "detail.spatialComingSoon", "public listing tour tile stays inert")
        for tile in tiles + detailTiles { tile.tap() }
        require(floorPlanCreations == 0 && spatialHubCreations == 0 && home.route == nil && home.gate == nil && !home.showRoute,
                "public taps perform no spatial construction or navigation")
        print("PASS: public routes and both unified entries stay inert; no RoomPlan or local hub is constructed")
#endif
        Config.useLiveBackend = true
        WorkspaceContext.selectedOrgID = nil
        let unselected = HomeFixture(); unselected.projects = [listing]
        unselected.toolTiles()[0].tap()
        unselected.toolTiles()[1].tap()
#if SPATIAL_CAPTURE_LAB
        require(unselected.listingsTrips == 2 && unselected.route == nil && unselected.gate == nil,
                "live shortcut requires the existing account listing context")
#else
        require(unselected.listingsTrips == 0, "public inert tile never starts account navigation")
#endif
    }
}
'''


def composition(parts):
    return interfaces + parts['open'] + '\n' + parts['go'] + '\n' + parts['featureButton'] + '\n' + '''
    @TileListBuilder func toolTiles() -> [TileEvidence] {
''' + parts['home'] + '''
    }
    @BoundaryBuilder func resolve(_ route: ProjectRoute) -> RouteEvidence {
        switch route.feature {
''' + parts['routePlan'] + parts['routeSpatial'] + '''
        default: FlythroughDetailView(listing: route.listing)
        }
    }
}
struct ListingFixture {
    let listing: Listing
    var sample: Bool { listing.isSample }
    var createFirst: String { "Create a home first" }
    func destinationListing() -> Listing { listing }
    @TileListBuilder func toolTiles() -> [TileEvidence] {
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
for name, expected in [('routePlan', 'public floor-plan route stays inert'),
                       ('routeSpatial', 'public tour hub route stays inert'),
                       ('home', 'public Home floor-plan tile stays inert'),
                       ('listing', 'public listing floor-plan tile stays inert')]:
    altered = dict(fragments)
    altered[name] = altered[name].replace('#if SPATIAL_CAPTURE_LAB', '#if true', 1)
    runs.append(run('unfenced-' + name, altered, False, expected))
altered = dict(fragments)
assert altered['listing'].count('disabled: sample,') == 2
altered['listing'] = altered['listing'].replace('disabled: sample,', 'disabled: false,', 1)
runs.append(run('enabled-sample', altered, True, 'sample listings cannot open a floor-plan scan'))
altered = dict(fragments)
first = altered['listing'].index('disabled: sample,')
second = altered['listing'].index('disabled: sample,', first + len('disabled: sample,'))
altered['listing'] = altered['listing'][:second] + altered['listing'][second:].replace('disabled: sample,', 'disabled: false,', 1)
runs.append(run('enabled-tour-sample', altered, True, 'sample listings cannot open a room-tour hub'))
after = source_hashes()
assert before == after, 'Source changed during boundary verification'
receipt = {'passed': True, 'sourceHashes': before, 'sourceHashesAtEnd': after,
           'sourceBoundAtEnd': True, 'actualFragmentHashes': {name: hashlib.sha256(body.encode()).hexdigest() for name, body in fragments.items()},
           'runs': runs, 'compiledNegativeControls': 6, 'preservedRoomPlanBodies': preserved,
           'scope': 'Actual Home plan/hub card/route/featureButton/open/go and actual listing conditional branches. Navigation/view interfaces are closed. Normal public cards/routes remain inert; local hub does not depend on cloud capability. No cloud consumer is executed here. Existing RoomPlan saved geometry, rescan/import/presentation/export and manual-measurement bodies are exact baseline-hash matched.',
           'cameraCalls': 0, 'networkCalls': 0, 'AppleCalls': 0, 'UIExecutions': 0}
(out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps({'passed': True, 'twoBuildVariants': True, 'compiledNegativeControls': 6, 'receipt': str(out / 'receipt.json')}))
