#!/usr/bin/env bash
# Set the Edge Function secrets for Rendprop. EDIT the values below, then run.
# SUPABASE_URL / ANON / SERVICE_ROLE are auto-injected by the platform — omit them.
#
# Every secret the functions read (grep "Deno.env.get" functions/) is listed;
# the ones marked OPTIONAL may stay blank and the feature degrades honestly
# (Stream deletion queues, Apple revocation is queued). TURNSTILE_SECRET_KEY is
# the one exception: leave it blank and POST /leads REJECTS every public lead
# submission (fails closed, audit fix) — paste a real key, or set
# TURNSTILE_OPTIONAL=1 below to knowingly launch without bot protection.
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
  JOB_TOKEN_SIGNING_SECRET="PASTE_RANDOM_SECRET_e.g._openssl_rand_-hex_32" \
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
  TURNSTILE_SECRET_KEY="PASTE_TURNSTILE_SECRET_KEY" \
  TURNSTILE_OPTIONAL="OPTIONAL_BLANK" \
  APPLE_TEAM_ID="PASTE_APPLE_TEAM_ID" \
  APPLE_CLIENT_ID="com.rendprop.app" \
  APPLE_KEY_ID="PASTE_SIGN_IN_WITH_APPLE_KEY_ID" \
  APPLE_PRIVATE_KEY_P8="$(cat "${APPLE_P8_PATH:-/dev/null}")" \
  QC_PASS_SCORE="85" \
  QC_MAX_RETRIES="2" \
  MAX_GEN_COST_PER_JOB_CENTS="2500" \
  TOUR_PUBLIC_BASE_URL="https://rendprop.com" \
  APNS_KEY_P8="$(cat "${APNS_P8_PATH:-/dev/null}")" \
  APNS_KEY_ID="OPTIONAL_BLANK" \
  APNS_TEAM_ID="OPTIONAL_BLANK" \
  RESEND_API_KEY="OPTIONAL_BLANK" \
  NOTIFY_FROM_EMAIL="OPTIONAL_BLANK"
#
# LIFECYCLE NOTIFICATIONS (migration 0047 + functions/notify). All five are
# OPTIONAL and the system SHIPS INERT without them: the outbox still fills
# (a lead, a finished tour, a trial ending), the drain still runs, and every
# row it cannot deliver is marked `skipped` with the exact variable names it
# is missing. Nothing 500s, nothing crash-loops, and the two channels are
# independent — e-mail set and push not (or the reverse) works fine.
#
#   APNS_KEY_P8 / APNS_KEY_ID / APNS_TEAM_ID   the .p8 token key from the
#     Apple Developer portal (Keys → "Apple Push Notifications service"),
#     its key id, and the 10-character team id. Set APNS_P8_PATH to the
#     downloaded file before running this script. WITHOUT THEM: every push
#     row is skipped with "push is not configured: set …". The topic is the
#     bundle id (com.rendprop.app) and is NOT a secret — it is hardcoded.
#   RESEND_API_KEY / NOTIFY_FROM_EMAIL        one Resend key and the From
#     address (e.g. "Rendprop <hello@rendprop.com>", on a domain verified in
#     Resend). WITHOUT THEM: every e-mail row is skipped with "email is not
#     configured: set …". A second provider is a new function in
#     functions/notify/email.ts, not a rewrite.
#
# A row that could not be delivered stays in the outbox until
# notification_sweep() expires it at 72 hours, so a key added the same day
# still delivers the backlog. See DEPLOYMENT.md §11.
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
# JOB_TOKEN_SIGNING_SECRET signs the opaque async-job status token ai-video
# mints at submit and verifies at GET /ai-video/status (_shared/providers/jobtoken.ts,
# audit item 4 — see docs/handoff/audit-fixes.md). A random secret dedicated to
# this ONE purpose — generate with `openssl rand -hex 32`, never reuse a vendor
# key or the service-role key. Unset means every routed job's status check is
# rejected as unverifiable (loud, not a silent fallback to unsigned tokens).
# Rotating it invalidates any token minted under the old value within
# TOKEN_TTL_SECONDS (2h) — acceptable churn, not a data-loss risk (the
# underlying vendor job is unaffected; a caller just has to re-poll and would
# see the same terminal state on any surviving legacy path).
#
# TURNSTILE_SECRET_KEY: Cloudflare dashboard -> Turnstile -> your widget -> Secret
# Key. Required — POST /leads (public lead capture) now FAILS CLOSED and rejects
# every submission when this is blank, instead of the old silent no-op. Leave it
# blank ONLY if you also set TURNSTILE_OPTIONAL=1 right below it, which is a
# knowing opt-out (a warning is still logged on every request either way). See
# services/supabase/functions/leads/README.md.
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
