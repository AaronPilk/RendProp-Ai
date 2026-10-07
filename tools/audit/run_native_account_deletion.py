#!/usr/bin/env python3
"""Compile actual native deletion admission/completion with suspended doubles.

No network, real Auth/Keychain, upload cancellation, or customer-file erasure.
SwiftUI lifecycle wiring is source checked; actual Foundation methods execute.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def require(value, message):
    if not value:
        raise RuntimeError(message)


def block(source, anchor):
    require(source.count(anchor) == 1, "Expected one source anchor: " + anchor)
    start = source.index(anchor)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    root = Path(__file__).resolve().parents[2]
    settings = root / "apps/ios/Rendprop/Screens/SettingsView.swift"
    auth = root / "apps/ios/Rendprop/Auth/AuthStore.swift"
    fixture = root / "tests/phase1/AccountDeletionContextTests.swift"
    inputs = [settings, auth, fixture, Path(__file__).resolve()]
    hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    source = settings.read_text()
    require("@State private var accountDeletionContext: AccountDeletionContext?" in source,
            "Confirmation must retain its captured account context")
    for label, action in [("Delete", 'Button("Delete", role: .destructive)'), ("Retry", 'Button("Retry")')]:
        require('let context = accountDeletionContext\n            ' + action + ' { scheduleAccountDeletion(context: context) }' in source,
                label + " must bind immutable confirmation before scheduling its Task")
    for anchor in [".onChange(of: auth.userID)", ".onChange(of: auth.syncSessionRevision)",
                   ".onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged))"]:
        start = source.index(anchor)
        wiring = source[start:source.index("}", start)]
        require("accountDeletionContext = nil; showDeleteConfirm = false; showDeleteError = false" in wiring,
                "Account/workspace/session changes must close stale confirmation and Retry: " + anchor)
    bodies = {
        "__JWT_SUBJECT__": block(auth.read_text(), "    static func jwtSubject("),
        "__ERROR__": block(source, "    private struct AccountDeleteError:"),
        "__CONTEXT__": block(source, "    private struct AccountDeletionContext {"),
        "__CONTEXT_ERROR__": block(source, "    private enum AccountDeletionContextError:"),
        "__RESPONSE__": block(source, "    private struct ServerDeleteResponse:"),
        "__REQUEST__": block(source, "    @MainActor private func requestServerAccountDeletion("),
        "__TAPPED__": block(source, "    private func deleteTapped()"),
        "__SCHEDULE__": block(source, "    @MainActor\n    @discardableResult private func scheduleAccountDeletion("),
        "__DELETE__": block(source, "    @MainActor\n    private func deleteAccount("),
    }
    template = fixture.read_text()
    generated = template
    for name, body in bodies.items():
        require(template.count(name) == 1, "Fixture must insert exact source once: " + name)
        generated = generated.replace(name, body.replace("private ", ""))
    predicate = "signedIn && self.owner == owner && self.revision == revision"
    token_guard = """        guard context.matches(owner: auth.userID, revision: auth.syncSessionRevision, signedIn: auth.isSignedIn) else {
            throw AccountDeletionContextError.changedBeforeDispatch
        }"""
    request = bodies["__REQUEST__"].replace("private ", "")
    require(request.count(token_guard) == 2, "Both initial and post-token session guards must remain exact")
    late_guard = """        if !context.matches(owner: auth.userID, revision: auth.syncSessionRevision, signedIn: auth.isSignedIn) {
            let confirmed = (200..<300).contains(status)
                && (try? JSONDecoder().decode(ServerDeleteResponse.self, from: data))?.ok == true
            throw AccountDeletionContextError.changedAfterDispatch(deletionConfirmed: confirmed)
        }"""
    final_guard = "        guard !serverAccountsEnabled || context?.matches(owner: auth.userID, revision: auth.syncSessionRevision, signedIn: auth.isSignedIn) == true else { return }"
    require(generated.count(late_guard) == 1 and generated.count(final_guard) == 1,
            "Response and final local cleanup must retain separate admission guards")
    # Removing only the post-refresh session guard still has a subject guard;
    # A→B→A proves the revision gate without requiring a mismatched token.
    first = request.index(token_guard)
    second = request.index(token_guard, first + len(token_guard))
    no_token_guard = request[:second] + request[second:].replace(token_guard, "        // synthetic removed post-token session guard", 1)
    controls = [
        ("drop-actor", generated.replace(predicate, "signedIn && self.revision == revision", 1), "Deletion context requires original actor"),
        ("drop-revision", generated.replace(predicate, "signedIn && self.owner == owner", 1), "Deletion context requires original revision"),
        ("drop-signed-in", generated.replace(predicate, "self.owner == owner && self.revision == revision", 1), "Deletion context requires signed-in session"),
        ("retarget-queued-confirmation", generated.replace("Task { await deleteAccount(context: context) }", "Task { await deleteAccount(context: accountDeletionContext) }", 1), "Queued confirmation cannot retarget deletion"),
        ("drop-post-token-context", generated.replace(request, no_token_guard, 1), "Changed token session cannot dispatch deletion"),
        ("drop-token-subject", generated.replace("guard AuthStore.jwtSubject(token) == context.owner else", "guard true else", 1), "Wrong or unverified JWT subject cannot dispatch deletion"),
        ("drop-response-context", generated.replace(late_guard, "        // synthetic removed response context guard", 1), "Stale response preserves confirmed prior-account deletion fact"),
        ("drop-response-and-cleanup-context", generated.replace(late_guard, "        // synthetic removed response context guard", 1).replace(final_guard, "        // synthetic removed cleanup context guard", 1), "Late deletion response preserves replacement files"),
    ]
    args.out.mkdir(parents=True, exist_ok=False)
    receipt = {"schema": "rendprop-native-account-deletion-controls-v1", "accepted": False,
               "sourceHashes": hashes, "actualBodyHashes": {k: hashlib.sha256(v.encode()).hexdigest() for k, v in bodies.items()},
               "networkCalls": 0, "realAuthCalls": 0, "customerFilesTouched": 0, "cameraCalls": 0,
               "sourceWiringChecks": 6, "runs": [],
               "limits": ["Foundation doubles replace token refresh and URLSession; no real account/network action",
                          "wipeLocalData and upload cancellation are spies; actual call-site admission runs",
                          "SwiftUI context invalidation is source checked; physical phone behavior remains untested"]}
    try:
        for name, text, expected in [("actual", generated, None)] + controls:
            require(name == "actual" or text != generated, "Missing mutation anchor: " + name)
            swift = args.out / (name + ".swift"); swift.write_text(text)
            binary = args.out / name
            run = {"name": name, "expectedRejection": expected, "compiledBodySHA256": hashlib.sha256(text.encode()).hexdigest(), "commands": []}
            receipt["runs"].append(run)
            for label, argv, timeout in [
                ("compile", ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(swift), "-o", str(binary)], 120),
                ("run", [str(binary)], 30),
            ]:
                completed = subprocess.run(argv, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
                log = args.out / (name + "-" + label + ".log"); log.write_text(completed.stdout)
                run["commands"].append({"name": label, "exitCode": completed.returncode,
                                        "log": {"path": str(log), "sha256": hashlib.sha256(log.read_bytes()).hexdigest()}})
                require(completed.returncode == 0 if label == "compile" or expected is None else
                        completed.returncode == 1 and "FAIL " + expected in completed.stdout,
                        "Unexpected compiled behavior: " + name + " " + label)
                if label == "run" and expected is None:
                    match = re.search(r"PASS AccountDeletionContextTests (\d+) checks", completed.stdout)
                    require(match, "Actual runtime assertion count absent")
                    receipt["positiveChecks"] = int(match.group(1))
            print(name + ": " + ("passed" if expected is None else "guard removal rejected"), flush=True)
        require(all(hashlib.sha256((root / name).read_bytes()).hexdigest() == value for name, value in hashes.items()),
                "Source changed during compiled proof")
        receipt["compiledNegativeControls"] = len(controls)
        receipt["accepted"] = True
    finally:
        (args.out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("Evidence:", args.out, flush=True)


if __name__ == "__main__":
    main()
