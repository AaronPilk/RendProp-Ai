#!/bin/bash
#
# bridge-cmd-storeshots.sh — the exact command block the INTEGRATOR drops into
# the Mac build bridge to capture the App Store screenshot set (6.9-inch).
#
#   bash "$HOME/Rendprop AI/repo/apps/ios/RendpropUITests/bridge-cmd-storeshots.sh"
#
# It creates (once) and boots a dedicated "Store 6.9" simulator, freezes its
# status bar at 9:41 / full battery / full bars, runs ONE test
# (RendpropUITests/StoreShots), pulls the PNGs out of the .xcresult, and refuses
# to hand over anything that is not exactly 1320 x 2868.
#
# Output: ~/Rendprop AI/_bridge/out/storeshots/s01-….png … s08-….png
#
# It never fails the bridge: every stage reports its own exit code and the run
# continues, because seven good screenshots are still worth having.
# Nothing here writes to the repo, deploys anything, or touches production.

set -u -o pipefail

ROOT="$HOME/Rendprop AI"
IOS_DIR="$ROOT/repo/apps/ios"
OUT_DIR="$ROOT/_bridge/out"
SHOTS_DIR="$OUT_DIR/storeshots"          # the deliverable — only s0*.png land here
RAW_DIR="$OUT_DIR/storeshots-raw"        # xcresulttool's dumping ground
PHOTO_DIR="$ROOT/_bridge/in/storeshot-photos"   # OPTIONAL: your own interior photos
DD_DIR="$ROOT/_bridge/dd-storeshots"
RESULT="$OUT_DIR/storeshots-$(date +%s).xcresult"
LOG="/tmp/rp-storeshots.log"

SIM_NAME="Store 6.9"
WANT_W=1320
WANT_H=2868

mkdir -p "$OUT_DIR" "$SHOTS_DIR" "$RAW_DIR"
rm -f "$SHOTS_DIR"/*.png 2>/dev/null       # a stale s05 from a previous run lies

# ---------------------------------------------------------------- 1. generate
cd "$IOS_DIR" || { echo "MISSING_DIR=$IOS_DIR"; exit 1; }
xcodegen generate
echo "XCODEGEN_EXIT=$?"

# ------------------------------------------------- 2. find or create the sim
# 6.9-inch class. iPhone 17 Pro Max first, iPhone 16 Pro Max as the fallback —
# both are 1320 x 2868, so either produces a valid 6.9" set.
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
  exit 1
fi

# -------------------------------------------------------------------- 3. boot
xcrun simctl boot "$UDID" 2>/dev/null
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
echo "SIM_STATE=$(xcrun simctl list devices | grep "$UDID" | sed 's/.*(\(.*\))/\1/')"

# Marketing status bar: 9:41, charged, full Wi-Fi and cellular. This is the
# convention every Apple screenshot uses, and it stops a random 14:37 / 23%
# battery from dating the set. Must be re-applied after every boot.
xcrun simctl status_bar "$UDID" override \
  --time 9:41 \
  --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4
echo "STATUS_BAR_EXIT=$?"

# --------------------------------------------------------- 4. seed the photos
# s04 (AI Photo Studio) and s05 (Reel Studio) look like the product only when
# the home has real photos — and the reel card stays disabled below two.
#
# BEST: drop your own listing photos (interiors, exteriors — the shots you would
# actually put on a listing) into $PHOTO_DIR. They are what appears in the
# screenshots, so they are worth doing properly. Nothing there? The run falls
# back to whatever macOS ships as a desktop picture, and if even that fails the
# studio is captured showing its one-tap-edit showcase instead.
SEED_DIR="$(mktemp -d)"
SEED_COUNT=0
if [ -d "$PHOTO_DIR" ]; then
  while IFS= read -r src; do
    [ -z "$src" ] && continue
    SEED_COUNT=$((SEED_COUNT + 1))
    sips -s format png "$src" --out "$SEED_DIR/seed-$SEED_COUNT.png" >/dev/null 2>&1 \
      || SEED_COUNT=$((SEED_COUNT - 1))
    [ "$SEED_COUNT" -ge 6 ] && break
  done < <(find "$PHOTO_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' \) | sort)
fi
if [ "$SEED_COUNT" -eq 0 ]; then
  echo "NO_OWN_PHOTOS — $PHOTO_DIR is empty or missing. Falling back to a system image."
  while IFS= read -r src; do
    [ -z "$src" ] && continue
    SEED_COUNT=$((SEED_COUNT + 1))
    sips -s format png "$src" --out "$SEED_DIR/seed-$SEED_COUNT.png" >/dev/null 2>&1 \
      || SEED_COUNT=$((SEED_COUNT - 1))
    [ "$SEED_COUNT" -ge 3 ] && break
  done < <(find /System/Library/Desktop\ Pictures /Library/Desktop\ Pictures \
                -maxdepth 2 -type f \( -iname '*.heic' -o -iname '*.jpg' -o -iname '*.png' \) 2>/dev/null | sort)
fi
if [ "$SEED_COUNT" -gt 0 ]; then
  xcrun simctl addmedia "$UDID" "$SEED_DIR"/seed-*.png 2>/dev/null
  echo "ADDMEDIA_EXIT=$? (seeded $SEED_COUNT image(s))"
else
  echo "ADDMEDIA_EXIT=skipped (no seed image — s04 falls back to the showcase, s05 will skip)"
fi

# -------------------------------------------------------------------- 5. test
xcodebuild test \
  -project Rendprop.xcodeproj \
  -scheme Rendprop \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:RendpropUITests/StoreShots \
  -derivedDataPath "$DD_DIR" \
  -resultBundlePath "$RESULT" \
  > "$LOG" 2>&1
echo "TEST_EXIT=$?"
grep -E "error:|Test Case|passed|failed" "$LOG" | tail -30

# ---------------------------------------------------------- 6. export the PNGs
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

# ------------------------------------------- 7. size gate, then the deliverable
# App Store Connect rejects a 6.9-inch shot that is not EXACTLY 1320 x 2868.
# A wrong size here almost always means the test ran on the wrong simulator.
OK=0
BAD=0
for src in "$RAW_DIR"/s0*.png; do
  [ -e "$src" ] || continue
  W=$(sips -g pixelWidth  "$src" 2>/dev/null | awk '/pixelWidth/{print $2}')
  H=$(sips -g pixelHeight "$src" 2>/dev/null | awk '/pixelHeight/{print $2}')
  BASE="$(basename "$src")"
  if [ "$W" = "$WANT_W" ] && [ "$H" = "$WANT_H" ]; then
    cp "$src" "$SHOTS_DIR/$BASE"
    OK=$((OK + 1))
    echo "OK    $BASE  ${W}x${H}"
  else
    BAD=$((BAD + 1))
    echo "WRONG $BASE  ${W:-?}x${H:-?}  (need ${WANT_W}x${WANT_H}) — NOT copied"
  fi
done
echo "SIZE_OK=$OK  SIZE_WRONG=$BAD"

# ------------------------------------------------------------------- 8. report
echo "RESULT_BUNDLE=$RESULT"
echo "STORESHOTS_DIR=$SHOTS_DIR"
ls -la "$SHOTS_DIR"/*.png 2>/dev/null \
  || echo "NO_PNGS — read $LOG and the activity notes in $RESULT"

# The skip reasons live in the result bundle as activity names:
#   xcrun xcresulttool get test-results activities \
#     --path "$RESULT" --test-id 'StoreShots/testStoreShots()'
echo "SKIP_NOTES=xcrun xcresulttool get test-results activities --path \"$RESULT\" --test-id 'StoreShots/testStoreShots()'"

# Leave the status-bar override in place: it costs nothing, and a re-run that
# forgets it would produce a set with two different clocks.
rm -rf "$SEED_DIR"
