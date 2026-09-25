#!/usr/bin/env bash
# Explicit selection, offline dry-run by default. Never implicitly deploy all.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/../../apps/studio/scripts/deploy-backend.mjs" "$@"
