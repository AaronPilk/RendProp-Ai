#!/bin/bash
#
# bridge-cmd-onboardingtour.sh — the exact command block the INTEGRATOR drops
# into the Mac build bridge to RECORD THE ONBOARDING VIDEO's raw take.
#
#   bash "$HOME/Rendprop AI/repo/apps/ios/RendpropUITests/bridge-cmd-onboardingtour.sh"
#
# It boots the existing 6.3-inch iPhone 17 Pro simulator, uninstalls the app so
# the tour starts from a clean container, freezes the status bar at 9:41, seeds
# the photo library (two photos + one walkthrough clip — see MEDIA below),
# builds the tests WITHOUT recording, then starts `xcrun simctl io recordVideo`
# in the background, runs ONE test (RendpropUITests/OnboardingTour — the slow,
# narrated-pace pass through the app described in
# docs/marketing/onboarding-video-script.md), stops the recording with SIGINT,
# and pulls the TOUR_MARK lines out of the .xcresult.
#
# Output (~/Rendprop AI/_bridge/out/onboardingtour/):
#   tour-raw.mp4      the simulator screen, device resolution, H.264
#   marks.txt         one `TOUR_MARK <segment> <seconds>` per segment, on the
#                     recording's clock, plus a header with the clock details
#   activities.txt    the test's full activity log (skip reasons, STOREKIT note)
#   onboarding.mp4 / onboarding-9x16.mp4 — only when ffmpeg is on this Mac; the
#                     build step is otherwise printed as a command to run where
#                     ffmpeg is (tools/video/build_onboarding.py).
#
# HOW THE MARKS LINE UP WITH THE VIDEO. The recorder is started before the test
# and the wall-clock moment it was launched is handed to the test as
# TEST_RUNNER_RECORD_START_EPOCH; the test stamps every TOUR_MARK against that
# clock. `simctl` needs a moment to actually start capturing, so the head of
# the video may sit up to ~1 s off — `build_onboarding.py --offset -1.0`
# nudges every mark; check the first cut once and it is right for good.
#
# MEDIA. Two photos and a short walkthrough clip make the studio, the reel card
# and the "upload a video" segment show the real thing. Drop your own into
#   ~/Rendprop AI/_bridge/in/onboarding-media/   (*.jpg *.png *.heic + one *.mp4/*.mov, 10–20 s)
# Nothing there? Photos fall back to _bridge/in/storeshot-photos, then to a
# macOS desktop picture; the clip falls back to a generated placeholder if
# ffmpeg is installed, else the tour skips segments 05 + 06 and says so. A
# placeholder is fine for a test take, not for the one you publish.
#
# NOTHING IS PURCHASED, DELETED, GENERATED OR PUBLISHED. The StoreKit test
# environment only makes the paywall render prices; no AI edit runs; the two
# photos go through the on-device enhancer; nothing is rendered unless
# TOUR_RENDER=1 (adds ~a minute and breaks the 150 s budget — only for a look).
#
# It never fails the bridge: every stage reports its own exit code and the run
# continues, because a take with one skipped segment is still worth having.
# Nothing here writes to the repo, deploys anything, or touches production.
#
# Env knobs:
#   KEEP_APP=1     skip the uninstall (re-run on a dirty container)
#   SIM_UDID=…     run on a different simulator
#   TOUR_RENDER=1  tap "Create my tour" in segment 06 and wait for the render
#   NO_PREBUILD=1  skip build-for-testing and record the whole `xcodebuild test`
#                  (a much longer head on the raw file; the build trims it)

set -u -o pipefail

UDID="${SIM_UDID:-CC58F5C6-C811-4FEB-889A-EF10CE1E7A0E}"   # iPhone 17 Pro (6.3-inch), iOS 26.x — same as the other walks
APP_ID="com.rendprop.app"

ROOT="$HOME/Rendprop AI"
IOS_DIR="$ROOT/repo/apps/ios"
OUT_DIR="$ROOT/_bridge/out"
TOUR_DIR="$OUT_DIR/onboardingtour"          # the deliverable
RAW_DIR="$OUT_DIR/onboardingtour-raw"       # xcresulttool's dumping ground
DD_DIR="$ROOT/_bridge/dd-onboardingtour"
MEDIA_DIR="$ROOT/_bridge/in/onboarding-media"      # OPTIONAL: your photos + walkthrough clip
PHOTO_DIR="$ROOT/_bridge/in/storeshot-photos"      # the store-shot photos, as a fallback
NARR_DIR="$ROOT/_bridge/in/onboarding-narration"   # OPTIONAL: 01.mp3 … 13.mp3 for the build step
SCRIPT_MD="$ROOT/repo/docs/marketing/onboarding-video-script.md"
BUILD_PY="$ROOT/repo/tools/video/build_onboarding.py"
RESULT="$OUT_DIR/onboardingtour-$(date +%s).xcresult"
LOG="/tmp/rp-onboardingtour.log"
REC_LOG="/tmp/rp-onboardingtour-record.log"
RAW_MP4="$TOUR_DIR/tour-raw.mp4"
MARKS="$TOUR_DIR/marks.txt"
TEST_ID="OnboardingTour/testOnboardingTour()"

mkdir -p "$OUT_DIR" "$TOUR_DIR" "$RAW_DIR"
rm -f "$RAW_MP4" "$MARKS" "$TOUR_DIR/activities.txt" 2>/dev/null   # a stale take lies

epoch_now() { python3 -c 'import time; print("%.3f" % time.time())'; }

# ---------------------------------------------------------------- 1. generate
# NOT optional: the committed .xcodeproj has no RendpropUITests target. xcodegen
# picks OnboardingTour.swift up from the RendpropUITests folder automatically
# (bridge-cmd-*.sh is excluded by project.yml).
cd "$IOS_DIR" || { echo "MISSING_DIR=$IOS_DIR"; exit 1; }
xcodegen generate
echo "XCODEGEN_EXIT=$?"

# -------------------------------------------------------------------- 2. boot
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
# The Simulator window has to be open for a screen recording to have frames.
open -a Simulator --args -CurrentDeviceUDID "$UDID" 2>/dev/null
sleep 3

# ------------------------------------------------------- 3. wipe the container
# After the boot, before the test. A clean container means the tour starts in
# real estate with no homes, creates exactly one ("24 Willow Bend Court") and
# every "first time" state is real. KEEP_APP=1 skips it.
if [ "${KEEP_APP:-0}" = "1" ]; then
  echo "UNINSTALL_EXIT=skipped (KEEP_APP=1)"
else
  xcrun simctl uninstall "$UDID" "$APP_ID" 2>/dev/null
  echo "UNINSTALL_EXIT=$? (app $APP_ID — 'not installed' is fine, the container is gone either way)"
fi

# Marketing status bar — the same convention as every other capture.
xcrun simctl status_bar "$UDID" override \
  --time 9:41 \
  --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4
echo "STATUS_BAR_EXIT=$?"

# ----------------------------------------------------------- 4. seed the media
SEED_DIR="$(mktemp -d)"
SEED_COUNT=0
seed_photos_from() {
  local dir="$1" max="$2"
  [ -d "$dir" ] || return 0
  while IFS= read -r src; do
    [ -z "$src" ] && continue
    SEED_COUNT=$((SEED_COUNT + 1))
    # -Z 2000: ingest runs Core Image on the full image; a 6K desktop picture
    # would make the studio pause for seconds on camera.
    sips -Z 2000 -s format png "$src" --out "$SEED_DIR/seed-$SEED_COUNT.png" >/dev/null 2>&1 \
      || SEED_COUNT=$((SEED_COUNT - 1))
    [ "$SEED_COUNT" -ge "$max" ] && break
  done < <(find "$dir" -maxdepth 2 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' \) 2>/dev/null | sort)
}
seed_photos_from "$MEDIA_DIR" 3
[ "$SEED_COUNT" -eq 0 ] && seed_photos_from "$PHOTO_DIR" 3
if [ "$SEED_COUNT" -eq 0 ]; then
  echo "NO_OWN_PHOTOS — $MEDIA_DIR and $PHOTO_DIR are empty. Falling back to a desktop picture."
  seed_photos_from "/System/Library/Desktop Pictures" 2
  [ "$SEED_COUNT" -eq 0 ] && seed_photos_from "/Library/Desktop Pictures" 2
fi
[ "$SEED_COUNT" -eq 1 ] && cp "$SEED_DIR/seed-1.png" "$SEED_DIR/seed-2.png" && SEED_COUNT=2

SEED_VIDEO="$(find "$MEDIA_DIR" -maxdepth 2 -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' \) 2>/dev/null | sort | head -1)"
if [ -n "$SEED_VIDEO" ]; then
  cp "$SEED_VIDEO" "$SEED_DIR/walkthrough.${SEED_VIDEO##*.}"
  echo "SEED_VIDEO=$SEED_VIDEO"
elif command -v ffmpeg >/dev/null 2>&1; then
  # A 12 s placeholder clip — a slow colour drift, portrait, silent. Enough to
  # import, tag and rest on Review & Submit. NOT the clip to publish with.
  ffmpeg -y -loglevel error -f lavfi -i "gradients=size=1080x1920:rate=30:speed=0.03:c0=0x2b1d5c:c1=0x8b6d3b:c2=0x1f3a5c" \
    -t 12 -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$SEED_DIR/walkthrough.mp4" 2>/dev/null \
  || ffmpeg -y -loglevel error -f lavfi -i "testsrc2=size=1080x1920:rate=30" -t 12 -c:v libx264 -pix_fmt yuv420p "$SEED_DIR/walkthrough.mp4"
  echo "SEED_VIDEO=placeholder (ffmpeg-generated) — drop a real 10–20 s walkthrough into $MEDIA_DIR for the publishable take"
else
  echo "SEED_VIDEO=none — no clip in $MEDIA_DIR and no ffmpeg to generate one; segments 05 + 06 will skip themselves"
fi
if ls "$SEED_DIR"/* >/dev/null 2>&1; then
  xcrun simctl addmedia "$UDID" "$SEED_DIR"/* 2>/dev/null
  echo "ADDMEDIA_EXIT=$? (seeded $SEED_COUNT photo(s) + $(ls "$SEED_DIR" | grep -c walkthrough) clip)"
else
  echo "ADDMEDIA_EXIT=skipped (nothing to seed)"
fi

# --------------------------------------------- 5. build first, record later
# The compile is minutes of nothing on screen — keep it OFF the recording.
# `test-without-building` then only installs and launches.
PREBUILT=0
if [ "${NO_PREBUILD:-0}" != "1" ]; then
  xcodebuild build-for-testing \
    -project Rendprop.xcodeproj \
    -scheme Rendprop \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DD_DIR" \
    > "$LOG" 2>&1
  BUILD_EXIT=$?
  echo "BUILD_FOR_TESTING_EXIT=$BUILD_EXIT"
  [ "$BUILD_EXIT" -eq 0 ] && PREBUILT=1 || grep -E "error:" "$LOG" | tail -10
fi

# ----------------------------------------------------- 6. start the recording
# BEFORE the test. The epoch noted here is what the test stamps its marks
# against (TEST_RUNNER_RECORD_START_EPOCH → the runner's RECORD_START_EPOCH).
RECORD_LAUNCH_EPOCH="$(epoch_now)"
xcrun simctl io "$UDID" recordVideo --codec h264 --force "$RAW_MP4" > "$REC_LOG" 2>&1 &
REC_PID=$!
# simctl takes a moment to start capturing; the first sign of life (output, or
# the file appearing) is a better zero than the launch itself.
RECORD_START_EPOCH="$RECORD_LAUNCH_EPOCH"
for _ in $(seq 1 40); do
  if [ -s "$REC_LOG" ] || [ -e "$RAW_MP4" ]; then RECORD_START_EPOCH="$(epoch_now)"; break; fi
  sleep 0.1
done
sleep 1
if kill -0 "$REC_PID" 2>/dev/null; then
  echo "RECORD_STARTED pid=$REC_PID launch_epoch=$RECORD_LAUNCH_EPOCH start_epoch=$RECORD_START_EPOCH"
else
  echo "RECORD_FAILED — recordVideo exited early: $(cat "$REC_LOG" 2>/dev/null | tail -3)"
fi

# -------------------------------------------------------------------- 7. test
if [ "$PREBUILT" -eq 1 ]; then
  xcodebuild test-without-building \
    -project Rendprop.xcodeproj \
    -scheme Rendprop \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:"RendpropUITests/OnboardingTour" \
    -derivedDataPath "$DD_DIR" \
    -resultBundlePath "$RESULT" \
    TEST_RUNNER_RECORD_START_EPOCH="$RECORD_START_EPOCH" \
    TEST_RUNNER_TOUR_RENDER="${TOUR_RENDER:-0}" \
    >> "$LOG" 2>&1
else
  xcodebuild test \
    -project Rendprop.xcodeproj \
    -scheme Rendprop \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:"RendpropUITests/OnboardingTour" \
    -derivedDataPath "$DD_DIR" \
    -resultBundlePath "$RESULT" \
    TEST_RUNNER_RECORD_START_EPOCH="$RECORD_START_EPOCH" \
    TEST_RUNNER_TOUR_RENDER="${TOUR_RENDER:-0}" \
    >> "$LOG" 2>&1
fi
echo "TEST_EXIT=$?"
grep -E "error:|Test Case|passed|failed" "$LOG" | tail -20

# ------------------------------------------------------ 8. stop the recording
# SIGINT is how `recordVideo` is told to finish the file; give it up to 30 s.
sleep 2
if kill -0 "$REC_PID" 2>/dev/null; then
  kill -INT "$REC_PID" 2>/dev/null
  for _ in $(seq 1 60); do
    kill -0 "$REC_PID" 2>/dev/null || break
    sleep 0.5
  done
  kill -0 "$REC_PID" 2>/dev/null && { echo "RECORD_STOP=timed out, sending TERM"; kill -TERM "$REC_PID" 2>/dev/null; }
fi
wait "$REC_PID" 2>/dev/null
echo "RECORD_EXIT=$? ($(tail -1 "$REC_LOG" 2>/dev/null))"

# ------------------------------------------------------- 9. export the marks
# Every TOUR_MARK is an activity title (and an NSLog line). Modern
# xcresulttool first, the legacy object graph second, the log third.
{
  echo "# OnboardingTour marks — seconds on the recording's clock (clock=recording) or since app.launch() (clock=launch)"
  echo "# record_launch_epoch=$RECORD_LAUNCH_EPOCH record_start_epoch=$RECORD_START_EPOCH sim=$UDID result=$RESULT"
} > "$MARKS"
MARK_SOURCE="none"
if [ -d "$RESULT" ]; then
  ACT_JSON="$RAW_DIR/activities.json"
  if xcrun xcresulttool get test-results activities --path "$RESULT" --test-id "$TEST_ID" > "$ACT_JSON" 2>/dev/null \
     && [ -s "$ACT_JSON" ]; then
    python3 - "$ACT_JSON" "$MARKS" "$TOUR_DIR/activities.txt" <<'PY'
import json, sys
path, marks_path, act_path = sys.argv[1:4]
doc = json.load(open(path))
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
clock = "launch"
n = 0
with open(marks_path, "a") as f:
    for _, t in titles:
        if t.startswith("CLOCK recording"):
            clock = "recording"
        if t.startswith("TOUR_MARK "):
            f.write(t.replace("\n", " ") + "\n"); n += 1
    f.write("# clock=%s\n" % clock)
print("MARKS_EXPORTED=%d clock=%s" % (n, clock))
PY
    MARK_SOURCE="xcresulttool"
  else
    echo "ACTIVITIES_MODERN_UNAVAILABLE — using the legacy graph"
    python3 - "$RESULT" "$MARKS" "$TOUR_DIR/activities.txt" <<'PY'
import json, subprocess, sys
bundle, marks_path, act_path = sys.argv[1:4]
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
def titles_in(node, out):
    if isinstance(node, dict):
        t = val(node, "title")
        if isinstance(t, str) and val(node, "_type", "_name") == "ActionTestActivitySummary":
            out.append(t)
        for v in node.values():
            titles_in(v, out)
    elif isinstance(node, list):
        for v in node:
            titles_in(v, out)
titles = []
try:
    root = get()
    for action in (root.get("actions", {}).get("_values") or []):
        tests_ref = val(action, "actionResult", "testsRef", "id")
        if not tests_ref:
            continue
        ids = []
        collect_summary_refs(get(tests_ref), ids)
        for sid in ids:
            titles_in(get(sid), titles)
except Exception as e:
    sys.stderr.write("LEGACY_ACTIVITIES_FAILED: %s\n" % e)
with open(act_path, "w") as f:
    for t in titles:
        f.write(t.replace("\n", " ") + "\n")
clock = "recording" if any(t.startswith("CLOCK recording") for t in titles) else "launch"
n = 0
with open(marks_path, "a") as f:
    for t in titles:
        if t.startswith("TOUR_MARK "):
            f.write(t.replace("\n", " ") + "\n"); n += 1
    f.write("# clock=%s\n" % clock)
print("MARKS_EXPORTED=%d clock=%s (legacy)" % (n, clock))
PY
    MARK_SOURCE="xcresulttool-legacy"
  fi
fi
if ! grep -q '^TOUR_MARK ' "$MARKS" 2>/dev/null; then
  echo "MARKS_FROM_LOG — no TOUR_MARK activity exported; grepping the NSLog lines out of $LOG"
  grep -o 'TOUR_MARK [A-Z0-9]* [0-9.]* sinceLaunch=[0-9.]* epoch=[0-9.]*' "$LOG" | awk '!seen[$2]++' >> "$MARKS"
  grep -q 'CLOCK recording' "$LOG" && echo "# clock=recording" >> "$MARKS" || echo "# clock=launch" >> "$MARKS"
  MARK_SOURCE="xcodebuild-log"
fi
echo "MARK_SOURCE=$MARK_SOURCE"
echo "---- marks.txt ----"
cat "$MARKS"

# ------------------------------------------------------------ 10. the video
if [ -s "$RAW_MP4" ]; then
  if command -v ffprobe >/dev/null 2>&1; then
    echo "VIDEO=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate:format=duration,size \
                  -of default=noprint_wrappers=1 "$RAW_MP4" | tr '\n' ' ')"
  else
    echo "VIDEO=$(mdls -name kMDItemDurationSeconds -name kMDItemPixelWidth -name kMDItemPixelHeight -name kMDItemFSSize "$RAW_MP4" | tr '\n' ' ')"
  fi
else
  echo "NO_VIDEO — $RAW_MP4 is missing or empty. Was the Simulator window open? Read $REC_LOG."
fi

# ------------------------------------------- 11. build the video (if ffmpeg)
# (no arrays: macOS's /bin/bash is 3.2, where an empty array trips `set -u`)
HAVE_NARR=""
[ -d "$NARR_DIR" ] && HAVE_NARR=1
if command -v ffmpeg >/dev/null 2>&1 && [ -s "$RAW_MP4" ] && grep -q '^TOUR_MARK ' "$MARKS"; then
  python3 "$BUILD_PY" --raw "$RAW_MP4" --marks "$MARKS" --script "$SCRIPT_MD" --out "$TOUR_DIR" \
    ${HAVE_NARR:+--narration "$NARR_DIR"}
  echo "BUILD_EXIT=$?"
else
  echo "BUILD_SKIPPED — run where ffmpeg is installed (brew install ffmpeg):"
  echo "  python3 \"$BUILD_PY\" --raw \"$RAW_MP4\" --marks \"$MARKS\" --script \"$SCRIPT_MD\" --narration \"$NARR_DIR\" --out \"$TOUR_DIR\""
fi

# ------------------------------------------------------------------ 12. report
echo "RESULT_BUNDLE=$RESULT"
echo "TOUR_DIR=$TOUR_DIR"
ls -la "$TOUR_DIR" 2>/dev/null
echo "SKIP_NOTES=$TOUR_DIR/activities.txt  (or: xcrun xcresulttool get test-results activities --path \"$RESULT\" --test-id '$TEST_ID')"
rm -rf "$SEED_DIR"

# Leave the status-bar override in place: it costs nothing, and a re-run that
# forgets it would produce a take with a different clock.
