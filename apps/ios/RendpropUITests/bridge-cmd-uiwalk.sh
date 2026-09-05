#!/bin/bash
#
# bridge-cmd-uiwalk.sh — the exact command block the INTEGRATOR drops into the
# Mac build bridge to run the automated UI walk and pull the screenshots out.
#
#   bash "$HOME/Rendprop AI/repo/apps/ios/RendpropUITests/bridge-cmd-uiwalk.sh"
#
# It never fails the bridge: every stage reports its own exit code and the run
# continues, because a walk that captures 7 of 9 screens is still worth having.
# Output lands in  ~/Rendprop AI/_bridge/out/shots/  as PNGs.
#
# Nothing here writes to the repo, deploys anything, or touches production.

set -u -o pipefail

UDID="CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E"     # iPhone simulator, iOS 26.x
ROOT="$HOME/Rendprop AI"
IOS_DIR="$ROOT/repo/apps/ios"
OUT_DIR="$ROOT/_bridge/out"
SHOTS_DIR="$OUT_DIR/shots"
DD_DIR="$ROOT/_bridge/dd-ui"
RESULT="$OUT_DIR/walk-$(date +%s).xcresult"
LOG="/tmp/rp-ui.log"

mkdir -p "$OUT_DIR" "$SHOTS_DIR"

# ---------------------------------------------------------------- 1. generate
cd "$IOS_DIR" || { echo "MISSING_DIR=$IOS_DIR"; exit 1; }
xcodegen generate
echo "XCODEGEN_EXIT=$?"

# ------------------------------------------------------------------- 2. boot
# Already-booted is not an error.
xcrun simctl boot "$UDID" 2>/dev/null
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1
echo "SIM_STATE=$(xcrun simctl list devices | grep "$UDID" | sed 's/.*(\(.*\))/\1/')"

# ------------------------------------------------- 3. (optional) seed photos
# Step 04 (Reel Studio → Voice) needs TWO photos on the walk's home, and the
# reel card stays disabled until they exist. A fresh simulator has an empty
# photo library, so seed it with two throwaway PNGs. Best effort: if `sips`
# cannot produce them the walk simply records "04 skipped" and carries on.
SEED_DIR="$(mktemp -d)"
if sips -s format png \
        /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns \
        --out "$SEED_DIR/walk-1.png" >/dev/null 2>&1; then
  cp "$SEED_DIR/walk-1.png" "$SEED_DIR/walk-2.png"
  xcrun simctl addmedia "$UDID" "$SEED_DIR/walk-1.png" "$SEED_DIR/walk-2.png" 2>/dev/null
  echo "ADDMEDIA_EXIT=$?"
else
  echo "ADDMEDIA_EXIT=skipped (no seed image; step 04 will skip itself)"
fi

# -------------------------------------------------------------------- 4. test
xcodebuild test \
  -project Rendprop.xcodeproj \
  -scheme Rendprop \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:RendpropUITests \
  -derivedDataPath "$DD_DIR" \
  -resultBundlePath "$RESULT" \
  > "$LOG" 2>&1
echo "TEST_EXIT=$?"
grep -E "error:|Test Case|passed|failed" "$LOG" | tail -30

# ---------------------------------------------------------- 5. export the PNGs
# Xcode 16+/26 path first. It writes every attachment plus a manifest.json that
# maps the exported file names back to the names the test gave them.
if [ ! -d "$RESULT" ]; then
  echo "EXPORT_EXIT=no result bundle at $RESULT"
else
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$SHOTS_DIR"
  EXPORT_EXIT=$?
  echo "EXPORT_ATTACHMENTS_EXIT=$EXPORT_EXIT"

  # Rename exported blobs to 01-home.png … 09-health-probe.png using the
  # manifest, so the owner gets the walk in order instead of UUIDs.
  if [ -f "$SHOTS_DIR/manifest.json" ]; then
    python3 - "$SHOTS_DIR" <<'PY'
import json, os, shutil, sys
shots = sys.argv[1]
manifest = json.load(open(os.path.join(shots, "manifest.json")))
entries = manifest if isinstance(manifest, list) else [manifest]
renamed = 0
for test in entries:
    for att in (test.get("attachments") or []):
        src = att.get("exportedFileName")
        name = att.get("suggestedHumanReadableName") or att.get("name") or ""
        if not src or not name:
            continue
        src_path = os.path.join(shots, src)
        if not os.path.exists(src_path):
            continue
        ext = os.path.splitext(src)[1] or ".png"
        dst = os.path.join(shots, name if name.endswith(ext) else name + ext)
        if os.path.abspath(src_path) != os.path.abspath(dst):
            shutil.copyfile(src_path, dst)
            renamed += 1
print("RENAMED=%d" % renamed)
PY
  fi

  # Fallback for a toolchain where `export attachments` is unavailable: walk
  # the legacy object graph and pull each named attachment out one by one.
  if [ "$EXPORT_EXIT" -ne 0 ]; then
    echo "falling back to the legacy xcresulttool flow"
    python3 - "$RESULT" "$SHOTS_DIR" <<'PY'
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
    """Collect every {name, payload id} pair anywhere in the graph."""
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

# ------------------------------------------------------------------- 6. report
echo "RESULT_BUNDLE=$RESULT"
echo "SHOTS_DIR=$SHOTS_DIR"
ls -la "$SHOTS_DIR"/*.png 2>/dev/null || echo "NO_PNGS — read $LOG and the activity notes in $RESULT"
rm -rf "$SEED_DIR"
