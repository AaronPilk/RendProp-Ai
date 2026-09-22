#!/usr/bin/env python3
"""Reject green screenshot collectors that never reached required screens."""
import argparse
import json
import subprocess
from pathlib import Path

if not __debug__:
    raise SystemExit("FAIL: run UI evidence verification without Python -O")

REVIEWER = {"ReviewerWalk/testReviewerWalk()"}
MAIN = {"RendpropUITests/testWalk()"}
SPATIAL = {
    "SpatialCaptureIntegrationTests/testSettingsEntryShowsHonestIdleControlsAndDoneReturns()",
    "SpatialCaptureIntegrationTests/testUnsupportedStartDoesNotRequestCameraOrOfferExport()",
    "SpatialCaptureIntegrationTests/testRelaunchAndReopenWithoutCaptureKeepExportUnavailable()",
}
REVIEWER_SHOTS = {
    "r01-onboarding-1", "r02-first-home", "r03-homes", "r04-sample-detail",
    "r05-sample-player", "r06-profile", "r07-settings-legal",
    "r08-delete-account", "r09-delete-confirm", "r11-ai-consent",
}
MAIN_SHOTS = {
    "01-home", "02-add-home", "03-photo-studio", "04-reel-studio-voice",
    "05-settings", "06-owner-console", "07-routing", "08-paywall", "09-health-probe",
}


def result_data(path: Path, kind: str, test_id: str | None = None):
    command = ["xcrun", "xcresulttool", "get", "test-results", kind,
               "--path", str(path), "--compact"]
    if test_id:
        command += ["--test-id", test_id]
    return json.loads(subprocess.check_output(command, timeout=60))


def objects(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from objects(child)


def verify(path: Path, expected: set[str], shots: set[str]):
    summary = result_data(path, "summary")
    requirements = {"result": "Passed", "totalTestCount": len(expected),
                    "passedTests": len(expected), "failedTests": 0,
                    "skippedTests": 0, "expectedFailures": 0}
    assert all(summary.get(k) == v for k, v in requirements.items()), "incomplete or failed test summary"
    cases = [node for node in objects(result_data(path, "tests"))
             if node.get("nodeType") == "Test Case"]
    assert len(cases) == len(expected), "unexpected test-case count"
    assert {node.get("nodeIdentifier") for node in cases} == expected, "wrong tests ran"
    assert all(node.get("result") == "Passed" for node in cases), "test did not pass"
    attachment_names = set()
    for test_id in expected:
        activities = result_data(path, "activities", test_id)
        for node in objects(activities):
            for attachment in node.get("attachments", []):
                attachment_names.add(attachment.get("name", ""))
    missing = sorted(shot for shot in shots
                     if not any(name == shot or name.startswith(shot + "_") for name in attachment_names))
    assert not missing, "required screens not captured: " + ", ".join(missing)
    print(f"PASS: {len(expected)} exact tests and {len(shots)} required screenshots in {path.name}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("reviewer", type=Path)
    parser.add_argument("main", type=Path)
    parser.add_argument("spatial", type=Path)
    args = parser.parse_args()
    verify(args.reviewer, REVIEWER, REVIEWER_SHOTS)
    verify(args.main, MAIN, MAIN_SHOTS)
    verify(args.spatial, SPATIAL, {"spatial-integrated-idle", "spatial-integrated-unsupported",
                                 "spatial-integrated-saved-empty"})
    # xcresult test summaries do not establish source/build provenance. Retain
    # the explicit -configuration Release build/test commands alongside results;
    # a matching screenshot name also still needs actual visual inspection.
    print("PASS: all five required UI tests and screen-evidence gates (configuration/provenance checked separately)")
