#!/usr/bin/env python3
"""Verify inventory/token contracts, never claim real browser or tenant parity.

Missing mappings are release-planning errors: compiling a screen cannot prove
that it implements an API operation that was omitted from the plan entirely.
"""
import argparse
import copy
import json
import math
import re
import sys
import unittest
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = ROOT / "packages/client-contracts"
ALLOWED_STATUS = {"planned", "restricted", "native-handoff", "upload-instead", "deferred-owner-gate"}
EXTRA_IDS = {
    "anonymous-session", "identity-adoption", "team-seats", "storekit-entitlements",
    "onboarding", "camera-video", "photo-camera-library", "lidar-roomplan",
    "spatial-phase-a", "floorplan-editor", "native-render", "reel-composer",
    "agent-reel-client", "saved-drafts-transfers", "review-submit", "two-links-playback",
    "share-qr-download", "account-deletion", "analytics-contract", "brokerage-governance",
    "speech-transcription", "admin-provider-probe", "admin-funnel", "gear-catalog",
}
REQUIRED_SYMBOLS = {"admin-provider-probe": {"adminProbeKeys", "adminLastKeyProbe"},
                    "admin-funnel": {"adminFunnel"}, "gear-catalog": {"performRefresh", "normalizedASIN"},
                    "speech-transcription": {"SpeechTranscriber"}}


class ContractError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ContractError(message)


def api_declarations(source):
    require(source.count("protocol APIClient: Sendable {") == 1, "ambiguous APIClient protocol")
    body = source.split("protocol APIClient: Sendable {", 1)[1].split("extension APIClient", 1)[0]
    declarations = Counter(re.findall(r"^\s*func\s+(\w+)\s*\(", body, re.MULTILINE))
    require(bool(declarations), "empty API inventory")
    return declarations


def validate_capabilities(doc, source, root=ROOT):
    require(type(doc.get("schema")) is int and doc["schema"] == 1, "schema must be integer 1")
    require(doc.get("claim") == "inventory-only; no browser parity is verified", "unsupported parity claim")
    require(bool(re.fullmatch(r"[0-9a-f]{40}", doc.get("baseline", ""))), "invalid source baseline")
    declarations = api_declarations(source)
    require(declarations.get("completeUpload") == 2, "completion overloads changed: review contract")
    rows = doc.get("api")
    extras = doc.get("outsideProtocol")
    require(isinstance(rows, list) and isinstance(extras, list), "missing inventory rows")
    seen_methods = []
    ids = []
    for row in rows + extras:
        require(isinstance(row, dict), "invalid capability row")
        require(isinstance(row.get("id"), str) and bool(row["id"]), "missing row ID")
        ids.append(row["id"])
        require(row.get("status") in ALLOWED_STATUS, "unverified capability advertised as done")
        require(isinstance(row.get("web"), str) and len(row["web"]) >= 12, "missing meaningful web mapping")
    require(len(ids) == len(set(ids)), "duplicate capability ID")
    for row in rows:
        methods = row.get("methods")
        require(isinstance(methods, list) and len(methods) > 0, "empty API mapping")
        require(all(isinstance(item, str) for item in methods), "invalid method name")
        seen_methods.extend(methods)
    require(len(seen_methods) == len(set(seen_methods)), "duplicate API mapping")
    require(set(seen_methods) == set(declarations),
            "API mismatch: missing=" + str(sorted(set(declarations) - set(seen_methods))) +
            " extra=" + str(sorted(set(seen_methods) - set(declarations))))
    require({row["id"] for row in extras} == EXTRA_IDS, "outside-protocol capability inventory changed")
    for row in extras:
        relative = row.get("source")
        require(isinstance(relative, str) and not Path(relative).is_absolute(), "source must be repo-relative")
        target = (root / relative).resolve()
        require(target.is_relative_to(root.resolve()) and target.is_file(), "source path missing or outside repo: " + row["id"])
        if row["id"] in REQUIRED_SYMBOLS:
            require(set(row.get("symbols", [])) == REQUIRED_SYMBOLS[row["id"]], "missing direct-client symbol mapping")
            contents = target.read_text()
            for symbol in row["symbols"]:
                require(bool(re.search(r"\b" + re.escape(symbol) + r"\b", contents)), "direct-client source symbol missing")
    return {"apiMethods": len(declarations), "apiDeclarations": sum(declarations.values()),
            "capabilityGroups": len(rows), "outsideProtocol": len(extras), "browserVerified": 0}


def luminance(color):
    require(isinstance(color, str) and bool(re.fullmatch(r"#[0-9A-Fa-f]{6}", color)), "invalid RGB color")
    channels = [int(color[n:n + 2], 16) / 255 for n in (1, 3, 5)]
    linear = [n / 12.92 if n <= 0.04045 else ((n + 0.055) / 1.055) ** 2.4 for n in channels]
    return sum(value * weight for value, weight in zip(linear, (0.2126, 0.7152, 0.0722)))


def contrast(first, second):
    values = sorted((luminance(first), luminance(second)))
    return (values[1] + 0.05) / (values[0] + 0.05)


def validate_tokens(doc):
    require(type(doc.get("schema")) is int and doc["schema"] == 1, "invalid token schema")
    require(doc["sources"] == ["docs/brand/README.md", "docs/marketing/instagram-carousels/src/slidekit.py"],
            "token provenance changed")
    colors = doc["color"]
    require(colors["ground"] == "#0B0D10" and colors["accent"] == "#7C3AED", "brand primitives changed")
    for color in colors.values():
        luminance(color)
    required_pairs = {("text", "ground"), ("text", "surface"), ("muted", "surface"),
                      ("accentText", "surface"), ("onAccent", "accent"), ("focus", "surface")}
    observed, ratios = set(), []
    for pair in doc["contrastPairs"]:
        key = (pair["foreground"], pair["background"])
        require(key not in observed, "duplicate contrast case")
        observed.add(key)
        minimum = pair["minimum"]
        require(type(minimum) in (int, float) and math.isfinite(minimum), "invalid contrast threshold")
        require(minimum >= (3 if key[0] == "focus" else 4.5), "weakened contrast threshold")
        ratio = contrast(colors[key[0]], colors[key[1]])
        require(ratio >= minimum, f"contrast failure {key}: {ratio:.4f} < {minimum}")
        ratios.append({"pair": "/".join(key), "ratio": round(ratio, 4)})
    require(observed == required_pairs, "missing contrast cases")
    require(doc["target"]["minimumPx"] >= 44, "touch target policy weakened")
    require(doc["focus"]["widthPx"] >= 2 and doc["focus"]["offsetPx"] >= 2, "focus policy weakened")
    require(doc["motion"]["reducedMs"] == 0 and doc["motion"]["autoplayPreview"] is False,
            "reduced motion / autoplay policy weakened")
    require(doc["font"]["binaryRedistributionVerified"] is False, "font redistribution is unverified")
    require(doc["font"]["sizeRem"]["body"] >= 1 and doc["font"]["bodyLineHeight"] >= 1.5,
            "body typography policy weakened")
    return ratios


class FoundationTests(unittest.TestCase):
    def setUp(self):
        self.cap = copy.deepcopy(CAP)
        self.tokens = copy.deepcopy(TOKENS)

    def test_complete_inventory(self):
        result = validate_capabilities(self.cap, SWIFT)
        self.assertEqual(result["apiMethods"], 53)
        self.assertEqual(result["apiDeclarations"], 54)
        self.assertEqual(result["capabilityGroups"], 15)
        self.assertEqual(result["outsideProtocol"], 24)
        self.assertEqual(result["browserVerified"], 0)
        spatial = next(row for row in self.cap["api"] if row["id"] == "spatial-jobs")
        self.assertEqual(spatial["status"], "planned")
        self.assertEqual(len(spatial["methods"]), 10)

    def test_token_positive(self):
        self.assertEqual(len(validate_tokens(self.tokens)), 6)

    def test_contrast_reference_values(self):
        self.assertAlmostEqual(contrast("#000000", "#FFFFFF"), 21)
        self.assertEqual(contrast("#161820", "#161820"), 1)

    def test_missing_upload_fails(self):
        self.cap["api"][1]["methods"].remove("completeUpload")
        with self.assertRaises(ContractError):
            validate_capabilities(self.cap, SWIFT)

    def test_missing_restart_fails(self):
        uploads = next(row for row in self.cap["api"] if row["id"] == "uploads")
        uploads["methods"].remove("restartUpload")
        with self.assertRaisesRegex(ContractError, r"^API mismatch: missing=\['restartUpload'\] extra=\[\]$"):
            validate_capabilities(self.cap, SWIFT)

    def test_missing_spatial_method_fails(self):
        # Check each omission separately: a single missing group must not mask
        # a validator that fails to inventory one of its recovery operations.
        methods = ["spatialJobs", "spatialJob", "createSpatialJob", "attachSpatialInputs",
                   "startSpatialJob", "reviewSpatialJob", "publishSpatialJob",
                   "retrySpatialJob", "cancelSpatialJob", "resumeSpatialJob"]
        for method in methods:
            with self.subTest(method=method):
                cap = copy.deepcopy(self.cap)
                spatial = next(row for row in cap["api"] if row["id"] == "spatial-jobs")
                spatial["methods"].remove(method)
                with self.assertRaisesRegex(ContractError, r"^API mismatch: missing=\['" + method + r"'\] extra=\[\]$"):
                    validate_capabilities(cap, SWIFT)

    def test_new_swift_method_requires_mapping(self):
        added = SWIFT.replace("protocol APIClient: Sendable {", "protocol APIClient: Sendable {\n    func futureCapability() async throws")
        with self.assertRaises(ContractError):
            validate_capabilities(self.cap, added)

    def test_duplicate_mapping_fails(self):
        self.cap["api"][0]["methods"].append("completeUpload")
        with self.assertRaises(ContractError):
            validate_capabilities(self.cap, SWIFT)

    def test_fake_parity_fails(self):
        self.cap["api"][0]["status"] = "verified"
        with self.assertRaises(ContractError):
            validate_capabilities(self.cap, SWIFT)

    def test_missing_native_capability_fails(self):
        self.cap["outsideProtocol"].pop()
        with self.assertRaises(ContractError):
            validate_capabilities(self.cap, SWIFT)

    def test_outside_source_path_fails(self):
        self.cap["outsideProtocol"][0]["source"] = "../not-our-source"
        with self.assertRaises(ContractError):
            validate_capabilities(self.cap, SWIFT)

    def test_low_contrast_fails(self):
        self.tokens["color"]["muted"] = self.tokens["color"]["surface"]
        with self.assertRaises(ContractError):
            validate_tokens(self.tokens)

    def test_weakened_contrast_threshold_fails(self):
        self.tokens["contrastPairs"][0]["minimum"] = 1
        with self.assertRaises(ContractError):
            validate_tokens(self.tokens)

    def test_nan_contrast_fails(self):
        self.tokens["contrastPairs"][0]["minimum"] = float("nan")
        with self.assertRaises(ContractError):
            validate_tokens(self.tokens)

    def test_missing_contrast_case_fails(self):
        self.tokens["contrastPairs"].pop()
        with self.assertRaises(ContractError):
            validate_tokens(self.tokens)

    def test_reduced_motion_fails(self):
        self.tokens["motion"]["reducedMs"] = 160
        with self.assertRaises(ContractError):
            validate_tokens(self.tokens)


def main():
    if not __debug__:
        raise ContractError("optimized Python is not a verification mode")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inject-fault", choices=["missing-upload", "low-contrast", "no-op-validator"])
    args = parser.parse_args()
    global CAP, TOKENS, SWIFT
    CAP = json.loads((CONTRACTS / "capabilities.json").read_text())
    TOKENS = json.loads((CONTRACTS / "design-tokens.json").read_text())
    SWIFT = (ROOT / "apps/ios/Rendprop/Networking/APIClient.swift").read_text()
    if args.inject_fault == "missing-upload":
        CAP["api"][1]["methods"].remove("completeUpload")
    elif args.inject_fault == "low-contrast":
        TOKENS["color"]["muted"] = TOKENS["color"]["surface"]
    inventory = validate_capabilities(CAP, SWIFT)
    ratios = validate_tokens(TOKENS)
    if args.inject_fault == "no-op-validator":
        # Prove the rejection tests detect an implementation that stops validating.
        globals()["validate_capabilities"] = lambda *_args, **_kwargs: inventory
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(FoundationTests))
    require(result.testsRun == 16 and not result.skipped, "missing/skipped tests")
    require(result.wasSuccessful(), "foundation tests failed")
    print(json.dumps({"inventory": inventory, "contrast": ratios, "tests": result.testsRun,
                      "skips": len(result.skipped), "browserTests": 0, "liveTests": 0}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ContractError, KeyError, TypeError, ValueError, OSError) as exc:
        print("FAIL:", str(exc), file=sys.stderr)
        sys.exit(1)
