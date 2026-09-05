#!/bin/bash
#
# bridge-cmd-paywallshot.sh — the exact command block the INTEGRATOR drops into
# the Mac build bridge to capture the App Store Connect SUBSCRIPTION REVIEW
# screenshot: the real paywall, real product names, real StoreKit prices.
#
#   bash "$HOME/Rendprop AI/repo/apps/ios/RendpropUITests/bridge-cmd-paywallshot.sh"
#
# It finds (or creates) and boots the same dedicated "Store 6.9" simulator the
# store shots use, freezes its status bar at 9:41 / full battery / full bars,
# runs ONE test (RendpropUITests/PaywallShot), pulls the PNGs out of the
# .xcresult, and — the one thing no other bridge script does — copies the
# monthly shot INTO THE REPO as docs/appstore/iap-review/paywall.png when it is
# exactly 1320 x 2868. `python3 tools/asc/asc.py review apply` attaches that
# file to every auto-renewable subscription.
#
# Output: ~/Rendprop AI/_bridge/out/paywallshot/p01-paywall-monthly.png
#                                              p02-paywall-yearly.png
#                                              p03-paywall-legal.png
#         ~/Rendprop AI/repo/docs/appstore/iap-review/paywall.png   (= p01)
#
# HOW THE PRODUCTS GET THERE. `xcodebuild test` attaches no StoreKit
# configuration (the scheme's is on the Run action only), so on its own the
# paywall would render "Plans aren't available right now". PaywallShot.swift
# creates an `SKTestSession` from Rendprop.storekit — a resource of the test
# bundle — before launching the app, which is Apple's automation path for
# StoreKit Testing in Xcode. If that did not take, the test captures the empty
# state as p01-paywall-EMPTY.png instead and this script says so; nothing
# empty is ever copied into the repo.
#
# NO PHOTOS ARE SEEDED (the paywall has no photos) and NO PURCHASE IS EVER
# MADE (the test never taps Subscribe / Start 7-day free trial).
#
# It never fails the bridge: every stage reports its own exit code and the run
# continues. The last line is always PAYWALL_PNG=<path> or PAYWALL_PNG=MISSING.
# Nothing here deploys anything or touches production.

set -u -o pipefail

ROOT="$HOME/Rendprop AI"
IOS_DIR="$ROOT/repo/apps/ios"
OUT_DIR="$ROOT/_bridge/out"
SHOTS_DIR="$OUT_DIR/paywallshot"          # the deliverable — only p*.png land here
RAW_DIR="$OUT_DIR/paywallshot-raw"        # xcresulttool's dumping ground
DD_DIR="$ROOT/_bridge/dd-paywallshot"
RESULT="$OUT_DIR/paywallshot-$(date +%s).xcresult"
LOG="/tmp/rp-paywallshot.log"

# Where the review screenshot lives in the repo. tools/asc/asc.py reads exactly
# this path (IAP_SCREENSHOT) — do not rename it.
IAP_DIR="$ROOT/repo/docs/appstore/iap-review"
IAP_PNG="$IAP_DIR/paywall.png"
DELIVERABLE="p01-paywall-monthly.png"

SIM_NAME="Store 6.9"
WANT_W=1320
WANT_H=2868

mkdir -p "$OUT_DIR" "$SHOTS_DIR" "$RAW_DIR"
rm -f "$SHOTS_DIR"/*.png 2>/dev/null       # a stale p01 from a previous run lies

# ---------------------------------------------------------------- 1. generate
# NOT optional: the committed .xcodeproj predates the UI test target, and the
# regenerated one is what adds Rendprop.storekit to RendpropUITests' resources.
cd "$IOS_DIR" || { echo "MISSING_DIR=$IOS_DIR"; echo "PAYWALL_PNG=MISSING"; exit 1; }
xcodegen generate
echo "XCODEGEN_EXIT=$?"

# ------------------------------------------------- 2. find or create the sim
# 6.9-inch class. iPhone 17 Pro Max first, iPhone 16 Pro Max as the fallback —
# both are 1320 x 2868. Same block as bridge-cmd-storeshots.sh, so it reuses the
# "Store 6.9" device that script created.
UDID="$(python3 - "$SIM_NAME" <<'PY'
import json, subprocess, sys, re
name = sys.argv[1]

def sh(*args):
    return json.loads(subprocess.check_output(["xcrun", "simctl", *args, "-j"]))

# Already there (from a previous run)?
for runtime, devices in sh("list", "devices")["devices"].items():
    for d in devices:
        if d.get("name") == name and d.get("isAvailable", True):
            print(d["udid"]); sys.exit(0)

# Newest available iOS runtime. Match on the identifier, not on "platform":
# older Xcode omits that key, and picking a watchOS runtime by accident would
# fail the create with a confusing message.
runtimes = [r for r in sh("list", "runtimes")["runtimes"]
            if r.get("isAvailable") and ".SimRuntime.iOS-" in r.get("identifier", "")]
if not runtimes:
    sys.stderr.write("NO_IOS_RUNTIME\n"); print("", end=""); sys.exit(0)

def version_key(r):
    return [int(p) for p in re.findall(r"\d+", r.get("version", "0"))]

runtime = max(runtimes, key=version_key)

# 6.9-inch, in preference order. Both are 1320 x 2868.
types = {t["identifier"] for t in sh("list", "devicetypes")["devicetypes"]}
wanted = ["com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max",
          "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro-Max"]
for device_type in wanted:
    if device_type not in types:
        continue
    sys.stderr.write("CREATING %s on %s with %s\n"
                     % (name, runtime["identifier"], device_type.rsplit(".", 1)[-1]))
    try:
        out = subprocess.check_output(
            ["xcrun", "simctl", "create", name, device_type, runtime["identifier"]],
            stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        # That device type is not supported by this runtime — try the next one.
        continue
    print(out.decode().strip()); sys.exit(0)

sys.stderr.write("NO_69_DEVICE_TYPE\n")
print("", end="")
PY
)"
echo "SIM_NAME=$SIM_NAME"
echo "SIM_UDID=$UDID"
if [ -z "$UDID" ]; then
  echo "NO_SIMULATOR — neither iPhone 17 Pro Max nor iPhone 16 Pro Max is installed."
  echo "Install one: Xcode → Settings → Components, then re-run."
  echo "PAYWALL_PNG=MISSING"
  exit 1
fi

# -------------------------------------------------------------------- 3. boot
xcrun simctl boot "$UDID" 2>/dev/null
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
echo "SIM_STATE=$(xcrun simctl list devices | grep "$UDID" | sed 's/.*(\(.*\))/\1/')"

# Same status bar as the store shots: 9:41, charged, full Wi-Fi and cellular,
# so this PNG sits next to them without a random 14:37 / 23% dating it. Must be
# re-applied after every boot.
xcrun simctl status_bar "$UDID" override \
  --time 9:41 \
  --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4
echo "STATUS_BAR_EXIT=$?"

# NO `simctl addmedia` HERE ON PURPOSE — the paywall shows no photos.

# -------------------------------------------------------------------- 4. test
xcodebuild test \
  -project Rendprop.xcodeproj \
  -scheme Rendprop \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:RendpropUITests/PaywallShot \
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

# ------------------------------------------- 6. size report + the p*.png set
# Every p-named attachment is copied to the output folder with its size, so
# the yearly and legal shots (and an EMPTY one, if that is what happened) are
# there to look at. The size gate proper is applied to the deliverable below.
COPIED=0
for src in "$RAW_DIR"/p[0-9][0-9]-*.png; do
  [ -e "$src" ] || continue
  BASE="$(basename "$src")"
  W=$(sips -g pixelWidth  "$src" 2>/dev/null | awk '/pixelWidth/{print $2}')
  H=$(sips -g pixelHeight "$src" 2>/dev/null | awk '/pixelHeight/{print $2}')
  cp "$src" "$SHOTS_DIR/$BASE"
  COPIED=$((COPIED + 1))
  if [ "$W" = "$WANT_W" ] && [ "$H" = "$WANT_H" ]; then
    echo "OK    $BASE  ${W}x${H}"
  else
    echo "SIZE  $BASE  ${W:-?}x${H:-?}  (expected ${WANT_W}x${WANT_H} — wrong simulator?)"
  fi
done
echo "COPIED=$COPIED"

if [ -e "$RAW_DIR/p01-paywall-EMPTY.png" ]; then
  echo "PAYWALL_EMPTY — the paywall rendered its empty state (no StoreKit products). Read the"
  echo "  STOREKIT / EMPTY activity notes (SKIP_NOTES below). Nothing was copied into the repo."
fi

# ------------------------------------- 7. the deliverable → the repo, gated
# ONLY the monthly shot, ONLY when it exists and is exactly 1320 x 2868. An
# EMPTY capture has a different name and can never land here.
PAYWALL_PNG="MISSING"
SRC="$RAW_DIR/$DELIVERABLE"
if [ -e "$SRC" ]; then
  W=$(sips -g pixelWidth  "$SRC" 2>/dev/null | awk '/pixelWidth/{print $2}')
  H=$(sips -g pixelHeight "$SRC" 2>/dev/null | awk '/pixelHeight/{print $2}')
  if [ "$W" = "$WANT_W" ] && [ "$H" = "$WANT_H" ]; then
    mkdir -p "$IAP_DIR"
    if cp "$SRC" "$IAP_PNG"; then
      PAYWALL_PNG="$IAP_PNG"
      echo "COPIED_TO_REPO  $DELIVERABLE → $IAP_PNG  (${W}x${H})"
    else
      echo "COPY_FAILED  could not write $IAP_PNG"
    fi
  else
    echo "WRONG_SIZE  $DELIVERABLE is ${W:-?}x${H:-?}, need ${WANT_W}x${WANT_H} — NOT copied into the repo"
  fi
else
  echo "NO_DELIVERABLE  $DELIVERABLE was not produced — see $LOG and the activity notes"
fi

# ------------------------------------------------------------------- 8. report
echo "RESULT_BUNDLE=$RESULT"
echo "PAYWALLSHOT_DIR=$SHOTS_DIR"
ls -la "$SHOTS_DIR"/*.png 2>/dev/null \
  || echo "NO_PNGS — read $LOG and the activity notes in $RESULT"

# The STOREKIT note (which SKTestSession init worked, or why none did), the
# "Price rendered: …" proof, and any skip reasons live in the result bundle as
# activity names:
echo "SKIP_NOTES=xcrun xcresulttool get test-results activities --path \"$RESULT\" --test-id 'PaywallShot/testPaywallShot()'"

# Next step once PAYWALL_PNG is a path: commit docs/appstore/iap-review/paywall.png,
# then attach it to every subscription with
#   python3 tools/asc/asc.py review apply --skip-product com.rendprop.app.team.annual
echo "PAYWALL_PNG=$PAYWALL_PNG"

# Leave the status-bar override in place: it costs nothing, and a re-run that
# forgets it would produce a set with two different clocks.
