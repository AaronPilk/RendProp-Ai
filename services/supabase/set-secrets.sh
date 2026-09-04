#!/usr/bin/env bash
# Set the Edge Function secrets for Rendprop. EDIT the values below, then run.
# SUPABASE_URL / ANON / SERVICE_ROLE are auto-injected by the platform — omit them.
#
# Every secret the functions read (grep "Deno.env.get" functions/) is listed;
# the ones marked OPTIONAL may stay blank and the feature degrades honestly
# (Stream deletion queues, Turnstile is a no-op, Apple revocation is queued).
set -euo pipefail
REF="ymgqpbnjpztwjsyvceld"   # dedicated RendProp project

supabase secrets set --project-ref "$REF" \
  CLOUDFLARE_ACCOUNT_ID="PASTE_ACCOUNT_ID" \
  R2_ACCESS_KEY_ID="PASTE_R2_ACCESS_KEY" \
  R2_SECRET_ACCESS_KEY="PASTE_R2_SECRET" \
  R2_BUCKET_UPLOADS="rendprop-uploads" \
  R2_BUCKET_RENDERS="rendprop-renders" \
  R2_BUCKET_PUBLIC="rendprop-public" \
  R2_PUBLIC_BASE_URL="https://PASTE_PUBLIC_R2_OR_CUSTOM_DOMAIN" \
  CLOUDFLARE_STREAM_TOKEN="PASTE_STREAM_TOKEN_OR_BLANK" \
  CLOUDFLARE_STREAM_CUSTOMER_CODE="PASTE_STREAM_CUSTOMER_CODE_OR_BLANK" \
  GEMINI_API_KEY="PASTE_GEMINI_KEY" \
  GEMINI_IMAGE_MODEL="gemini-2.5-flash-image" \
  GEMINI_TEXT_MODEL="gemini-2.5-flash" \
  FAL_KEY="PASTE_FAL_KEY" \
  ANTHROPIC_API_KEY="PASTE_ANTHROPIC_KEY" \
  ANTHROPIC_MODEL_QC="claude-haiku-4-5" \
  ANTHROPIC_MODEL_ESCALATE="claude-sonnet-5" \
  KIE_API_KEY="OPTIONAL_BLANK" \
  GHL_API_KEY="OPTIONAL_BLANK" \
  GHL_LOCATION_ID="OPTIONAL_BLANK" \
  TURNSTILE_SECRET_KEY="OPTIONAL_BLANK" \
  APPLE_TEAM_ID="PASTE_APPLE_TEAM_ID" \
  APPLE_CLIENT_ID="com.rendprop.app" \
  APPLE_KEY_ID="PASTE_SIGN_IN_WITH_APPLE_KEY_ID" \
  APPLE_PRIVATE_KEY_P8="$(cat "${APPLE_P8_PATH:-/dev/null}")" \
  QC_PASS_SCORE="85" \
  QC_MAX_RETRIES="2" \
  MAX_GEN_COST_PER_JOB_CENTS="2500" \
  TOUR_PUBLIC_BASE_URL="https://rendprop.com"
# TOUR_PUBLIC_BASE_URL must match the tour host's routed domain (wrangler.toml routes
# rendprop.com/f/* and /a/*; every code default is rendprop.com). It used to say
# rendprop.app here, which would have minted share links on an unrouted host.
#
# APPLE_PRIVATE_KEY_P8: export APPLE_P8_PATH=~/Downloads/AuthKey_XXXX.p8 before running
# (the .p8 contents, PEM). All four APPLE_* values are required for Sign in with Apple
# token revocation on account deletion (TN3194); without them /me/apple-code returns
# stored:false and DELETE /me leaves the Apple grant queued forever.

echo "✓ Secrets set for project $REF"
