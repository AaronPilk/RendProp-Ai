// ai-photo — single-image real-estate AI edits (twilight | sky | lawn |
// declutter | stage) via Gemini image edit ("Nano Banana"). Owner-authenticated.
// Mirrors services/pipeline providers/gemini.py + router.PHOTO_EDIT_PROMPTS.
//
//   POST /ai-photo  { image_b64, mime?, edit, style? }  ->  { image_b64, mime, edit, style? }
//
//   edit  = twilight | sky | lawn | declutter | stage
//   style = modern | rustic | minimalist | scandinavian   (stage only; default modern)
//
// Needs the GEMINI_API_KEY function secret. Returns the edited image inline
// (base64) so the app can show a before/after and let the agent save/share.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, readJson, respondError } from "../_shared/http.ts";
import { getUser } from "../_shared/supabase.ts";

const MODEL = Deno.env.get("GEMINI_IMAGE_MODEL") ?? "gemini-2.5-flash-image";
const GEMINI_KEY = Deno.env.get("GEMINI_API_KEY");

const LOCK =
  "Do not change the building's architecture, structure, dimensions, walls, or " +
  "window/door placement. Photorealistic, natural, consistent perspective and shadows.";

// Staging must NEVER remodel the room — only add furnishings.
const STAGE_LOCK =
  "CRITICAL: keep the room's architecture EXACTLY as photographed — identical walls, " +
  "windows, doors, ceiling, flooring material, trim, built-ins, light fixtures, the view " +
  "through the windows, camera angle, and perspective. Only ADD furniture and decor; do not " +
  "remodel, repaint, resurface, or alter the structure or lighting direction in any way. " +
  "Photorealistic materials with shadows and reflections that match the room's existing light.";

const PROMPTS: Record<string, string> = {
  twilight:
    "Convert this daytime exterior real-estate photo into a stunning twilight/dusk shot: " +
    "deep blue-to-warm-orange gradient sky, warm glowing interior window lights, subtle " +
    "landscape/path lighting, professional dusk real-estate photography. Keep the house, " +
    "landscaping, driveway, and composition exactly the same — only change the sky and lighting. " + LOCK,
  sky:
    "Replace the dull, grey, or overcast sky in this real-estate photo with a bright, clear " +
    "blue sky with soft natural clouds. Keep the house, trees, and ground exactly the same and " +
    "match the lighting, shadows, and reflections naturally. " + LOCK,
  lawn:
    "Repair and green the lawn in this real-estate photo: lush, healthy, vibrant green grass; " +
    "remove brown/dead patches, dirt, and weeds. Keep the house, hardscape, driveway, plants, " +
    "and everything else identical. " + LOCK,
  declutter:
    "Remove all clutter, mess, and personal items from this real-estate photo: shoes, bags, " +
    "boxes, cords, laundry, dishes, papers, toys, toiletries, fridge magnets, and stray items " +
    "on floors, counters, and surfaces. Keep the room, furniture, decor, and architecture " +
    "IDENTICAL — same walls, windows, doors, flooring, fixtures, camera angle, and lighting. " +
    "Seamlessly fill revealed floor/surface areas to match the surrounding material and light. " + LOCK,
};

// Per-style furnishing direction for edit:"stage".
const STAGE_STYLES: Record<string, string> = {
  modern:
    "modern contemporary furniture: clean-lined sofa and chairs, a low-profile coffee table, " +
    "a large area rug, tasteful wall art, and designer accent lighting in a neutral palette " +
    "with warm accents",
  rustic:
    "rustic farmhouse furniture: warm natural woods, a comfortable linen-upholstered sofa, " +
    "woven and vintage accents, layered cozy textiles, and earthy tones",
  minimalist:
    "minimalist furniture: a few essential low-profile pieces, uncluttered surfaces, a " +
    "restrained monochrome palette, and plenty of intentional negative space",
  scandinavian:
    "Scandinavian furniture: light woods, soft whites with muted pastel accents, simple " +
    "functional pieces, hygge textiles like wool throws and sheepskin, and airy styling",
};

function stagePrompt(styleDesc: string): string {
  return (
    "Virtually stage this real-estate photo: furnish the room with " + styleDesc + ". " +
    "Use realistic scale and placement appropriate to the room type, resting naturally on the " +
    "existing floor. If the room already has furniture, replace it cleanly with the new set. " +
    STAGE_LOCK
  );
}

interface Body {
  image_b64?: string;
  mime?: string;
  edit?: string;
  style?: string;
  /** Free-text instruction for edit:"custom" (Mirino-style prompting). */
  prompt?: string;
}

const MAX_CUSTOM_PROMPT = 600;

/** Wrap a user's free-text instruction with the guardrails every edit gets. */
function customPrompt(userText: string): string {
  return (
    "Edit this real-estate photo as follows: " + userText.trim() + ". " +
    "Stay photorealistic and true to the space — this is a real property listing. " + LOCK
  );
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();
  try {
    await getUser(req); // owner auth; RLS not needed (no DB touch)
    if (req.method !== "POST") throw new HttpError(405, "POST only");
    if (!GEMINI_KEY) throw new HttpError(500, "GEMINI_API_KEY function secret is not set");

    const body = await readJson<Body>(req);
    assert(body.image_b64, 400, "image_b64 is required");
    const edit = body.edit ?? "twilight";
    const mime = body.mime ?? "image/jpeg";

    let prompt: string;
    let style: string | undefined;
    if (edit === "stage") {
      style = (body.style ?? "modern").toLowerCase();
      const styleDesc = STAGE_STYLES[style];
      assert(styleDesc, 400, `style must be ${Object.keys(STAGE_STYLES).join("|")} (got ${style})`);
      prompt = stagePrompt(styleDesc);
    } else if (edit === "custom") {
      const userText = (body.prompt ?? "").trim();
      assert(userText.length > 0, 400, "edit:'custom' requires a non-empty `prompt`");
      assert(userText.length <= MAX_CUSTOM_PROMPT, 400,
             `prompt too long (max ${MAX_CUSTOM_PROMPT} chars)`);
      prompt = customPrompt(userText);
    } else {
      prompt = PROMPTS[edit];
      assert(prompt, 400, `edit must be twilight|sky|lawn|declutter|stage|custom (got ${edit})`);
    }

    const url = `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`;
    const payload = {
      contents: [{
        role: "user",
        parts: [
          { text: prompt },
          { inline_data: { mime_type: mime, data: body.image_b64 } },
        ],
      }],
      generationConfig: { responseModalities: ["IMAGE"] },
    };

    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json", "x-goog-api-key": GEMINI_KEY },
      body: JSON.stringify(payload),
    });
    const data = await res.json();
    if (!res.ok) {
      throw new HttpError(502, `Gemini ${res.status}: ${JSON.stringify(data).slice(0, 300)}`);
    }

    let outB64: string | null = null;
    const texts: string[] = [];
    for (const cand of (data.candidates ?? [])) {
      for (const part of ((cand.content?.parts) ?? [])) {
        const blob = part.inlineData ?? part.inline_data;
        if (blob?.data) { outB64 = blob.data as string; break; }
        if (part.text) texts.push(part.text as string);
      }
      if (outB64) break;
    }
    if (!outB64) {
      throw new HttpError(502, `Gemini returned no image. ${texts.join(" | ").slice(0, 300)}`);
    }
    return json({ image_b64: outB64, mime: "image/png", edit, ...(style ? { style } : {}) });
  } catch (err) {
    return respondError(err);
  }
});
