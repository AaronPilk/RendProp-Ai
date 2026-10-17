#!/usr/bin/env python3
"""Compile actual local account/session admission; no Apple, Keychain or network."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
AUTH = ROOT / "apps/ios/Rendprop/Auth/AuthStore.swift"
APP = ROOT / "apps/ios/Rendprop/RendpropApp.swift"
CONFIG = ROOT / "apps/ios/Rendprop/Config.swift"
SIGNIN = ROOT / "apps/ios/Rendprop/Screens/RenderStatusView.swift"
ROUTES = ROOT / "apps/ios/Rendprop/DeepLink/DeepLink.swift"
ONBOARDING = ROOT / "apps/ios/Rendprop/Screens/OnboardingView.swift"


def block(source, marker):
    assert source.count(marker) == 1, marker
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    output = args.output_dir or Path(tempfile.mkdtemp(prefix="rendprop-required-account-"))
    output.mkdir(parents=True, exist_ok=True)
    texts = {path: path.read_text() for path in (AUTH, APP, CONFIG, SIGNIN, ROUTES, ONBOARDING)}
    auth, app, config, signin, routes, onboarding = (texts[p] for p in (AUTH, APP, CONFIG, SIGNIN, ROUTES, ONBOARDING))

    # Real view/modifier wiring is checked alongside the compiled policy.
    account_view = block(app, "    @ViewBuilder private var accountContent:")
    assert "if accountReady" in account_view and "businessContent.paywallHost()" in account_view
    assert "RequiredAccountGate()" in account_view
    assert "signInAnonymouslyIfNeeded()" not in app
    assert 'appendingPathComponent("signup")' not in auth
    assert "mayPresentIncomingRoutes ? incomingLink : nil" in app
    assert "mayPresentIncomingRoutes ? rootSheet : nil" in app
    assert "mayPresentIncomingRoutes && incomingLinkError" in app
    assert "let canPresent = mayPresentIncomingRoutes &&" in app
    assert app.count("PaywallRouter.shared.dismiss()") >= 2
    assert "if !requiresAccount {" in signin and 'Button("Not now")' in signin
    assert ".interactiveDismissDisabled(requiresAccount || isExchanging)" in signin
    assert "if !requiresAccount { dismiss() }" in signin
    assert "submitAppleAuthorizationCode(authCode, for: identity)" in signin
    assert "guard identity.isCurrent" in signin
    assert 'Link("Terms", destination: URL(string: "https://rendprop.com/terms")!)' in signin
    assert 'Link("Privacy", destination: URL(string: "https://rendprop.com/privacy")!)' in signin
    assert 'Link("Get help", destination: SettingsView.supportMailURL(subject: "Rendprop account help"))' in signin
    assert "#if DEBUG && targetEnvironment(simulator)" in block(config, "    static var isSessionNetworkTesting:")
    assert "#if targetEnvironment(simulator)" in block(config, "    static var isUITesting:")
    assert "Config.isOfflineAccountFixture" in app
    assert "ProfileFeedbackFixtureHost.isRequested" in app and "DetailMetadataRegressionHost.requestedCase" in app

    markers = ["    init()", "    private static func cachedSessionOwner(",
               "    nonisolated private static func tokenPayload(", "    nonisolated private static func tokenIdentityClaimIsValid(",
               "    nonisolated private static func jwtExpiry(", "    nonisolated static func tokenIsIdentified(",
               "    static func jwtSubject(", "    @MainActor private func validatedCurrentAccessToken(",
               "    func signInAnonymouslyIfNeeded()", "    func ensureSession()", "    private func establishSession()",
               "    func signOut(", "    private func applySession(", "    private func performRefresh()", "    private struct SupabaseSession:"]
    methods = "\n".join(block(auth, marker) for marker in markers)
    fixture = Path(__file__).with_name("Fixture.swift.template").read_text()
    actual = fixture.replace("__AUTH_METHODS__", methods).replace("__ADMISSION__", block(app, "enum NativeAccountLaunchAdmission"))
    actual = actual.replace("__QUEUE__", block(routes, "enum NativeIncomingRoute") + "\n" + block(routes, "struct NativeIncomingQueue"))
    actual = actual.replace("__REQUIRED_SIGNIN__", block(signin, "    static func requiredAccount()"))
    actual = actual.replace("__ONBOARDING_FINISH__", block(onboarding, "    private func finish(showPlans:"))
    actual = actual.replace("__REFRESH_IF_NEEDED__", block(auth, "    func refreshIfNeeded("))
    fixture_config = "\n".join(block(config, marker) for marker in ["    static var isSessionNetworkTesting:", "    static var isUITesting:", "    static var isOfflineAccountFixture:"])
    actual = actual.replace("__REAL_CONFIG__", fixture_config)
    mutations = [
        ("guest-entry", "signedIn && identified && actorID.flatMap(UUID.init(uuidString:)) != nil", "signedIn && actorID.flatMap(UUID.init(uuidString:)) != nil", "Legacy guest cannot enter business onboarding or Home"),
        ("route-bypass", "accountReady && hasOnboarded", "hasOnboarded", "Onboarding preference cannot bypass the account gate"),
        ("confirmation-dismiss", "requiresAccount: true", "requiresAccount: false", "Required sign-in has no dismiss mode"),
        ("signed-out-retry", "guard isSignedIn else { return false }", "guard true else { return false }", "Fresh signed-out actions do not enter a retry loop"),
        ("typed-identity", "return CFGetTypeID(claim as CFTypeRef) == CFBooleanGetTypeID()", "return true", "Wrong-typed anonymous claim cannot unlock the account"),
        ("forced-discard", "if !preservingAdoption { discardPendingAdoption() }", "discardPendingAdoption()", "Forced invalidation preserves guest adoption evidence"),
        ("refresh-owner", "Self.jwtSubject(session.accessToken) == userID,", "true,", "Foreign refresh cannot replace account or cached files"),
        ("remote-expiry", "let expiry = Self.jwtExpiry(token), expiry > Date()", "let expiry = Self.jwtExpiry(token), expiry > Date(timeIntervalSince1970: 0)", "Offline admission never sends an expired credential"),
        ("cache-refresh-chronology", "UserDefaults.standard.set(min(expiry, Self.tokenExpiresAt ?? expiry).timeIntervalSince1970, forKey: Keys.expiresAt)", "// cached JWT scheduling fence omitted", "Expired cached JWT refreshes despite future remembered metadata"),
        ("cache-owner-metadata", "if let cachedOwner { UserDefaults.standard.set(cachedOwner, forKey: Keys.userID) }", "// accepted cache owner metadata omitted", "Cached account does not detach itself on same-owner refresh"),
        ("onboarding-late-completion", "guard NativeAccountLaunchAdmission.allows(signedIn: AuthStore.shared.isSignedIn,\n            identified: AuthStore.shared.isIdentified, actorID: AuthStore.shared.userID,\n            offlineFixture: Config.isOfflineAccountFixture) else { return }", "// late completion account fence omitted", "Stale onboarding completion cannot save preferences or present purchases"),
        ("physical-fixture", "#if targetEnvironment(simulator)", "#if true", "Nonsimulator compiled configuration cannot trust UI login flags"),
    ]
    receipt = {"accepted": False, "networkCalls": 0, "AppleCalls": 0, "hostKeychainCalls": 0,
               "sourceHashes": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in texts},
               "actualMethodHashes": {marker: hashlib.sha256(block(auth, marker).encode()).hexdigest() for marker in markers},
               "results": [], "runtimeScope": "Actual session/cache/refresh/signout methods and account/route policy, inert credential storage and transport. View wiring is source checked; no device UI or Apple credential exchange is simulated."}
    for name, source, expected in [("actual", actual, None)] + [(name, actual.replace(old, new), expected) for name, old, new, expected in mutations]:
        if expected:
            old = next(row[1] for row in mutations if row[0] == name)
            assert actual.count(old) == 1, name
            assert source != actual
        directory = output / name
        directory.mkdir()
        swift, binary = directory / "ActualAccountAdmission.swift", directory / "checks"
        swift.write_text(source)
        row = {"name": name, "expectedRejection": expected, "sourceSHA256": hashlib.sha256(source.encode()).hexdigest(), "commands": []}
        receipt["results"].append(row)
        for label, argv, timeout in [("compile", ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-D", "DEBUG", "-parse-as-library", str(swift), "-o", str(binary)], 120), ("run", [str(binary), "-uiTesting"], 15)]:
            log = directory / (label + ".log")
            with log.open("w") as stream:
                result = subprocess.run(argv, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
            text = log.read_text()
            row["commands"].append({"name": label, "argv": argv, "exit": result.returncode, "log": str(log), "sha256": hashlib.sha256(log.read_bytes()).hexdigest()})
            (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
            valid = result.returncode == (1 if label == "run" and expected else 0)
            if label == "run":
                valid = valid and (expected in text if expected else "PASS:" in text)
            assert valid, f"{name} {label}: {text}"
        print(name, row["commands"][-1]["exit"], flush=True)
    receipt["accepted"] = True
    receipt["compiledNegativeControls"] = len(mutations)
    receipt["checks"] = int((output / "actual/run.log").read_text().split("PASS: ")[1].split(" ")[0])
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("Evidence:", output, flush=True)


if __name__ == "__main__":
    main()
