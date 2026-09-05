#!/bin/bash
# bridge-600-archive-upload.sh
#
# Archive Rendprop and upload the build to App Store Connect / TestFlight.
# Runs on the owner's Mac. Reads the App Store Connect API key from
#   ~/Rendprop AI/_bridge/.asc/AuthKey_<KEYID>.p8   (KEY_ID = the filename suffix)
#   ~/Rendprop AI/_bridge/.asc/config               (ISSUER_ID=<uuid>)
# Neither the key id, the issuer id, nor the key itself is ever echoed.
#
# Steps:
#   1. xcodegen generate      - rebuild the .xcodeproj from apps/ios/project.yml
#   2. xcodebuild archive     - Release, generic/platform=iOS
#   3. xcodebuild -exportArchive with destination=upload, which uploads using
#      the API key. If that fails, falls back to `xcrun altool --upload-app`.
#
# Prints BUILD_EXIT, EXPORT_EXIT and the last 20 relevant log lines.
#
# Usage:  bash tools/asc/bridge-600-archive-upload.sh
#         bash tools/asc/bridge-600-archive-upload.sh --no-upload   (archive only)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IOS_DIR="$REPO_ROOT/apps/ios"
SCHEME="Rendprop"
TEAM_ID="5F5C5G25Y6"
KEY_DIR="$HOME/Rendprop AI/_bridge/.asc"
WORK_DIR="${TMPDIR:-/tmp}/rendprop-archive"
ARCHIVE_PATH="$WORK_DIR/Rendprop.xcarchive"
EXPORT_DIR="$WORK_DIR/export"
BUILD_LOG="$WORK_DIR/build.log"
EXPORT_LOG="$WORK_DIR/export.log"
EXPORT_OPTIONS_SRC="$REPO_ROOT/tools/asc/exportOptions.plist"
EXPORT_OPTIONS="$WORK_DIR/exportOptions.plist"

UPLOAD=1
[ "${1:-}" = "--no-upload" ] && UPLOAD=0

BUILD_EXIT=1
EXPORT_EXIT=1

say()  { printf '%s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; }

# Print the last N lines that actually say something, filtering the noise
# xcodebuild produces.
tail_relevant() {
  local file="$1" count="${2:-20}"
  [ -f "$file" ] || { say "  (no log at $file)"; return; }
  grep -aE 'error:|warning:|failed|FAILED|\*\* |Archive |Export |Upload |Signing |Provisioning|Application Loader|Transporter|altool|ITMS-|No profiles|Code Sign|The operation couldn' "$file" \
    | tail -n "$count" \
    | sed 's/^/  /'
}

summary() {
  say ""
  say "===================================================================="
  say "BUILD_EXIT=$BUILD_EXIT"
  say "EXPORT_EXIT=$EXPORT_EXIT"
  say "===================================================================="
  if [ "$BUILD_EXIT" -ne 0 ]; then
    say ""
    say "Last relevant build log lines ($BUILD_LOG):"
    tail_relevant "$BUILD_LOG" 20
  fi
  if [ "$UPLOAD" -eq 1 ] && [ "$EXPORT_EXIT" -ne 0 ]; then
    say ""
    say "Last relevant export log lines ($EXPORT_LOG):"
    tail_relevant "$EXPORT_LOG" 20
  fi
  say ""
  if [ "$BUILD_EXIT" -eq 0 ] && { [ "$UPLOAD" -eq 0 ] || [ "$EXPORT_EXIT" -eq 0 ]; }; then
    if [ "$UPLOAD" -eq 1 ]; then
      say "Uploaded. The build takes 5-30 minutes to finish processing before it"
      say "appears in TestFlight. Check it with:"
      say "    python3 tools/asc/asc.py status"
    else
      say "Archived at $ARCHIVE_PATH (no upload was requested)."
    fi
  else
    say "Did not upload. Fix the errors above and re-run."
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

if [ "$(uname -s)" != "Darwin" ]; then
  fail "This script only runs on macOS (it needs Xcode)."
  exit 1
fi

for tool in xcodebuild xcrun; do
  command -v "$tool" >/dev/null 2>&1 || { fail "$tool not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"; exit 1; }
done

if ! command -v xcodegen >/dev/null 2>&1; then
  fail "xcodegen not found. Install it with:  brew install xcodegen"
  exit 1
fi

# --- credentials (never echoed) --------------------------------------------
if [ ! -d "$KEY_DIR" ]; then
  fail "No App Store Connect key directory at ~/Rendprop AI/_bridge/.asc"
  say  "  Put AuthKey_<KEYID>.p8 and a config file containing ISSUER_ID=<uuid> there."
  exit 1
fi

P8_PATH=""
for candidate in "$KEY_DIR"/AuthKey_*.p8; do
  [ -e "$candidate" ] || continue
  if [ -n "$P8_PATH" ]; then
    fail "More than one AuthKey_*.p8 in the key directory; leave exactly one."
    exit 1
  fi
  P8_PATH="$candidate"
done
if [ -z "$P8_PATH" ]; then
  fail "No AuthKey_<KEYID>.p8 in the key directory."
  exit 1
fi

# KEY_ID is the filename suffix. Kept in a variable, never printed.
KEY_ID="$(basename "$P8_PATH" .p8)"
KEY_ID="${KEY_ID#AuthKey_}"

if [ ! -f "$KEY_DIR/config" ]; then
  fail "No config file in the key directory (needs a line ISSUER_ID=<uuid>)."
  exit 1
fi
ISSUER_ID="$(sed -n 's/^ISSUER_ID=//p' "$KEY_DIR/config" | tr -d '"'"'"' \r' | head -n 1)"
if [ -z "$ISSUER_ID" ]; then
  fail "No ISSUER_ID=<uuid> line in the key directory's config file."
  exit 1
fi
say "App Store Connect credentials loaded."   # deliberately says nothing more

mkdir -p "$WORK_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

# ---------------------------------------------------------------------------
# 1. Regenerate the Xcode project
# ---------------------------------------------------------------------------
say ""
say "[1/3] xcodegen generate"
if ! ( cd "$IOS_DIR" && xcodegen generate ); then
  fail "xcodegen could not generate the project from apps/ios/project.yml"
  BUILD_EXIT=1
  summary
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Archive
# ---------------------------------------------------------------------------
say ""
say "[2/3] xcodebuild archive (Release, generic/platform=iOS)"
say "      log: $BUILD_LOG"

xcodebuild archive \
  -project "$IOS_DIR/Rendprop.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$P8_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  >"$BUILD_LOG" 2>&1
BUILD_EXIT=$?

if [ "$BUILD_EXIT" -ne 0 ] || [ ! -d "$ARCHIVE_PATH" ]; then
  BUILD_EXIT=${BUILD_EXIT:-1}
  [ "$BUILD_EXIT" -eq 0 ] && BUILD_EXIT=1
  fail "The archive step failed."
  summary
  exit 1
fi
say "      archive created: $ARCHIVE_PATH"

if [ "$UPLOAD" -eq 0 ]; then
  EXPORT_EXIT=0
  summary
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Export + upload
# ---------------------------------------------------------------------------
say ""
say "[3/3] xcodebuild -exportArchive (destination=upload)"
say "      log: $EXPORT_LOG"

cp "$EXPORT_OPTIONS_SRC" "$EXPORT_OPTIONS"

# Xcode 15.3 renamed the App Store method from "app-store" to
# "app-store-connect". Downgrade the key for older Xcode so this works either way.
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | sed -n '1s/^Xcode //p')"
XCODE_MAJOR="${XCODE_VERSION%%.*}"
XCODE_MINOR="$(printf '%s' "$XCODE_VERSION" | cut -d. -f2)"
XCODE_MAJOR="${XCODE_MAJOR:-0}"
XCODE_MINOR="${XCODE_MINOR:-0}"
if [ "$XCODE_MAJOR" -lt 15 ] || { [ "$XCODE_MAJOR" -eq 15 ] && [ "$XCODE_MINOR" -lt 3 ]; }; then
  say "      Xcode $XCODE_VERSION predates the app-store-connect rename; using method=app-store"
  /usr/libexec/PlistBuddy -c "Set :method app-store" "$EXPORT_OPTIONS" >/dev/null 2>&1
fi

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$P8_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" \
  >"$EXPORT_LOG" 2>&1
EXPORT_EXIT=$?

# ---------------------------------------------------------------------------
# Fallback: export an .ipa to disk, then upload it with altool.
# altool reads the key from ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8,
# so the key is copied there (0600) if it is not already present.
# ---------------------------------------------------------------------------
if [ "$EXPORT_EXIT" -ne 0 ]; then
  say ""
  say "      destination=upload failed (exit $EXPORT_EXIT); trying the altool fallback."
  tail_relevant "$EXPORT_LOG" 10

  FALLBACK_PLIST="$WORK_DIR/exportOptions-fallback.plist"
  cp "$EXPORT_OPTIONS" "$FALLBACK_PLIST"
  /usr/libexec/PlistBuddy -c "Set :destination export" "$FALLBACK_PLIST" >/dev/null 2>&1

  say "      re-exporting an .ipa to disk"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$FALLBACK_PLIST" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$P8_PATH" \
    -authenticationKeyID "$KEY_ID" \
    -authenticationKeyIssuerID "$ISSUER_ID" \
    >>"$EXPORT_LOG" 2>&1
  IPA_EXIT=$?

  IPA_PATH=""
  for candidate in "$EXPORT_DIR"/*.ipa; do
    [ -e "$candidate" ] && IPA_PATH="$candidate" && break
  done

  if [ "$IPA_EXIT" -eq 0 ] && [ -n "$IPA_PATH" ]; then
    PRIVATE_KEYS_DIR="$HOME/.appstoreconnect/private_keys"
    mkdir -p "$PRIVATE_KEYS_DIR"
    chmod 700 "$PRIVATE_KEYS_DIR"
    if [ ! -f "$PRIVATE_KEYS_DIR/$(basename "$P8_PATH")" ]; then
      cp "$P8_PATH" "$PRIVATE_KEYS_DIR/"
      chmod 600 "$PRIVATE_KEYS_DIR/$(basename "$P8_PATH")"
    fi

    say "      xcrun altool --upload-app"
    xcrun altool --upload-app \
      --type ios \
      --file "$IPA_PATH" \
      --apiKey "$KEY_ID" \
      --apiIssuer "$ISSUER_ID" \
      >>"$EXPORT_LOG" 2>&1
    EXPORT_EXIT=$?
    [ "$EXPORT_EXIT" -eq 0 ] && say "      altool upload succeeded."
  else
    say "      could not produce an .ipa for the fallback either."
  fi
fi

summary
if [ "$BUILD_EXIT" -eq 0 ] && [ "$EXPORT_EXIT" -eq 0 ]; then
  exit 0
fi
exit 1
