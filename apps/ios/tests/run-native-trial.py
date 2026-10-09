#!/usr/bin/env python3
"""Compile actual trial models, /me DTO/decode and billing consumer with faults.

Foundation and closed network interfaces only. Full SwiftUI/device compilation
is separate; no StoreKit, camera, provider, account or production calls.
"""
from pathlib import Path
import argparse, hashlib, json, subprocess, tempfile

root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--out', type=Path)
args = parser.parse_args()
out = (args.out or Path(tempfile.mkdtemp(prefix='rendprop-native-trial-'))).resolve()
out.mkdir(parents=True, exist_ok=True)
names = ['Purchases/SubscriptionBillingContext.swift', 'Networking/APIClient.swift',
         'Networking/LiveAPIClient.swift', 'Networking/WorkspaceSync.swift', 'Models/Money.swift',
         'Screens/SettingsView.swift', 'Purchases/PaywallView.swift', 'Purchases/PurchasesAPI.swift',
         'Purchases/PurchaseManager.swift', 'Screens/FlythroughDetailView.swift', 'Purchases/PaywallHost.swift']
names += ['Plan/PlanBanner.swift']
paths = [root/'apps/ios/Rendprop'/name for name in names]
paths += [root/'apps/ios/tests/TrialUsageTests.swift', Path(__file__).resolve()]
hashes = lambda: {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
start = hashes()
billing, api, live, workspace, money, settings, paywall, purchases, manager, fly, host, banner = [p.read_text() for p in paths[:len(names)]]
def block(source, needle):
    begin = source.index(needle); opening = source.index('{', begin); depth = 1; end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}'); end += 1
    return source[begin:end]

# Bind real presentation call sites to the actual compiled counter/offer data.
rows = block(settings, 'private func usageRows(')
assert 'if let trial = usage.trialUsage {' in rows and 'trialUsageRows(trial)' in rows
assert '} else if let e = usage.entitlements {' in rows
assert 'ForEach(trial.rows, id: \\.title)' in block(settings, 'private func trialUsageRows(')
details = block(paywall, '@ViewBuilder private var trialDetails:')
assert 'if let trial = purchases.billingContext?.trialUsage' in details
assert 'else if selectedHasIntroOffer' in details and 'offer.enabled, !offer.benefitLines.isEmpty' in details
assert 'ForEach(offer.benefitLines, id: \\.self)' in details
assert 'After the trial' in block(paywall, 'private struct SelectedPlanDetails:')
assert 'TrialUsageSummary.explanation' in settings and 'TrialUsageSummary.explanation' in details
assert 'usage.servingActivation?.shouldShowPending(' in rows and 'ServingActivationSummary.pendingTitle' in rows
usage_load = block(settings, 'private func loadUsage(')
assert usage_load.count('usageLoadGeneration == generation') == 3 and 'usage = nil' in usage_load.split('} catch {')[1]
assert 'purchases.billingContext?.servingActivation?.available != false' in block(paywall, 'private var content:')
assert 'state = PlanBanner.pendingActivationState()' in banner
assert 'SubscriptionBillingContext.fromMe(data, selectedOrg: WorkspaceContext.selectedOrgID, billingOrg: WorkspaceContext.billingOrgID, servingOrg: WorkspaceContext.servingOrgID)' in purchases
assert 'WorkspaceContext.selectedOrgID == org' in block(purchases, 'static func getBilling(')
assert 'WorkspaceContext.selectedOrgID == selectedOrg' in block(manager, 'func refreshBillingContext(')
assert 'for: .rendpropPlanChanged' in paywall
purchase_body = block(manager, 'func purchase(')
assert 'hasFreeIntroductoryOffer(for: product)' in purchase_body and '!hasSevenDayTrial(for: product)' in purchase_body
assert 'await product.subscription?.isEligibleForIntroOffer' in purchase_body
assert purchase_body.index('try await validateTrialPurchase(') < purchase_body.index('try await product.purchase(')
assert '!purchases.canStartNewPurchase(for: product) && !purchases.canCheckTrialAvailability(for: product)' in block(paywall, 'private func buyButton(')
assert 'Trial unavailable' in block(paywall, 'private func buyTitle(')
assert 'Check trial availability' in block(paywall, 'private func buyTitle(')
assert 'purchases.heldTrialOffer(for: product)' in details
assert 'state = PlanBanner.boundedTrialState(trial)' in banner
assert 'trial.checked(org: billingOrg)' in banner and banner.count('WorkspaceContext.selectedOrgID == org') == 2
assert "A plan upgrade unlocks this. Your saved work is still here." in block(fly, 'var actionHint:')
assert 'this month' not in block(host, 'var contextLine:').split('case .quota(let feature):')[1].split('case .trialEnded:')[0]

interfaces = '''
import Foundation
enum APIError: Error { case decoding, notConfigured }
typealias Color = String
enum Theme { static let accent = "accent"; static let warn = "warn" }
enum WorkspaceContext { static var selectedOrgID: UUID?; static var billingOrgID: UUID? { selectedOrgID }; static var servingOrgID: UUID? { selectedOrgID } }
@MainActor final class AuthStore {
    static let shared = AuthStore()
    var userID: String? = "synthetic-owner"
    var syncSessionRevision: UInt64 = 1
    var identityWrites = 0
    func applyServerIdentity(userName: String?, orgName: String?) { identityWrites += 1 }
}
@MainActor final class LiveTrialFixture {
    let data: Data; var onRead: (() -> Void)?
    var identityWrites: Int { AuthStore.shared.identityWrites }
    init(data: Data) { self.data = data; AuthStore.shared.identityWrites = 0 }
    private func url(_ parts: [String]) -> URL { URL(string: "https://fixture.invalid/" + parts.joined(separator: "/"))! }
    private func makeRequest(url: URL) -> URL { url }
    private func execute(_ url: URL) async throws -> Data { onRead?(); return data }
'''
def generated(billing_source, live_source, manager_source, banner_source):
    shared = 'import Foundation\n' + billing_source + '\n' + money + '\n' + block(purchases, 'struct EntitlementSync:') + '\n'
    for needle in ['struct Entitlements:', 'struct HostingRetentionSummary:', 'struct UsageSummary:']:
        shared += block(api, needle) + '\n'
    shared += block(workspace, 'enum CloudSyncError:') + '\n' + interfaces
    for needle in ['struct LenientInt:', 'private struct MeDTO:', 'private func decode<T:',
                   'private static func parseDate(', '@MainActor func me(']:
        shared += block(live_source, needle) + '\n'
    shared += '\n}\nstruct PlanBanner {\n'
    for needle in ['enum Kind:', 'struct PlanState:', 'static func boundedTrialState(', 'static func pendingActivationState(']:
        shared += block(banner_source, needle) + '\n'
    shared += '\n}\n'
    shared += '''
@MainActor final class HeldBillingAPI {
    var pending: [CheckedContinuation<SubscriptionBillingContext, Error>] = []
    func billingContext() async throws -> SubscriptionBillingContext {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
}
@MainActor final class BillingRefreshFixture {
    var billingContext: SubscriptionBillingContext?
    var billingError: String?
    let api: HeldBillingAPI?
    init(_ api: HeldBillingAPI) { self.api = api }
'''
    property_line = next(line.strip() for line in manager_source.splitlines() if 'private var billingRefreshGeneration:' in line)
    shared += property_line + '\n' + block(manager_source, 'func refreshBillingContext(')
    shared += '\n' + block(manager_source, 'private func validateTrialPurchase(').replace('private ', '', 1) + '\n}\n'
    return shared

faults = [
    ('actual', None, None, None),
    ('counter-remaining', 'remaining == cap - used', 'remaining >= 0', 'Malformed trial response accepted'),
    ('counter-org', 'orgId == org,', 'true,', 'Recorded trial cannot cross workspaces'),
    ('trial-window', 'end.timeIntervalSince(start) <= 7 * 24 * 60 * 60', 'true', 'Malformed trial response accepted'),
    ('disabled-offer', 'guard enabled, checked() != nil', 'guard checked() != nil', 'Disabled configured quantities stay hidden'),
    ('offer-max-days', 'maxDays == 7,', 'maxDays != nil,', 'Non-seven-day enabled offer accepted'),
    ('drop-recorded-usage', 'trialUsage: dto.trialUsage', 'trialUsage: nil', 'Actual me forwards recorded trial usage'),
    ('drop-enabled-offer', 'trialOffer: dto.trialOffer', 'trialOffer: nil', 'Disabled offer never promises numeric quantities'),
    ('billing-enclosing-org', 'trial.org?.id == selectedOrg,', 'true,', 'Billing offer accepted foreign enclosing org'),
    ('stale-actor', 'AuthStore.shared.userID == actor', 'true', 'Changed actor accepted after response'),
    ('stale-session', 'AuthStore.shared.syncSessionRevision == revision', 'true', 'Changed revision accepted after response'),
    ('stale-workspace', 'WorkspaceContext.selectedOrgID == selectedOrg', 'true', 'Changed workspace accepted after response'),
    ('same-org-renewal-race', 'billingRefreshGeneration == generation', 'true', 'Older same-workspace trial response replaced verified paid state'),
    ('home-remaining-count', 'let photos = trial.photoEdits.remaining', 'let photos = trial.photoEdits.cap', 'Home banner presents actual remaining photo credits'),
    ('home-ended-state', 'PlanState(kind: .ended, title: trial.statusLabel', 'PlanState(kind: .paid, title: trial.statusLabel', 'Home banner obeys expired server status'),
    ('purchase-offer-required', 'let offer = billing.trialOffer, offer.enabled, offer.checked() != nil', 'billing.role == "owner"', 'Absent offer authorized an introductory purchase'),
    ('purchase-offer-enabled', 'offer.enabled, offer.checked() != nil', 'true, offer.checked() != nil', 'Disabled offer authorized an introductory purchase'),
    ('purchase-offer-bounds', 'offer.checked() != nil', 'true', 'Malformed offer authorized an introductory purchase'),
    ('purchase-org', 'billing.orgID == org', 'true', 'Foreign workspace authorized noneligible billing'),
    ('purchase-authority', 'billing.canManageSubscription', 'true', 'Denied fresh authority authorized noneligible billing'),
    ('purchase-snapshot', 'captured == current', 'true', 'Late account or workspace response authorized introductory billing'),
    ('activation-org', 'guard orgId == org else { return nil }', 'guard true else { return nil }', 'Foreign activation workspace accepted'),
    ('activation-flags', 'return !available && !funded ? self : nil', 'return self', 'Malformed activation accepted'),
    ('activation-allowance', 'dto.servingActivation?.available == false ? 0 : ent.photoEditsPerMonth?.value ?? 0', 'ent.photoEditsPerMonth?.value ?? 0', 'Pending activation exposed usable paid photo allowance'),
]
results = []
for name, old, new, expected in faults:
    b, l, m, h = billing, live, manager, banner
    if old is not None:
        if old in b: b = b.replace(old, new)
        elif old in l: l = l.replace(old, new)
        elif old in m: m = m.replace(old, new)
        elif old in h: h = h.replace(old, new)
        else: raise RuntimeError('Unapplied semantic fault: ' + name)
    source = generated(b, l, m, h)
    folder = out/name; folder.mkdir(exist_ok=True)
    swift = folder/'Actual.swift'; swift.write_text(source)
    binary = folder/'native-trial'
    built = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(swift), str(paths[-2]), '-o', str(binary)], capture_output=True, text=True)
    (folder/'compile.log').write_text(built.stdout+built.stderr)
    if built.returncode: raise RuntimeError('Compile failure: ' + str(folder/'compile.log'))
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
    output = result.stdout+result.stderr
    (folder/'runtime.log').write_text(output)
    passed = (result.returncode == 0 and 'Native bounded trial:' in output) if expected is None else (result.returncode != 0 and expected in output and 'Fatal error:' in output)
    results.append({'case': name, 'passed': passed, 'compileExit': built.returncode, 'runtimeExit': result.returncode, 'expectedFailure': expected, 'compiledSourceSHA256': hashlib.sha256(source.encode()).hexdigest()})
    if not passed: raise RuntimeError('Semantic failure: ' + str(folder/'runtime.log'))
bound = hashes() == start
receipt = {'passed': bound and all(r['passed'] for r in results), 'sourceBoundAtEnd': bound, 'sourceSHA256': start, 'actual': results[0], 'negativeControls': results[1:], 'networkRequests': 0, 'providerCalls': 0, 'appleCalls': 0, 'fileDeletions': 0, 'limitations': 'Actual Foundation models, billing envelope validation, /me DTO/method, Home state and concurrent billing refresh compiled with closed network/presentation interfaces. SwiftUI call sites source-bound; real app compile and physical camera/StoreKit acceptance are separate.'}
(out/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
print(json.dumps({'passed': receipt['passed'], 'compiledNegativeControls': len(results)-1, 'actualOutput': (out/'actual/runtime.log').read_text().strip(), 'receipt': str(out/'receipt.json')}))
raise SystemExit(0 if receipt['passed'] else 1)
