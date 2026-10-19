#!/usr/bin/env python3
"""Offline measurement wire/sync proof compiled from actual Swift sources.

Only HTTP/Auth boundaries and file-path resolution are fixtures. Production
sources are read, never modified. No network, user files or camera access.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
CLIENT = ROOT / "apps/ios/Rendprop/Networking/LiveAPIClient.swift"
APP = ROOT / "apps/ios/Rendprop/RendpropApp.swift"
SYNC = ROOT / "apps/ios/Rendprop/Networking/WorkspaceSync.swift"
EDITOR = ROOT / "apps/ios/Rendprop/Screens/FloorMeasurementsView.swift"

# PR29's hosted macOS runner compiled the positive fixture in 73.56 seconds,
# then exceeded the old 90-second limit compiling the first copied fault.
# Allow bounded compiler headroom; executing the proof still has its own
# unchanged 90-second deadline and exact semantic-rejection requirements.
# A later serial hosted run exceeded 240 seconds for ignore-facts-review before
# runtime. Its host cause is unknown; retain failure at a separate 480s bound.
COMPILE_TIMEOUT_SECONDS = 480
RUN_TIMEOUT_SECONDS = 90


def save_receipt(out, receipt):
    pending = out / ".receipt.pending"
    with pending.open("w") as file:
        json.dump(receipt, file, indent=2)
        file.write("\n")
        file.flush()
        os.fsync(file.fileno())
    pending.replace(out / "receipt.json")
    fd = os.open(out, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def stop_owned_group(child):
    # The leader can exit before its compiler descendants. Always address the
    # exact session created here, including on normal exit and exceptions.
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    grace_deadline = time.monotonic() + 2
    while time.monotonic() < grace_deadline:
        child.poll()
        try:
            os.killpg(child.pid, 0)
        except ProcessLookupError:
            break
        time.sleep(.05)
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        raise RuntimeError("Owned command exit unknown after bounded cleanup") from None


def run_command(command, out, label, seconds, receipt, expected_exit):
    argv = list(map(str, command))
    stdout_path = out / (label + ".stdout.log")
    stderr_path = out / (label + ".stderr.log")
    started = time.monotonic()
    row = {"name": label, "command": argv, "exit": None,
           "expectedExit": expected_exit, "timedOut": False,
           "timeoutSeconds": seconds, "failure": None}
    receipt["commands"].append(row)
    save_receipt(out, receipt)
    child = None
    try:
        with stdout_path.open("xb") as stdout, stderr_path.open("xb") as stderr:
            try:
                if time.monotonic() - started >= seconds:
                    raise TimeoutError("Command deadline elapsed before launch")
                child = subprocess.Popen(argv, cwd=ROOT, stdin=subprocess.DEVNULL,
                                         stdout=stdout, stderr=stderr,
                                         start_new_session=True)
                while child.poll() is None:
                    if time.monotonic() - started >= seconds:
                        raise TimeoutError(f"{label} exceeded its {seconds}s bound; no retry")
                    if stdout_path.stat().st_size + stderr_path.stat().st_size > 16 * 1024 * 1024:
                        raise RuntimeError("Command output exceeded its 16MiB bound")
                    time.sleep(.05)
                row["exit"] = child.returncode
            finally:
                if child is not None:
                    stop_owned_group(child)
                    row["exit"] = child.returncode
                stdout.flush()
                stderr.flush()
                os.fsync(stdout.fileno())
                os.fsync(stderr.fileno())
        if stdout_path.stat().st_size + stderr_path.stat().st_size > 16 * 1024 * 1024:
            raise RuntimeError("Command output exceeded its 16MiB bound")
        if time.monotonic() - started >= seconds:
            raise TimeoutError(f"{label} exceeded its {seconds}s bound; no retry")
        output = (stdout_path.read_bytes() + stderr_path.read_bytes()).decode("utf-8", errors="replace")
        if row["exit"] != expected_exit:
            raise RuntimeError(f"{label} exit {row['exit']} differs from required {expected_exit}")
        if time.monotonic() - started >= seconds:
            raise TimeoutError(f"{label} exceeded its {seconds}s bound; no retry")
        return subprocess.CompletedProcess(argv, row["exit"], stdout=output)
    except BaseException as error:
        row["timedOut"] = isinstance(error, TimeoutError)
        row["failure"] = {"class": type(error).__name__, "reason": str(error)}
        receipt["passed"] = False
        receipt["failure"] = {"kind": "timeout" if row["timedOut"] else "command-error",
                              "stage": label, "timeoutSeconds": seconds,
                              "class": type(error).__name__, "reason": str(error)}
        raise
    finally:
        row["elapsedSeconds"] = round(time.monotonic() - started, 3)
        logs = [path for path in [stdout_path, stderr_path] if path.is_file()]
        row["logs"] = []
        for path in logs:
            with path.open("rb") as file:
                digest = hashlib.file_digest(file, "sha256").hexdigest()
            row["logs"].append({"path": str(path), "bytes": path.stat().st_size, "sha256": digest})
        if sum(path.stat().st_size for path in logs) <= 16 * 1024 * 1024:
            log = out / (label + ".log")
            with log.open("xb") as file:
                for path in logs:
                    file.write(path.read_bytes())
                file.flush()
                os.fsync(file.fileno())
            row["log"] = str(log)
            row["sha256"] = hashlib.sha256(log.read_bytes()).hexdigest()
        save_receipt(out, receipt)


def block(source, marker):
    assert source.count(marker) == 1, marker
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--inject-fault", choices=["drop-wire", "drop-fingerprint", "ignore-dirty", "drop-replay-adopt", "rewrite-raw-keys", "legacy-ignore-edit", "discard-outline-only", "outline-fingerprint", "legacy-v2-accept", "drop-local-raw-mirror", "omit-cas-base", "ignore-pending-measurements", "wrong-cas-workspace", "ignore-cas-conflict", "omit-facts-fingerprint", "ignore-facts-review", "skip-legacy-recovery", "ignore-cas-lineage", "overwrite-shared-backup", "compare-backup-wire-only", "retain-backup-after-new-edit"])
    args = parser.parse_args()
    out = args.output_dir or Path(tempfile.mkdtemp(prefix="rendprop-floor-measurement-sync-", dir="/tmp"))
    out.mkdir(parents=True, exist_ok=True)
    fixture_template = Path(__file__).with_name("Fixture.swift.template")
    legacy_template = Path(__file__).with_name("LegacyModels.swift.template")
    harness_bytes = {p: p.read_bytes() for p in [Path(__file__).resolve(), fixture_template, legacy_template]}
    source_bytes = {p: p.read_bytes() for p in [CLIENT, APP, SYNC, EDITOR]}
    client, app, sync = (source_bytes[p].decode() for p in [CLIENT, APP, SYNC])
    actual_sync = sync
    tolerant_map = block(client, "    struct TolerantStringMap: Decodable")
    if args.inject_fault == "drop-wire":
        before = "details = FloorMeasurementPlan.replacingWire(in: details, with: try plan.encodedWireValue())"
        assert sync.count(before) == 1
        sync = sync.replace(before, "_ = plan")
    elif args.inject_fault == "drop-fingerprint":
        before = "fingerprintFacts(listing, details: ListingWireDetails.merged(listing))"
        assert sync.count(before) == 1
        sync = sync.replace(before, "fingerprintFacts(listing, details: listing.details ?? [:])")
    elif args.inject_fault == "ignore-dirty":
        before = "if existing.needsServerSync != true && !protected.contains(existing.id) {"
        assert sync.count(before) == 1
        sync = sync.replace(before, "if !protected.contains(existing.id) {")
    elif args.inject_fault == "drop-replay-adopt":
        # Removing the first assignment alone is repaired by the independent
        # facts acknowledgement/adoptFacts path. Retain the old typed plan at
        # final persistence to exercise the same observable replay defect.
        ensure = block(sync, "    static func ensure(snapshot: Listing,")
        before = "        save(latest)"
        assert ensure.count(before) == 1
        corrupted = ensure.replace(before, """        if created.cloudCreateReplayed == true, unchanged {
            latest.floorMeasurements = snapshot.floorMeasurements
        }
""" + before)
        sync = sync.replace(ensure, corrupted)
    elif args.inject_fault == "legacy-ignore-edit":
        before = """guard listing.floorMeasurements == nil || listing.floorMeasurements ==
                FloorMeasurementPlan.decodeWireValue(listing.details?[FloorMeasurementPlan.wireKey]) else { return false }"""
        assert sync.count(before) == 1
        sync = sync.replace(before, "// injected unsafe legacy comparison ignoring independent edits")
    elif args.inject_fault == "discard-outline-only":
        before = "if let plan = listing.floorMeasurements {"
        assert sync.count(before) == 1
        sync = sync.replace(before, "if let plan = listing.floorMeasurements, plan.version != 2 || !plan.rooms.isEmpty {")
    elif args.inject_fault == "outline-fingerprint":
        before = "try fingerprintFacts(listing, details: ListingWireDetails.merged(listing))"
        assert sync.count(before) == 1
        sync = sync.replace(before, """var rectanglesOnly = listing
        if rectanglesOnly.floorMeasurements?.rooms.isEmpty == true { rectanglesOnly.floorMeasurements = nil }
        return try fingerprintFacts(rectanglesOnly, details: ListingWireDetails.merged(rectanglesOnly))""")
    elif args.inject_fault == "ignore-pending-measurements":
        before = "if existing.measurementSync?.pending == true {"
        assert sync.count(before) == 1
        sync = sync.replace(before, "if false {")
    elif args.inject_fault == "omit-facts-fingerprint":
        before = "listing.cloudCreateFactsFingerprint = try factsFingerprint(listing)"
        assert sync.count(before) == 1
        sync = sync.replace(before, "listing.cloudCreateFactsFingerprint = nil")
    elif args.inject_fault == "rewrite-raw-keys":
        tolerant_map = '''    struct TolerantStringMap: Decodable {
        let value: [String: String]
        let raw: [String: ListingFactValue]
        private struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(from decoder: Decoder) throws {
            raw = try decoder.singleValueContainer().decode([String: ListingFactValue].self)
            var out: [String: String] = [:]
            let c = try decoder.container(keyedBy: AnyKey.self)
            for key in c.allKeys {
                if let s = try? c.decode(String.self, forKey: key) { out[key.stringValue] = s }
                else if let i = try? c.decode(Int.self, forKey: key) { out[key.stringValue] = String(i) }
                else if let d = try? c.decode(Double.self, forKey: key) { out[key.stringValue] = String(d) }
                else if let b = try? c.decode(Bool.self, forKey: key) { out[key.stringValue] = String(b) }
            }
            value = out
        }
    }'''
    replacements = {
        "__CREATE__": block(client, "    func createListing(_ listing: Listing)"),
        "__UPDATE__": block(client, "    func updateListing(_ listing: Listing)"),
        "__UPDATE_MEASUREMENTS__": block(client, "    func updateMeasurements(_ listing: Listing)"),
        "__SAVE_MEASUREMENTS__": block(app, "    func saveMeasurements(_ plan: FloorMeasurementPlan,"),
        "__RELOAD_SHARED__": block(app, "    func reloadSharedMeasurements(_ id: UUID,"),
        "__CONFIRM_LOCAL__": block(app, "    func confirmLocalListingDetails(_ id: UUID)"),
        "__LOAD_FACTS_REVIEW__": block(app, "    func loadListingFactsReview(_ id: UUID)"),
        "__RESOLVE_FACTS__": block(app, "    func resolveListingFacts(_ review: ListingFactsReview,"),
        "__LISTING_BODY__": block(client, "    private func listingBody(_ l: Listing,"),
        "__MAP_LISTING__": block(client, "    private func mapListing(_ dto: ListingDTO)"),
        "__LISTING_DTO__": block(client, "    private struct ListingDTO: Decodable"),
        "__TOLERANT_MAP__": tolerant_map,
        "__DECODE__": block(client, "    private func decode<T: Decodable>"),
        "__PARSE_DATE__": block(client, "    private static func parseDate("),
        "__ISO_STRING__": block(client, "    private static func isoString("),
        "__WIRE_STATUS__": block(client, "    private static func wireStatus("),
        "__LOCAL_STATUS__": block(client, "    private static func localStatus("),
        "__MODIFY__": block(app, "    func modify(_ id: UUID,"),
        "__MARK_DIRTY__": block(app, "    func markDirty(_ id: UUID)"),
        "__IS_IN_WORKSPACE__": block(app, "    func isInSelectedWorkspace(_ listing: Listing)"),
        "__SYNC_LISTING__": block(app, "    func syncListing(_ id: UUID)"),
        "__EDITOR_PERSIST__": block(source_bytes[EDITOR].decode(), "    private func persist(_ candidate: FloorMeasurementPlan)"),
    }
    if args.inject_fault == "drop-local-raw-mirror":
        before = "try FloorMeasurementSync.stage(plan, in: &changed)"
        assert replacements["__SAVE_MEASUREMENTS__"].count(before) == 1
        replacements["__SAVE_MEASUREMENTS__"] = replacements["__SAVE_MEASUREMENTS__"].replace(before, before + "\n        changed.details?.removeValue(forKey: FloorMeasurementPlan.wireKey)")
    if args.inject_fault == "omit-cas-base":
        before = '"expected": state.expected as Any? ?? NSNull()'
        assert replacements["__UPDATE_MEASUREMENTS__"].count(before) == 1
        replacements["__UPDATE_MEASUREMENTS__"] = replacements["__UPDATE_MEASUREMENTS__"].replace(before, '"expected": NSNull()')
    elif args.inject_fault == "wrong-cas-workspace":
        before = 'org.uuidString.lowercased(), forHTTPHeaderField: "X-Org-Id"'
        assert replacements["__UPDATE_MEASUREMENTS__"].count(before) == 1
        replacements["__UPDATE_MEASUREMENTS__"] = replacements["__UPDATE_MEASUREMENTS__"].replace(before, '"44444444-4444-4444-8444-444444444444", forHTTPHeaderField: "X-Org-Id"')
    elif args.inject_fault == "ignore-cas-conflict":
        before = "listings[i].measurementSync?.conflict = true"
        assert replacements["__SYNC_LISTING__"].count(before) == 1
        replacements["__SYNC_LISTING__"] = replacements["__SYNC_LISTING__"].replace(before, "listings[i].measurementSync?.conflict = false")
    elif args.inject_fault == "ignore-facts-review":
        before = "snapshot.measurementSync?.factsReviewRequired != true else {"
        assert replacements["__SYNC_LISTING__"].count(before) == 1
        replacements["__SYNC_LISTING__"] = replacements["__SYNC_LISTING__"].replace(before, "true else {")
    elif args.inject_fault == "ignore-cas-lineage":
        before = """guard current.measurementSync?.pending == true,
                              current.measurementSync?.conflict != true,
                              current.measurementSync?.expected == snapshot.measurementSync?.expected,
                              FloorMeasurementPlan.wireValue(in: receipt.details) == FloorMeasurementPlan.wireValue(in: snapshot.details) else { return }"""
        assert replacements["__SYNC_LISTING__"].count(before) == 1
        replacements["__SYNC_LISTING__"] = replacements["__SYNC_LISTING__"].replace(before, "// injected missing current-queue lineage guard")
    elif args.inject_fault in ["overwrite-shared-backup", "retain-backup-after-new-edit"]:
        before = """state.savedLocalCopy = stillUsingSharedPlan
            ? prior?.savedLocalCopy ?? localCopy
            : localCopy ?? prior?.savedLocalCopy"""
        assert replacements["__RELOAD_SHARED__"].count(before) == 1
        after = "state.savedLocalCopy = localCopy" if args.inject_fault == "overwrite-shared-backup" else "state.savedLocalCopy = prior?.savedLocalCopy ?? localCopy"
        replacements["__RELOAD_SHARED__"] = replacements["__RELOAD_SHARED__"].replace(before, after)
    elif args.inject_fault == "compare-backup-wire-only":
        before = "current.floorMeasurements == FloorMeasurementPlan.decodeWireValue(prior?.expected)"
        assert replacements["__RELOAD_SHARED__"].count(before) == 1
        replacements["__RELOAD_SHARED__"] = replacements["__RELOAD_SHARED__"].replace(before, "localCopy == prior?.expected")
    # The Listing DTO still uses snake-case conversion. Its freeform dictionary
    # must therefore preserve keys itself on create and facts-CAS readback.
    for marker in ["json: try listingBody(listing, forPatch: false)", 'url(["listings", target.uuidString, "facts"])', "json: try ListingFactsSync.body(listing)"]:
        assert marker in client
    source = harness_bytes[fixture_template].decode()
    for key, value in replacements.items():
        assert source.count(key) == 1, key
        source = source.replace(key, value)
    checks = out / "ActualFloorMeasurementSync.swift"
    checks.write_text(source)
    compiled_sync = out / "WorkspaceSync.swift"
    compiled_sync.write_text(sync)
    models = [ROOT / ("apps/ios/Rendprop/" + path) for path in ["Models/Listing.swift", "Models/ListingClientContact.swift", "Models/Money.swift", "Networking/NativeReelDraft.swift", "Auth/AnonymousAdoptionRecovery.swift", "Auth/AdoptionLocalBindings.swift"]]
    legacy_bytes = harness_bytes[legacy_template]
    legacy = legacy_bytes.decode().replace("FloorMeasurement", "LegacyFloorMeasurement").replace("ListingWireDetails", "LegacyListingWireDetails")
    if args.inject_fault == "legacy-v2-accept":
        before = "guard version == 1 else { throw LegacyFloorMeasurementError.unsupportedVersion }"
        assert legacy.count(before) == 1
        legacy = legacy.replace(before, "guard version == 1 || version == 2 else { throw LegacyFloorMeasurementError.unsupportedVersion }")
    compiled_legacy = out / "LegacyModels.swift"
    compiled_legacy.write_text(legacy)
    sources = [CLIENT, APP, SYNC, EDITOR] + models
    source_bytes.update({p: p.read_bytes() for p in models})
    listing_model = models[0]
    compiled_listing_text = source_bytes[listing_model].decode()
    if args.inject_fault == "skip-legacy-recovery":
        recovery = block(compiled_listing_text, "    static func recoverLegacyPending(in listing: inout Listing)")
        compiled_listing_text = compiled_listing_text.replace(recovery, "    static func recoverLegacyPending(in listing: inout Listing) { return }")
    compiled_listing = out / "Listing.swift"
    compiled_listing.write_text(compiled_listing_text)
    models[0] = compiled_listing
    # Compile a captured source snapshot even when another audit agent edits
    # its owned file while swiftc is running. Runtime sources remain untouched.
    for i, model in enumerate(models[1:], start=1):
        copied_model = out / model.name
        copied_model.write_bytes(source_bytes[model])
        models[i] = copied_model
    receipt = {"passed": False, "networkCalls": 0, "cameraCalls": 0, "userFilesAccessed": 0, "productionMutations": 0,
               "injectedFault": args.inject_fault,
               "sourceHashes": {str(p.relative_to(ROOT)): hashlib.sha256(source_bytes[p]).hexdigest() for p in sources},
               "harnessHashes": {str(p.relative_to(ROOT)): hashlib.sha256(data).hexdigest() for p, data in harness_bytes.items()},
               "compiledExtractedBodyHashes": {key: hashlib.sha256(value.encode()).hexdigest() for key, value in replacements.items()},
               "compiledAcceptanceSha256": hashlib.sha256(source.encode()).hexdigest(),
               "actualSyncSha256": hashlib.sha256(actual_sync.encode()).hexdigest(),
               "compiledSyncSha256": hashlib.sha256(sync.encode()).hexdigest(),
               "legacyReaderTemplateSha256": hashlib.sha256(legacy_bytes).hexdigest(),
               "compiledLegacyReaderSha256": hashlib.sha256(legacy.encode()).hexdigest(),
               "actualListingSha256": hashlib.sha256(source_bytes[listing_model]).hexdigest(),
               "compiledListingSha256": hashlib.sha256(compiled_listing_text.encode()).hexdigest(), "commands": []}
    compile_command = ["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", *map(str, models), str(compiled_sync), str(compiled_legacy), str(checks), "-o", str(out / "checks")]
    expected = {"drop-wire": "Typed plan overrides stale wire independently of generic details",
                "drop-fingerprint": "Measurement-only edits change the create fingerprint",
                "ignore-dirty": "Dirty manual plan survives an older remote snapshot",
                "drop-replay-adopt": "Unedited replay adopts the office measurement plan",
                "rewrite-raw-keys": "Actual DTO decoder retains the exact measurements wire key",
                "legacy-ignore-edit": "Legacy fingerprint cannot hide a new typed measurement edit",
                "discard-outline-only": "Outline-only plan survives create assembly and stays out of generic facts CAS",
                "outline-fingerprint": "Outline-only edits change the actual create fingerprint",
                "legacy-v2-accept": "Frozen v1 reader refuses version-two outlines instead of interpreting them as an empty rectangle plan",
                "drop-local-raw-mirror": "Actual measurement save mirrors typed geometry and exact raw wire atomically" , "omit-cas-base": "Actual measurement request contains only CAS base and value, never sqft/status/sold_at",
                "ignore-pending-measurements": "Offline measurement refresh retains CAS state while adopting other shared facts",
                "wrong-cas-workspace": "Actual measurement endpoint is bound to server listing and captured workspace",
                "ignore-cas-conflict": "Conflicting measurement write retains local plan and surfaces resolution state",
                "omit-facts-fingerprint": "First create captures ordinary facts intent separately from measurements",
                "ignore-facts-review": "Unproven legacy listing facts never reach generic facts CAS",
                "skip-legacy-recovery": "Legacy pending geometry recovers exact CAS baseline before generic acknowledgement",
                "ignore-cas-lineage": "Late CAS success or conflict cannot revive a queue replaced by shared reload",
                "overwrite-shared-backup": "Sequential shared measurements then shared facts retain the original phone backup",
                "compare-backup-wire-only": "Semantically identical shared JSON formatting does not replace the saved phone plan",
                "retain-backup-after-new-edit": "New pending local geometry replaces the old backup when loading shared measurements"}.get(args.inject_fault)
    for label, command in [("compile", compile_command), ("run", [str(out / "checks")])]:
        timeout_seconds = COMPILE_TIMEOUT_SECONDS if label == "compile" else RUN_TIMEOUT_SECONDS
        try:
            result = run_command(command, out, label, timeout_seconds, receipt,
                                 0 if label == "compile" or expected is None else 1)
            output = result.stdout
        except BaseException:
            receipt["passed"] = False
            save_receipt(out, receipt)
            print(label, "failed; partial diagnostics retained", flush=True)
            print("Evidence:", out, flush=True)
            raise
        receipt["sourceHashesAtEnd"] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
        receipt["harnessHashesAtEnd"] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in harness_bytes}
        receipt["sourceBoundAtEnd"] = receipt["sourceHashes"] == receipt["sourceHashesAtEnd"]
        receipt["harnessBoundAtEnd"] = receipt["harnessHashes"] == receipt["harnessHashesAtEnd"]
        bound = receipt["sourceBoundAtEnd"] and receipt["harnessBoundAtEnd"]
        if label == "run":
            receipt["passed"] = bound and not receipt.get("failure") and (result.returncode == 0 if expected is None else result.returncode == 1 and expected in result.stdout)
            if expected:
                receipt["expectedRejection"] = expected
            elif receipt["passed"]:
                count = re.search(r"(\d+) assertions", result.stdout)
                assert count
                receipt["assertions"] = int(count[1])
        elif result.returncode or not bound:
            receipt["passed"] = False
        save_receipt(out, receipt)
        print(label, result.returncode, output[-3500:] if label == "compile" or result.returncode == 0 else "Acceptance rejected the copied regression" if receipt.get("passed") else output[-3500:], flush=True)
        if not bound or (label == "compile" and result.returncode) or (label == "run" and not receipt["passed"]):
            print("Evidence:", out, flush=True)
            raise SystemExit(1)
    print("Evidence:", out, flush=True)


if __name__ == "__main__":
    main()
