#!/usr/bin/env python3
"""Actual owner-scoped Apple-code session methods; no Apple/Keychain/network."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "apps/ios/Rendprop/Auth/AuthStore.swift"
CALLER = ROOT / "apps/ios/Rendprop/Screens/RenderStatusView.swift"


def block(source, marker):
    assert source.count(marker) == 1, marker
    start = source.index(marker); opening = source.index("{", start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--inject-fault", choices=["drop-dispatch-fences", "drop-receipt-fences", "legacy-rebind", "drop-exchange-fence"])
    args = parser.parse_args()
    source = SOURCE.read_text()
    caller = CALLER.read_text()
    assert "let identity = try await AuthStore.shared.exchangeAppleIdentityToken" in caller
    assert "await AuthStore.submitAppleAuthorizationCode(authCode, for: identity)" in caller
    assert "guard identity.isCurrent else { isExchanging = false; return }" in caller
    markers = ["    struct AppleSessionIdentity:", "    private struct PendingAppleCode:",
               "    @MainActor static func submitAppleAuthorizationCode(", "    @MainActor private static func sendPendingAppleCode(",
               "    @MainActor static func retryPendingAppleAuthorizationCodeIfNeeded()", "    private func applySession(",
               "    static func jwtSubject(", "    nonisolated static func tokenIsIdentified(", "    private struct SupabaseSession:",
               "    func exchangeAppleIdentityToken("]
    methods = {marker: block(source, marker) for marker in markers}
    hashes = {marker: hashlib.sha256(body.encode()).hexdigest() for marker, body in methods.items()}
    expected = None
    if args.inject_fault == "drop-dispatch-fences":
        marker = "    @MainActor private static func sendPendingAppleCode("
        methods[marker] = methods[marker].replace("guard identity.isCurrent, jwtSubject(token) == identity.ownerID, tokenIsIdentified(token),", "guard true,")
        methods[marker] = methods[marker].replace("guard identity.isCurrent, (try? SecureStore.getChecked(key)) == encoded else { return }", "guard (try? SecureStore.getChecked(key)) == encoded else { return }")
        expected = "token-await account switch dispatches no former code"
    elif args.inject_fault == "drop-receipt-fences":
        marker = "    @MainActor private static func sendPendingAppleCode("
        needle = "              identity.isCurrent, (try? SecureStore.getChecked(key)) == encoded,"
        assert methods[marker].count(needle) == 1
        methods[marker] = methods[marker].replace(needle, "              identity.isCurrent,")
        expected = "late older success preserves newer same-owner pending record"
    elif args.inject_fault == "legacy-rebind":
        marker = "    @MainActor static func retryPendingAppleAuthorizationCodeIfNeeded()"
        needle = "        let identity = AppleSessionIdentity(ownerID: owner, sessionRevision: shared.syncSessionRevision)"
        assert methods[marker].count(needle) == 1
        methods[marker] = methods[marker].replace(needle, needle + "\n        if let legacy = SecureStore.get(Keys.pendingAppleAuthCode) { await submitAppleAuthorizationCode(legacy, for: identity) }")
        expected = "legacy unscoped code is preserved without transport"
    elif args.inject_fault == "drop-exchange-fence":
        marker = "    func exchangeAppleIdentityToken("
        needle = "        guard !Task.isCancelled, sessionEpoch == acceptedEpoch,\n              isSignedIn, isIdentified, let acceptedOwner, userID == acceptedOwner else { throw CancellationError() }"
        assert methods[marker].count(needle) == 1
        methods[marker] = methods[marker].replace(needle, "        guard let acceptedOwner else { throw CancellationError() }")
        expected = "exchange cannot return a sign-in receipt after replacement identity"
    fixture = Path(__file__).with_name("Fixture.swift.template").read_text().replace("__METHODS__", "\n".join(methods.values()))
    out = args.output_dir or Path(tempfile.mkdtemp(prefix="rendprop-apple-code-session-"))
    out.mkdir(parents=True, exist_ok=True)
    swift = out / "ActualAppleCodeSession.swift"; swift.write_text(fixture)
    receipt = {"sourceHashes": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [SOURCE, CALLER]},
               "actualMethodHashes": hashes, "compiledMethodHashes": {marker: hashlib.sha256(body.encode()).hexdigest() for marker, body in methods.items()},
               "fault": args.inject_fault, "AppleAPICalls": 0, "networkCalls": 0, "hostKeychainCalls": 0, "commands": []}
    for label, command in [("compile", ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(out / "checks")]),
                           ("run", [str(out / "checks")])]:
        result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        log = out / f"{label}.log"; log.write_text(result.stdout)
        receipt["commands"].append({"name": label, "exit": result.returncode, "log": str(log)})
        if label == "run":
            receipt["passed"] = result.returncode == 1 and expected in result.stdout if expected else result.returncode == 0
            receipt["expectedRejection"] = expected
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(label, result.returncode, result.stdout.strip(), flush=True)
        if (label == "compile" and result.returncode) or (label == "run" and not receipt["passed"]):
            print("Evidence:", out); raise SystemExit(1)
    print("Evidence:", out)


if __name__ == "__main__":
    main()
