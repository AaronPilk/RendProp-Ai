#!/usr/bin/env python3
"""Execute actual consumable custody against closed Apple/HTTP boundaries."""
import argparse, hashlib, json, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(); parser.add_argument('--out', type=Path); args = parser.parse_args()
out = args.out or Path(tempfile.mkdtemp(prefix='rendprop-website-upgrade-'))
out.mkdir(parents=True, exist_ok=True)
paths = [ROOT / p for p in ['apps/ios/Rendprop/Models/WebsiteDesign.swift',
    'apps/ios/Rendprop/Purchases/WebsiteUpgradeStore.swift', 'apps/ios/tests/WebsiteUpgradeTests.swift',
    'apps/ios/tests/run-website-upgrade.py']]
hashes = lambda: {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
start = hashes()
models = paths[0].read_text()
old = '''let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)'''
assert models.count(old) == 1
models = models.replace(old, 'let base = WebsiteUpgradeFixture.directory')
store = paths[1].read_text().replace('import StoreKit', 'import Combine')
interfaces = r'''
import Foundation
import Combine
enum WebsiteUpgradeFixture { static let directory = URL(fileURLWithPath:CommandLine.arguments[1], isDirectory:true) }
enum CloudSyncError: Error { case invalidResponse, identityChanged }
enum APIError: Error { case notConfigured }
enum DeepLink { static func buyerWebsiteURL(from url:URL)->URL?{url} }
enum WorkspaceContext { static var selectedOrgID:UUID? }
@MainActor final class AuthStore { static let shared=AuthStore(); var userID:String?; var isSignedIn=true; var syncSessionRevision:UInt64=1 }
enum Config { static func makeAPIClient()->Any?{nil} }
protocol WebsiteDesignAPI {
 func websiteDesignState(context:WebsiteDesignContext)async throws->WebsiteDesignState
 func assignWebsiteUpgrade(signedTransaction:String,context:WebsiteDesignContext)async throws->WebsiteDesignState
}
enum VerificationResult<T> { case verified(T), unverified
 var jwsRepresentation:String{if case .verified(let t)=self, let tx=t as? Transaction{return "signed-"+String(tx.id)};return "unverified"}
}
enum AppStore { enum Environment {case production,sandbox,xcode} }
struct AppTransaction {let environment:AppStore.Environment
 static var fixtureEnvironment=AppStore.Environment.production
 static var shared:VerificationResult<AppTransaction>{get async throws{.verified(AppTransaction(environment:fixtureEnvironment))}}
}
@MainActor final class Transaction {
 enum Ownership {case purchased,familyShared}
 let id:UInt64; var productID=WebsiteUpgradeProduct.id; var productType=Product.ProductType.consumable
 var ownershipType=Ownership.purchased; let appAccountToken:UUID?; let purchasedQuantity:Int
 var finishes=0; var onFinish:(()->Void)?
 init(id:UInt64,owner:UUID,quantity:Int){self.id=id;appAccountToken=owner;purchasedQuantity=quantity}
 func finish()async{onFinish?();finishes+=1;Self.queue.removeAll{if case .verified(let t)=$0{return t.id==id};return false}}
 static var queue:[VerificationResult<Transaction>]=[]
 static var unfinished:AsyncStream<VerificationResult<Transaction>>{AsyncStream{c in queue.forEach{c.yield($0)};c.finish()}}
 static var updates:AsyncStream<VerificationResult<Transaction>>{AsyncStream{c in c.finish()}}
}
@MainActor final class Product {
 enum ProductType {case consumable,autoRenewable}
 enum PurchaseOption:Hashable {case appAccountToken(UUID),quantity(Int)}
 enum PurchaseResult {case success(VerificationResult<Transaction>),userCancelled,pending}
 var id=WebsiteUpgradeProduct.id;var type=ProductType.consumable;var nextResult=PurchaseResult.userCancelled
 static var catalog:[Product]=[];static var purchases=0;static var onPurchase:(()->Void)?
 static func products(for ids:[String])async throws->[Product]{catalog}
 func purchase(options:Set<PurchaseOption>)async throws->PurchaseResult{Self.onPurchase?();Self.purchases+=1;return nextResult}
}
@MainActor final class FakeWebsiteAPI:WebsiteDesignAPI {
 var context:WebsiteDesignContext;var assignments=0;var enabled=true;var sandboxEnabled=false;var unlocked=false;var revoked=false
 var transactionID:String?;var error:Error?;var onAssignment:(()->Void)?
 init(context:WebsiteDesignContext){self.context=context}
 func state(_ assigned:Bool=false)->WebsiteDesignState{WebsiteDesignState(listingID:context.listingID,orgID:context.orgID,theme:.basic,
 premium:.init(unlocked:assigned && !revoked || unlocked,purchaseEnabled:enabled,sandboxPurchaseEnabled:sandboxEnabled),assigned:assigned,replay:false,revoked:revoked,
 environment:"Sandbox",transactionID:transactionID)}
 func websiteDesignState(context:WebsiteDesignContext)async throws->WebsiteDesignState{state()}
 func assignWebsiteUpgrade(signedTransaction:String,context:WebsiteDesignContext)async throws->WebsiteDesignState{assignments+=1;onAssignment?();if let error{throw error};return state(true)}
}
'''
faults = [
 ('actual', None, None, None),
 ('finish-refused', 'let acknowledged = try await api.assignWebsiteUpgrade', 'await transaction.finish()\n        let acknowledged = try await api.assignWebsiteUpgrade', 'Apple finished before server acknowledgment'),
 ('late-account', 'guard context.isCurrent,\n              try acknowledged.acknowledges', 'guard true,\n              try acknowledged.acknowledges', 'Late replacement-account response finished Apple'),
 ('quantity', 'transaction.purchasedQuantity == 1', 'transaction.purchasedQuantity > 0', 'Untrusted purchase was sent for fulfillment'),
 ('intent-overwrite', 'guard existing.id == intent.id', 'guard true', 'Durable purchase slot overwritten'),
 ('restore-early-return', 'if filtered.isEmpty, saved == nil, state.premium.unlocked', 'if saved == nil, state.premium.unlocked', 'Reinstall after assignment stranded an unfinished credit'),
 ('orphan-pin-before-ack', 'saveBeforeAcknowledgment: saved != nil', 'saveBeforeAcknowledgment: true', 'Refused orphan destination pinned the wrong property'),
]
runs = []
try:
 for name, old, new, expected in faults:
  actual_models, actual_store = models, store
  if old:
   target = actual_models if name == 'intent-overwrite' else actual_store
   assert target.count(old) == 1, name
   if name == 'intent-overwrite': actual_models = target.replace(old, new)
   else: actual_store = target.replace(old, new)
  folder = out / name; folder.mkdir(exist_ok=True)
  program = folder / 'Actual.swift'; program.write_text(interfaces + '\n' + actual_models + '\n' + actual_store)
  binary = folder / 'checks'
  c = subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(program),str(paths[2]),'-o',str(binary)],capture_output=True,text=True,timeout=90)
  (folder / 'compile.log').write_text(c.stdout+c.stderr)
  assert c.returncode == 0, name + ': ' + c.stderr
  r = subprocess.run([str(binary),str(folder/'isolated-storage')],capture_output=True,text=True,timeout=30)
  (folder / 'runtime.log').write_text(r.stdout+r.stderr)
  correct = r.returncode == 0 if expected is None else r.returncode != 0 and expected in r.stdout+r.stderr
  runs.append(dict(name=name,compile_exit=c.returncode,runtime_exit=r.returncode,expected_failure=expected,passed=correct))
  assert correct, name + ': ' + r.stdout+r.stderr
finally:
 receipt = dict(passed=len(runs)==len(faults) and all(x['passed']for x in runs) and hashes()==start,
     start_source_sha256=start,end_source_sha256=hashes(),source_unchanged=hashes()==start,runs=runs,
     apple_calls=0,external_requests=0,limitations='Actual purchase and durable custody execute against closed StoreKit/HTTP/Auth interfaces. Physical Apple payment-sheet acceptance and server receipt validation are separate gates.')
 (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 print(json.dumps({'receipt':str(out/'receipt.json'),'passed':receipt['passed'],'runs':len(runs)}))
assert receipt['passed']
