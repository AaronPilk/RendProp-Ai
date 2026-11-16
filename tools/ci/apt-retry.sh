#!/usr/bin/env bash
# Bounded, signature-preserving retry around `apt-get update` + `apt-get install`.
#
#   tools/ci/apt-retry.sh PACKAGE [PACKAGE...]
#   tools/ci/apt-retry.sh --no-install-recommends PACKAGE [PACKAGE...]
#
# Hosted runners fetch package indexes from mirrors that are sometimes caught
# mid-sync ("File has unexpected size", "Hash Sum mismatch") or briefly
# unreachable. That is not a code failure, so the fetch is retried a fixed
# number of times with backoff, dropping the half-downloaded indexes first.
#
# Nothing here relaxes verification: repository signatures and package hashes
# are still checked by apt on every attempt, and no --allow-unauthenticated,
# --allow-insecure-repositories or trusted=yes option is ever passed. When the
# attempts are exhausted the step fails and says it was a package-mirror
# problem, so it is not mistaken for a failing test.
set -euo pipefail

attempts="${APT_RETRY_ATTEMPTS:-4}"
update_deadline="${APT_RETRY_UPDATE_DEADLINE_SECONDS:-120}"
install_deadline="${APT_RETRY_INSTALL_DEADLINE_SECONDS:-300}"
# Test seam only: lets the unit test replace sudo and skip the real waits.
elevate="${APT_RETRY_ELEVATE-sudo}"
pause="${APT_RETRY_SLEEP:-sleep}"
delays=(10 30 60)

if [ "$#" -eq 0 ]; then
  echo "usage: tools/ci/apt-retry.sh [apt-get install options] PACKAGE..." >&2
  exit 64
fi
for argument in "$@"; do
  case "$argument" in
    --allow-unauthenticated|--allow-insecure-repositories|--allow-downgrades|--force-yes|*AllowInsecure*|*AllowUnauthenticated*|*trusted=yes*)
      echo "apt-retry refuses to weaken package verification: $argument" >&2
      exit 64
      ;;
  esac
done

run() {
  if [ -n "$elevate" ]; then "$elevate" "$@"; else "$@"; fi
}

attempt=1
while :; do
  echo "apt-retry: attempt $attempt of $attempts"
  status=0
  run timeout "$update_deadline" apt-get update -qq \
    -o Acquire::Retries=3 -o DPkg::Lock::Timeout=60 || status=$?
  if [ "$status" -eq 0 ]; then
    run timeout "$install_deadline" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      -o Acquire::Retries=3 -o DPkg::Lock::Timeout=60 "$@" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    echo "apt-retry: installed on attempt $attempt"
    exit 0
  fi
  if [ "$attempt" -ge "$attempts" ]; then
    echo "::error title=Infrastructure miss (package mirror)::apt-get could not fetch or install [$*] after $attempts bounded attempts (last exit $status). No test ran in this step; re-run the failed job."
    exit 1
  fi
  delay="${delays[$((attempt - 1))]:-60}"
  echo "::warning title=Package mirror retry::apt-get exit $status on attempt $attempt; clearing downloaded indexes and retrying in ${delay}s"
  # A size or hash mismatch leaves a rejected index behind; remove the
  # downloaded lists so the next attempt fetches and verifies them afresh.
  run find /var/lib/apt/lists -mindepth 1 -maxdepth 1 ! -name lock -exec rm -rf {} + || true
  "$pause" "$delay"
  attempt=$((attempt + 1))
done
