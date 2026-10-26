#!/usr/bin/env python3
"""Exercise the production no-charge classifier without an Apple purchase.

The Swift fixture compiles the exact helper from WebsiteUpgradeStore.swift.
Source guards also ensure it is called only around Product.purchase, while
pending/unknown results and server acknowledgement keep their recovery path.
"""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
source_path = root / "apps/ios/Rendprop/Purchases/WebsiteUpgradeStore.swift"
source = source_path.read_text()
marker = "enum WebsitePurchasePretransactionRecovery {"
assert source.count(marker) == 1
helper = source[source.index(marker):]
assert helper.count("enum WebsitePurchasePretransactionRecovery") == 1

unfinished_start = source.index("private func hasUnfinishedWebsitePurchase() async -> Bool {")
brace = source.index("{", unfinished_start)
depth = 1
unfinished_end = brace + 1
while depth:
    depth += (source[unfinished_end] == "{") - (source[unfinished_end] == "}")
    unfinished_end += 1
unfinished_method = source[unfinished_start:unfinished_end].replace(
    "WebsiteUpgradeProduct.id", '"com.rendprop.app.website.premium.property"')

purchase_start = source.index("let result: Product.PurchaseResult")
purchase_end = source.index("switch result {", purchase_start)
pretransaction = source[purchase_start:purchase_end]
assert pretransaction.index("try await product.purchase(") < pretransaction.index("catch {")
assert pretransaction.index("catch {") < pretransaction.index("WebsiteUpgradeIntentStore.clear(intent)")
assert "!(await hasUnfinishedWebsitePurchase())" in pretransaction
assert "context.isCurrent" in pretransaction
assert "try await settle(" not in pretransaction
assert "case .pending:" in source[purchase_end:source.index("private func verifiedStoreEnvironment()")]
assert "setMessage(\"Apple is waiting for approval." in source
settlement = source[source.index("private func settle("):source.index("private func setMessage(")]
assert settlement.index("acknowledged.acknowledges(") < settlement.index("await transaction.finish()")

work = Path(tempfile.mkdtemp(prefix="rendprop-website-purchase-recovery-", dir=root.parent))
fixture = work / "main.swift"
fixture.write_text(
    "import Foundation\nimport StoreKit\n" + helper + "\n"
    + "struct StoreKitUnfinishedProbe {\n" + unfinished_method + "\n}\n" + r'''
@main struct Check {
    static func main() {
        func kept(_ error: Error, unfinished: Bool) -> Bool {
            var savedIntent = true
            if WebsitePurchasePretransactionRecovery.isKnownNoCharge(error) && !unfinished {
                savedIntent = false
            }
            return savedIntent
        }
        precondition(!kept(StoreKitError.userCancelled, unfinished: false),
                     "thrown cancellation without transaction releases the intent for retry")
        precondition(!kept(Product.PurchaseError.purchaseNotAllowed, unfinished: false),
                     "purchase-not-allowed before transaction releases the intent")
        precondition(!kept(Product.PurchaseError.productUnavailable, unfinished: false),
                     "unavailable product before transaction releases the intent")
        precondition(kept(StoreKitError.userCancelled, unfinished: true),
                     "a possible unfinished website transaction retains the original property")
        precondition(kept(StoreKitError.unknown, unfinished: false),
                     "unknown StoreKit result may have charged and stays pinned")
        precondition(kept(StoreKitError.networkError(URLError(.networkConnectionLost)), unfinished: false),
                     "uncertain transport remains pinned")
        precondition(WebsitePurchasePretransactionRecovery.message(StoreKitError.userCancelled)
                     .contains("cancelled"), "cancellation copy is specific")
        print("PASS: 7 typed StoreKit pretransaction/recovery scenarios")
    }
}
'''
)
compile_cmd = ["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(work / "module-cache"),
               str(fixture), "-o", str(work / "check")]
environment = dict(os.environ, TMPDIR=str(work))
compiled = subprocess.run(compile_cmd, env=environment, text=True, capture_output=True)
assert compiled.returncode == 0, compiled.stdout + compiled.stderr
ran = subprocess.run([str(work / "check")], env=environment, text=True, capture_output=True)
assert ran.returncode == 0, ran.stdout + ran.stderr
assert "PASS: 7" in ran.stdout
receipt = {
    "passed": True,
    "source": str(source_path),
    "source_sha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
    "typed_storekit_scenarios": 7,
    "source_guards": 8,
    "scope": "No StoreKit purchase, server write, account, or phone; exact helper compiled with StoreKit, plus source-order checks for pending and fulfilment.",
    "limitations": "Does not replace TestFlight sandbox cancellation, pending approval, and server-assignment testing.",
}
(work / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(work / "receipt.json")
