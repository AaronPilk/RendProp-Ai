import type { Listing } from "../../data/contracts";

export type Edit =
  | "twilight"
  | "sky"
  | "lawn"
  | "declutter"
  | "stage"
  | "custom";
export const PRESETS: { id: Edit; name: string; hint: string }[] = [
  {
    id: "twilight",
    name: "Day to dusk",
    hint: "Warm evening light for an exterior.",
  },
  {
    id: "sky",
    name: "Sky replacement",
    hint: "Improve the sky and preserve the property.",
  },
  {
    id: "lawn",
    name: "Lawn refresh",
    hint: "Refresh the visible grass and landscaping.",
  },
  {
    id: "declutter",
    name: "Declutter",
    hint: "Remove movable clutter and personal items.",
  },
  {
    id: "stage",
    name: "Virtual staging",
    hint: "Furnish a room with its structure preserved.",
  },
  { id: "custom", name: "Custom edit", hint: "Describe the change you want." },
];
export type Shot = {
  photoId: string;
  order: number;
  room: string;
  motion: string;
  seconds: number;
  caption: string;
  voiceLine: string;
};
export type ShotPlanHandoff = {
  listingId: string;
  shots: Shot[];
  script: string;
  narrationResultId: string | null;
};
export type Cutaway = {
  photoId: string;
  start: number;
  end: number;
  caption: string;
  motion: string;
};
export type AgentPlanHandoff = {
  listingId: string;
  assetId: string;
  cutaways: Cutaway[];
  script?: string;
};
export type Chapter = {
  start_s: number;
  label: string;
  room_type: string;
  sort: number;
};
export type CreativeDraft = {
  schema: 1;
  script: string;
  shots: Shot[];
  cutaways: Cutaway[];
  agentAssetId: string | null;
  agentDuration: number | null;
  agentTranscript: string;
  chapters: Chapter[];
  chapterAssetId: string | null;
  updatedAt: string;
};
export const EMPTY_DRAFT: CreativeDraft = {
  schema: 1,
  script: "",
  shots: [],
  cutaways: [],
  agentAssetId: null,
  agentDuration: null,
  agentTranscript: "",
  chapters: [],
  chapterAssetId: null,
  updatedAt: "",
};
export function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(
      "The creative service returned an unreadable result. Please retry.",
    );
  }
  return value as Record<string, unknown>;
}
export function text(value: unknown, max = 4000): string {
  return typeof value === "string" ? value.trim().slice(0, max) : "";
}
export function number(value: unknown, fallback = 0): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}
export function rows(value: unknown, max = 200): unknown[] {
  return Array.isArray(value) ? value.slice(0, max) : [];
}
export function requiredText(
  value: unknown,
  label: string,
  max = 4000,
): string {
  const result = text(value, max);
  if (!result) throw new Error(`The creative service did not return ${label}.`);
  return result;
}
export function listingFacts(listing: Listing): Record<string, unknown> {
  const facts: Record<string, unknown> = {};
  for (const field of ["beds", "baths", "sqft"] as const) {
    if (listing[field] && listing[field]! > 0) facts[field] = listing[field];
  }
  if (listing.priceCents && listing.priceCents > 0) {
    facts.price_label = new Intl.NumberFormat("en-US", {
      style: "currency",
      currency: "USD",
      maximumFractionDigits: 0,
    }).format(listing.priceCents / 100);
  }
  if (listing.tagline) facts.tagline = listing.tagline.slice(0, 200);
  // Freeform details can include a full street address, owner information or access codes.
  // Copy assist gets explicitly selected property facts only, as the native contract requires.
  const allowed = [
    "property_type",
    "parking",
    "lot_size",
    "year_built",
    "features",
    "amenities",
    "style",
    "stories",
    "outdoor_space",
    "renovations",
    "capacity",
    "square_feet",
  ];
  const details: Record<string, string> = {};
  for (const key of allowed) {
    const value = listing.details[key];
    if (typeof value === "string" || typeof value === "number") {
      details[key] = String(value).slice(0, 80);
    }
  }
  if (Object.keys(details).length) facts.details = details;
  return facts;
}
export function decodeShots(
  value: unknown,
  photoIds: readonly string[],
): Shot[] {
  const allowed = new Set(photoIds), seen = new Set<string>();
  return rows(value, 20).flatMap((raw, index) => {
    const r = record(raw),
      id = text(r.photo_id, 80),
      duration = number(r.seconds, 5);
    if (!allowed.has(id) || seen.has(id) || duration < 2 || duration > 12) {
      return [];
    }
    seen.add(id);
    return [{
      photoId: id,
      order: number(r.order, index + 1),
      room: text(r.room, 40),
      motion: text(r.motion, 100),
      seconds: duration,
      caption: text(r.on_screen_text, 60),
      voiceLine: text(r.voice_line, 300),
    }];
  }).sort((a, b) => a.order - b.order);
}
export function decodeCutaways(
  value: unknown,
  photoIds: readonly string[],
  duration: number,
): Cutaway[] {
  const allowed = new Set(photoIds);
  let previousEnd = 0;
  return rows(value, 12).flatMap((raw) => {
    const r = record(raw),
      start = number(r.start, -1),
      end = number(r.end, -1),
      photoId = text(r.photo_id, 80);
    if (
      !allowed.has(photoId) || start < 2 || end > duration - 1.5 ||
      end <= start || start < previousEnd
    ) return [];
    previousEnd = end;
    return [{
      photoId,
      start,
      end,
      caption: text(r.on_screen_text, 60),
      motion: text(r.motion, 80),
    }];
  });
}
export function parseTranscript(
  input: string,
  duration: number,
): { t: number; text: string }[] {
  const out: { t: number; text: string }[] = [];
  let last = -1;
  for (const line of input.split(/\r?\n/).filter((line) => line.trim())) {
    const match = /^\s*(?:(\d{1,2}):)?(\d{1,3}(?:\.\d{1,3})?)\s+(.+)$/.exec(
      line,
    );
    if (!match) {
      throw new Error(
        "Start each transcript line with its time, for example: 0:04 This kitchen opens onto the patio.",
      );
    }
    const t = Number(match[1] ?? 0) * 60 + Number(match[2]);
    if (t <= last || t < 0 || t >= duration || out.length >= 200) {
      throw new Error(
        "Transcript times must increase and stay inside the selected clip.",
      );
    }
    if (match[3].trim().length > 200) {
      throw new Error("Keep each transcript phrase under 200 characters.");
    }
    out.push({ t, text: match[3].trim() });
    last = t;
  }
  if (out.length < 3) {
    throw new Error(
      "Add at least three timed phrases so the edit can follow your actual words.",
    );
  }
  return out;
}
export function decodeChapters(value: unknown): Chapter[] {
  return rows(value, 24).flatMap((raw) => {
    const r = record(raw), seconds = number(r.start_s, -1);
    if (seconds < 0) return [];
    return [{
      start_s: seconds,
      label: text(r.label, 80) || "Room",
      room_type: text(r.room_type, 40) || "other",
      sort: 0,
    }];
  }).sort((a, b) => a.start_s - b.start_s).map((chapter, index) => ({
    ...chapter,
    sort: index,
  }));
}
export function decodeDraft(value: unknown): CreativeDraft {
  const r = record(value);
  if (r.schema !== 1) {
    throw new Error("This creative draft needs a newer version of Studio.");
  }
  const shots = rows(r.shots, 20).map((raw) => {
    const s = record(raw);
    return {
      photoId: text(s.photoId, 80),
      order: number(s.order),
      room: text(s.room, 40),
      motion: text(s.motion, 100),
      seconds: number(s.seconds, 5),
      caption: text(s.caption, 60),
      voiceLine: text(s.voiceLine, 300),
    };
  });
  const cutaways = rows(r.cutaways, 12).map((raw) => {
    const s = record(raw);
    return {
      photoId: text(s.photoId, 80),
      start: number(s.start),
      end: number(s.end),
      caption: text(s.caption, 60),
      motion: text(s.motion, 80),
    };
  });
  return {
    schema: 1,
    script: text(r.script, 4000),
    shots,
    cutaways,
    agentAssetId: text(r.agentAssetId, 80) || null,
    agentDuration:
      typeof r.agentDuration === "number" && Number.isFinite(r.agentDuration) &&
        r.agentDuration >= 6 && r.agentDuration <= 180
        ? r.agentDuration
        : null,
    agentTranscript: text(r.agentTranscript, 20000),
    chapters: decodeChapters(r.chapters),
    chapterAssetId: text(r.chapterAssetId, 80) || null,
    updatedAt: text(r.updatedAt, 80),
  };
}
export type CreativeResult = {
  id: string;
  kind: "voice" | "video";
  state: string;
  url: string | null;
  expiresAt: string | null;
  assetId: string | null;
  sourceAssetId: string | null;
  sourceUrl: string | null;
  provenanceId: string | null;
  requestId: string | null;
  label: string;
  disclosure: string;
  videoKind: string | null;
  duration: number | null;
  voiceName: string | null;
  words: { text: string; start: number; end: number }[];
  message: string | null;
  qcRequired: boolean;
  qcPublishable: boolean;
  qcMessage: string | null;
};
function mediaLink(value: unknown): string | null {
  if (!value) return null;
  const parsed = new URL(requiredText(value, "a media link", 8192));
  if (
    parsed.protocol !== "https:" ||
    !/^[a-f0-9]{32}\.r2\.cloudflarestorage\.com$/.test(parsed.hostname) ||
    parsed.username || parsed.password || parsed.port || parsed.hash
  ) throw new Error("The creative result has an invalid media link.");
  return parsed.href;
}
export function decodeResult(value: unknown): CreativeResult {
  const r = record(value), id = requiredText(r.id, "a result identifier", 80);
  if (
    !/^[a-f0-9-]{36}$/i.test(id) || !["voice", "video"].includes(String(r.kind))
  ) throw new Error("The creative service returned an invalid result.");
  const url = mediaLink(r.url);
  return {
    id,
    kind: r.kind as "voice" | "video",
    state: text(r.state, 40),
    url,
    expiresAt: text(r.expires_at, 80) || null,
    assetId: text(r.asset_id, 80) || null,
    sourceAssetId: text(r.source_asset_id, 80) || null,
    sourceUrl: mediaLink(r.source_url),
    provenanceId: text(r.provenance_id, 80) || null,
    requestId: text(r.request_id, 500) || null,
    label: text(r.label, 80),
    disclosure: text(r.disclosure, 1000),
    videoKind: text(r.video_kind, 40) || null,
    duration: number(r.duration_s) || null,
    voiceName: text(r.voice_name, 100) || null,
    words: rows(r.words, 1500).flatMap((raw) => {
      const w = record(raw),
        start = number(w.start, -1),
        end = number(w.end, -1),
        word = text(w.text, 200);
      return word && start >= 0 && end >= start
        ? [{ text: word, start, end }]
        : [];
    }),
    message: text(r.message, 600) || null,
    qcRequired: r.qc_required === true,
    qcPublishable: r.qc_publishable === true,
    qcMessage: text(r.qc_message, 1000) || null,
  };
}
export function subtitleFile(words: CreativeResult["words"]): string {
  function stamp(seconds: number) {
    const ms = Math.round(seconds * 1000);
    return `${String(Math.floor(ms / 3600000)).padStart(2, "0")}:${
      String(Math.floor(ms / 60000) % 60).padStart(2, "0")
    }:${String(Math.floor(ms / 1000) % 60).padStart(2, "0")},${
      String(ms % 1000).padStart(3, "0")
    }`;
  }
  const groups: CreativeResult["words"][] = [];
  for (let i = 0; i < words.length; i += 7) groups.push(words.slice(i, i + 7));
  return groups.map((group, index) =>
    `${index + 1}\n${stamp(group[0]!.start)} --> ${
      stamp(group[group.length - 1]!.end)
    }\n${group.map((w) => w.text).join(" ").replace(/[\r\n]/g, " ")}\n`
  ).join("\n");
}
