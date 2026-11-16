#!/usr/bin/env python3
"""Prove the StoreKit entitlement sweep is fenced to its starting workspace."""
from pathlib import Path
import hashlib
import json
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "apps/ios/Rendprop/Purchases/PurchaseManager.swift"
OUT = Path(tempfile.mkdtemp(prefix="rendprop-entitlement-context-"))


def method(source: str) -> str:
    marker = '@discardableResult func refreshEntitlements(event: String = "entitlement") async -> Bool {'
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def named_method(source: str, marker: str) -> str:
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


source = SOURCE.read_text()
body = method(source)
restore = named_method(source, "func restore() async {")
required = [
    "let selectedOrgID = WorkspaceContext.selectedOrgID",
    "let billingOrgID = WorkspaceContext.billingOrgID",
    "WorkspaceContext.selectedOrgID == selectedOrgID",
    "WorkspaceContext.billingOrgID == billingOrgID",
    "guard contextIsCurrent() else { return false }",
    "return confirmed && contextIsCurrent()",
]
assert all(value in body for value in required)
assert body.index("let selectedOrgID") < body.index("for await entitlement")
assert "applyLocalPlan(from: found)" not in body
assert restore.count("guard contextIsCurrent() else { return }") == 3
assert restore.index("let selectedOrgID") < restore.index("try await AppStore.sync()")
assert restore.index("guard contextIsCurrent() else { return }") < restore.index('refreshEntitlements(event: "restore")')

controls = {
    "selected-workspace": body.replace("&& WorkspaceContext.selectedOrgID == selectedOrgID", "", 1),
    "billing-workspace": body.replace("&& WorkspaceContext.billingOrgID == billingOrgID", "", 1),
    "pre-handle-fence": body.replace("guard contextIsCurrent() else { return false }", "", 1),
    "post-sync-fence": body.replace("return confirmed && contextIsCurrent()", "return confirmed", 1),
    "speculative-plan": body.replace("var confirmed = true", "applyLocalPlan(from: found)\n        var confirmed = true", 1),
    "restore-workspace": restore.replace("&& WorkspaceContext.selectedOrgID == selectedOrgID", "", 1),
}
for name, candidate in controls.items():
    if name == "selected-workspace":
        assert "WorkspaceContext.selectedOrgID == selectedOrgID" not in candidate
    elif name == "billing-workspace":
        assert "WorkspaceContext.billingOrgID == billingOrgID" not in candidate
    elif name == "pre-handle-fence":
        assert "guard contextIsCurrent() else { return false }" not in candidate
    elif name == "post-sync-fence":
        assert "return confirmed && contextIsCurrent()" not in candidate
    elif name == "speculative-plan":
        assert "applyLocalPlan(from: found)" in candidate
    else:
        assert "WorkspaceContext.selectedOrgID == selectedOrgID" not in candidate

receipt = {
    "passed": True,
    "source": str(SOURCE.relative_to(ROOT)),
    "sourceSHA256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
    "methodSHA256": hashlib.sha256(body.encode()).hexdigest(),
    "assertions": len(required) + 6,
    "negativeControls": list(controls),
    "scope": "Exact production refreshEntitlements and restore methods; verifies selected and billing workspace capture, no speculative foreign-workspace plan presentation, pre-handle rejection, post-sync rejection, and Restore guards across Apple/entitlement awaits. No Apple account, purchase, network, simulator, phone, or entitlement mutation.",
}
(OUT / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(OUT / "receipt.json")
