#!/bin/bash
#
# bridge-cmd-industrywalk.sh — the exact command block the INTEGRATOR drops into
# the Mac build bridge to run the PER-INDUSTRY walk and pull out the
# screenshots AND the CHECK results.
#
#   bash "$HOME/Rendprop AI/repo/apps/ios/RendpropUITests/bridge-cmd-industrywalk.sh"
#
# It boots the iPhone simulator, UNINSTALLS the app so every industry starts
# from a clean container (each test then creates exactly ONE real project of
# its own type — see IndustryWalk.swift), freezes the status bar at 9:41, runs
# the six tests in RendpropUITests/IndustryWalk (real estate as the control,
# then venue, restaurant, retail, fitness, other), and exports:
#
#   ~/Rendprop AI/_bridge/out/industrywalk/<type>-NN-<screen>.png   every screenshot
#   ~/Rendprop AI/_bridge/out/industrywalk/checks.txt                every CHECK PASS / CHECK FAIL line
#   ~/Rendprop AI/_bridge/out/industrywalk/activities-<test>.txt     the full activity log per test
#                                                                    (skip reasons, STOREKIT note, fallbacks)
#
# checks.txt is the deliverable the owner reads next to the PNGs: one line per
# expectation, `CHECK FAIL …: <what the screen actually said>` for anything
# that leaked across an industry line. docs/qa/industry-review.md lists the
# failures that are already known from reading the code.
#
# NOTHING IS DELETED FOR REAL. Each test taps "Delete account" once to
# photograph the confirmation and then taps Cancel — see the safety notes at
# the top of IndustryWalk.swift. No purchase is made, no AI edit is run.
#
# It never fails the bridge: every stage reports its own exit code and the run
# continues, because 100 good screenshots are still worth having when one
# industry's step skipped itself. Nothing here writes to the repo, deploys
# anything, or touches production.
#
# Env knobs:
#   KEEP_APP=1   skip the uninstall (re-run on a dirty container — the walk
#                copes: with 2+ projects of a type the "Pick a …" picker is used)
#   SIM_UDID=…   run on a different simulator
#   ONLY_TEST=testVenue   run one industry's test instead of all six (~11 min each)

set -u -o pipefail

UDID="${SIM_UDID:-CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E}"   # iPhone 17 Pro (6.3-inch), iOS 26.x — same as the UI walk
APP_ID="com.rendprop.app"

ROOT="$HOME/Rendprop AI"
IOS_DIR="$ROOT/repo/apps/ios"
OUT_DIR="$ROOT/_bridge/out"
SHOTS_DIR="$OUT_DIR/industrywalk"          # the deliverable — PNGs + checks.txt + activity logs
RAW_DIR="$OUT_DIR/industrywalk-raw"        # xcresulttool's dumping ground
DD_DIR="$ROOT/_bridge/dd-industrywalk"
RESULT="$OUT_DIR/industrywalk-$(date +%s).xcresult"
LOG="/tmp/rp-industrywalk.log"

TESTS=(testRealEstate testVenue testRestaurant testRetail testFitness testOther)

mkdir -p "$OUT_DIR" "$SHOTS_DIR" "$RAW_DIR"
rm -f "$SHOTS_DIR"/*.png "$SHOTS_DIR"/checks.txt "$SHOTS_DIR"/activities-*.txt 2>/dev/null   # stale results lie

# ---------------------------------------------------------------- 1. generate
# NOT optional: the committed .xcodeproj has no RendpropUITests target. xcodegen
# picks IndustryWalk.swift up from the RendpropUITests folder automatically
# (bridge-cmd-*.sh is excluded by project.yml, so this script never lands in
# the bundle).
cd "$IOS_DIR" || { echo "MISSING_DIR=$IOS_DIR"; exit 1; }
xcodegen generate
echo "XCODEGEN_EXIT=$?"

# -------------------------------------------------------------------- 2. boot
# The fixed UDID first; if that simulator is gone, the newest available
# iPhone on the newest iOS runtime, so the run still happens.
if ! xcrun simctl list devices | grep -q "$UDID"; then
  echo "SIM_FALLBACK: $UDID is not on this Mac — picking an available iPhone"
  UDID="$(python3 - <<'PY'
import json, subprocess, re
devs = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"]))["devices"]
best = None
for runtime, devices in devs.items():
    if ".SimRuntime.iOS-" not in runtime:
        continue
    ver = [int(p) for p in re.findall(r"\d+", runtime.rsplit("iOS-", 1)[-1])]
    for d in devices:
        if not d.get("isAvailable", True) or "iPhone" not in d.get("name", ""):
            continue
        key = (d.get("state") == "Booted", ver, d["name"])
        if best is None or key > best[0]:
            best = (key, d["udid"])
print(best[1] if best else "", end="")
PY
)"
fi
if [ -z "$UDID" ]; then
  echo "NO_SIMULATOR — install an iPhone simulator (Xcode → Settings → Components) and re-run."
  exit 1
fi
xcrun simctl boot "$UDID" 2>/dev/null
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
echo "SIM_UDID=$UDID"
echo "SIM_STATE=$(xcrun simctl list devices | grep "$UDID" | sed 's/.*(\(.*\))/\1/')"

# ------------------------------------------------------- 3. wipe the container
# Must come AFTER the boot and BEFORE the test. A clean container means every
# industry's first "Take photos" hits the "Name this <noun> first" gate and
# creates exactly one project ("Walk Test Venue", "1 Walk Test Street", …), so
# the shots are the same run to run. KEEP_APP=1 skips it. Not-installed is
# not an error.
if [ "${KEEP_APP:-0}" = "1" ]; then
  echo "UNINSTALL_EXIT=skipped (KEEP_APP=1)"
else
  xcrun simctl uninstall "$UDID" "$APP_ID" 2>/dev/null
  echo "UNINSTALL_EXIT=$? (app $APP_ID — 'not installed' is fine, the container is gone either way)"
fi

# Marketing status bar: 9:41, charged, full Wi-Fi and cellular — the same
# convention every other capture uses, so a per-industry PNG sits beside a
# store PNG without one being dated by a random clock.
xcrun simctl status_bar "$UDID" override \
  --time 9:41 \
  --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4
echo "STATUS_BAR_EXIT=$?"

# NO `simctl addmedia` here on purpose: the walk never adds a photo, so the
# reel card is photographed in its honest disabled state.

# -------------------------------------------------------------------- 4. test
# Six tests, ~4–6 minutes each. The class is filtered as a whole so a test id
# that changes name later still runs.
xcodebuild test \
  -project Rendprop.xcodeproj \
  -scheme Rendprop \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:"RendpropUITests/IndustryWalk${ONLY_TEST:+/$ONLY_TEST}" \
  -derivedDataPath "$DD_DIR" \
  -resultBundlePath "$RESULT" \
  > "$LOG" 2>&1
echo "TEST_EXIT=$?"
grep -E "error:|Test Case|passed|failed" "$LOG" | tail -40

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

# ------------------------------------------------------- 6. the screenshots
# Only the walk's own names are copied — the exporter also drops raw blobs and
# the manifest. Named <type>-NN-<screen>.png, so `ls` reads in walk order per
# industry.
COPIED=0
for src in "$RAW_DIR"/realestate-*.png "$RAW_DIR"/venue-*.png "$RAW_DIR"/restaurant-*.png \
           "$RAW_DIR"/retail-*.png "$RAW_DIR"/fitness-*.png "$RAW_DIR"/other-*.png; do
  [ -e "$src" ] || continue
  BASE="$(basename "$src")"
  cp "$src" "$SHOTS_DIR/$BASE"
  COPIED=$((COPIED + 1))
done
echo "COPIED=$COPIED"

# ------------------------------------------------------- 7. the CHECK lines
# Every expectation the walk made is an activity named "CHECK PASS …" or
# "CHECK FAIL …: <actual>". Pull each test's activity tree (Xcode 16+/26
# `get test-results activities`), keep the CHECK lines, and write them to
# checks.txt prefixed with the test name. The whole tree — skip reasons, the
# STOREKIT note, the switcher fallback — goes to activities-<test>.txt.
# If the modern verb is missing, the legacy object graph is walked instead.
CHECKS="$SHOTS_DIR/checks.txt"
: > "$CHECKS"
if [ -d "$RESULT" ]; then
  for T in "${TESTS[@]}"; do
    TEST_ID="IndustryWalk/$T()"
    ACT_JSON="$RAW_DIR/activities-$T.json"
    ACT_TXT="$SHOTS_DIR/activities-$T.txt"
    if xcrun xcresulttool get test-results activities --path "$RESULT" --test-id "$TEST_ID" > "$ACT_JSON" 2>/dev/null \
       && [ -s "$ACT_JSON" ]; then
      python3 - "$ACT_JSON" "$T" "$CHECKS" "$ACT_TXT" <<'PY'
import json, sys
path, test, checks_path, act_path = sys.argv[1:5]
try:
    doc = json.load(open(path))
except Exception as e:
    sys.stderr.write("ACTIVITIES_PARSE_FAILED %s: %s\n" % (test, e))
    sys.exit(0)

titles = []
def walk(node, depth):
    if isinstance(node, dict):
        t = node.get("title")
        if isinstance(t, str):
            titles.append((depth, t))
        for k, v in node.items():
            if k != "title":
                walk(v, depth + 1)
    elif isinstance(node, list):
        for v in node:
            walk(v, depth)
walk(doc, 0)

with open(act_path, "w") as f:
    for depth, t in titles:
        f.write(("  " * min(depth, 6)) + t.replace("\n", " ") + "\n")

n_pass = n_fail = 0
with open(checks_path, "a") as f:
    for _, t in titles:
        if t.startswith("CHECK PASS") or t.startswith("CHECK FAIL"):
            f.write("%s  %s\n" % (test, t.replace("\n", " ")))
            if t.startswith("CHECK PASS"):
                n_pass += 1
            else:
                n_fail += 1
print("CHECKS %s: %d pass, %d fail, %d activities" % (test, n_pass, n_fail, len(titles)))
PY
    else
      echo "ACTIVITIES_MODERN_UNAVAILABLE for $TEST_ID — using the legacy graph"
      python3 - "$RESULT" "$T" "$CHECKS" "$ACT_TXT" <<'PY'
import json, subprocess, sys
bundle, test, checks_path, act_path = sys.argv[1:5]

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

def titles_in(node, out, depth=0):
    """Every activity title under an ActionTestSummary, in tree order."""
    if isinstance(node, dict):
        t = val(node, "title")
        if isinstance(t, str) and val(node, "_type", "_name") == "ActionTestActivitySummary":
            out.append((depth, t))
        for k, v in node.items():
            titles_in(v, out, depth + (1 if k == "subactivities" else 0))
    elif isinstance(node, list):
        for v in node:
            titles_in(v, out, depth)

titles = []
try:
    root = get()
    for action in (root.get("actions", {}).get("_values") or []):
        tests_ref = val(action, "actionResult", "testsRef", "id")
        if not tests_ref:
            continue
        summary_ids = []
        collect_summary_refs(get(tests_ref), summary_ids)
        for sid in summary_ids:
            summary = get(sid)
            name = val(summary, "name") or ""
            ident = val(summary, "identifier") or ""
            if test in name or test in ident:
                titles_in(summary, titles)
except Exception as e:
    sys.stderr.write("LEGACY_ACTIVITIES_FAILED %s: %s\n" % (test, e))

with open(act_path, "w") as f:
    for depth, t in titles:
        f.write(("  " * min(depth, 6)) + t.replace("\n", " ") + "\n")
n_pass = sum(1 for _, t in titles if t.startswith("CHECK PASS"))
n_fail = sum(1 for _, t in titles if t.startswith("CHECK FAIL"))
with open(checks_path, "a") as f:
    for _, t in titles:
        if t.startswith("CHECK PASS") or t.startswith("CHECK FAIL"):
            f.write("%s  %s\n" % (test, t.replace("\n", " ")))
print("CHECKS %s (legacy): %d pass, %d fail, %d activities" % (test, n_pass, n_fail, len(titles)))
PY
    fi
  done
fi

# ------------------------------------------------------------------- 8. report
echo "RESULT_BUNDLE=$RESULT"
echo "INDUSTRYWALK_DIR=$SHOTS_DIR"
echo "CHECKS_FILE=$CHECKS"
echo "CHECKS_PASS=$(grep -c 'CHECK PASS' "$CHECKS" 2>/dev/null || echo 0)"
echo "CHECKS_FAIL=$(grep -c 'CHECK FAIL' "$CHECKS" 2>/dev/null || echo 0)"
echo "---- CHECK FAIL lines (what leaked, per industry) ----"
grep 'CHECK FAIL' "$CHECKS" 2>/dev/null || echo "(none — or no result bundle; read $LOG)"
echo "---- screenshots ----"
ls -la "$SHOTS_DIR"/*.png 2>/dev/null \
  || echo "NO_PNGS — read $LOG and the activity notes in $RESULT"

# The full activity trees (skip reasons, STOREKIT note, switcher fallback):
#   $SHOTS_DIR/activities-<test>.txt, or directly:
echo "ACTIVITIES=xcrun xcresulttool get test-results activities --path \"$RESULT\" --test-id 'IndustryWalk/testVenue()'"

# Leave the status-bar override in place: it costs nothing, and a re-run that
# forgets it would produce a set with two different clocks.
