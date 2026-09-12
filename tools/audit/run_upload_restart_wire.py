#!/usr/bin/env python3
"""Compile the actual restart wire adapter, then execute with network denied.

Only application configuration and execute() are injected. The request builder,
idempotency policy, restart method, upload mapper/DTO and decoder are extracted
verbatim from --root. This deliberately complements the engine fixtures, whose
fake APIClient could not catch an invalid argument inside LiveAPIClient itself.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from datetime import datetime, timezone


HARNESS_ROOT = Path(__file__).resolve().parents[2]


def require(value, message):
    if not value:
        raise RuntimeError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=HARNESS_ROOT,
                        help="Repository whose actual iOS declarations must compile")
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    out = Path(tempfile.mkdtemp(prefix="rendprop-upload-restart-wire-", dir="/tmp"))
    receipt = {"accepted": False, "observed_at": datetime.now(timezone.utc).isoformat(),
               "source_root": str(root), "harness_root": str(HARNESS_ROOT),
               "network": "execute fixture only; runtime sandbox denies network*",
               "commands": [], "source_hashes": {}, "extractions": [], "negative_controls": []}
    print("EVIDENCE:", out, flush=True)

    def read(relative):
        path = root / relative
        require(path.is_file() and path.stat().st_size <= 2 * 1024 * 1024, f"Missing or oversized source: {relative}")
        data = path.read_bytes()
        receipt["source_hashes"][relative] = sha(data)
        return data.decode("utf-8")

    def extract(text, relative, first, after):
        require(text.count(first) == 1 and text.count(after) == 1,
                f"Extraction anchors changed: {first}")
        start = text.index(first)
        end = text.index(after)
        require(end > start, f"Extraction order changed: {first}")
        value = text[start:end]
        receipt["extractions"].append({"source": relative, "declaration": first.strip(),
            "start_line": text.count("\n", 0, start) + 1,
            "end_line": text.count("\n", 0, end) + 1, "sha256": sha(value.encode())})
        return value

    def run(name, command, expected=0):
        command = list(map(str, command))
        result = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=90)
        log = out / (name + ".log")
        log.write_text(result.stdout)
        receipt["commands"].append({"name": name, "argv": command,
            "exit": result.returncode, "log": str(log), "log_sha256": sha(result.stdout.encode())})
        require(result.returncode == 0 if expected == 0 else result.returncode != 0,
                f"{name}: unexpected exit {result.returncode}; see {log}")
        print(f"{name}: exit={result.returncode}", flush=True)
        return result.stdout

    try:
        live_path = "apps/ios/Rendprop/Networking/LiveAPIClient.swift"
        api_path = "apps/ios/Rendprop/Networking/APIClient.swift"
        direct_path = "apps/ios/Rendprop/Upload/DirectUploader.swift"
        live, api, direct = read(live_path), read(api_path), read(direct_path)
        declarations = [
            ("    private func url(", "\n    /// How one write's"),
            ("    private enum Idempotency {", "\n    /// Assemble a request."),
            ("    private func makeRequest(", "\n    /// The server accepts keys"),
            ("    private static func boundedIdempotencyKey(", '\n    /// `"k:" + sha256('),
            ("    private static func derivedIdempotencyKey(", "\n    /// Caller key when there is one, otherwise derive"),
            ("    private static func idempotency(", "\n    /// Caller key when there is one, otherwise a fresh"),
            ("    private func decode<T:", "\n    /// ISO8601 → Date"),
            ("    private func uploadTicket(", "\n    func renewUpload("),
            ("    func restartUpload(", "\n    func fetchPartURLs("),
            ("    private struct UploadTicketDTO:", "\n    private struct PartURLsDTO:"),
        ]
        pieces = [extract(live, live_path, first, after) for first, after in declarations]
        models = extract(api, api_path, "struct UploadTicket:", "\nstruct UploadAbortReceipt:")
        models += extract(api, api_path, "enum APIError:", "\n// MARK: - Admin console models")
        hashes = extract(direct, direct_path, "    static func sha256Hex(_ string:", "\n    // MARK: - Content types")
        # Storage/init and the final I/O boundary are the only client stand-ins.
        # No production declaration is rewritten to make this fixture compile.
        actual = "import Foundation\nimport CryptoKit\n" + models
        actual += "\nenum DirectUploader {\n" + hashes + "\n}\n"
        actual += """
final class LiveAPIClient {
    private let base: URL
    private let fixture: RestartWireTransport
    init(base: URL, fixture: RestartWireTransport) { self.base = base; self.fixture = fixture }
    private func execute(_ request: URLRequest) async throws -> Data {
        try await fixture.execute(request)
    }
""" + "\n".join(pieces) + "\n}\n"
        actual_path = out / "ActualRestartWire.swift"
        actual_path.write_text(actual)
        receipt["actual_source_sha256"] = sha(actual.encode())
        fixture_path = HARNESS_ROOT / "tests/phase1/UploadRestartWireTests.swift"
        fixture = fixture_path.read_bytes()
        receipt["harness_hashes"] = {
            "tools/audit/run_upload_restart_wire.py": sha(Path(__file__).read_bytes()),
            "tests/phase1/UploadRestartWireTests.swift": sha(fixture),
        }
        # Fail before invoking the compiler if a no-op extraction omitted the
        # method whose typed call site broke the real app build.
        for symbol in ["func restartUpload(", "private enum Idempotency", "private func makeRequest(",
                       "private struct UploadTicketDTO:", "private func decode<T:"]:
            require(actual.count(symbol) == 1, f"Actual-source symbol not unique: {symbol}")
        swift = ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-parse-as-library"]
        sandbox = ["/usr/bin/sandbox-exec", "-p", "(version 1) (allow default) (deny network*)"]
        receipt["compiler"] = run("compiler-version", ["/usr/bin/xcrun", "swiftc", "--version"]).strip()
        binary = out / "actual-wire"
        run("compile-actual-wire", [*swift, actual_path, fixture_path, "-o", binary])
        output = run("actual-wire", [*sandbox, binary])
        match = re.fullmatch(r"PASS UploadRestartWireTests (\d+) assertions\n", output)
        require(match and int(match[1]) >= 40, "Actual wire assertions did not execute")
        receipt["assertions"] = int(match[1])
        receipt["binary_sha256"] = sha(binary.read_bytes())

        # A source compile gate is necessary: mocked APIClient methods in the
        # engine test suite never type-checked this production call expression.
        wrapped = ".key(operationID.uuidString.lowercased())"
        require(actual.count(wrapped) == 1, "Expected one explicit typed restart idempotency expression")
        compile_mutant = out / "StringIdempotency.swift"
        compile_mutant.write_text(actual.replace(wrapped, "operationID.uuidString.lowercased()", 1))
        failure = run("reject-string-idempotency", [*swift, compile_mutant, fixture_path, "-o", out / "string-broken"], expected=1)
        require("cannot convert value of type 'String'" in failure and "Idempotency" in failure,
                "Compile negative control failed for an unrelated reason")
        receipt["negative_controls"].append({"name": "String instead of Idempotency", "phase": "compile", "rejected": True})

        mutations = [
            ("fresh-key", wrapped, ".perAttempt", "Restart header uses the saved operation UUID"),
            ("no-consent", 'json: ["confirm_new_attempt": true]', 'json: ["confirm_new_attempt": false]',
             "Restart body is exactly explicit confirmation"),
            ("missing-retry-metadata", "retryAfterSeconds: dto.retryAfterSeconds", "retryAfterSeconds: nil",
             "Snake-case retry_after_seconds survives the actual mapper"),
            ("missing-generation", "restartGeneration: dto.restartGeneration", "restartGeneration: nil",
             "Snake-case restart_generation survives the actual mapper"),
        ]
        for name, needle, replacement, expected_message in mutations:
            require(actual.count(needle) == 1, f"Negative control anchor changed: {name}")
            mutant = out / (name + ".swift")
            mutant.write_text(actual.replace(needle, replacement, 1))
            broken = out / name
            run("compile-" + name, [*swift, mutant, fixture_path, "-o", broken])
            failure = run("reject-" + name, [*sandbox, broken], expected=1)
            require("FAIL " + expected_message in failure, f"Wrong negative-control failure: {name}")
            receipt["negative_controls"].append({"name": name, "phase": "runtime", "rejected": True})
        # Source changes during a parallel build invalidate the receipt rather
        # than lending yesterday's test result to today's source bytes.
        for relative, digest in receipt["source_hashes"].items():
            require(sha((root / relative).read_bytes()) == digest, f"Source changed during test: {relative}; rerun")
        restored = run("restored-actual-wire", [*sandbox, binary])
        require(restored == output, "Restored actual run changed its assertion count")
        receipt["accepted"] = True
        print(f"PASS actual-source wire: {receipt['assertions']} assertions; "
              f"{len(receipt['negative_controls'])} negative controls rejected", flush=True)
    finally:
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
