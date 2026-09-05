#!/bin/bash
#
# bridge-cmd-reviewerwalk.sh — the exact command block the INTEGRATOR drops into
# the Mac build bridge to capture WHAT AN APP STORE REVIEWER SEES FIRST.
#
#   bash "$HOME/Rendprop AI/repo/apps/ios/RendpropUITests/bridge-cmd-reviewerwalk.sh"
#
# It boots the existing 6.3-inch iPhone 17 Pro simulator, UNINSTALLS the app so
# UserDefaults are genuinely empty, freezes the status bar at 9:41 / full
# battery / full bars, runs ONE test (RendpropUITests/ReviewerWalk), and pulls
# the PNGs out of the .xcresult.
#
# Output: ~/Rendprop AI/_bridge/out/reviewerwalk/r01-….png … r11-….png
#
# THE UNINSTALL IS THE POINT. `ReviewerWalk` passes only `-uiTesting` and
# `-appearance light`; it does NOT pass `-hasOnboarded YES` or
# `-ai.thirdPartyProcessing.consent.v1 YES` the way the UI walk and the store
# shots do. Those two flags live in UserDefaults inside the app's container, so
# a container left over from a previous run would already have `hasOnboarded`
# true and the AI consent granted — the intro would not show, the consent sheet
# would not appear, and the run would quietly capture the wrong app. `xcrun
# simctl uninstall` deletes the container, which is the only way to be sure.
#
# NO PHOTOS ARE SEEDED. Unlike bridge-cmd-storeshots.sh this run wants an empty
# photo library: a reviewer's simulator has one too, and r11 stops at the AI
# consent sheet without ever picking a photo.
#
# NOTHING IS DELETED FOR REAL. The test taps "Delete account" once to
# photograph the Guideline 5.1.1(v) confirmation and then taps Cancel — see the
# safety notes at the top of ReviewerWalk.swift.
#
# It never fails the bridge: every stage reports its own exit code and the run
# continues, because ten good screenshots are still worth having.
# Nothing here writes to the repo, deploys anything, or touches production.

set -u -o pipefail

UDID="CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E"     # iPhone 17 Pro (6.3-inch), iOS 26.x
APP_ID="com.rendprop.app"

ROOT="$HOME/Rendprop AI"
IOS_DIR="$ROOT/repo/apps/ios"
OUT_DIR="$ROOT/_bridge/out"
SHOTS_DIR="$OUT_DIR/reviewerwalk"          # the deliverable — only r*.png land here
RAW_DIR="$OUT_DIR/reviewerwalk-raw"        # xcresulttool's dumping ground
DD_DIR="$ROOT/_bridge/dd-reviewerwalk"
RESULT="$OUT_DIR/reviewerwalk-$(date +%s).xcresult"
LOG="/tmp/rp-reviewerwalk.log"

mkdir -p "$OUT_DIR" "$SHOTS_DIR" "$RAW_DIR"
rm -f "$SHOTS_DIR"/*.png 2>/dev/null       # a stale r09 from a previous run lies

# ---------------------------------------------------------------- 1. generate
cd "$IOS_DIR" || { echo "MISSING_DIR=$IOS_DIR"; exit 1; }
xcodegen generate
echo "XCODEGEN_EXIT=$?"

# -------------------------------------------------------------------- 2. boot
# Already-booted is not an error.
xcrun simctl boot "$UDID" 2>/dev/null
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
echo "SIM_UDID=$UDID"
echo "SIM_STATE=$(xcrun simctl list devices | grep "$UDID" | sed 's/.*(\(.*\))/\1/')"

# ------------------------------------------------------- 3. WIPE THE CONTAINER
# Must come AFTER the boot (uninstall needs a booted device) and BEFORE the
# test. This is what makes the run a first-run: it deletes the app's
# UserDefaults, so `hasOnboarded` is false and
# `ai.thirdPartyProcessing.consent.v1` is unset. Not-installed is not an error.
xcrun simctl uninstall "$UDID" "$APP_ID" 2>/dev/null
echo "UNINSTALL_EXIT=$? (app $APP_ID — 'not installed' is fine, the container is gone either way)"

# Marketing status bar: 9:41, charged, full Wi-Fi and cellular — the same
# convention the store shots use, so a reviewer-walk PNG and a store PNG sit
# side by side without one of them being dated by a random clock. Must be
# re-applied after every boot.
xcrun simctl status_bar "$UDID" override \
  --time 9:41 \
  --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4
echo "STATUS_BAR_EXIT=$?"

# NO `simctl addmedia` HERE ON PURPOSE — see the header.

# -------------------------------------------------------------------- 4. test
xcodebuild test \
  -project Rendprop.xcodeproj \
  -scheme Rendprop \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:RendpropUITests/ReviewerWalk \
  -derivedDataPath "$DD_DIR" \
  -resultBundlePath "$RESULT" \
  > "$LOG" 2>&1
echo "TEST_EXIT=$?"
grep -E "error:|Test Case|passed|failed" "$LOG" | tail -30

# ---------------------------------------------------------- 5. export the PNGs
# Xcode 16+/26 path. It writes every attachment plus a manifest.json that maps
# the exported blob names back to the names the test gave them.
if [ ! -d "$RESULT" ]; then
  echo "EXPORT_EXIT=no result bundle at $RESULT"
else
  rm -rf "$RAW_DIR"; mkdir -p "$RAW_DIR"
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$RAW_DIR"
  EXPORT_EXIT=$?
  echo "EXPORT_ATTACHMENTS_EXIT=$EXPORT_EXIT"

  if [ -f "$RAW_DIR/manifest.json" ]; then
    python3 - "$RAW_DIR" <<'PY'
import json, os, shutil, sys
raw = sys.argv[1]
manifest = json.load(open(os.path.join(raw, "manifest.json")))
entries = manifest if isinstance(manifest, list) else [manifest]
renamed = 0
for test in entries:
    for att in (test.get("attachments") or []):
        src = att.get("exportedFileName")
        name = att.get("suggestedHumanReadableName") or att.get("name") or ""
        if not src or not name:
            continue
        src_path = os.path.join(raw, src)
        if not os.path.exists(src_path):
            continue
        ext = os.path.splitext(src)[1] or ".png"
        dst = os.path.join(raw, name if name.endswith(ext) else name + ext)
        if os.path.abspath(src_path) != os.path.abspath(dst):
            shutil.copyfile(src_path, dst)
            renamed += 1
print("RENAMED=%d" % renamed)
PY
  fi

  # Fallback for a toolchain without `export attachments`: walk the legacy
  # object graph and pull each named attachment out one by one.
  if [ "$EXPORT_EXIT" -ne 0 ]; then
    echo "falling back to the legacy xcresulttool flow"
    python3 - "$RESULT" "$RAW_DIR" <<'PY'
import json, subprocess, sys, os
bundle, out = sys.argv[1], sys.argv[2]

def get(obj_id=None):
    cmd = ["xcrun", "xcresulttool", "get", "--legacy", "--format", "json", "--path", bundle]
    if obj_id:
        cmd += ["--id", obj_id]
    return json.loads(subprocess.check_output(cmd))

def val(node, *keys):
    for k in keys:
        if not isinstance(node, dict):
            return None
        node = node.get(k)
    return node.get("_value") if isinstance(node, dict) else node

def walk(node, found):
    if isinstance(node, dict):
        if "attachments" in node:
            for a in (node["attachments"].get("_values") or []):
                name = val(a, "name") or val(a, "filename")
                pid = val(a, "payloadRef", "id")
                if name and pid:
                    found.append((name, pid))
        for v in node.values():
            walk(v, found)
    elif isinstance(node, list):
        for v in node:
            walk(v, found)

def collect_summary_refs(node, ids):
    if isinstance(node, dict):
        sid = val(node, "summaryRef", "id")
        if sid:
            ids.append(sid)
        for v in node.values():
            collect_summary_refs(v, ids)
    elif isinstance(node, list):
        for v in node:
            collect_summary_refs(v, ids)

root = get()
found = []
for action in (root.get("actions", {}).get("_values") or []):
    tests_ref = val(action, "actionResult", "testsRef", "id")
    if not tests_ref:
        continue
    summary_ids = []
    collect_summary_refs(get(tests_ref), summary_ids)
    for sid in summary_ids:
        walk(get(sid), found)

os.makedirs(out, exist_ok=True)
n = 0
for name, pid in found:
    dst = os.path.join(out, name if name.lower().endswith(".png") else name + ".png")
    rc = subprocess.call(["xcrun", "xcresulttool", "export", "--legacy", "--type", "file",
                          "--path", bundle, "--id", pid, "--output-path", dst])
    if rc == 0:
        n += 1
print("LEGACY_EXPORTED=%d" % n)
PY
    echo "LEGACY_EXPORT_EXIT=$?"
  fi
fi

# ------------------------------------------------------- 6. the deliverable
# No size gate here: these are review-notes screenshots, not App Store Connect
# uploads, so any size the simulator produces is fine. Only the r-named ones
# are copied — the exporter also drops raw blobs and the manifest.
COPIED=0
for src in "$RAW_DIR"/r[0-9][0-9]-*.png; do
  [ -e "$src" ] || continue
  BASE="$(basename "$src")"
  cp "$src" "$SHOTS_DIR/$BASE"
  COPIED=$((COPIED + 1))
  DIM="$(sips -g pixelWidth -g pixelHeight "$src" 2>/dev/null \
        | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w"x"h}')"
  echo "OK    $BASE  $DIM"
done
echo "COPIED=$COPIED"

# ------------------------------------------------------------------- 7. report
echo "RESULT_BUNDLE=$RESULT"
echo "REVIEWERWALK_DIR=$SHOTS_DIR"
ls -la "$SHOTS_DIR"/*.png 2>/dev/null \
  || echo "NO_PNGS — read $LOG and the activity notes in $RESULT"

# The skip reasons — and the onboarding page count — live in the result bundle
# as activity names. r10 (the sign-in gate) is EXPECTED to skip: the app reports
# itself signed in for the whole run because AuthStore short-circuits on
# `Config.isUITesting`, so that sheet has to be captured by hand on a device.
echo "SKIP_NOTES=xcrun xcresulttool get test-results activities --path \"$RESULT\" --test-id 'ReviewerWalk/testReviewerWalk()'"

# Leave the status-bar override in place: it costs nothing, and a re-run that
# forgets it would produce a set with two different clocks.
