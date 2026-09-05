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
  ELEVENLABS_API_KEY="PASTE_ELEVENLABS_KEY" \
  ELEVENLABS_MODEL_ID="OPTIONAL_BLANK" \
  ANTHROPIC_API_KEY="PASTE_ANTHROPIC_KEY" \
  OPENAI_API_KEY="PASTE_OPENAI_KEY" \
  WORLDLABS_API_KEY="OPTIONAL_BLANK" \
  ANTHROPIC_MODEL_QC="claude-haiku-4-5" \
  ANTHROPIC_MODEL_ESCALATE="claude-sonnet-5" \
  KIE_API_KEY="OPTIONAL_BLANK" \
  HIGGSFIELD_API_KEY_ID="OPTIONAL_BLANK" \
  HIGGSFIELD_API_KEY_SECRET="OPTIONAL_BLANK" \
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
# AI ROUTER PROVIDERS (docs/AI-ROUTER-CONTRACT.md). KIE_API_KEY,
# HIGGSFIELD_API_KEY_ID and HIGGSFIELD_API_KEY_SECRET are OPTIONAL and should
# stay blank until the terms are signed: every Kie and Higgsfield row in
# ai_routes ships `enabled = false` (commercial rights / no-training terms
# unconfirmed), so nothing routes to them and a blank secret costs nothing. When
# they are filled in, the adapters read them and NOTHING else does — the value
# is never logged, never returned and never put in a job token. Higgsfield takes
# TWO values and sends them as one header, `Authorization: Key <ID>:<SECRET>`.
#
# ELEVENLABS_API_KEY powers the reel voiceover (ai-voice). Without it BOTH
# /ai-voice routes return 503 `upstream` naming this secret — the app shows that
# message rather than an empty voice list. Get it from the ElevenLabs dashboard
# under Profile -> API Keys. ELEVENLABS_MODEL_ID is OPTIONAL and should normally
# stay blank: unset means the function sends no model_id and ElevenLabs uses its
# own current default, which cannot be retired out from under us the way a
# hardcoded model id can (that is exactly how GEMINI_TEXT_MODEL broke).
#
# TOUR_PUBLIC_BASE_URL must match the tour host's routed domain (wrangler.toml routes
# rendprop.com/f/* and /a/*; every code default is rendprop.com). It used to say
# rendprop.app here, which would have minted share links on an unrouted host.
#
# APPLE_PRIVATE_KEY_P8: export APPLE_P8_PATH=~/Downloads/AuthKey_XXXX.p8 before running
# (the .p8 contents, PEM). All four APPLE_* values are required for Sign in with Apple
# token revocation on account deletion (TN3194); without them /me/apple-code returns
# stored:false and DELETE /me leaves the Apple grant queued forever.

echo "✓ Secrets set for project $REF"
