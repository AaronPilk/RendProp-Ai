#!/usr/bin/env python3
"""
Google Gemini adapter — virtual restage via "Nano Banana"
(Gemini 2.5 Flash Image). Best-in-class geometry + lighting preservation, and
the cheapest direct route at ~$0.039/img.

We use the stable `:generateContent` REST surface (GA, and the one whose pricing
maps exactly to the cost model: 1290 output tok/img × $30/1M = $0.0387 ≈ 3.9¢):

  POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
  header: x-goog-api-key: $GEMINI_API_KEY
  body:  { "contents":[{"role":"user","parts":[
              {"text": <edit prompt>},
              {"inline_data":{"mime_type":"image/jpeg","data":"<base64>"}} ]}],
          "generationConfig":{"responseModalities":["IMAGE"]} }
  resp:  { "candidates":[{"content":{"parts":[
              {"inlineData":{"mimeType":"image/png","data":"<base64>"}} ]}}] }

The model id is configurable (GEMINI_IMAGE_MODEL). Google has since introduced a
newer `/v1beta/interactions` surface (model e.g. `gemini-3.1-flash-image`, with
`input:[{type,text},{type:image,mime_type,data}]` and `interaction.output_image`)
— switching routes is a one-line config change; the $/img key lives in costs.py.

CITATIONS:
  https://ai.google.dev/gemini-api/docs/image-generation   (interactions + REST)
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
        "generationConfig": {"responseModalities": ["IMAGE"]},
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
