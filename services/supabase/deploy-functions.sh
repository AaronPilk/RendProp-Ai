#!/usr/bin/env bash
# Deploy all Rendprop edge functions to the Supabase project.
# The functions live in services/supabase/functions/, but the Supabase CLI
# expects a standard `supabase/functions/` layout — so we stage a temp copy.
#
# Prereqs: supabase CLI installed + `supabase login`. Run: ./deploy-functions.sh
set -euo pipefail

REF="ymgqpbnjpztwjsyvceld"   # dedicated RendProp project
HERE="$(cd "$(dirname "$0")" && pwd)"      # services/supabase
STAGE="$HERE/.deploy"

echo "→ Staging functions into standard layout…"
rm -rf "$STAGE"
mkdir -p "$STAGE/supabase"
cp -R "$HERE/functions" "$STAGE/supabase/functions"
cat > "$STAGE/supabase/config.toml" <<TOML
project_id = "$REF"
[functions]
TOML

cd "$STAGE"

# Owner routes (require a valid JWT — default).
for f in listings uploads renders me ai-enhance; do
  echo "→ deploy $f"
  supabase functions deploy "$f" --project-ref "$REF"
done

# Public routes (no JWT — the tour host + browsers call these).
for f in tours leads beacon portfolio; do
  echo "→ deploy $f (public)"
  supabase functions deploy "$f" --project-ref "$REF" --no-verify-jwt
done

cd "$HERE"
rm -rf "$STAGE"
echo "✓ All functions deployed. Set secrets with ./set-secrets.sh if you haven't."
