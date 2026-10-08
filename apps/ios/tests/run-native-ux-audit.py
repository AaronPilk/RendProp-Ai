#!/usr/bin/env python3
"""Compile actual native UX bodies with closed UI/network boundaries and semantic faults."""
from pathlib import Path
import argparse, hashlib, json, subprocess, tempfile

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--evidence-dir', type=Path)
args = parser.parse_args()
out = args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-native-ux-audit-'))
out.mkdir(parents=True, exist_ok=True)
names = ['RendpropApp.swift', 'DeepLink/DeepLink.swift', 'Models/Listing.swift', 'Models/ListingClientContact.swift',
         'Models/Money.swift', 'Models/ProductionGuidance.swift', 'Purchases/PaywallHost.swift',
         'Screens/FlythroughDetailView.swift', 'Screens/NewListingView.swift', 'Screens/OnboardingView.swift',
         'Screens/PlayerWebView.swift', 'Screens/ReviewSubmitView.swift', 'Screens/HomeListingsView.swift', 'Screens/CloudMediaView.swift',
         'Networking/LiveAPIClient.swift', 'Networking/WorkspaceSync.swift', 'Team/TeamView.swift',
         'Upload/UploadManager.swift', 'Purchases/PurchaseManager.swift']
paths = [root/'apps/ios/Rendprop'/name for name in names]
paths += [Path(__file__).resolve(), root/'apps/ios/tests/NativeUXAuditTests.swift']
hashes = lambda: {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
start = hashes()
src = {name: path.read_text() for name,path in zip(names,paths)}
def block(source, anchor):
    begin = source.index(anchor); opening = source.index('{', begin); depth = 1; end = opening+1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[begin:end]

# Consumer source binding accompanies executable extracted bodies. The full
# app build and UIKit cases are separate, not implied by these closed doubles.
app, fly, form, wall = [src[n] for n in ['RendpropApp.swift','Screens/FlythroughDetailView.swift','Screens/NewListingView.swift','Purchases/PaywallHost.swift']]
app_routes = block(app, 'struct RendpropApp: App')
assert app.count('demoSection') == 2
assert '.id("\\(workspaceAuth.userID' not in app
assert '.task { await model.load(); Analytics.start' in app
assert 'await model.load()' in block(src['Team/TeamView.swift'], 'private func join()')
assert 'cellularApproved: cellularApproved' in block(app, 'func publishExisting(')
assert 'cellularApproved: cellularApproved' in block(app, 'func publishTour(')
assert 'publishNow(cellularApproved: true)' in block(fly, 'private var publishCard:')
assert 's.listingID == listingID, s.role == role' in block(src['Upload/UploadManager.swift'], 'func upload(fileURL:')
assert 'if entry == .studio, await AIConsent.shared.ensureGranted()' in fly
for anchor in ['private func openCustomEdit(', 'private func aiEdit(', 'private func suggestEdits(', 'private func animate(', 'private func runBatch(']:
    assert 'runPhotoAI {' in block(fly, anchor), anchor
assert 'if RoomCaptureSession.isSupported {' in fly and 'RoomCaptureSession.isSupported && planExists' not in fly
assert 'primaryButton("Start scan", "cube.transparent") { showScanner = true }' in fly
assert 'showRescanConfirm = true' in fly
assert 'Button("Add photos") { showReelPhotos = true }' in block(fly, 'private var photoPickerGrid:')
assert 'refreshedPhotos = EnhancedPhoto.loadAll' in fly
assert 'let chosen = selected.compactMap { id in reelPhotos.first' in fly
assert 'let canPresent = mayPresentIncomingRoutes && scenePhase == .active' in block(app, 'private func drainIncomingRoutes()')
assert 'NativeAccountLaunchAdmission.allowsRoutes(accountReady: accountReady, hasOnboarded: hasOnboarded)' in block(app, 'private var mayPresentIncomingRoutes:')
assert 'accountReady && hasOnboarded' in block(app, 'static func allowsRoutes(')
assert '!NativePresentationAvailability.hasPresentedController' in app
assert 'if accepted { push.clearPendingRoute() }' in block(app, 'private func consumePushRoute()')
assert 'Button("See plans") { finish(showPlans: true) }' in src['Screens/OnboardingView.swift']
assert 'PrimaryButton(title: "Explore the app", systemImage: "arrow.right") { finish(showPlans: false) }' in src['Screens/OnboardingView.swift']
assert 'if entitlements != nil {\n                    PaywallRouter.shared.present' in src['Screens/ReviewSubmitView.swift']
assert '.disabled(locked && entitlements != nil)' not in src['Screens/ReviewSubmitView.swift']
assert fly.count('.paywallHost(managesLifecycle: false)') == 3
assert 'isInactive' in block(src['Screens/HomeListingsView.swift'],'private var filtered:')
assert 'l.cloudArchived = dto.status == "archived"' in src['Networking/LiveAPIClient.swift']
assert '"beds": number(dto.beds.map(Double.init))' in src['Networking/LiveAPIClient.swift']
assert 'current.cloudArchived = receipt.cloudArchived' in src['Models/Listing.swift']
assert 'PurchaseFulfilmentRecovery.message(error)' in block(src['Purchases/PurchaseManager.swift'], 'private func sync(')
assert 'sandbox_testing_required' in block(src['Purchases/PurchaseManager.swift'], 'enum PurchaseFulfilmentRecovery')
floor_view = src['Screens/CloudMediaView.swift']
assert 'mediaContext == context(org: org, listingID: sid)' in block(floor_view, 'private var floorPlanURL:')
assert 'CloudFloorPlanLink.resolve' in block(floor_view, 'private var floorPlanURL:')
assert 'current.serverOrgID == org' in block(floor_view, '@MainActor private func load(')
assert 'mediaContext = context(org: org, listingID: sid)' in block(floor_view, '@MainActor private func load(')

interfaces = '''
import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<T> { var wrappedValue: T; init(wrappedValue: T) { self.wrappedValue = wrappedValue } }
enum Config { static var useLiveBackend = true; static var isOfflineAccountFixture = false }
enum FileStore { static func url(fromRelativePath value: String) -> URL { URL(fileURLWithPath: "/synthetic/" + value) } }
@MainActor final class AuthStore {
 static let shared = AuthStore(); var userID: String?; var syncSessionRevision: UInt64 = 1; var isIdentified = false; var isSignedIn = false
}
enum WorkspaceContext { static var selectedOrgID: UUID? }
@MainActor final class AIConsent {
 static let shared = AIConsent(); var isGranted = false; var wait = false
 var waiter: CheckedContinuation<Bool,Never>?
 func ensureGranted() async -> Bool { if wait { return await withCheckedContinuation { waiter = $0 } }; return isGranted }
 func resume() { wait = false; waiter?.resume(returning: isGranted); waiter = nil }
}
@MainActor final class Connection {
 var calls = 0; func run(_ action: () -> Void) { calls += 1; action() }
}
class UIView { var isHidden = true }
class UILabel { var text: String? }
class UIButton { var isHidden = true }
class UIActivityIndicatorView { var animating = false; func startAnimating() { animating = true }; func stopAnimating() { animating = false } }
class WKWebView {}; class WKNavigation {}
class UIViewController { var presentedViewController: UIViewController?; var children: [UIViewController] = [] }
'''
actual = interfaces + src['DeepLink/DeepLink.swift']
actual += '\n' + block(src['Screens/HomeListingsView.swift'], 'private enum AppGuideTopic:').replace('private enum', 'enum', 1)
actual += '\n@MainActor enum NativePresentationAvailability {\nstatic var hasPresentedController = false\n' + block(app, 'static func hasPresentedController(in controller:') + '\n}\n'
actual += block(wall, 'enum PaywallReason:') + '\n' + block(wall, 'final class PaywallRouter:').replace('final class','@MainActor final class',1)
actual += '\n' + block(app, 'enum NativeAccountLaunchAdmission {') + '\n'
actual += block(app, 'private enum RootSheet:').replace('private ', '', 1) + '\n'
actual += '''enum ScenePhase { case active, inactive, background }
@MainActor final class PushFixture { var showPrePrompt = true }
@MainActor final class RootRouteFixture {
 let analyticsAuth = AuthStore.shared; let push = PushFixture()
 var hasOnboarded = false; var scenePhase = ScenePhase.active
 var incomingLink: DeepLink?; var rootSheet: RootSheet?; var incomingLinkError = false
 var incomingQueue = NativeIncomingQueue()
'''
for anchor in ['private var accountReady:', 'private var mayPresentIncomingRoutes:', '@MainActor private func drainIncomingRoutes()']:
    actual += block(app_routes, anchor).replace('private ', '', 1) + '\n'
actual += '}\n'
actual += '\n@MainActor final class FormFixture {\nvar formOwnerID: String?; var formSessionRevision: UInt64 = 1; var formWorkspaceID: UUID?\nvar createdListing: Listing?; var photosListing: Listing?; var pendingAsset: String?; var text = ""\n'
for anchor in ['private var formContextIsCurrent:', 'private func bindFormContext()', 'private func bindInitialFormContext()']:
    actual += block(form,anchor).replace('private ', '',1)+'\n'
actual += '}\n' + block(fly,'private struct NativeMediaExportContext').replace('private struct','@MainActor struct',1)
actual += '\n@MainActor final class PhotoFixture { let connection = Connection(); var dispatches = 0\n'
actual += block(fly,'private func runPhotoAI(').replace('private ', '',1)+'\n}\n'
actual += '''@MainActor final class PlayerFixture {
 var retry: (() -> Void)?; var preparationTask: Task<Void,Never>?; var timeoutTask: Task<Void,Never>?
 var isMounted = true; var statusOverlay: UIView? = UIView(); var loadingIndicator: UIActivityIndicatorView? = UIActivityIndicatorView()
 var statusLabel: UILabel? = UILabel(); var retryButton: UIButton? = UIButton()
'''
player=src['Screens/PlayerWebView.swift']
for anchor in ['func showLoading()', 'func showFailure()', 'func stop()', 'func webView(_ webView: WKWebView, didFinish']:
    actual += block(player,anchor)+'\n'
actual+='}\n'
actual += '\n' + block(src['Networking/WorkspaceSync.swift'], 'enum CloudSyncError:')
actual += '\n' + block(src['Networking/WorkspaceSync.swift'], 'struct CloudMediaPage:')
actual += '\nenum CloudListingMerge {\n' + block(src['Networking/WorkspaceSync.swift'], 'static func date(') + '\n' + block(src['Networking/WorkspaceSync.swift'], 'static func validateMedia(') + '\n}\n'
actual += block(src['Screens/CloudMediaView.swift'], 'enum CloudFloorPlanLink {')
actual += '\nenum CloudMergeFixture {\n' + block(src['Networking/WorkspaceSync.swift'], 'static func merge(local:') + '\n}\n'
actual += '\nfinal class ListingMappingFixture {\n'
for anchor in ['struct TolerantStringMap:', 'private struct ListingDTO:', 'private static func parseDate(', 'private static func localStatus(', 'private func mapListing(']:
    actual += block(src['Networking/LiveAPIClient.swift'],anchor).replace('private ', '', 1) + '\n'
actual += 'func mapJSON(_ data: Data) throws -> Listing { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return mapListing(try d.decode(ListingDTO.self, from: data)) }\n}\n'

library = [root/'apps/ios/Rendprop'/name for name in ['Models/Listing.swift','Models/ListingClientContact.swift','Models/Money.swift','Models/ProductionGuidance.swift']]
controls = [
 ('drop-account-route-admission', 'let canPresent = mayPresentIncomingRoutes && scenePhase == .active', 'let canPresent = scenePhase == .active', 'required account keeps queued private routes unpresented'),
 ('drop-onboarding-route-admission', 'accountReady && hasOnboarded', 'accountReady', 'business onboarding keeps queued private routes unpresented'),
 ('drop-identified-route-admission', 'offlineFixture || (signedIn && identified && actorID.flatMap(UUID.init(uuidString:)) != nil)', 'offlineFixture || signedIn', 'legacy guest keeps queued private routes unpresented'),
 ('drop-deferred-link', 'guard canPresent else { return nil }', 'guard true else { return nil }', 'capture modal retains link'),
 ('replay-deferred-link', 'return routes.removeFirst()', 'return routes.first', 'lead resumes second'),
 ('child-modal-ignored', 'controller.children.contains { hasPresentedController(in: $0) }', 'false', 'nested capture controller keeps incoming route deferred'),
 ('modal-paywall-swallowed', 'activeHost = hosts.last', 'activeHost = hosts.first', 'modal owns upgrade'),
 ('implicit-workspace-rebind', 'formWorkspaceID == nil { bindFormContext() }', 'true { bindFormContext() }', 'team switch cannot silently rebind draft'),
 ('consent-bypass', 'guard await AIConsent.shared.ensureGranted(), context.isCurrent', 'guard true, context.isCurrent', 'declined consent prevents AI dispatch'),
 ('stale-photo-context', 'context.isCurrent', 'true', 'workspace change while disclosure waits cannot dispatch old photo'),
 ('archive-mapping-lost', 'l.cloudArchived = dto.status == "archived"', 'l.cloudArchived = false', 'live DTO archive maps independently of soldAt'),
 ('archive-merge-lost', 'merged.cloudArchived = fresh.cloudArchived', 'merged.cloudArchived = existing.cloudArchived', 'current cloud archive survives real merge'),
 ('zero-CAS-null', '"beds": number(dto.beds.map(Double.init))', '"beds": number(nil)', 'DTO literal zero remains CAS baseline'),
 ('hide-offline-retry', 'retryButton?.isHidden = false', 'retryButton?.isHidden = true', 'offline exposes retry'),
 ('floorplan-raw-alias', 'return photo.url', 'return URL(string: details?["floorplan_url"] ?? "")', 'attached floorplan uses scoped signed media URL')
]
receipt={'passed':False,'start_source_sha256':start,'runs':[],'limitations':['Closed presentation/network boundaries; actual extracted production bodies and full pure listing models execute.','No camera, provider, StoreKit purchase, production API or Photos write. UIKit integration and physical Release compilation are separate root-owned evidence.']}
for name,old,new,expected in [('actual',None,None,None)]+controls:
    source=actual if old is None else actual.replace(old,new)
    assert old is None or source!=actual,name
    target=out/(name+'.swift');target.write_text(source)
    binary=out/name
    cmd=['xcrun','swiftc','-parse-as-library',*map(str,library),str(target),str(paths[-1]),'-o',str(binary)]
    compile=subprocess.run(cmd,text=True,capture_output=True);(out/(name+'-compile.log')).write_text(compile.stdout+compile.stderr)
    assert compile.returncode==0,(name,compile.stderr[-3000:])
    run=subprocess.run([str(binary)],text=True,capture_output=True);log=run.stdout+run.stderr;(out/(name+'.log')).write_text(log)
    if expected is None: assert run.returncode==0,log[-3000:]
    else: assert run.returncode!=0 and 'FAILED: '+expected in log,(name,log[-3000:])
    receipt['runs'].append({'name':name,'exit':run.returncode,'expected_fault':expected,'generated_sha256':hashlib.sha256(source.encode()).hexdigest(),'log':str(out/(name+'.log'))})
receipt['end_source_sha256']=hashes();assert receipt['end_source_sha256']==start
receipt['passed']=True;(out/'receipt.json').write_text(json.dumps(receipt,indent=2));print(json.dumps({'passed':True,'runs':len(receipt['runs']),'receipt':str(out/'receipt.json')}))
