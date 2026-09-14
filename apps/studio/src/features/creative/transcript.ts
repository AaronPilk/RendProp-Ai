import { parseTranscript } from "./model";

export const TRANSCRIPT_FILE_BYTES = 256 * 1024;
function timestamp(raw: string): number {
  const match = /^(?:(\d{1,2}):)?([0-5]\d):([0-5]\d)[.,](\d{3})$/.exec(raw);
  if (!match) {
    throw new Error(
      "Each subtitle needs a valid time such as 00:00:04,250 or 00:04.250.",
    );
  }
  return Number(match[1] ?? 0) * 3600 + Number(match[2]) * 60 +
    Number(match[3]) + Number(match[4]) / 1000;
}
function words(raw: string): string {
  return raw.replace(/<[^>]*>/g, "").replace(
    /&(?:amp|lt|gt|quot|apos|nbsp|#39);/g,
    (entity) =>
      ({
        "&amp;": "&",
        "&lt;": "<",
        "&gt;": ">",
        "&quot;": '"',
        "&apos;": "'",
        "&#39;": "'",
        "&nbsp;": " ",
      })[entity] ?? entity,
  )
    .replace(/\s+/g, " ").trim();
}
function formatTime(seconds: number): string {
  const millis = Math.round(seconds * 1000),
    minutes = Math.floor(millis / 60000),
    rest = millis % 60000;
  const fraction = String(rest % 1000).padStart(3, "0").replace(/0+$/, "");
  return `${minutes}:${String(Math.floor(rest / 1000)).padStart(2, "0")}${
    fraction ? `.${fraction}` : ""
  }`;
}
/** Import genuine subtitle cue times. No speech boundaries or missing times are inferred. */
export function importSubtitleTranscript(
  input: string,
  format: "srt" | "vtt",
  duration: number,
): string {
  if (
    typeof input !== "string" || input.length > TRANSCRIPT_FILE_BYTES ||
    !Number.isFinite(duration) || duration < 6 || duration > 180
  ) {
    throw new Error(
      "Choose a 6–180 second video and a subtitle file smaller than 256 KiB.",
    );
  }
  let text = input.replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n").trim();
  if (format === "vtt") {
    if (!/^WEBVTT(?:[ \t].*)?(?:\n|$)/.test(text)) {
      throw new Error("This .vtt file is missing its WEBVTT header.");
    }
    text = text.replace(/^WEBVTT[^\n]*(?:\n|$)/, "").trimStart();
  }
  const phrases: { start: number; end: number; text: string }[] = [];
  for (
    const block of text.split(/\n[ \t]*\n/).filter((block) => block.trim())
  ) {
    if (
      format === "vtt" &&
      /^(?:NOTE(?:[ \t]|\n|$)|STYLE(?:\n|$)|REGION(?:\n|$))/.test(block)
    ) continue;
    const lines = block.split("\n"),
      index = lines.findIndex((line) => line.includes("-->"));
    if (index < 0 || index > 1 || index === lines.length - 1) {
      throw new Error(
        "Every subtitle must include its start/end times and spoken text.",
      );
    }
    const timing = /^\s*(\S+)\s+-->\s+(\S+)(?:[ \t]+[^\n]*)?\s*$/.exec(
      lines[index],
    );
    if (!timing) throw new Error("A subtitle has an unreadable time range.");
    const start = timestamp(timing[1]),
      end = timestamp(timing[2]),
      spoken = words(lines.slice(index + 1).join(" "));
    if (
      start < 0 || end <= start || end > duration + .001 || start >= duration ||
      phrases.length && start < phrases[phrases.length - 1].end
    ) {
      throw new Error(
        "Subtitle times must be ordered, must not overlap, and must stay inside the selected video.",
      );
    }
    if (!spoken || spoken.length > 200) {
      throw new Error(
        "Use subtitle phrases between 1 and 200 characters long.",
      );
    }
    if (phrases.length >= 200) {
      throw new Error(
        "Import at most 200 timed subtitle phrases.",
      );
    }
    phrases.push({ start, end, text: spoken });
  }
  const result = phrases.map((phrase) =>
    `${formatTime(phrase.start)} ${phrase.text}`
  ).join("\n");
  if (result.length > 20000) {
    throw new Error(
      "The imported transcript is too long. Use a shorter clip or fewer subtitle phrases.",
    );
  }
  parseTranscript(result, duration);
  return result;
}
