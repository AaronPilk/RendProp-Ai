#!/usr/bin/env python3
"""Compile the mock receipt parser used by local StoreKit subscription tests."""

from pathlib import Path
import os
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[3]
SOURCE = (ROOT / "apps/ios/Rendprop/Purchases/PurchasesAPI.swift").read_text()


def braced(marker: str) -> str:
    start = SOURCE.index(marker)
    opening = SOURCE.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (SOURCE[end] == "{") - (SOURCE[end] == "}")
        end += 1
    return SOURCE[start:end]


methods = "\n".join([
    braced("fileprivate static func productID(inJWS jws: String) -> String? {"),
    braced("fileprivate static func originalTransactionID(inJWS jws: String) -> String? {"),
    braced("private static func payload(inJWS jws: String) -> [String: Any]? {"),
])
assert "let originalTransactionID = MockAPIClient.originalTransactionID(inJWS: signedTransaction)" in SOURCE
assert "originalTransactionId: originalTransactionID" in SOURCE
assert 'originalTransactionId: "mock-original-transaction"' not in SOURCE

work = Path(tempfile.mkdtemp(prefix="rendprop-storekit-mock-receipt-"))
fixture = work / "main.swift"
fixture.write_text(
    "import Foundation\nenum MockAPIClient {\n" + methods + "\n}\n"
    + '''
@main struct Check {
    static func signedLike(_ payload: [String: Any]) -> String {
        let bytes = try! JSONSerialization.data(withJSONObject: payload)
        let body = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\\(body).signature"
    }
    static func main() {
        let numeric = signedLike(["productId": "com.rendprop.app.pro.monthly",
                                  "originalTransactionId": 1000000123456789 as Int64])
        precondition(MockAPIClient.productID(inJWS: numeric) == "com.rendprop.app.pro.monthly")
        precondition(MockAPIClient.originalTransactionID(inJWS: numeric) == "1000000123456789")
        let string = signedLike(["productId": "com.rendprop.app.team.monthly",
                                 "originalTransactionId": "1000000987654321"])
        precondition(MockAPIClient.originalTransactionID(inJWS: string) == "1000000987654321")
        precondition(MockAPIClient.originalTransactionID(inJWS: signedLike(["productId": "x"])) == nil)
        precondition(MockAPIClient.productID(inJWS: "malformed") == nil)
        print("PASS: 5 numeric, string, and malformed local StoreKit receipt scenarios")
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
