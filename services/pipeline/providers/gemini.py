#!/usr/bin/env python3
"""
Google Gemini adapter — virtual restage through GenerateContent.
The configured model defaults to gemini-3.1-flash-image. Image geometry is
prompt-controlled and must still pass the separate drift check.

The REST request is:

  POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
  header: x-goog-api-key: $GEMINI_API_KEY
  body:  { "contents":[{"role":"user","parts":[
              {"text": <edit prompt>},
              {"inline_data":{"mime_type":"image/jpeg","data":"<base64>"}} ]}],
          "generationConfig":{"responseModalities":["IMAGE"],
            "candidateCount":1,"maxOutputTokens":4096,
            "imageConfig":{"imageSize":"1K"}} }
  resp:  { "candidates":[{"content":{"parts":[
              {"inlineData":{"mimeType":"image/png","data":"<base64>"}} ]}}] }

The model id is configurable (GEMINI_IMAGE_MODEL). Paid dispatch requires the
worker's funded session and a quote bound to the actual payload. Historical
per-image cost estimates in costs.py are not provider invoices or authority
to spend. Unknown models require explicit private testing sponsorship.

CITATIONS:
  https://ai.google.dev/gemini-api/docs/generate-content/thinking#token-limits-and-max_output_tokens
  https://ai.google.dev/gemini-api/docs/image-generation
  https://ai.google.dev/gemini-api/docs/image-understanding (inline_data input)
"""

from __future__ import annotations

import base64

from config import SETTINGS
from providers import costs
from providers.base import (
    MissingKey,
    ProviderError,
    ProviderResult,
    request_json,
    sniff_mime,
)
from providers.funding import IMAGE_MAX_OUTPUT_TOKENS

API_ROOT = "https://generativelanguage.googleapis.com/v1beta/models"

# KNOWN unit cost (from the single cost table).
UNIT_COST_CENTS = costs.UNIT_COSTS_CENTS["restage_gemini"]


def _extract_image(resp: dict) -> bytes:
    """Pull the first inline image out of a generateContent response.

    Tolerates camelCase (`inlineData`/`mimeType`) and snake_case
    (`inline_data`/`mime_type`). Raises with any text the model returned instead
    (e.g. a safety refusal) so failures are debuggable.
    """
    candidates = resp.get("candidates") or []
    texts: list[str] = []
    for cand in candidates:
        parts = (cand.get("content") or {}).get("parts") or []
        for part in parts:
            blob = part.get("inlineData") or part.get("inline_data")
            if blob and blob.get("data"):
                return base64.b64decode(blob["data"])
            if part.get("text"):
                texts.append(part["text"])
    reason = " | ".join(texts) if texts else str(resp)[:800]
    raise ProviderError(f"Gemini returned no image. Model said: {reason}")


def restage(image: bytes, style_prompt: str, *, model: str | None = None) -> bytes:
    """Restage a room image in a target style. Returns edited image bytes.

    `style_prompt` should already carry the architecture-lock language (the
    router builds it via config.style_prompt). Architecture preservation here is
    STATISTICAL (prompt-enforced) — the QC drift judge gates the result.
    """
    if not SETTINGS.gemini_api_key:
        raise MissingKey("GEMINI_API_KEY is not set — cannot call Gemini.")
    model = model or SETTINGS.gemini_image_model
    url = f"{API_ROOT}/{model}:generateContent"
    payload = {
        "contents": [{
            "role": "user",
            "parts": [
                {"text": style_prompt},
                {"inline_data": {"mime_type": sniff_mime(image), "data": base64.b64encode(image).decode()}},
            ],
        }],
        # Some model builds require ["TEXT","IMAGE"]; "IMAGE" keeps output lean.
        "generationConfig": {"responseModalities": ["IMAGE"],
                             "candidateCount": 1, "maxOutputTokens": IMAGE_MAX_OUTPUT_TOKENS,
                             **({"imageConfig": {"imageSize": "1K"}} if model.startswith("gemini-3") else {})},
    }
    resp = request_json(url, method="POST", payload=payload,
                        headers={"x-goog-api-key": SETTINGS.gemini_api_key}, timeout=180, retries=2)
    return _extract_image(resp)


def restage_result(image: bytes, style_prompt: str, *, model: str | None = None) -> ProviderResult:
    """restage() with the cost/meta envelope the router logs to the ledger."""
    data = restage(image, style_prompt, model=model)
    return ProviderResult(
        data=data, provider="gemini", model=model or SETTINGS.gemini_image_model,
        feature="restage", units=1, unit_cost_cents=UNIT_COST_CENTS,
        total_cents=UNIT_COST_CENTS, meta={"route": "gemini_direct"},
    )
