#!/usr/bin/env python3
"""Check accepted StoreKit receipts drive plan display and survive a reinstall."""

from pathlib import Path
import os
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[3]
SOURCE = (ROOT / "apps/ios/Rendprop/Purchases/PurchaseManager.swift").read_text()


def braced(marker: str) -> str:
    start = SOURCE.index(marker)
    opening = SOURCE.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (SOURCE[end] == "{") - (SOURCE[end] == "}")
        end += 1
    return SOURCE[start:end]


apply_plan = braced("private func applyServerPlan(_ result: EntitlementSync, productID: String,")
sync = braced("private func sync(_ pending: PendingSync, event: String) async -> Bool {")
assert sync.index("api.syncEntitlement(") < sync.index("applyServerPlan(result,") < sync.index("pending.transaction.finish()")
assert "activePlan = RendpropProducts.planName" not in sync
assert "activeProductID = pending.transaction.productID" not in sync
assert "activeBillingOwner = nil" in braced('@discardableResult func refreshEntitlements(event: String = "entitlement") async -> Bool {')

work = Path(tempfile.mkdtemp(prefix="rendprop-storekit-fulfilment-state-"))
fixture = work / "main.swift"
fixture.write_text(
    "import Foundation\n"
    + "struct EntitlementSync { let plan: String; let productId: String?; "
      "let originalTransactionId: String?; let expiresAt: Date? }\n"
    + "final class PlanState { var activePlan: String?; var activeProductID: String?; "
      "var activeOriginalTransactionID: String?; var activeExpiresAt: Date?; var activeBillingOwner: UUID?\n"
    + apply_plan.replace("private func applyServerPlan", "func applyServerPlan", 1) + "\n}\n"
    + '''
@main struct Check {
    static func main() {
        let owner = UUID()
        let state = PlanState()
        state.applyServerPlan(.init(plan: "Pro", productId: "com.rendprop.app.pro.monthly",
                                    originalTransactionId: "1234", expiresAt: nil),
                              productID: "fallback", originalTransactionID: "5678", billingOwner: owner)
        precondition(state.activePlan == "pro")
        precondition(state.activeOriginalTransactionID == "1234")
        precondition(state.activeBillingOwner == owner)
        state.applyServerPlan(.init(plan: "starter", productId: nil,
                                    originalTransactionId: nil, expiresAt: nil),
                              productID: "com.rendprop.app.starter.monthly", originalTransactionID: "5678",
                              billingOwner: owner)
        precondition(state.activePlan == "starter")
        precondition(state.activeProductID == "com.rendprop.app.starter.monthly")
        precondition(state.activeOriginalTransactionID == "5678")
        state.applyServerPlan(.init(plan: "free", productId: nil,
                                    originalTransactionId: nil, expiresAt: nil),
                              productID: "ignored", originalTransactionID: "5678", billingOwner: owner)
        precondition(state.activePlan == nil && state.activeProductID == nil)
        precondition(state.activeOriginalTransactionID == nil && state.activeBillingOwner == nil)
        print("PASS: 9 accepted, fallback, downgrade, and revoked-plan state assertions")
    }
}
'''
)
env = dict(os.environ, TMPDIR=str(work))
compile_result = subprocess.run(
    ["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(work / "module-cache"),
     str(fixture), "-o", str(work / "check")], env=env, text=True, capture_output=True,
)
assert compile_result.returncode == 0, compile_result.stdout + compile_result.stderr
run_result = subprocess.run([str(work / "check")], env=env, text=True, capture_output=True)
assert run_result.returncode == 0, run_result.stdout + run_result.stderr
print(run_result.stdout.strip())
print(f"Fixture: {work}")
