#!/usr/bin/env python3
"""Compile actual native policies against isolated files, Contacts and closed transport.
UI layout/image preparation remains covered by the simulator host, not these stubs.
"""
import argparse, fcntl, hashlib, json, pathlib, subprocess, tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
HERE = pathlib.Path(__file__).resolve().parent
S = ROOT / "apps/ios/Rendprop/Screens/SettingsView.swift"
L = ROOT / "apps/ios/Rendprop/Networking/LiveAPIClient.swift"
M = ROOT / "apps/ios/Rendprop/Networking/MockAPIClient.swift"

def block(source, anchor):
    start = source.index(anchor)
    opening = source.index("{", start)
    depth = 0
    for position in range(opening, len(source)):
        if source[position] == "{": depth += 1
        elif source[position] == "}":
            depth -= 1
            if depth == 0: return source[start:position + 1]
    raise AssertionError("Unclosed actual source: " + anchor)

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--fault", choices=["logo-late-context", "logo-old-draft", "portfolio-all-listings", "share-late-context", "share-unbound-workspace", "personal-inviter-brand", "personal-late-context", "personal-old-draft", "personal-broad-fields", "personal-untouched-adoption", "personal-erase-cache", "logo-stale-brand-read", "personal-erase-legacy", "logo-reload-stale-read"])
    args = parser.parse_args()
    out = pathlib.Path(args.out).resolve(); out.mkdir(parents=True, exist_ok=True)
    models = [ROOT / "apps/ios/Rendprop" / p for p in ["Models/ListingClientContact.swift", "Models/Listing.swift", "Models/Money.swift", "Networking/WorkspaceSync.swift", "Networking/NativeReelDraft.swift", "Voice/VoiceTypes.swift", "Workspace/WorkspaceContext.swift"]]
    inputs = models + [S, L, M, ROOT / "apps/ios/Rendprop/Networking/APIClient.swift", ROOT / "apps/ios/Rendprop/RendpropApp.swift", ROOT / "apps/ios/Rendprop/Purchases/PaywallView.swift", ROOT / "apps/ios/Rendprop/Screens/ClientContactView.swift", HERE / "run.py", HERE / "Fixture.swift.template"]
    hashes = {str(p.relative_to(ROOT)): digest(p) for p in inputs}
    source = S.read_text(); live = L.read_text(); mock = M.read_text()
    # Read actual sources into the compiler input once; no shared runtime edits.
    head = source[source.index("struct AgentCard {"):source.index("    static let fieldNames", source.index("struct AgentCard {"))]
    anchors = ["    static let fieldNames", "    static var personalPrefix:", "    static var personalReadVersion:", "    static var primaryTypeKey:", "    static var lastPushedKey:", "    static var cloudOwnerKey:", "    @MainActor static func acceptCloud", "    static func migrateLegacyIfNeeded", "    static var primaryBrandType:", "    static func key(_ field: String, for type:", "    static func key(_ field: String)", "    static func card(for type:", "    static var current: AgentCard", "    var brandFields:", "    var instagramURL:", "    var tiktokURL:", "    var linkedinURL:", "    private static func socialURL", "    private static func looksLikeHost", "    static func headshotURL(for type:", "    static var headshotURL:", "    var resolvedHeadshotURL:", "    var headshotBase64:", "    var resolvedBusinessLogoURL:", "    var businessLogoBase64:", "    var websiteURL:", "    var isSet:", "    var initials:"]
    card = head
    for anchor in anchors:
        if anchor == "    static let fieldNames": card += source[source.index(anchor):source.index("\n", source.index(anchor))] + "\n"
        else: card += block(source, anchor) + "\n"
    card += "}\n"
    policies = "\n".join(block(source, a) for a in ["private enum PersonalCardError", "private struct PersonalCardDraft", "private enum PersonalCardStore", "private enum ProfileLogoError", "private struct ProfileLogoDraft", "private enum ProfileLogoStore", "private enum ProfileLogoCommit", "private struct ProfileShareContext", "private struct ProfileShareSnapshot", "enum BusinessCardExporter"])
    portfolio = block(source, "enum PortfolioExporter")
    photo = block(portfolio, "    private static func photoBase64")
    portfolio = portfolio.replace(photo, "    private static func photoBase64(_ url: URL) -> String? { nil }")
    app = ROOT / "apps/ios/Rendprop/RendpropApp.swift"
    bindings = "@MainActor final class AppModel { var listings: [Listing] = []\n" + block(app.read_text(), "    func isInSelectedWorkspace") + "\n}\n"
    receipt = "\n".join(block((ROOT / "apps/ios/Rendprop/Networking/APIClient.swift").read_text(), a) for a in ["struct BusinessLogoReceipt"])
    live_methods = "\n".join(block(live, a) for a in ["    @MainActor func uploadBusinessLogo", "    @MainActor func removeBusinessLogo", "    @MainActor func businessLogo", "    @MainActor func personalCard", "    @MainActor func savePersonalCard"])
    mock_fields = mock[mock.index("    private var businessLogos:"):mock.index("    func uploadBusinessLogo")]
    mock_fields += mock[mock.index("    private var personalCards:"):mock.index("    func personalCard()")]
    mock_methods = "\n".join(block(mock, a) for a in ["    func uploadBusinessLogo", "    func removeBusinessLogo", "    func businessLogo", "    func personalCard", "    func savePersonalCard"])
    generated = "\n".join([receipt, card, policies, portfolio, bindings]) + "\nactor ClosedMock {\n" + mock_fields + mock_methods + "\n}\n" + "@MainActor final class ClosedLive {\n" + live_methods + "\n" + (HERE / "Fixture.swift.template").read_text().split("// LIVE SUPPORT\n")[1].split("// END LIVE SUPPORT")[0] + "\n}\n"
    # Compile the actual UI action against a closed model. Only preview refresh
    # and error presentation are inert; request/context/pointer/draft behavior
    # comes from the production action and actual Live method above.
    reload_logo = block(source, "    @MainActor private func reloadLogo").replace("private func", "func", 1)
    generated += """
@MainActor private final class ClosedLogoEditor {
    struct Model { let api: ClosedLive }
    let model: Model
    let editingContext = ProfileShareContext.current
    let editingWorkspace = WorkspaceContext.storagePrefix
    var savingLogo = false
    var logoError: String?
    var previews = 0
    var contextIsCurrent: Bool { editingContext == .current && editingWorkspace == WorkspaceContext.storagePrefix }
    init(api: ClosedLive) { model = Model(api: api) }
    func refreshLogoPreview() { previews += 1 }
""" + reload_logo + "\n}\n"
    expected_failure = None
    if args.fault == "logo-late-context":
        old = "        try check()\n        guard receipt.ok"
        assert generated.count(old) == 1
        generated = generated.replace(old, "        // altered-source late fence omitted\n        guard receipt.ok")
        expected_failure = "Logo held reply rejects changed context"
    elif args.fault == "logo-old-draft":
        old = "        guard try pending(prefix: prefix, defaults: defaults) == draft else { throw ProfileLogoError.changed }"
        assert generated.count(old) == 1
        generated = generated.replace(old, "        // altered-source exact pending record comparison omitted")
        expected_failure = "Older upload cannot erase a newer pending logo"
    elif args.fault == "portfolio-all-listings":
        old = "eligible(listings, type: type).filter { ids.contains($0.id) }"
        assert generated.count(old) == 1
        generated = generated.replace(old, "eligible(listings, type: type)")
        expected_failure = "Explicit selection returns only requested published houses"
    elif args.fault == "share-late-context":
        old = "guard context == .current, !Config.useLiveBackend || context.org != nil,"
        assert generated.count(old) == 1
        generated = generated.replace(old, "guard !Config.useLiveBackend || context.org != nil,")
        expected_failure = "Completed card cannot cross a session revision"
    elif args.fault == "share-unbound-workspace":
        old = "&& (!Config.useLiveBackend || $0.serverOrgID == context.org)"
        assert generated.count(old) == 1
        generated = generated.replace(old, "")
        expected_failure = "Unbound published house cannot accompany selected workspace card"
    elif args.fault == "personal-inviter-brand":
        old = '        if let personal = brand.personalCard, personal.userID == brand.userID,'
        assert generated.count(old) == 1
        generated = generated.replace(old, '        if let inviter = brand.fields["name"] { defaults.set(inviter, forKey: key("name", for: type)) }\n' + old)
        expected_failure = "Accepting team workspace never replaces personal Profile with inviter card"
    elif args.fault == "personal-late-context":
        old = "        let receipt = try await save(draft)\n        guard isCurrent() else { throw PersonalCardError.changed }"
        assert generated.count(old) == 1
        generated = generated.replace(old, "        let receipt = try await save(draft)\n        // altered-source late context fence omitted")
        expected_failure = "Personal save held reply rejects changed account/session"
    elif args.fault == "personal-old-draft":
        old = "        guard try pending(owner: draft.owner, defaults: defaults) == draft else { throw PersonalCardError.changed }"
        assert generated.count(old) == 1
        generated = generated.replace(old, "        // altered-source exact personal pending record omitted")
        expected_failure = "Old personal save cannot erase newer pending edit"
    elif args.fault == "personal-broad-fields":
        old = "fields.filter { key, value in (expected.publicCard?[key] ?? \"\") != value }"
        assert generated.count(old) == 1
        generated = generated.replace(old, "fields")
        expected_failure = "Disjoint personal Save merges a newer untouched phone"
    elif args.fault == "personal-untouched-adoption":
        old = '                defaults.set(receipt.publicCard?[key] ?? "", forKey: AgentCard.key(key, for: type))'
        assert generated.count(old) == 1
        generated = generated.replace(old, '                // altered-source untouched receipt adoption omitted')
        expected_failure = "Disjoint personal receipt adopts newer untouched phone"
    elif args.fault == "personal-erase-cache":
        old = '            if privateCardKey { defaults.removeObject(forKey: key) }'
        method = block(generated, '    static func eraseDeviceCache')
        assert method.count(old) == 1
        generated = generated.replace(method, method.replace(old, '            // altered-source phone erase omitted'))
        expected_failure = "Phone erase removes all account personal contact caches and drafts"
    elif args.fault == "logo-stale-brand-read":
        old = '        if personalReadVersion == nil || personalReadVersion == Self.personalReadVersion {\n            ProfileLogoStore.acceptHostedURL'
        assert generated.count(old) == 1
        generated = generated.replace(old, '        if true {\n            ProfileLogoStore.acceptHostedURL')
        expected_failure = "Hosted brand read begun before logo Save cannot erase acknowledged logo"
    elif args.fault == "personal-erase-legacy":
        method = block(generated, '    static func eraseDeviceCache')
        generated = generated.replace(method, '''    static func eraseDeviceCache(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("personal.card.v1.") { defaults.removeObject(forKey: key) }
    }''')
        expected_failure = "Phone erase cannot resurrect contact through legacy migration"
    elif args.fault == "logo-reload-stale-read":
        old = "            ProfileLogoStore.invalidateBrandReads(owner: editingContext.owner)"
        assert generated.count(old) == 1
        generated = generated.replace(old, "            // altered-source explicit logo Reload invalidation omitted")
        expected_failure = "Hosted brand read begun before explicit logo Reload cannot replace refreshed logo"
    # Bound UI composition checks complement compiled policy checks.
    paywall = (ROOT / "apps/ios/Rendprop/Purchases/PaywallView.swift").read_text()
    assert "PersonalCardStore.eraseDeviceCache(defaults: d)" in block(source, "    private func wipeLocalData")
    assert ".safeAreaInset(edge: .bottom)" in block(source, "struct AgentCardEditorView")
    assert ".accessibilityIdentifier(\"profile.save\")" in block(source, "struct AgentCardEditorView")
    assert "SelectedPlanDetails(plan: selectedPlan" in paywall
    compact = block(paywall, "private struct PlanCardBody")
    assert "plan.benefits" not in compact and "plan.billingNote" not in compact
    assert "plan.benefits" in block(paywall, "private struct SelectedPlanDetails")
    assert "ClientContactError.changed.localizedDescription" in (ROOT / "apps/ios/Rendprop/Screens/ClientContactView.swift").read_text()
    fixture = (HERE / "Fixture.swift.template").read_text().split("// FIXTURE START\n")[1]
    with tempfile.TemporaryDirectory(prefix="rendprop-profile-policy-") as temporary:
        temporary = pathlib.Path(temporary)
        swift = temporary / "ProfileProof.swift"
        swift.write_text("import Foundation\nimport Contacts\n" + generated + "\n" + fixture)
        executable = temporary / "proof"
        compiler = subprocess.run(["xcrun", "swiftc", "-parse-as-library", *map(str, models), str(swift), "-o", str(executable)], capture_output=True, text=True)
        (out / "compiler.log").write_text(compiler.stdout + compiler.stderr)
        # Actual WorkspaceContext/AgentCard read this executable's standard
        # preferences. Serialize only execution so parallel controls cannot
        # change another proof's synthetic selection while it is awaiting.
        with (pathlib.Path(tempfile.gettempdir()) / "rendprop-profile-policy.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = subprocess.run([str(executable)], capture_output=True, text=True) if compiler.returncode == 0 else None
        log = (result.stdout + result.stderr) if result else "not executed"
        (out / "actual.log").write_text(log)
        mismatches = [name for name, value in hashes.items() if digest(ROOT / name) != value]
        passed = compiler.returncode == 0 and result is not None and not mismatches and (result.returncode == 0 if not args.fault else result.returncode != 0 and expected_failure in log)
        count_line = next((line for line in log.splitlines() if line.startswith("PROFILE_ASSERTIONS=")), None)
        receipt_value = {"passed": passed, "fault": args.fault, "expectedFailure": expected_failure, "compilerExit": compiler.returncode, "executableExit": result.returncode if result else None, "assertions": int(count_line.split("=")[1]) if count_line else None, "sourceSHA256": hashes, "sourceBoundAtEnd": not mismatches, "sourceMismatches": mismatches, "generatedSHA256": digest(swift), "transport": "closed in-memory; no network, credentials, Photos access or contact-store writes", "limits": "Policy slices use actual production Listing and Contacts parser. UIKit image resizing, SwiftUI layout and OS share UI require simulator proof; this fixture does not certify camera/physical behavior."}
        (out / "receipt.json").write_text(json.dumps(receipt_value, indent=2) + "\n")
        print(json.dumps({k:receipt_value[k] for k in ["passed", "fault", "assertions", "sourceBoundAtEnd"]}))
        if not passed:
            print((compiler.stdout + compiler.stderr + log)[-6000:])
            raise SystemExit(1)

if __name__ == "__main__": main()
