#!/bin/bash
# bridge-610-asc-apply.sh
#
# Push everything this repo knows about the App Store listing into App Store
# Connect, in order, stopping at the first failure. Runs on the owner's Mac from
# the repo checkout; the API key stays in ~/Rendprop AI/_bridge/.asc.
#
# Each step is idempotent, so running this twice is safe and the second run
# should report "already correct, nothing to do" throughout.
#
# Usage:
#   bash tools/asc/bridge-610-asc-apply.sh                        # apply
#   bash tools/asc/bridge-610-asc-apply.sh --dry-run              # show the plan only
#   bash tools/asc/bridge-610-asc-apply.sh --replace-screenshots  # apply, and rebuild
#                                                                 # the screenshot set
#
# Screenshots come from docs/appstore/screenshots/6.9-framed (the composed
# set - docs/appstore/screenshots/README.md) when that directory holds PNGs,
# else from the raw docs/appstore/screenshots/6.9. The first upload after a
# re-frame needs --replace-screenshots: the old images are still in the set,
# and a set holds at most 10, so they are deleted before the new ones go up.
# Without it the step only adds what is missing by checksum.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASC="$REPO_ROOT/tools/asc/asc.py"
FRAMED_DIR="$REPO_ROOT/docs/appstore/screenshots/6.9-framed"

DRY_RUN=0
REPLACE_SCREENSHOTS=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    --replace-screenshots) REPLACE_SCREENSHOTS=1 ;;
    *) printf 'Unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || {
  printf 'ERROR: python3 not found.\n' >&2
  exit 1
}
[ -f "$ASC" ] || {
  printf 'ERROR: %s not found.\n' "$ASC" >&2
  exit 1
}

STEP_NUMBER=0

run_step() {
  local title="$1"
  shift
  STEP_NUMBER=$((STEP_NUMBER + 1))
  printf '\n'
  printf '====================================================================\n'
  printf ' %d. %s\n' "$STEP_NUMBER" "$title"
  printf '====================================================================\n'

  python3 "$ASC" "$@"
  local status=$?
  if [ "$status" -ne 0 ]; then
    printf '\n'
    printf '********************************************************************\n'
    printf ' STOPPED at step %d (%s) - exit %d\n' "$STEP_NUMBER" "$title" "$status"
    printf ' Nothing after this step ran. Fix the problem above and re-run:\n'
    printf '     bash tools/asc/bridge-610-asc-apply.sh\n'
    printf ' Re-running is safe: every step only creates what is missing.\n'
    printf '********************************************************************\n'
    exit "$status"
  fi
}

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'DRY RUN - nothing will be changed in App Store Connect.\n'
  ACTION=plan
else
  ACTION=apply
fi

# 1. The app record must exist first; everything else hangs off it.
run_step "Find the app record" app

# 2. Subscriptions: group, six products, localizations, prices, availability,
#    free trials, and the App Store Server Notification URLs.
run_step "Subscriptions" subscriptions "$ACTION"

# 3. The listing: name, subtitle, categories, age rating, privacy policy,
#    description, keywords, promotional text, release notes, URLs.
run_step "App Store listing metadata" metadata "$ACTION"

# 4. Screenshots: the framed set when it exists, else the raw captures.
#    --replace-screenshots rebuilds the set (delete, upload, order).
SHOT_ARGS=()
if ls "$FRAMED_DIR"/*.png >/dev/null 2>&1; then
  SHOT_ARGS+=(--dir "$FRAMED_DIR")
fi
if [ "$REPLACE_SCREENSHOTS" -eq 1 ]; then
  SHOT_ARGS+=(--replace)
fi
# ${SHOT_ARGS[@]+"${SHOT_ARGS[@]}"}: an empty array under `set -u` is an
# error on the bash 3.2 macOS ships; this form expands to nothing instead.
if [ "$DRY_RUN" -eq 1 ]; then
  run_step "Screenshots" screenshots plan ${SHOT_ARGS[@]+"${SHOT_ARGS[@]}"}
else
  run_step "Screenshots" screenshots apply ${SHOT_ARGS[@]+"${SHOT_ARGS[@]}"}
fi

# 5. App Review contact details, review notes, and the paywall screenshot that
#    App Review needs on every subscription.
run_step "App Review details" review "$ACTION"

# 6. Where everything stands. `status` exits non-zero when something is still
#    missing, which is information rather than a failure, so it runs last and
#    its exit code is reported without stopping the script.
#
#    com.rendprop.app.team.annual is deliberately not sold at launch: Apple's
#    yearly USD price points stop at 1000.00 and its contract price is 2490.00,
#    so `subscriptions unprice` withdrew it from every territory. --skip-product
#    keeps it out of WHAT IS MISSING - unless it turns out to be on sale, in
#    which case status still shouts.
STEP_NUMBER=$((STEP_NUMBER + 1))
printf '\n'
printf '====================================================================\n'
printf ' %d. Status\n' "$STEP_NUMBER"
printf '====================================================================\n'
python3 "$ASC" status --skip-product com.rendprop.app.team.annual
STATUS_EXIT=$?

printf '\n'
if [ "$STATUS_EXIT" -eq 0 ]; then
  printf 'Everything this tool can set is set.\n'
else
  printf 'Some things are still missing - see "WHAT IS MISSING" above.\n'
  printf 'The ones the API cannot do are listed in docs/appstore/ASC-API-PLAN.md.\n'
fi

# The run itself succeeded; `status` reporting gaps is not a script failure.
exit 0
