#!/usr/bin/env python3
"""Compile actual upload implementations, execute isolated Swift regression,
and require successfully compiled broken implementations to fail assertions.
No real API, media, simulator, app container, uploads, or Apple operations.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    out = Path(tempfile.mkdtemp(prefix="rendprop-upload-recovery-", dir="/tmp"))
    api = root / "apps/ios/Rendprop/Networking/APIClient.swift"
    source = api.read_text()
    # Extract these existing top-level declarations verbatim, not a simplified
    # rewrite. Everything around them is unrelated real-estate/UI domain code.
    models = out / "ActualUploadModels.swift"
    start = source.index("struct UploadTicket:")
    end = source.index("/// The org's plan", start)
    error_start = source.index("enum APIError:")
    error_end = source.index("// MARK: - Admin console models", error_start)
    models.write_text("import Foundation\n" + source[start:end] + source[error_start:error_end])
    upload = root / "apps/ios/Rendprop/Upload"
    files = [models, upload / "UploadRecovery.swift", upload / "DirectUploader.swift",
             upload / "DirectUploadJournal.swift", upload / "UploadManager.swift", upload / "UploadStore.swift",
             root / "tests/phase1/UploadRecoveryDependencies.swift", root / "tests/phase1/UploadRecoveryTests.swift"]
    receipt = {"accepted": False, "commands": [], "sourceHashes": {
        str(p.relative_to(root) if p.is_relative_to(root) else p.name): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in [api, *files]}, "network": "injected fixture operations only", "sourceRoot": str(root)}
    print("EVIDENCE:", out, flush=True)

    def run(name, command, expected=0):
        result = subprocess.run(list(map(str, command)), cwd=root, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        log = out / (name + ".log")
        log.write_text(result.stdout)
        receipt["commands"].append({"name": name, "exit": result.returncode, "command": list(map(str, command)), "log": str(log)})
        assert (result.returncode == 0) == (expected == 0), f"{name}: unexpected exit {result.returncode}, {log}"
        print(f"{name}: exit={result.returncode}", flush=True)
        return result.stdout

    try:
        # Source presence before every native build. No silent no-op patch can
        # turn into a green baseline build and masquerade as a recovery proof.
        assert "enum UploadRecovery" in files[1].read_text()
        assert "reconcileTicket(expectedAssetID:" in files[4].read_text()
        assert "reticketSingle" not in files[4].read_text()
        assert "self.api.renewUpload(assetID: id)" in files[4].read_text()
        swift = ["/usr/bin/xcrun", "swiftc", "-swift-version", "5"]
        binary = out / "tests"
        run("compile-actual-implementations", [*swift, *files, "-o", binary])
        fixture = out / "fixture"; fixture.mkdir()
        output = run("actual-implementations", [binary, fixture])
        match = re.fullmatch(r"PASS UploadRecoveryTests (\d+) assertions\n", output)
        assert match and int(match[1]) >= 30, "Expected actual assertion count"
        receipt["assertions"] = int(match[1])
        mutations = [
            ("no-complete-probe", files[2], "if record.dispatched || record.ticket?.replayed != false {",
             'if false {',
             "Lost complete response must not resend PUT bytes", 1),
            ("no-legacy-consent", files[1], "guard allowLegacyCancellation else",
             "guard true else", "Legacy replacement requires explicit resume", 1),
            ("rollback-relabels-ticket", files[1], "ticket.transportVersion == 2",
             "true", "Rollback cannot relabel a reservation", 1),
            ("no-same-asset-fence", files[1], "sameAsset(ticket.assetID, previous.assetID)",
             "true", "Changed asset must be rejected", 1),
            ("resume-discards-identity", files[4], "legacyRecoveryApproved = true",
             "legacyRecoveryApproved = true; assetID = nil; parts = []", "Explicit Resume preserves legacy identity and completed parts", 1),
            ("pause-cancels-dispatched", files[4], "mutate { $0.status = .paused }",
             "mutate { $0.status = .paused }; backgroundSession.getAllTasks { $0.forEach { $0.cancel() } }",
             "Pause must not interrupt a dispatched one-write operation", 1),
            ("ignore-confirmed-parts", files[4], "for receipt in ticket.confirmedParts ?? [] {",
             "for receipt in [UploadTicket.ConfirmedPart]() {",
             "Confirmed multipart receipts skip physical retransfers", 1),
            ("overwrite-corrupt-journal", files[2], "if canPersistRecord { try? await store.save(record, for: journalKey) }",
             "if true { try? await store.save(record, for: journalKey) }",
             "Failed journal load must never overwrite the original receipt", 1),
            ("recreate-restart-intent", files[2], "if record.restartIntent == nil { record.restartIntent = .init",
             "if true { record.restartIntent = .init",
             "Restart intent survives lost response and reuses one UUID", 1),
            ("restart-after-completion", files[1], "try await complete()\n            try checkOwner()",
             "try await complete()\n            try checkOwner()\n            _ = try await replace(intent.assetID, intent.operationID)",
             "Completion probe winner never calls restart route", 1),
        ]
        for name, path, needle, replacement, expected_message, expected_count in mutations:
            text = path.read_text()
            assert text.count(needle) == expected_count, f"Mutant anchor changed: {name}"
            mutant = out / (name + ".swift")
            mutant.write_text(text.replace(needle, replacement, 1))
            mutated_files = [mutant if p == path else p for p in files]
            broken = out / name
            run("compile-" + name, [*swift, *mutated_files, "-o", broken])
            isolated = out / (name + "-fixture"); isolated.mkdir()
            failure = run("reject-" + name, [broken, isolated], expected=1)
            assert "FAIL " + expected_message in failure, f"Wrong mutant failure: {name}"
        restored = out / "restored-fixture"; restored.mkdir()
        run("restore-production", [binary, restored])
        receipt["accepted"] = True
    finally:
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
