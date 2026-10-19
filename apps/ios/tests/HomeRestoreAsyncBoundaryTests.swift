import Foundation

enum CloudSyncError: Error, Equatable { case identityChanged, invalidResponse }
enum APIError: Error { case decoding, server(Int); var status: Int? { if case .server(let value) = self { return value }; return nil } }
enum Config { static var useLiveBackend = true; static var isUITesting = false }
final class AuthStore {
    static let shared = AuthStore()
    var userID: String? = "fixture-owner"
    @MainActor var syncSessionRevision: UInt64 = 1
    var isIdentified = true
}
enum WorkspaceContext { static var selectedOrgID: UUID? = UUID() }
struct RestoredListing: Sendable, Hashable {
    let id: UUID; let orgID: UUID; let address: String?
    let republishedRenders: Int; let cancelledClientDeliveries: Int
}
protocol RestoreAPI { func restoreListing(serverID: UUID) async throws -> RestoredListing }
@MainActor final class ControlledRestoreAPI: RestoreAPI {
    var gate: Gate?
    var error: Error?
    let result: RestoredListing
    init(result: RestoredListing) { self.result = result }
    func restoreListing(serverID: UUID) async throws -> RestoredListing {
        if let gate { await gate.wait() }
        if let error { throw error }
        return result
    }
}
@MainActor final class Gate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { let current = continuation; continuation = nil; current?.resume() }
}
final class LiveRestoreHarness: RestoreAPI {
    var tokenGate: Gate?; var responseGate: Gate?
    var calls = 0; var dispatches = 0; var sent: URLRequest?
    var body = Data()
    func url(_ segments: [String]) -> URL { URL(string: "https://example.invalid/" + segments.joined(separator: "/"))! }
    func makeRequest(url: URL, method: String, json: [String: Any]) -> URLRequest {
        var value = URLRequest(url: url); value.httpMethod = method; return value
    }
    @MainActor func execute(_ request: URLRequest, beforeSend: (@MainActor () throws -> Void)? = nil) async throws -> Data {
        calls += 1
        if let tokenGate { await tokenGate.wait() }
        try beforeSend?()
        dispatches += 1; sent = request
        if let responseGate { await responseGate.wait() }
        return body
    }
    func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
    // __LIVE_METHOD__
    // __RESTORE_DTO__
}
@MainActor final class ModelRestoreHarness {
    let api: any RestoreAPI
    var cloudRefreshTask: Task<Void, Never>?
    var cloudRefreshOperation: UUID?
    var refreshCalls = 0, joinedReads = 0
    var refreshOwners: [String?] = []
    var refreshGate: Gate?
    init(api: any RestoreAPI) { self.api = api }
    func refreshCloudWorkspace() async {
        if let old = cloudRefreshTask { joinedReads += 1; await old.value; return }
        refreshCalls += 1; refreshOwners.append(AuthStore.shared.userID)
        if let refreshGate { await refreshGate.wait() }
    }
    // __MODEL_METHOD__
}

struct CLLocationCoordinate2D { var latitude: Double; var longitude: Double }
struct CLLocation { var coordinate = CLLocationCoordinate2D(latitude: 35.123456, longitude: -80.987654) }
struct CLPlacemark { var address: String }
@MainActor final class OneShotLocation {
    var pending: ((CLLocation?) -> Void)?; var cancels = 0
    func request(_ result: @escaping (CLLocation?) -> Void) { pending = result }
    func cancel() { pending = nil; cancels += 1 }
}
@MainActor final class CLGeocoder {
    static var created: [CLGeocoder] = []
    var pending: (([CLPlacemark]?, Error?) -> Void)?; var cancels = 0
    init() { Self.created.append(self) }
    func reverseGeocodeLocation(_ location: CLLocation, completionHandler: @escaping ([CLPlacemark]?, Error?) -> Void) { pending = completionHandler }
    func cancelGeocode() { cancels += 1 }
}
@MainActor final class AddressCompleter {
    var accepts = 0
    func accept() { accepts += 1 }
    func focus(on coordinate: CLLocationCoordinate2D) {}
    static func formatted(_ placemark: CLPlacemark) -> String { placemark.address }
}
func coarseCoordinate(_ value: Double) -> Double { (value * 1_000).rounded() / 1_000 }
struct FixtureForm {
    var address = "typed old address", unit = "12"
    mutating func setSuggestedAddress(_ value: String) { address = value }
}
@propertyWrapper struct FixtureState<Value> {
    final class Storage { var value: Value; init(_ value: Value) { self.value = value } }
    private let storage: Storage
    init(wrappedValue: Value) { storage = Storage(wrappedValue) }
    var wrappedValue: Value { get { storage.value } nonmutating set { storage.value = newValue } }
}
struct TrashedListing { let id: UUID; let address: String }
@MainActor final class CallerWorkspace {
    struct Selection { let id: UUID }
    var selected: Selection? { WorkspaceContext.selectedOrgID.map { .init(id: $0) } }
}
enum AppModel { static func userMessage(for error: Error) -> String { String(describing: error) } }
@MainActor enum Haptics { static var successes = 0; static func selection() {}; static func success() { successes += 1 } }
@MainActor struct RestoreCallerHarness {
    let model: any RestoreAPI
    let workspace = CallerWorkspace(), auth = AuthStore.shared
    @FixtureState var restoring: UUID?
    @FixtureState var restoreError: String?
    @FixtureState var restored: RestoredListing?
    @FixtureState var rows: [TrashedListing] = []
    func begin(_ row: TrashedListing) { restore(row) }
    // __CALLER_RESTORE__
}
@MainActor struct HomeLocationHarness {
    @FixtureState var name = "typed old address"
    let owner = AuthStore.shared.userID, revision = AuthStore.shared.syncSessionRevision, org = WorkspaceContext.selectedOrgID
    let locator = OneShotLocation(), completer = AddressCompleter()
    @FixtureState var locating = false
    @FixtureState var locationNote: String?
    @FixtureState var locationRequestID: UUID?
    @FixtureState var locationGeocoder: CLGeocoder?
    func begin() { useCurrentLocation() }
    func cancel() { cancelCurrentLocation() }
    // __HOME_CONTEXT__
    // __HOME_LOCATION__
    // __HOME_CANCEL__
}
@MainActor struct ListingLocationHarness {
    @FixtureState var form = FixtureForm()
    let formOwnerID = AuthStore.shared.userID, formSessionRevision = AuthStore.shared.syncSessionRevision, formWorkspaceID = WorkspaceContext.selectedOrgID
    let locator = OneShotLocation()
    @FixtureState var locating = false
    @FixtureState var pendingCoord: CLLocationCoordinate2D?
    @FixtureState var pendingCoordAddress: String?
    @FixtureState var locationRequestID: UUID?
    @FixtureState var locationGeocoder: CLGeocoder?
    func begin() { useCurrentLocation() }
    func cancel() { cancelCurrentLocation() }
    static func formatAddress(_ placemark: CLPlacemark) -> String { placemark.address }
    // __LISTING_CONTEXT__
    // __LISTING_LOCATION__
    // __LISTING_APPLY_LOCATION__
    // __LISTING_CANCEL__
}

@main struct HomeRestoreAsyncBoundaryTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); checks += 1
        }
        func settle(_ predicate: () -> Bool) async {
            for _ in 0..<2_000 { if predicate() { return }; await Task.yield() }
            precondition(predicate(), "controlled async boundary did not settle")
        }
        func reset() {
            AuthStore.shared.userID = "fixture-owner"; AuthStore.shared.syncSessionRevision = 1
            AuthStore.shared.isIdentified = true; WorkspaceContext.selectedOrgID = UUID()
            Config.useLiveBackend = true; CLGeocoder.created = []
            Haptics.successes = 0
        }
        let target = UUID(), storedOrg = UUID()
        func live(ok: Bool = true, id: UUID? = nil) throws -> LiveRestoreHarness {
            let client = LiveRestoreHarness()
            client.body = try JSONSerialization.data(withJSONObject: ["ok": ok, "id": (id ?? target).uuidString,
                "org_id": storedOrg.uuidString, "address": "100 Synthetic Restore Lane", "republished_renders": 2,
                "cancelled_client_deliveries": 1])
            return client
        }
        func assertIdentityFailure(_ operation: () async throws -> Void, _ message: String) async {
            do { try await operation(); check(false, message) }
            catch { check(error as? CloudSyncError == .identityChanged, message) }
        }
        reset()
        let good = try live(), selected = WorkspaceContext.selectedOrgID!
        let result = try await good.restoreListing(serverID: target)
        check(result.id == target, "restore preserves submitted listing identity")
        check(result.orgID == storedOrg && storedOrg != selected, "delegated restore accepts a distinct storage org")
        check(result.republishedRenders == 2 && result.cancelledClientDeliveries == 1, "restore retains server confirmation details")
        check(good.sent?.value(forHTTPHeaderField: "X-Org-Id") == selected.uuidString.lowercased(), "restore sends its captured library header")
        check(good.sent?.httpMethod == "POST" && good.sent?.url?.path.hasSuffix(target.uuidString + "/restore") == true, "restore submits the requested route")

        reset(); WorkspaceContext.selectedOrgID = nil
        let missing = try live()
        await assertIdentityFailure({ _ = try await missing.restoreListing(serverID: target) }, "missing library refuses restore")
        check(missing.dispatches == 0 && missing.calls == 0, "missing library cannot dispatch")

        for mutation in 0..<3 {
            reset(); let client = try live(); let gate = Gate(); client.tokenGate = gate
            var failed = false
            let task = Task { do { _ = try await client.restoreListing(serverID: target) }
                catch { failed = error as? CloudSyncError == .identityChanged } }
            await settle { gate.entered }
            if mutation == 0 { WorkspaceContext.selectedOrgID = UUID() }
            else if mutation == 1 { AuthStore.shared.userID = "different-owner" }
            else { AuthStore.shared.syncSessionRevision += 1 }
            gate.release(); await task.value
            check(failed, "changed request context is refused")
            check(client.dispatches == 0, "changed request context cannot dispatch restore")
        }
        reset(); let late = try live(); let lateGate = Gate(); late.responseGate = lateGate
        var lateFailed = false
        let lateTask = Task { do { _ = try await late.restoreListing(serverID: target) }
            catch { lateFailed = error as? CloudSyncError == .identityChanged } }
        await settle { lateGate.entered }; WorkspaceContext.selectedOrgID = UUID()
        lateGate.release(); await lateTask.value
        check(lateFailed && late.dispatches == 1, "late restore reply cannot escape into another library")
        for client in [try live(ok: false), try live(id: UUID())] {
            reset()
            do { _ = try await client.restoreListing(serverID: target); check(false, "invalid restore reply is refused") }
            catch { check(error is APIError, "invalid restore reply is refused") }
        }

        reset(); let immediate = try live(); let model = ModelRestoreHarness(api: immediate); let readGate = Gate()
        model.refreshGate = readGate
        let restored = try await model.restoreListing(serverID: target)
        check(restored.id == target, "model restore confirms before library refresh finishes")
        await settle { readGate.entered }
        check(model.refreshCalls == 1, "successful restore requests a library snapshot")
        readGate.release()

        reset(); let prior = ModelRestoreHarness(api: try live()); let oldGate = Gate()
        let oldTask = Task { await oldGate.wait() }
        prior.cloudRefreshTask = oldTask; prior.cloudRefreshOperation = UUID()
        await settle { oldGate.entered }
        _ = try await prior.restoreListing(serverID: target)
        for _ in 0..<10 { await Task.yield() }
        check(prior.refreshCalls == 0, "restore returns while the previous read is still pending")
        oldGate.release(); await oldTask.value
        await settle { prior.refreshCalls > 0 || prior.joinedReads > 0 }
        check(prior.refreshCalls == 1 && prior.joinedReads == 0, "restore refresh must fetch after the pre-restore snapshot")

        reset(); let switched = ModelRestoreHarness(api: try live()); let switchGate = Gate()
        let switchRead = Task { await switchGate.wait() }
        switched.cloudRefreshTask = switchRead; switched.cloudRefreshOperation = UUID()
        await settle { switchGate.entered }
        _ = try await switched.restoreListing(serverID: target)
        for _ in 0..<10 { await Task.yield() }
        AuthStore.shared.userID = "different-owner"; AuthStore.shared.syncSessionRevision += 1
        switchGate.release(); await switchRead.value
        for _ in 0..<30 { await Task.yield() }
        check(switched.refreshCalls == 0 && switched.joinedReads == 0, "a stale pending restore cannot refresh another account")

        reset(); let replaced = ModelRestoreHarness(api: try live()); let replacedGate = Gate()
        let replacedRead = Task { await replacedGate.wait() }
        replaced.cloudRefreshTask = replacedRead; replaced.cloudRefreshOperation = UUID()
        await settle { replacedGate.entered }
        _ = try await replaced.restoreListing(serverID: target)
        for _ in 0..<10 { await Task.yield() }
        let newerGate = Gate(), newerOperation = UUID()
        let newerRead = Task { await newerGate.wait() }
        replaced.cloudRefreshTask = newerRead; replaced.cloudRefreshOperation = newerOperation
        await settle { newerGate.entered }; replacedGate.release(); await replacedRead.value
        await settle { replaced.joinedReads > 0 || replaced.refreshCalls > 0 }
        check(replaced.cloudRefreshOperation == newerOperation && replaced.cloudRefreshTask != nil,
            "older restore completion must preserve a newer refresh operation")
        newerGate.release(); await newerRead.value

        reset(); let changedAPI = ControlledRestoreAPI(result: result); let changedGate = Gate(); changedAPI.gate = changedGate
        let changedModel = ModelRestoreHarness(api: changedAPI); var changedFailed = false
        let changedTask = Task { do { _ = try await changedModel.restoreListing(serverID: target) }
            catch { changedFailed = error as? CloudSyncError == .identityChanged } }
        await settle { changedGate.entered }; AuthStore.shared.syncSessionRevision += 1
        changedGate.release(); await changedTask.value
        check(changedFailed && changedModel.refreshCalls == 0, "model rejects an account-context change before presenting success")
        reset()
        let wrongResult = RestoredListing(id: UUID(), orgID: storedOrg, address: nil, republishedRenders: 0, cancelledClientDeliveries: 0)
        let wrongModel = ModelRestoreHarness(api: ControlledRestoreAPI(result: wrongResult))
        do { _ = try await wrongModel.restoreListing(serverID: target); check(false, "model refuses a different restored listing") }
        catch { check(error as? CloudSyncError == .invalidResponse, "model refuses a different restored listing") }
        reset(); Config.useLiveBackend = false; let offline = ModelRestoreHarness(api: try live())
        await assertIdentityFailure({ _ = try await offline.restoreListing(serverID: target) }, "offline restore cannot report cloud success")

        reset(); let row = TrashedListing(id: target, address: "100 Synthetic Restore Lane")
        let callerAPI = ControlledRestoreAPI(result: result), callerGate = Gate(); callerAPI.gate = callerGate
        let caller = RestoreCallerHarness(model: callerAPI); caller.rows = [row]; caller.begin(row)
        await settle { callerGate.entered }
        check(caller.restoring == row.id && caller.rows.count == 1, "restore caller retains the row while the server is pending")
        callerGate.release(); await settle { caller.restoring == nil }
        check(caller.rows.isEmpty && caller.restored?.id == target && Haptics.successes == 1,
            "current restore caller removes the row and presents server success")

        for shouldFail in [false, true] {
            reset(); let api = ControlledRestoreAPI(result: result), gate = Gate(); api.gate = gate
            if shouldFail { api.error = APIError.server(410) }
            let view = RestoreCallerHarness(model: api); view.rows = [row]; view.begin(row)
            await settle { gate.entered }
            AuthStore.shared.userID = "different-owner"; AuthStore.shared.syncSessionRevision += 1
            gate.release(); await settle { view.restoring == nil }
            check(view.rows.count == 1 && view.restored == nil && view.restoreError == nil && Haptics.successes == 0,
                "stale restore caller cannot present success or error in another account")
        }

        // Execute both real location bodies with controlled Core Location and
        // geocoder callbacks, including callbacks already queued at cancellation.
        reset(); let home = HomeLocationHarness(); home.begin()
        check(home.locating && home.locator.pending != nil, "Home begins one location request")
        home.locator.pending?(CLLocation()); let homeCoder = CLGeocoder.created.last!
        homeCoder.pending?([CLPlacemark(address: "100 Synthetic Geocoded Lane")], nil)
        check(home.name == "100 Synthetic Geocoded Lane" && !home.locating, "Home accepts its current geocode")
        check(home.completer.accepts == 1 && home.locationGeocoder == nil, "Home ends the lookup before assigning the suggested address")
        for mutation in 0..<3 {
            reset(); let subject = HomeLocationHarness(); subject.begin(); subject.locator.pending?(CLLocation())
            let coder = CLGeocoder.created.last!
            if mutation == 0 { subject.name = "new manual address" }
            else if mutation == 1 { AuthStore.shared.userID = "different-owner" }
            else { subject.cancel() }
            let retained = subject.name
            coder.pending?([CLPlacemark(address: "late wrong address")], nil)
            check(subject.name == retained && subject.completer.accepts == 0, "stale Home geocode cannot overwrite typed or switched context")
            check(!subject.locating, "stale Home geocode ends its own spinner")
        }
        reset(); let canceledHome = HomeLocationHarness(); canceledHome.begin()
        let queuedLocation = canceledHome.locator.pending!; canceledHome.cancel(); queuedLocation(CLLocation())
        check(CLGeocoder.created.isEmpty, "canceled Home location cannot start a geocoder")

        reset(); let listing = ListingLocationHarness(); listing.begin(); listing.locator.pending?(CLLocation())
        let listingCoder = CLGeocoder.created.last!
        listingCoder.pending?([CLPlacemark(address: "200 Synthetic Geocoded Lane")], nil)
        check(listing.form.address == "200 Synthetic Geocoded Lane" && listing.form.unit == "12", "Listings accepts a street without changing the entered unit")
        check(listing.pendingCoord?.latitude == 35.123 && listing.pendingCoord?.longitude == -80.988,
            "Listings stores only the coarse coordinate after an accepted geocode")
        check(listing.pendingCoordAddress == listing.form.address,
            "Listings binds the accepted coordinate to its exact suggested address")
        check(!listing.locating && listing.locationGeocoder == nil, "Listings finishes its location request")
        for mutation in 0..<3 {
            reset(); let subject = ListingLocationHarness(); subject.begin(); subject.locator.pending?(CLLocation())
            let coder = CLGeocoder.created.last!
            if mutation == 0 { subject.form.address = "new manual address" }
            else if mutation == 1 { WorkspaceContext.selectedOrgID = UUID() }
            else { subject.cancel() }
            let retained = subject.form.address
            coder.pending?([CLPlacemark(address: "late wrong address")], nil)
            check(subject.form.address == retained && subject.pendingCoord == nil,
                "stale Listings geocode cannot overwrite typed or switched context")
            check(!subject.locating, "stale Listings geocode ends its own spinner")
        }
        print("PASSED: \(checks) actual-body Home/location/restore async boundary assertions")
    }
}
