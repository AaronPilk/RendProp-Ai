#!/usr/bin/env python3
"""Execute production refresh methods with a throwing/counting credential seam.

This is a focused native test, not an iOS Keychain/network end-to-end test.
"""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "apps/ios/Rendprop/Auth/AuthStore.swift"


def extract(text, name):
    start = text.index(f"func {name}(")
    opening = text.index("{", start)
    depth = 1
    for index in range(opening + 1, len(text)):
        if text[index] == "{": depth += 1
        if text[index] == "}": depth -= 1
        if not depth:
            return text[start:index + 1]
    raise AssertionError("missing production method")


HARNESS = '''
import Foundation
@MainActor enum Config { static var isUITesting=true; static var isSessionNetworkTesting=false; static var enableAuth=true }
@MainActor final class AuthCore {
 var isSignedIn=true; var signsOut=0; var refreshes=0
 static var reads=0; static var refresh:String?=nil; static var tokenExpiresAt:Date?=Date(timeIntervalSince1970:0)
 static func storedRefreshToken()->String? { reads += 1; return refresh }
 func signOut() { signsOut += 1; isSignedIn=false }
 func runRefresh() async -> Bool { refreshes += 1; return true }
 METHODS
}
@main struct Main {
 @MainActor static func main() async {
  var count=0
  func check(_ ok:Bool,_ message:String) { guard ok else { print("FAIL: " + message); exit(1) }; count += 1 }
  let offline=AuthCore()
  let passive=await offline.refreshIfNeeded(); let forced=await offline.forceRefresh()
  check(passive && forced,"offline walk may not lose its mock identity")
  check(AuthCore.reads==0,"offline walk read a real credential")
  check(offline.signsOut==0 && offline.refreshes==0,"offline walk invoked real auth lifecycle")
  Config.isSessionNetworkTesting=true
  let network=AuthCore(); let networkResult=await network.forceRefresh()
  check(!networkResult && network.signsOut==1,"real-network fixtures must not use the offline bypass")
  Config.isUITesting=false; Config.isSessionNetworkTesting=false; AuthCore.refresh="test-only-fixture"
  let production=AuthCore(); let productionResult=await production.refreshIfNeeded()
  check(productionResult && production.refreshes==1,"normal auth refresh stopped executing")
  Config.enableAuth=false; AuthCore.reads=0
  let disabled=AuthCore(); _=await disabled.forceRefresh()
  check(AuthCore.reads==0,"disabled auth touched credential storage")
  print("PASS: \\(count) production-method assertions")
 }
}
'''


def run(text, destination):
    destination.mkdir()
    harness = HARNESS.replace("METHODS", "\n".join(extract(text, n) for n in ("refreshIfNeeded", "forceRefresh")))
    swift = destination / "Harness.swift"; swift.write_text(harness)
    binary = destination / "check"
    compiled = subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift), "-o", str(binary)], capture_output=True, text=True)
    (destination / "compile.log").write_text(compiled.stdout + compiled.stderr)
    assert compiled.returncode == 0, "a compiler failure is not a valid behavioral negative control"
    result = subprocess.run([str(binary)], capture_output=True, text=True)
    (destination / "run.log").write_text(result.stdout + result.stderr)
    return result


def main():
    out = Path(tempfile.mkdtemp(prefix="rendprop-mock-auth-"))
    source = SOURCE.read_text()
    assert "if Config.enableAuth && !offlineWalk" in source
    assert "let hasToken = !offlineWalk && Self.storedAccessToken() != nil" in source
    for name in ("refreshIfNeeded", "forceRefresh", "scheduleAutoRefresh", "retryPendingAdoptionIfNeeded"):
        assert "guard !Config.isUITesting || Config.isSessionNetworkTesting" in extract(source, name)
    baseline = subprocess.check_output(["git", "show", "dc2ee7a:apps/ios/Rendprop/Auth/AuthStore.swift"], cwd=ROOT, text=True)
    before = run(baseline, out / "before")
    assert before.returncode == 1 and "offline walk" in before.stdout
    after = run(source, out / "after")
    assert after.returncode == 0 and "PASS: 6 production-method assertions" in after.stdout
    (out / "receipt.json").write_text(json.dumps({"accepted": True, "baseline_runtime_exit": before.returncode,
        "source_runtime_exit": after.returncode, "assertions": 6, "network_calls": 0, "full_keychain_runtime": False}, indent=2))
    print(f"PASS: native auth-isolation regression, old code failed; receipt {out / 'receipt.json'}")


if __name__ == "__main__": main()
