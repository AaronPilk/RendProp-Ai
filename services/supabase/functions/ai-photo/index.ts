// ai-photo — single-image real-estate AI edits (twilight | sky | lawn |
// declutter | stage) via Gemini image edit ("Nano Banana"). Owner-authenticated.
// Mirrors services/pipeline providers/gemini.py + router.PHOTO_EDIT_PROMPTS.
//
//   POST /ai-photo  { image_b64, mime?, edit, style? }  ->  { image_b64, mime, edit, style? }
//
//   edit  = twilight | sky | lawn | declutter | stage | custom
//   style = modern | rustic | minimalist | scandinavian   (stage only; default modern)
//
// Two cheap text/vision helper modes (no image generated, nothing billed extra):
//
//   edit:"suggest"         { image_b64, mime? }  ->  { suggestions: [{ edit, reason, confidence }] }
//       Looks at the photo and recommends up to 3 edits (from the 5 canned ones)
//       that would genuinely improve it — e.g. twilight only for exteriors.
//
//   edit:"improve_prompt"  { prompt }            ->  { prompt }
//       Rewrites the user's rough custom-edit idea (≤300 chars) into a precise,
//       photorealistic edit instruction (≤400 chars). The improved prompt is
//       meant to be sent back as edit:"custom", where the architecture-lock
//       guardrails are appended server-side as usual — so the rewrite itself
//       stays purely about the visual change.
//
// Needs the GEMINI_API_KEY function secret. Returns the edited image inline
// (base64) so the app can show a before/after and let the agent save/share.

import { handleOptions } from "../_shared/cors.ts";
import { HttpError, assert, json, readJson, respondError } from "../_shared/http.ts";
import { adminClient, getUser, orgForUser, preferredOrg } from "../_shared/supabase.ts";
import { durableRateLimit } from "../_shared/ratelimit.ts";

// Denial-of-wallet guard: image edits bill Gemini per call.
const EDIT_MAX_PER_WINDOW = 40;
const EDIT_WINDOW_SECONDS = 300; // 40 photo edits / 5 min / org
const MONTH_SECONDS = 30 * 86400;

// Plan-scaled monthly ceilings. These MIRROR the published numbers on
// rendprop.com/pricing (Solo 150 / Pro 500 / Team 2000 AI photo edits) — a flat
// 3000 both ignored plan entitlement and over-delivered against a $49 plan.
// Free early access gets the Solo allowance.
const EDIT_MONTHLY_BY_PLAN: Record<string, number> = {
  free: 150,
  solo: 150,
  pro: 500,
  team: 2000,
};

/**
 * Charge the paid-generation quotas. MUST be called only AFTER the request body
 * and its parameters are known-good: charging first meant a caller could burn
 * an org's burst + monthly quota with `{}` bodies that never reached Gemini
 * (audit round 4). Also enforces the role gate — marketing is read-only and
 * must not be able to spend the workspace's AI budget.
 */
async function guardEdit(userId: string, req: Request): Promise<void> {
  const orgId = await orgForUser(userId, preferredOrg(req));
  const admin = adminClient();

  const { data: mem, error: mErr } = await admin
    .from("memberships").select("role").eq("user_id", userId).eq("org_id", orgId).maybeSingle();
  if (mErr) throw new HttpError(500, `Role lookup failed: ${mErr.message}`);
  if (!mem?.role || mem.role === "marketing") {
    throw new HttpError(403, "Your role does not permit AI photo edits");
  }

  const { data: org } = await admin.from("orgs").select("plan").eq("id", orgId).maybeSingle();
  const monthlyCap = EDIT_MONTHLY_BY_PLAN[String(org?.plan ?? "free")] ?? EDIT_MONTHLY_BY_PLAN.free;

  const idem = req.headers.get("idempotency-key")?.trim();
  if (idem && idem.length <= 128) {
    if (!(await durableRateLimit(`aipidem:${orgId}:${idem}`, 1, 120))) {
      throw new HttpError(409, "Duplicate submission — this edit was already started.");
    }
  }
  if (!(await durableRateLimit(`aiphoto:${orgId}`, EDIT_MAX_PER_WINDOW, EDIT_WINDOW_SECONDS))) {
    throw new HttpError(429, "AI photo edit limit reached for now — try again in a few minutes.");
  }
  if (!(await durableRateLimit(`aiphotomo:${orgId}`, monthlyCap, MONTH_SECONDS))) {
    throw new HttpError(429, "This workspace has reached its monthly AI edit limit for its plan — contact support to raise it.");
  }
}

// Bound the inline base64 image so a caller can't push unbounded memory
// pressure through readJson (audit round 4). ~12 MB of base64 ≈ 9 MB binary.
const MAX_IMAGE_B64_CHARS = 12_000_000;

const MODEL = Deno.env.get("GEMINI_IMAGE_MODEL") ?? "gemini-2.5-flash-image";
// Text+vision model for the suggest / improve_prompt helper modes (NOT the
// image model — these are plain generateContent calls returning JSON).
const TEXT_MODEL = Deno.env.get("GEMINI_TEXT_MODEL") ?? "gemini-2.5-flash";
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
const MAX_IMPROVE_INPUT = 300;  // rough idea in
const MAX_IMPROVE_OUTPUT = 400; // polished instruction out

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
    const user = await getUser(req); // owner auth; RLS not needed (no DB touch)
    if (req.method !== "POST") throw new HttpError(405, "POST only");
    if (!GEMINI_KEY) throw new HttpError(500, "GEMINI_API_KEY function secret is not set");

    // VALIDATE FIRST, CHARGE SECOND (audit round 4). Every quota consumption
    // below happens only once we know the request would actually reach Gemini.
    const body = await readJson<Body>(req);
    const edit = body.edit ?? "twilight";
    const mime = body.mime ?? "image/jpeg";

    if (body.image_b64 !== undefined) {
      assert(typeof body.image_b64 === "string", 400, "image_b64 must be a string");
      assert(body.image_b64.length <= MAX_IMAGE_B64_CHARS, 413,
             "image is too large — resize it before sending");
    }

    // Helper modes: text/vision analysis only — no image generation.
    if (edit === "suggest") {
      assert(body.image_b64, 400, "image_b64 is required");
      await guardEdit(user.id, req);
      return json({ suggestions: await suggestEdits(body.image_b64, mime) });
    }
    if (edit === "improve_prompt") {
      const rough = (body.prompt ?? "").trim();
      assert(rough.length > 0, 400, "edit:'improve_prompt' requires a non-empty `prompt`");
      assert(rough.length <= MAX_IMPROVE_INPUT, 400,
             `prompt too long (max ${MAX_IMPROVE_INPUT} chars)`);
      await guardEdit(user.id, req);
      return json({ prompt: await improvePrompt(rough) });
    }

    assert(body.image_b64, 400, "image_b64 is required");

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
      assert(prompt, 400,
             `edit must be twilight|sky|lawn|declutter|stage|custom|suggest|improve_prompt (got ${edit})`);
    }

    // Everything validated — NOW charge the quota, immediately before the
    // billable Gemini call.
    await guardEdit(user.id, req);

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

// ── helper modes: suggest / improve_prompt (text+vision, JSON out) ────────────

interface Suggestion {
  edit: string;
  reason: string;
  confidence: number;
}

const SUGGESTABLE_EDITS = ["twilight", "sky", "lawn", "declutter", "stage"];

const SUGGEST_INSTRUCTION =
  "You are reviewing ONE real-estate listing photo for an agent. These are the available " +
  "one-tap AI edits:\n" +
  "- twilight: turn a daytime EXTERIOR into a dusk shot with glowing windows (exteriors only)\n" +
  "- sky: replace a dull/grey/overcast sky with a clear blue one (only when sky is visible " +
  "and actually dull)\n" +
  "- lawn: green up patchy/brown grass (only when a lawn is visible and looks unhealthy)\n" +
  "- declutter: remove mess and personal items from floors and surfaces (only when visible " +
  "clutter hurts the shot)\n" +
  "- stage: virtually furnish an empty or sparsely furnished room (empty/sparse interiors only)\n\n" +
  "Recommend ONLY edits that would genuinely improve THIS specific photo — an interior must " +
  "never get twilight/sky/lawn, a furnished room must never get stage, a clean room must " +
  "never get declutter. Zero suggestions is a valid answer.\n\n" +
  'Reply with STRICT JSON only, shaped exactly like {"suggestions":[{"edit":"sky",' +
  '"reason":"...","confidence":0.9}]} — at most 3 entries, best first. "reason" is a plain-' +
  "language sentence of at most 80 characters written for the agent (e.g. \"Grey sky makes " +
  "the house look gloomy\"). \"confidence\" is 0 to 1.";

/** edit:"suggest" — analyze the photo and pick up to 3 genuinely useful edits. */
async function suggestEdits(imageB64: string, mime: string): Promise<Suggestion[]> {
  const raw = await geminiText(
    [
      { text: SUGGEST_INSTRUCTION },
      { inline_data: { mime_type: mime, data: imageB64 } },
    ],
    true,
  );

  const parsed = parseJsonLoose(raw);
  const list = Array.isArray((parsed as Record<string, unknown>)?.suggestions)
    ? (parsed as { suggestions: unknown[] }).suggestions
    : Array.isArray(parsed)
    ? (parsed as unknown[])
    : [];

  const out: Suggestion[] = [];
  const seen = new Set<string>();
  for (const item of list) {
    if (out.length >= 3) break;
    if (!item || typeof item !== "object") continue;
    const o = item as Record<string, unknown>;
    const edit = String(o.edit ?? "").toLowerCase().trim();
    if (!SUGGESTABLE_EDITS.includes(edit) || seen.has(edit)) continue;
    const reason = String(o.reason ?? "").trim().slice(0, 80);
    let confidence = Number(o.confidence);
    if (!Number.isFinite(confidence)) confidence = 0.5;
    confidence = Math.min(1, Math.max(0, Math.round(confidence * 100) / 100));
    out.push({ edit, reason, confidence });
    seen.add(edit);
  }
  return out;
}

const IMPROVE_INSTRUCTION =
  "You polish rough photo-edit requests from real-estate agents into precise instructions " +
  "for an AI photo editor working on a real listing photo.\n\n" +
  "Rewrite the user's idea as ONE clear, imperative edit instruction: concrete about what " +
  "changes and what stays, photorealistic, plausible for a real property, no camera jargon, " +
  "no markdown, no quotes, a single paragraph of at most 400 characters. Keep the user's " +
  "intent exactly — never invent extra changes they did not ask for. Do NOT add boilerplate " +
  "about preserving architecture; the system appends that separately.\n\n" +
  'Reply with STRICT JSON only: {"prompt":"<rewritten instruction>"}';

/** edit:"improve_prompt" — rewrite a rough custom-edit idea into a precise one. */
async function improvePrompt(rough: string): Promise<string> {
  const raw = await geminiText(
    [{ text: IMPROVE_INSTRUCTION + "\n\nUser's idea: " + rough }],
    true,
  );

  const parsed = parseJsonLoose(raw);
  let improved = "";
  if (parsed && typeof parsed === "object" && typeof (parsed as Record<string, unknown>).prompt === "string") {
    improved = ((parsed as Record<string, unknown>).prompt as string).trim();
  } else if (typeof raw === "string") {
    // Model ignored the JSON contract — fall back to its plain text.
    improved = raw.replace(/^```(?:json)?|```$/g, "").replace(/^"|"$/g, "").trim();
  }
  if (!improved) throw new HttpError(502, "Gemini returned no improved prompt");
  return improved.replace(/\s+/g, " ").slice(0, MAX_IMPROVE_OUTPUT);
}

/** One text/vision generateContent call on the cheap flash model → first text part. */
async function geminiText(parts: unknown[], wantJson: boolean): Promise<string> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${TEXT_MODEL}:generateContent`;
  const payload = {
    contents: [{ role: "user", parts }],
    generationConfig: {
      temperature: 0.4,
      ...(wantJson ? { responseMimeType: "application/json" } : {}),
    },
  };
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-goog-api-key": GEMINI_KEY! },
    body: JSON.stringify(payload),
  });
  const data = await res.json().catch(() => ({} as Record<string, unknown>));
  if (!res.ok) {
    throw new HttpError(502, `Gemini ${res.status}: ${JSON.stringify(data).slice(0, 300)}`);
  }
  // deno-lint-ignore no-explicit-any
  for (const cand of ((data as any).candidates ?? [])) {
    for (const part of ((cand.content?.parts) ?? [])) {
      if (typeof part.text === "string" && part.text.trim()) return part.text as string;
    }
  }
  throw new HttpError(502, `Gemini returned no text. ${JSON.stringify(data).slice(0, 200)}`);
}

/** Defensive JSON parse: strip code fences, else grab the first {...} block. */
function parseJsonLoose(raw: string): unknown {
  const cleaned = raw.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  try {
    return JSON.parse(cleaned);
  } catch {
    const start = cleaned.indexOf("{");
    const end = cleaned.lastIndexOf("}");
    if (start >= 0 && end > start) {
      try {
        return JSON.parse(cleaned.slice(start, end + 1));
      } catch {
        return null;
      }
    }
    return null;
  }
}
