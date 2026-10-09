#!/usr/bin/env python3
"""Compile actual reservation DTO, API request and pre-StoreKit methods.

Storefront, StoreKit sheet, URLSession and persistence are closed interfaces.
No network, Apple purchase, sponsor funding or production account is touched.
"""
from pathlib import Path
import argparse, hashlib, json, subprocess, tempfile

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--out', type=Path)
args = parser.parse_args()
out = (args.out or Path(tempfile.mkdtemp(prefix='rendprop-native-trial-hold-'))).resolve()
out.mkdir(parents=True, exist_ok=True)
paths = [root/'apps/ios/Rendprop/Purchases'/name for name in
         ['SubscriptionBillingContext.swift', 'PurchasesAPI.swift', 'PurchaseManager.swift', 'PaywallView.swift']]
paths.append(root/'apps/ios/Rendprop/Models/Money.swift')
paths += [root/'apps/ios/Rendprop/Auth/AuthStore.swift', root/'apps/ios/tests/TrialPurchaseHoldTests.swift', Path(__file__).resolve()]
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
hashes = lambda: {str(p.relative_to(root)): digest(p) for p in paths}
start = hashes()
billing, api, manager, paywall = [p.read_text() for p in paths[:4]]
money = paths[4].read_text()

def block(source, needle):
    begin = source.index(needle)
    opening = source.index('{', begin)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[begin:end]

# The actual app's sheet/CTA and cancellation wiring must use these compiled
# guards. These are source bindings, not claims of SwiftUI/device execution.
purchase = block(manager, 'func purchase(')
check = block(manager, 'func checkTrialAvailability(')
button = block(paywall, 'private func buyButton(')
assert 'continuingHeldTrial: continuingHeldTrial' in button
assert button.index('let continuingHeldTrial =') < button.index('Task {')
assert 'await purchases.checkTrialAvailability(' in button
assert '!purchases.canStartNewPurchase(for: product) && !purchases.canCheckTrialAvailability(for: product)' in button
assert 'Check trial availability' in block(paywall, 'private func buyTitle(')
assert 'Paid subscriptions unavailable' in block(paywall, 'private func buyTitle(')
assert 'PurchaseDispatchAdmission.paidUnavailableMessage' in block(paywall, 'private func disclosure(')
assert 'purchases.heldTrialOffer(for: product)' in block(paywall, '@ViewBuilder private var trialDetails:')
assert purchase.index('validateHeldTrialPurchase(') < purchase.index('validateCurrentHeldTrialPurchase(') < purchase.index('try await product.purchase(')
assert purchase.count('await trialRegionSupported(') == 2
assert check.index('await trialRegionSupported(') < check.index('validateHeldTrialPurchase(')
assert 'discardUnpurchased' not in check and 'automatically released or restarted' in check
assert purchase.count('if !retainTrialBinding, createdBinding, let binding = preparedBinding') == 4
assert purchase.index('verifiedHeldTrialForDispatch = true') > purchase.index('validateCurrentHeldTrialPurchase(')
assert purchase.index('guard PurchaseDispatchAdmission.allows(') < purchase.index('try await product.purchase(')
assert 'await ' not in purchase.split('guard PurchaseDispatchAdmission.allows(', 1)[1].split('try await product.purchase(', 1)[0]
assert purchase.count('verifiedHeldTrialForDispatch = true') == 1
assert 'actor.flatMap(UUID.init(uuidString:)).map { [.appAccountToken($0)] }' in purchase
prepare_needle = 'func prepareTrialPurchase(orgID: UUID, productID: String, appAccountToken: UUID) async throws -> TrialPurchaseReservation {'
assert 'retriesUnauthorized: false, requiredCurrentOrg: orgID' in block(api, prepare_needle)
assert 'completionHandler(nil)' in block(api, 'private final class TrialPurchaseRedirectPolicy:')

interfaces = r'''
import Foundation
enum APIError: Error { case decoding, notConfigured, invalidURL, badResponse(Int) }
enum CloudSyncError: Error { case identityChanged, invalidResponse }
enum Config { static var useLiveBackend = true; static var isUITesting = false; static let enableAuth = true
    static let apiBaseURL: URL? = URL(string: "https://fixture.invalid/functions/v1")
    static let supabaseAnonKey = "synthetic-anon" }
enum WorkspaceContext { static var selectedOrgID: UUID?; static var billingOrgID: UUID? { selectedOrgID }; static var servingOrgID: UUID? { selectedOrgID } }
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String?; var syncSessionRevision: UInt64 = 1
    var isSignedIn = true; var isIdentified = true; var refreshes = 0
    static var token: String? = "synthetic-bearer"
    static func validAccessToken() async -> String? { token }
    static func storedAccessToken() -> String? { token }
    func forceRefresh() async -> Bool { refreshes += 1; return true }
}
enum DirectUploader { static func sha256Hex(_ value: Data) -> String { String(repeating: "a", count: 64) }
    static func sha256Hex(_ value: String) -> String { String(repeating: "b", count: 64) } }
@MainActor final class URLSession {
    static let shared = URLSession()
    static var requests: [URLRequest] = []; static var status = 200; static var reply = Data()
    static var onResponse: (() -> Void)?
    init() {}
    init(configuration: URLSessionConfiguration, delegate: Any?, delegateQueue: OperationQueue?) {}
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        Self.requests.append(request); Self.onResponse?()
        return (Self.reply, HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}
final class UserDefaults {
    static let standard = UserDefaults(); var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ value: Data, forKey key: String) { values[key] = value }
    func synchronize() -> Bool { true }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}
struct LiveAPIClient { static func serverError(status: Int, data: Data) -> APIError { .badResponse(status) } }
enum SubscriptionOfferPolicy {
    enum PeriodUnit { case day, week, month, year, unknown }
    static func isSevenDayFreeTrial(eligible: Bool, free: Bool, value: Int, unit: PeriodUnit, count: Int) -> Bool {
        eligible && free && count == 1 && ((unit == .day && value == 7) || (unit == .week && value == 1))
    }
}
enum SheetError: Error { case cancelled, timeout }
@MainActor final class Subscription {
    struct Offer { enum Payment { case freeTrial, paid }; enum Unit { case day, week, month, year }
        struct Period { let value: Int; let unit: Unit }
        var paymentMode: Payment = .freeTrial; let period = Period(value: 7, unit: .day); let periodCount = 1 }
    var introductoryOffer: Offer? = Offer()
    var values: [Bool?] = [true]; var onRead: (() -> Void)?; var reads = 0
    var isEligibleForIntroOffer: Bool? { get async { reads += 1; onRead?(); return values.count > 1 ? values.removeFirst() : values.first! } }
}
@MainActor struct Product {
    let id: String; var subscription: Subscription? = Subscription()
    struct PriceStyle { var currencyCode = "USD" }; var priceFormatStyle = PriceStyle()
    enum PurchaseOption: Hashable { case appAccountToken(UUID) }
    enum PurchaseResult { case success(Bool), pending, userCancelled, unresolved }
    static var sheetCalls = 0; static var receivedOptions: Set<PurchaseOption> = []
    static var result: PurchaseResult = .userCancelled; static var error: SheetError?
    func purchase(options: Set<PurchaseOption>) async throws -> PurchaseResult {
        Self.sheetCalls += 1; Self.receivedOptions = options
        if let error = Self.error { throw error }; return Self.result
    }
}
@MainActor struct Storefront {
    let countryCode: String
    static var values: [String?] = ["USA"]; static var reads = 0; static var onRead: (() -> Void)?
    static var current: Storefront? { get async {
        reads += 1; onRead?(); let value = values.count > 1 ? values.removeFirst() : values.first!
        return value.map { .init(countryCode: $0) }
    } }
}
@MainActor enum PaywallEvents { static func track(_ event: String, product: Product, extra: [String: String]? = nil) {} }
@MainActor final class HeldAPI {
    let org: UUID; let actor: UUID; let product: String
    var held: TrialPurchaseReservation?; var prepareCalls = 0; var billingCalls = 0
    var failPrepare = false; var converted = false; var onPrepare: (() -> Void)?; var onBilling: (() -> Void)?
    var overrideHold: TrialPurchaseReservation?; var overrideContext: SubscriptionBillingContext?
    init(org: UUID, actor: UUID, product: String) { self.org = org; self.actor = actor; self.product = product }
    func billingContext() async throws -> SubscriptionBillingContext {
        billingCalls += 1; onBilling?()
        if let overrideContext { return overrideContext }
        var value = SubscriptionBillingContext(orgID: org, orgName: "Synthetic workspace", role: "owner", canManageSubscription: true, source: nil)
        value.trialReservation = converted ? nil : held
        value.trialOffer = converted ? nil : held?.trialOffer
        return value
    }
    func prepareTrialPurchase(orgID: UUID, productID: String, appAccountToken: UUID) async throws -> TrialPurchaseReservation {
        prepareCalls += 1
        if held == nil { held = makeHold(actor: actor, org: org, product: product) }
        onPrepare?()
        if failPrepare { throw SheetError.timeout }
        return overrideHold ?? held!
    }
}
@MainActor final class PurchaseFixture {
    var isPurchasing = false; var isRestoring = false; var lastError: String?; var notice: String?
    var activePlan: String?; var activeProductID: String?; var activeBillingOwner: UUID?
    var activeOriginalTransactionID: String?; var unsyncedCount = 0
    var billingContext: SubscriptionBillingContext?; var billingError: String?
    var preparedTrialReservation: TrialPurchaseReservation?; var preparedTrialSnapshot: TrialPurchaseSnapshot?
    var introOfferEligible: [String: Bool] = [:]; let api: HeldAPI?
    private var billingRefreshGeneration: UInt64 = 0
    init(_ api: HeldAPI) { self.api = api }
    func refreshEntitlements() async -> Bool { true }
    func refreshIntroEligibility() async {}
    func handle(_ value: Bool, event: String) async -> Bool { value }
    static func isCancellation(_ error: Error) -> Bool { (error as? SheetError) == .cancelled }
    static func message(for error: Error, fallback: String) -> String { fallback }
'''

auth_source=paths[-3].read_text()
interfaces=interfaces.replace('func forceRefresh() async -> Bool { refreshes += 1; return true }', 'func forceRefresh() async -> Bool { refreshes += 1; return true }\n'+block(auth_source,'static func jwtSubject('))
def generated(b, a, m):
    source = interfaces + '\n}\n' + b + '\n' + money + '\n'
    source += '@MainActor extension LiveAPIClient {\n' + block(a, prepare_needle) + '\n}\n'
    request = block(a, '@MainActor private enum PurchasesRequest {')
    # Real redirect delegate is checked above and by the SDK compile. Closed
    # URLSession has no requests/redirects beyond the recorded direct dispatch.
    source += request + '\nfinal class TrialPurchaseRedirectPolicy {}\n'
    source += '@MainActor extension PurchaseFixture {\n'
    for needle in ['func showsIntroOffer(', 'func trialEligibility(', 'private func hasFreeIntroductoryOffer(',
                   'private func hasSevenDayTrial(', 'func canStartNewPurchase(', 'func heldTrialOffer(',
                   'func ceilingModePurchaseAllowed(', 'func ceilingShowsIntroOffer(',
                   'func canCheckTrialAvailability(', 'private func trialRegionSupported(',
                   'private func validateHeldTrialPurchase(', 'private func validateCurrentHeldTrialPurchase(',
                   'func checkTrialAvailability(', 'private func validateTrialPurchase(',
                   'func refreshBillingContext(', 'func purchase(']:
        source += block(m, needle).replace('private ', '', 1) + '\n'
    return source + '\n}\n'

faults = [
    ('actual', None, None, None),
    ('hold-actor', 'actorId == actor,', 'true,', 'Wrong held actor accepted'),
    ('hold-token', 'appAccountToken == actor,', 'true,', 'Wrong echoed appAccountToken accepted'),
    ('hold-org', 'orgId == org, productId == product,', 'true, productId == product,', 'Wrong held workspace accepted'),
    ('hold-product', 'productId == product,', 'true,', 'Wrong held product accepted'),
    ('hold-photo-cap', 'trialOffer.photoEdits == 5,', 'true,', 'Wrong held allowance accepted'),
    ('hold-enabled', 'trialOffer.enabled,', 'true,', 'Disabled held offer accepted'),
    ('region-country', 'country == "USA" &&', 'true &&', 'Foreign country created a hold'),
    ('region-currency', 'currency == "USD"', 'true', 'Non-USD currency created a hold'),
    ('region-snapshot', 'return captured == current &&', 'return true &&', 'Late storefront identity accepted'),
    ('fresh-reservation', 'billing.trialReservation == hold,', 'true,', 'Converted hold opened Apple sheet'),
    ('fresh-terms', 'billing.trialOffer == hold.trialOffer', 'true', 'Changed fresh terms opened Apple sheet'),
    ('prepared-snapshot', 'guard before == captured else', 'guard true else', 'Changed pre-prepare snapshot dispatched'),
    ('returned-snapshot', 'captured == current, let actor', 'true, let actor', 'Late hold response accepted'),
    ('same-reservation', 'expectedReservationID.map({ held.reservationId == $0 }) ?? true', 'true', 'Replacement reservation accepted'),
    ('eligibility-at-continue', 'guard eligible == true, let heldAtTap,', 'guard let heldAtTap,', 'Changed held eligibility opened Apple sheet'),
    ('eligibility-after-hold', 'guard finalEligibility == true, hasSevenDayTrial(for: product)', 'guard hasSevenDayTrial(for: product)', 'Late eligibility change opened Apple sheet'),
    ('retain-cancel', 'if !retainTrialBinding, createdBinding, let binding = preparedBinding', 'if createdBinding, let binding = preparedBinding', 'Cancellation discarded trial workspace binding'),
    ('api-token', 'AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) == appAccountToken,', 'true,', 'Foreign appAccountToken dispatched'),
    ('api-workspace', 'WorkspaceContext.billingOrgID == orgID else', 'true else', 'Foreign API workspace dispatched'),
    ('api-401-retry', 'retriesUnauthorized: false,', 'retriesUnauthorized: true,', 'Reservation retried after 401'),
    ('api-response-snapshot', 'let (data, resp) = try await session.data(for: req)\n        guard AuthStore.shared.userID == actor, AuthStore.shared.syncSessionRevision == revision,\n              WorkspaceContext.selectedOrgID == viewedOrg,\n              requiredCurrentOrg.map({ WorkspaceContext.billingOrgID == $0 }) ?? true else { throw CloudSyncError.identityChanged }',
     'let (data, resp) = try await session.data(for: req)', 'Late API response accepted'),
    ('fresh-authority-order', None, None, 'Late server authority during Apple await opened sheet'),
    ('fresh-false-cache', 'introOfferEligible[product.id] = eligible', 'introOfferEligible[product.id] = true', 'Fresh ineligible result reused stale trial authority'),
    ('paid-proof', 'return verifiedHeldTrial', 'return true', 'Existing authority authorized a new paid charge'),
    ('paid-dispatch-snapshot', 'guard captured == current, current.actor.flatMap(UUID.init(uuidString:)) != nil,',
     'guard current.actor.flatMap(UUID.init(uuidString:)) != nil,', 'Stale dispatch snapshot accepted'),
    ('paid-ui-eligibility', 'guard trialEligibility(for: product) == true, heldTrialOffer(for: product) != nil else',
     'guard heldTrialOffer(for: product) != nil else', 'Ineligible paywall enabled a new paid purchase'),
    ('paid-last-dispatch', None, None, 'Unfunded direct paid purchase reached Apple'),
]
results = []
for name, old, new, expected in faults:
    b, a, m = billing, api, manager
    if name == 'paid-last-dispatch':
        original = block(m, 'guard PurchaseDispatchAdmission.allows(')
        closing = original.index(' else {')
        m = m.replace(original, 'guard true' + original[closing:])
    if name == 'fresh-authority-order':
        guard = '''                    guard try await validateCurrentHeldTrialPurchase(held, captured: captured) else {
                        throw SubscriptionBillingContext.TrialPresentationError.invalidResponse
                    }
'''
        if m.count(guard) != 1: raise RuntimeError('Unapplied owner-order guard fault')
        m = m.replace(guard, '')
        marker = '                    let finalEligibility = await product.subscription?.isEligibleForIntroOffer'
        m = m.replace(marker, guard + marker)
    if old is not None:
        if old in b: b = b.replace(old, new)
        elif old in a:
            a = a.replace(old, new)
            if name == 'api-workspace':
                a = a.replace('requiredCurrentOrg.map({ WorkspaceContext.billingOrgID == $0 }) ?? true', 'true')
        elif old in m: m = m.replace(old, new)
        else: raise RuntimeError('Unapplied guard fault: ' + name)
    folder = out/name; folder.mkdir(exist_ok=True)
    source = generated(b, a, m)
    swift = folder/'Actual.swift'; swift.write_text(source)
    binary = folder/'native-trial-hold'
    build = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(swift), str(paths[-2]), '-o', str(binary)], capture_output=True, text=True)
    (folder/'compile.log').write_text(build.stdout + build.stderr)
    if build.returncode: raise RuntimeError('Compilation failure: ' + str(folder/'compile.log'))
    run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
    output = run.stdout + run.stderr; (folder/'runtime.log').write_text(output)
    passed = (run.returncode == 0 and 'Native trial hold:' in output) if expected is None else (run.returncode != 0 and expected in output and 'Fatal error:' in output)
    results.append({'case': name, 'passed': passed, 'compileExit': build.returncode, 'runtimeExit': run.returncode,
                    'expectedFailure': expected, 'compiledSourceSHA256': hashlib.sha256(source.encode()).hexdigest()})
    if not passed: raise RuntimeError('Semantic guard failure: ' + str(folder/'runtime.log'))
bound = hashes() == start
receipt = {'passed': bound and all(r['passed'] for r in results), 'sourceBoundAtEnd': bound, 'sourceSHA256': start,
           'actual': results[0], 'negativeControls': results[1:], 'externalNetworkRequests': 0, 'appleCalls': 0,
           'fundingMutations': 0, 'providerCalls': 0,
           'limitations': 'Actual DTO, reservation API plumbing and pre-StoreKit purchase methods compiled against closed interfaces. SwiftUI and redirect delegate call sites bound to source; SDK compile and real Apple/device acceptance remain separate.'}
(out/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
print(json.dumps({'passed': receipt['passed'], 'compiledNegativeControls': len(results)-1,
                  'actualOutput': (out/'actual/runtime.log').read_text().strip(), 'receipt': str(out/'receipt.json')}))
raise SystemExit(0 if receipt['passed'] else 1)
