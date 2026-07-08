#!/bin/bash
# Rendprop — API key setup.
# HOW TO USE: double-click this file in Finder. (If macOS blocks it the first
# time: right-click it → Open → Open.)
# It asks for your keys and saves them safely to services/pipeline/.env
# The .env file is ignored by git, so your keys never leave your computer.

cd "$(dirname "$0")"
ENV_FILE="services/pipeline/.env"

echo ""
echo "  ── Rendprop API key setup ──"
echo ""
echo "  Your keys are saved to $ENV_FILE (private, never uploaded)."
echo "  Paste each key and press Return. Paste with Cmd+V."
echo ""

read -r -p "  1/3  Claude (Anthropic) API key: " ANTHROPIC_KEY
echo ""
echo "  Higgsfield gives you TWO values (find them at cloud.higgsfield.ai → API keys):"
read -r -p "  2/3  Higgsfield API key: " HF_KEY
read -r -p "  3/3  Higgsfield API secret: " HF_SECRET
echo ""

mkdir -p services/pipeline
cat > "$ENV_FILE" <<EOF
# Rendprop pipeline credentials — created $(date '+%Y-%m-%d %H:%M')
ANTHROPIC_API_KEY=$ANTHROPIC_KEY
ANTHROPIC_MODEL=claude-fable-5

HIGGSFIELD_API_KEY=$HF_KEY
HIGGSFIELD_API_SECRET=$HF_SECRET

# Model routing (Higgsfield hosts all of these — swap freely)
HF_IMAGE_EDIT_MODEL=nano-banana-pro/image-edit
HF_I2V_MODEL=bytedance/seedance/v2/pro/image-to-video

# Quality loop
QC_PASS_SCORE=85
QC_MAX_RETRIES=2
MAX_GEN_COST_PER_JOB_CENTS=2500

# Optional: Cloudflare R2 (needed to upload frames for the API to reach)
R2_ACCOUNT_ID=
R2_ACCESS_KEY_ID=
R2_SECRET_ACCESS_KEY=
R2_BUCKET=rendprop-dev
EOF

chmod 600 "$ENV_FILE"
echo "  ✓ Saved. You can close this window."
echo ""
read -r -p "  Press Return to finish."
