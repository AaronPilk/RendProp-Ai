#!/usr/bin/env bash
# Set the Edge Function secrets for Rendprop. EDIT the values below, then run.
# SUPABASE_URL / ANON / SERVICE_ROLE are auto-injected by the platform — omit them.
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
  FAL_KEY="PASTE_FAL_KEY" \
  ANTHROPIC_API_KEY="PASTE_ANTHROPIC_KEY" \
  ANTHROPIC_MODEL_QC="claude-haiku-4-5" \
  ANTHROPIC_MODEL_ESCALATE="claude-sonnet-5" \
  KIE_API_KEY="OPTIONAL_BLANK" \
  GHL_API_KEY="OPTIONAL_BLANK" \
  GHL_LOCATION_ID="OPTIONAL_BLANK" \
  QC_PASS_SCORE="85" \
  QC_MAX_RETRIES="2" \
  MAX_GEN_COST_PER_JOB_CENTS="2500" \
  TOUR_PUBLIC_BASE_URL="https://rendprop.app"

echo "✓ Secrets set for project $REF"
