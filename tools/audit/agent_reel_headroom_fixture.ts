// Offline measurement input, not a new route, model request, or token budget.
// Import the production planner/parser: counting an invented full HTTP EDL as
// model output would charge it for timestamps and motion the server adds free.
import {
  agentReelInstruction,
  buildAgentReelTurn,
  cleanTranscript,
  MAX_CLIP_SECONDS,
  MAX_PHRASE_CHARS,
  MAX_TRANSCRIPT_PHRASES,
  MAX_WINDOWS,
  parseAgentReel,
  planWindows,
  t1,
} from "../../services/supabase/functions/ai-copy/agentreel.ts";
import {
  captionFrom,
  cleanPhotos,
  MAX_OVERLAY_CHARS,
  MAX_PHOTO_ID_CHARS,
  MAX_SHOTS,
} from "../../services/supabase/functions/ai-copy/shotlist.ts";

let assertions = 0;
function check(ok: unknown, message: string): asserts ok {
  assertions++;
  if (!ok) throw new Error(message);
}
check(MAX_CLIP_SECONDS === 180 && MAX_TRANSCRIPT_PHRASES === 200 && MAX_WINDOWS === 12,
  "measurement must track the actual 180s/200phrases/12windows contract");
check(MAX_PHRASE_CHARS === 200 && MAX_SHOTS === 20 && MAX_PHOTO_ID_CHARS === 64 && MAX_OVERLAY_CHARS === 28,
  "input/output string caps changed; explicitly revisit this measurement");

const phraseText = "The room has an open layout with a counter, a doorway, a window, and a clear path through the room. ".repeat(3).slice(0, MAX_PHRASE_CHARS - 1) + ".";
const phrases = cleanTranscript(Array.from({ length: MAX_TRANSCRIPT_PHRASES }, (_, i) => ({
  t: i * 0.9, text: phraseText,
})), MAX_CLIP_SECONDS);
check(phrases.length === 200 && phrases.every((p) => p.text.length === 200), "all 200 maximum-length phrases must survive actual cleaning");

function randomAscii(seed: number, length: number): string {
  let state = seed;
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  let out = "";
  while (out.length < length) {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    out += alphabet[state % alphabet.length];
  }
  return out;
}

type Fixture = {
  name: string;
  kind: string;
  model_response: string;
  enriched_http_response: string;
  provider_input_text: string;
  retained_captions: string[];
  windows: number;
  filled: number;
  photo_id_code_units: number[];
};
const fixtures: Fixture[] = [];

function specimen(name: string, id: (i: number) => string, caption: string, kind = "canonical_stress") {
  const photos = cleanPhotos(Array.from({ length: MAX_SHOTS }, (_, i) => ({
    id: id(i), room: "Living room", caption_hint: "A clear view of the room and its finishes.",
  })));
  check(photos.length === MAX_SHOTS, `${name}: all 20 distinct offered photos survive cleaning`);
  const windows = planWindows(phrases, MAX_CLIP_SECONDS, photos.length);
  check(windows.length === MAX_WINDOWS, `${name}: actual planner reaches all 12 windows`);
  check(captionFrom(caption) === caption, `${name}: caption must already obey the production clamp`);
  const modelObject = { windows: windows.map((w, i) => ({ window_id: w.window_id, photo_id: photos[i].id, on_screen_text: caption })) };
  const request = { space: "real_estate" as const, tone: "punchy" as const, subject: "listing" as const, facts: {}, photos, windows, clipSeconds: MAX_CLIP_SECONDS };
  const input = `${agentReelInstruction(request)}\n\n---\n\n${buildAgentReelTurn(request)}`;
  function append(fixtureName: string, raw: string, expectedFilled = MAX_WINDOWS, fixtureKind = kind) {
    const answer = parseAgentReel(raw, windows, photos);
    check(answer !== null, `${fixtureName}: real parser must accept this specimen`);
    check(answer.cutaways.length === 12, `${fixtureName}: HTTP retains all 12 deterministic windows`);
    check(answer.cutaways.filter((c) => c.photo_id).length === expectedFilled, `${fixtureName}: assignments must survive, not silently fall back`);
    if (expectedFilled === MAX_WINDOWS) check(answer.cutaways.every((c) => c.on_screen_text === caption), `${fixtureName}: every bounded caption must survive intact`);
    const http = JSON.stringify({ subject: "listing", clip_seconds: t1(MAX_CLIP_SECONDS), cutaways: answer.cutaways,
      covered_seconds: answer.covered_seconds, face_seconds: t1(MAX_CLIP_SECONDS - answer.covered_seconds), model: "gpt-6-astra" });
    const fixture: Fixture = { name: fixtureName, kind: fixtureKind, model_response: raw, enriched_http_response: http,
      provider_input_text: input, retained_captions: answer.cutaways.map((c) => c.on_screen_text), windows: windows.length,
      filled: expectedFilled, photo_id_code_units: photos.map((p) => p.id.length) };
    fixtures.push(fixture);
    return fixture;
  }
  const fixture = append(name, JSON.stringify(modelObject));
  return { append, fixture, modelObject, windows, photos };
}

const short = specimen("short_ids_empty_captions_12", (i) => String(i), "", "canonical_small");
short.append("single_assignment_accepted_for_12_windows", JSON.stringify({ windows: [{ window_id: "w1", photo_id: "0" }] }), 1, "accepted_sparse");
specimen("uuid_ids_28_ascii_caption_12", (i) => `01234567-89ab-4def-8123-${String(i).padStart(12, "0")}`, "COVERED PATIO · GARDEN VIEWS", "canonical_typical_ids");
specimen("ascii_64_ids_28_ascii_caption_12", (i) => randomAscii(i + 1, MAX_PHOTO_ID_CHARS), "QZJXVKQZJXVKQZJXVKQZJXVKQZJX");
// These are legal input IDs/captions, not normal English real-estate copy.
// A US-only UI does not turn its permissive Unicode wire format into ASCII.
const unicode = specimen("bmp_64_ids_28_bmp_caption_12", (i) => "Ⱟ".repeat(62) + String(i).padStart(2, "0"), "Ⱟ".repeat(MAX_OVERLAY_CHARS));
specimen("escaped_64_ids_28_ascii_caption_12", (i) => '"'.repeat(62) + String(i).padStart(2, "0"), "QZJXVKQZJXVKQZJXVKQZJXVKQZJX");
// JSON.stringify uses six ASCII bytes for each of these non-whitespace C0
// characters. Twenty distinct IDs still pass cleanPhotos. This reaches the
// exact canonical BYTE bound, not necessarily the largest BPE token count.
const controls = Array.from({ length: 32 }, (_, i) => String.fromCharCode(i)).filter((s) => !/\s/.test(s) && s !== "\b");
const largestBytes = specimen("control_64_ids_28_bmp_caption_12", (i) => "\u0000".repeat(63) + controls[i], "Ⱟ".repeat(MAX_OVERLAY_CHARS));
const canonicalByteBound = 14 + 11 + 12 * (50 + 64 * 6 + 28 * 3) + 9 * 2 + 3 * 3;
check(canonicalByteBound === 6268, "canonical model schema byte arithmetic changed");
check(new TextEncoder().encode(largestBytes.fixture.model_response).length === canonicalByteBound,
  "legal production-cleaned fixture must actually reach the canonical byte bound");

const canonical = unicode.fixture.model_response;
for (const repetitions of [100, 1000, 10000]) {
  const padded = unicode.append(`same_edl_${repetitions}_whitespace_pairs`, " \n".repeat(repetitions) + canonical,
    MAX_WINDOWS, "raw_shape_has_no_whitespace_bound");
  check(padded.enriched_http_response === unicode.fixture.enriched_http_response, "raw whitespace must change tokens without changing the actual EDL");
}
const ignored = unicode.append("same_edl_ignored_10000_char_field", JSON.stringify({ ...unicode.modelObject, ignored: "QZ".repeat(5000) }),
  MAX_WINDOWS, "raw_shape_has_no_unknown_field_bound");
check(ignored.enriched_http_response === unicode.fixture.enriched_http_response, "unknown raw field must be ignored by the actual parser");

// Proposed alternative only: select photo/caption catalog indexes instead of
// echoing arbitrary asset IDs or authoring strings. Production does NOT parse
// this shape today. Its canonical UTF-8 bytes are a conservative BPE bound;
// arbitrary raw whitespace and hidden reasoning are still separate concerns.
const compactProposal = JSON.stringify(Object.fromEntries(Array.from({ length: MAX_WINDOWS }, (_, i) => [`w${i + 1}`, [20, 99]])));
check(new TextEncoder().encode(compactProposal).length === 160, "proposal must retain window IDs with an exact160-byte canonical upper bound");
check(fixtures.length === 11, "every explicit measurement case must execute");
console.log(JSON.stringify({
  schema_version: 1,
  runtime: { deno: Deno.version.deno, v8: Deno.version.v8 },
  assertions,
  caps: { clip_seconds: MAX_CLIP_SECONDS, transcript_phrases: phrases.length, phrase_chars: MAX_PHRASE_CHARS,
    offered_photos: MAX_SHOTS, windows: MAX_WINDOWS, photo_id_code_units: MAX_PHOTO_ID_CHARS, caption_code_units: MAX_OVERLAY_CHARS },
  canonical_model_byte_bound: canonicalByteBound,
  compact_proposal: { status: "NOT_IMPLEMENTED", photo_indexes: "0..20 (0=face)", caption_indexes: "0..99 (0=empty)", canonical: compactProposal },
  fixtures,
}));
