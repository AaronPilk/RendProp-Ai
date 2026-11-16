#!/usr/bin/env python3
"""Exercise the exact native policy that prevents old trial usage from replacing a current plan."""

from pathlib import Path
import os
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[3]
POLICY = (ROOT / "apps/ios/Rendprop/Purchases/SubscriptionBillingContext.swift").read_text()
SETTINGS = (ROOT / "apps/ios/Rendprop/Screens/SettingsView.swift").read_text()
PAYWALL = (ROOT / "apps/ios/Rendprop/Purchases/PaywallView.swift").read_text()


def braced(source: str, marker: str) -> str:
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


trial_policy = braced(POLICY, "enum RecordedTrialPresentation {")
pending_policy = braced(POLICY, "func shouldShowPending(plan: String?, recordedTrial: TrialUsageSummary?) -> Bool {")
assert SETTINGS.count("showCurrentTrial, let trial = usage.trialUsage") == 3
assert "RecordedTrialPresentation.isCurrent(planName: usage.entitlements?.plan ?? usage.planName)" in SETTINGS
assert "RecordedTrialPresentation.isCurrent(planName: purchases.billingContext?.planName)" in PAYWALL

work = Path(tempfile.mkdtemp(prefix="rendprop-storekit-plan-display-"))
fixture = work / "main.swift"
fixture.write_text(
    "import Foundation\n"
    + trial_policy
    + "\nenum TrialStatus { case active, expired, exhausted }\n"
    + "struct TrialUsageSummary { let status: TrialStatus }\n"
    + "struct Activation { let available: Bool\n"
    + pending_policy
    + "\n}\n"
    + '''
@main struct Check {
    static func main() {
        precondition(RecordedTrialPresentation.isCurrent(planName: "trial"))
        precondition(RecordedTrialPresentation.isCurrent(planName: nil))
        precondition(!RecordedTrialPresentation.isCurrent(planName: "free"))
        precondition(!RecordedTrialPresentation.isCurrent(planName: "starter"))
        precondition(!RecordedTrialPresentation.isCurrent(planName: " pro "))
        precondition(RecordedTrialPresentation.isPaid(planName: "team"))
        precondition(!RecordedTrialPresentation.isPaid(planName: "trial"))
        precondition(!RecordedTrialPresentation.isPaid(planName: "free"))
        let expired = TrialUsageSummary(status: .expired)
        let active = TrialUsageSummary(status: .active)
        precondition(Activation(available: false).shouldShowPending(plan: "pro", recordedTrial: expired))
        precondition(Activation(available: false).shouldShowPending(plan: "trial", recordedTrial: active))
        precondition(!Activation(available: false).shouldShowPending(plan: "free", recordedTrial: expired))
        precondition(!Activation(available: true).shouldShowPending(plan: "pro", recordedTrial: expired))
        print("PASS: 12 current-plan, downgrade, and activation-pending scenarios")
    }
}
'''
)
env = dict(os.environ, TMPDIR=str(work))
compile_result = subprocess.run(
    ["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(work / "module-cache"),
     str(fixture), "-o", str(work / "check")],
    env=env, text=True, capture_output=True,
)
assert compile_result.returncode == 0, compile_result.stdout + compile_result.stderr
run_result = subprocess.run([str(work / "check")], env=env, text=True, capture_output=True)
assert run_result.returncode == 0, run_result.stdout + run_result.stderr
print(run_result.stdout.strip())
print(f"Fixture: {work}")
