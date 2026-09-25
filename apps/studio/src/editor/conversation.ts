import { EDIT_LIMITS, clipDuration, timelineDuration, validateDraft, type EditClip, type EditDraft, type Ratio, type Transition } from "./model";

export type ConversationOperation =
  | { type: "duration"; seconds: number }
  | { type: "pace"; value: "faster" | "slower" }
  | { type: "reorder"; clipIds: string[] }
  | { type: "caption"; clipId: string; text: string }
  | { type: "title"; text: string }
  | { type: "transition"; value: Transition }
  | { type: "photo-motion"; value: NonNullable<EditClip["motion"]> }
  | { type: "ratio"; value: Ratio }
  | { type: "audio"; value: EditDraft["audio"] }
  | { type: "music-volume"; value: number }
  | { type: "music-ducking"; value: "speech" | "original" | "none" }
  | { type: "music-fades"; seconds: number }
  | { type: "highlight"; targetSeconds?: number };
export type ConversationPlan = { draftId: string; expectedRevision: number; operations: ConversationOperation[] };
export type ConversationResult = { draft: EditDraft; summary: string };
export type LocalEditInterpretation =
  | { kind: "plan"; plan: ConversationPlan }
  | { kind: "clarification"; message: string }
  | { kind: "unsupported"; message: string };
export const CONVERSATION_LIMITS = { operations: 12, messageCharacters: 2000 } as const;

function record(value: unknown, allowed: string[], label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      ![Object.prototype, null].includes(Object.getPrototypeOf(value)) ||
      Object.keys(value).some(key => !allowed.includes(key))) throw new Error(`Unsupported ${label}.`);
  return value as Record<string, unknown>;
}
function choice<T extends string>(value: unknown, values: readonly T[], label: string): T {
  if (typeof value !== "string" || !values.includes(value as T)) throw new Error(`Choose a supported ${label}.`);
  return value as T;
}
function text(value: unknown, maximum: number, label: string): string {
  if (typeof value !== "string" || value.length > maximum || value.split("\n").length > 4 || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(value))
    throw new Error(`${label} must fit within ${maximum} characters and four lines.`);
  return value;
}
function requireClips(draft: EditDraft): void {
  if (!draft.clips.length) throw new Error("Add photos or video before making this edit.");
}
function requireUntimed(draft: EditDraft): void {
  if (draft.narration || draft.overlays?.length) throw new Error("This edit has timed narration or cutaways. Adjust its timing in the timeline so the picture stays matched to the speech.");
}
function seconds(value: unknown): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < .5 || value > EDIT_LIMITS.timelineSeconds)
    throw new Error("Choose a duration between 0.5 and 180 seconds.");
  return value;
}
const rounded = (value: number) => Number(value.toFixed(2));

/** Allocate within existing video spans. Photos may hold longer; no source is repeated,
 * inferred, dropped or accelerated. Saturated shots release their share to the rest. */
function withDuration(draft: EditDraft, target: number): EditDraft {
  requireClips(draft); requireUntimed(draft); seconds(target);
  const bounds = draft.clips.map(clip => ({
    minimum: EDIT_LIMITS.minClipSeconds / (clip.source.kind === "video" ? clip.speed ?? 1 : 1),
    maximum: clip.source.kind === "image" ? EDIT_LIMITS.photoSeconds : clipDuration(clip),
    weight: clipDuration(clip),
  }));
  const minimum = bounds.reduce((sum, item) => sum + item.minimum, 0), maximum = bounds.reduce((sum, item) => sum + item.maximum, 0);
  if (target < minimum - 1e-8 || target > maximum + 1e-8)
    throw new Error(`These shots support ${rounded(minimum)}–${rounded(Math.min(maximum, EDIT_LIMITS.timelineSeconds))} seconds without dropping shots or extending video. Add footage or choose a duration in that range.`);
  // Monotone bounded proportional allocation; binary search avoids a clamp order bias.
  let low = 0, high = Math.max(...bounds.map(item => item.maximum / item.weight));
  for (let step = 0; step < 80; step++) {
    const scale = (low + high) / 2;
    const total = bounds.reduce((sum, item) => sum + Math.max(item.minimum, Math.min(item.maximum, item.weight * scale)), 0);
    if (total < target) low = scale; else high = scale;
  }
  const durations = bounds.map(item => Math.max(item.minimum, Math.min(item.maximum, item.weight * high)));
  return validateDraft({ ...draft, clips: draft.clips.map((clip, index) => ({ ...clip,
    end: clip.source.kind === "image" ? durations[index] : Math.max(clip.start + EDIT_LIMITS.minClipSeconds,
      Math.min(clip.end, clip.start + durations[index] * (clip.speed ?? 1))),
  })) });
}

/** Returns a detached, validated snapshot at the SAME revision. The editor applies
 * it through editHistory once, giving the whole message one undoable new revision. */
export function applyConversationPlan(input: EditDraft, value: unknown): ConversationResult {
  let draft = validateDraft(input);
  const plan = record(value, ["draftId", "expectedRevision", "operations"], "edit plan");
  if (plan.draftId !== draft.id || plan.expectedRevision !== draft.revision)
    throw new Error("The edit changed. Ask again using the current preview.");
  if (!Array.isArray(plan.operations) || !plan.operations.length || plan.operations.length > CONVERSATION_LIMITS.operations)
    throw new Error("Use between 1 and 12 edits in one message.");
  const summaries: string[] = [];
  for (const raw of plan.operations) {
    const header = record(raw, ["type", "seconds", "value", "clipIds", "clipId", "text", "targetSeconds"], "edit operation");
    switch (header.type) {
      case "duration": case "pace": {
        const isDuration = header.type === "duration";
        const operation = record(raw, isDuration ? ["type", "seconds"] : ["type", "value"], "timing edit");
        const target = isDuration ? seconds(operation.seconds) : seconds(timelineDuration(draft.clips) * (choice(operation.value, ["faster", "slower"], "pace") === "faster" ? .8 : 1.25));
        const before = draft;
        draft = withDuration(draft, target);
        const trimmed = draft.clips.some((clip, index) => clip.source.kind === "video" && clip.end < before.clips[index].end - 1e-8);
        summaries.push(`The reel is ${rounded(timelineDuration(draft.clips))} seconds. Playback speed is unchanged.${trimmed ? " Video endings were shortened; check the speech before sharing." : ""}`);
        break;
      }
      case "reorder": {
        const operation = record(raw, ["type", "clipIds"], "shot order");
        requireClips(draft); requireUntimed(draft);
        if (!Array.isArray(operation.clipIds) || operation.clipIds.length !== draft.clips.length ||
            new Set(operation.clipIds).size !== draft.clips.length || operation.clipIds.some(id => typeof id !== "string" || !draft.clips.some(clip => clip.id === id)))
          throw new Error("The shot order must contain every current clip exactly once.");
        draft = validateDraft({ ...draft, clips: operation.clipIds.map(id => draft.clips.find(clip => clip.id === id)!) });
        summaries.push("Reordered the existing shots. Every source and selected trim is retained.");
        break;
      }
      case "caption": {
        const operation = record(raw, ["type", "clipId", "text"], "caption edit");
        if (!draft.clips.some(clip => clip.id === operation.clipId)) throw new Error("Choose a current clip for this caption.");
        const caption = text(operation.text, EDIT_LIMITS.captionCharacters, "The caption");
        draft = validateDraft({ ...draft, clips: draft.clips.map(clip => clip.id === operation.clipId ? { ...clip, caption } : clip) });
        summaries.push(caption ? "Added your exact text to the selected clip." : "Cleared the selected clip’s caption.");
        break;
      }
      case "title": {
        const operation = record(raw, ["type", "text"], "title edit");
        draft = validateDraft({ ...draft, title: text(operation.text, 80, "The title") });
        summaries.push(draft.title ? "Updated the title with your exact text." : "Cleared the title."); break;
      }
      case "transition": {
        const operation = record(raw, ["type", "value"], "transition edit"); requireClips(draft);
        const transition = choice(operation.value, ["cut", "dissolve", "whip"] as const, "transition");
        draft = validateDraft({ ...draft, clips: draft.clips.map((clip, index) => ({ ...clip, transition: index ? transition : "cut" })) });
        summaries.push(`Set ${transition === "cut" ? "hard cuts" : `${transition} transitions`} between the shots.`); break;
      }
      case "photo-motion": {
        const operation = record(raw, ["type", "value"], "photo motion");
        const motion = choice(operation.value, ["still", "push_in", "pull_out", "pan_left", "pan_right"] as const, "photo motion");
        if (!draft.clips.some(clip => clip.source.kind === "image")) throw new Error("Add a photo to the main sequence before changing photo motion.");
        draft = validateDraft({ ...draft, clips: draft.clips.map(clip => clip.source.kind === "image" ? { ...clip, motion } : clip) });
        summaries.push(`Set photo motion to ${motion.replaceAll("_", " ")}. Video footage is unchanged.`); break;
      }
      case "ratio": {
        const operation = record(raw, ["type", "value"], "aspect ratio");
        draft = validateDraft({ ...draft, ratio: choice(operation.value, ["9:16", "16:9", "1:1"] as const, "aspect ratio") });
        summaries.push(`Changed the frame to ${draft.ratio}. Check the framing in the preview.`); break;
      }
      case "audio": {
        const operation = record(raw, ["type", "value"], "audio edit");
        draft = validateDraft({ ...draft, audio: choice(operation.value, ["original", "muted"] as const, "audio mode") });
        summaries.push(`${draft.audio === "muted" ? "Muted the original clip audio." : "Kept the original clip audio."}${draft.narration ? " Your saved narration is unchanged." : ""}`); break;
      }
      case "music-volume": case "music-ducking": case "music-fades": {
        if (!draft.music) throw new Error("Add your licensed music in Sound & captions first.");
        const operation = record(raw, header.type === "music-fades" ? ["type", "seconds"] : ["type", "value"], "music edit");
        let music = {...draft.music};
        if (header.type === "music-volume") {
          if (typeof operation.value !== "number" || !Number.isFinite(operation.value) || operation.value < 0 || operation.value > 1) throw new Error("Choose music volume from 0 to 100 percent.");
          music.volume = operation.value; summaries.push(`Set music volume to ${rounded(music.volume * 100)} percent.`);
        } else if (header.type === "music-ducking") {
          music.ducking = choice(operation.value, ["speech", "original", "none"], "music ducking");
          summaries.push(music.ducking === "none" ? "Music keeps a steady level." : music.ducking === "speech" ? "Music lowers under reviewed speech and narration." : "Music lowers under original video sound and narration.");
        } else {
          if (typeof operation.seconds !== "number" || !Number.isFinite(operation.seconds) || operation.seconds < 0 || operation.seconds > Math.min(10, music.end - music.start)) throw new Error("Choose a music fade that fits this track, up to ten seconds.");
          music.fadeIn = operation.seconds; music.fadeOut = operation.seconds; summaries.push(`Music fades in and out over ${operation.seconds} seconds.`);
        }
        draft = validateDraft({...draft, music}); break;
      }
      case "highlight": {
        const operation = record(raw, ["type", "targetSeconds"], "highlight edit"); requireClips(draft);
        if (operation.targetSeconds !== undefined) draft = withDuration(draft, seconds(operation.targetSeconds));
        draft = validateDraft({ ...draft, clips: draft.clips.map((clip, index) => ({ ...clip, transition: index ? "dissolve" : "cut", ...(clip.source.kind === "image" ? { motion: "push_in" } : {}) })) });
        summaries.push(`Built a ${rounded(timelineDuration(draft.clips))}-second highlight using your current shot order, gentle photo motion and dissolves.${operation.targetSeconds !== undefined && draft.clips.some(clip => clip.source.kind === "video") ? " Review the video endings for complete speech." : ""}`);
        break;
      }
      default: throw new Error("This edit is not supported. Your current video is unchanged.");
    }
  }
  return { draft: validateDraft(draft), summary: summaries.join(" ") };
}

function commandList(message: string): string[] | null {
  const commands: string[] = []; let current = "", quote = "";
  for (const character of message) {
    if ((character === '"' || character === "“" || character === "”") && (!quote || character === quote || quote === "“" && character === "”")) quote = quote ? "" : character;
    if (character === ";" && !quote) { commands.push(current.trim()); current = ""; } else current += character;
  }
  commands.push(current.trim());
  return quote || commands.some(item => !item) || commands.length > CONVERSATION_LIMITS.operations ? null : commands;
}

/** A deliberately finite convenience parser. It does not inspect pixels, understand
 * speech, invoke a model or pretend unknown instructions have been performed. */
export function interpretLocalEdit(message: string, input: EditDraft): LocalEditInterpretation {
  if (typeof message !== "string" || !message.trim() || message.length > CONVERSATION_LIMITS.messageCharacters)
    return { kind: "clarification", message: "Describe one edit in up to 2,000 characters." };
  const starter = message.trim().match(/^(Make a \d+(?:\.\d+)?-second reel)\.\s*Use slow zooms and smooth transitions\.?$/i);
  const draft = validateDraft(input), commands = commandList(starter ? `${starter[1]}; Add slow zooms; Use smooth transitions` : message.trim());
  if (!commands) return { kind: "clarification", message: "Use up to 12 complete edits separated by semicolons, and close any quotation marks." };
  const operations: ConversationOperation[] = [];
  for (const raw of commands) {
    const command = raw.replace(/[.!]$/, "").replace(/^please\s+/i, "").trim();
    const latestOrder = [...operations].reverse().find(operation => operation.type === "reorder");
    const currentClips = latestOrder?.type === "reorder" ? latestOrder.clipIds.map(id => draft.clips.find(clip => clip.id === id)!) : draft.clips;
    let match: RegExpMatchArray | null;
    if ((match = command.match(/^(?:add|set)(?: the)? caption ["“]([\s\S]*)["”] (?:to|on|for) clip (\d+)$/i))) {
      const clip = currentClips[Number(match[2]) - 1];
      if (!clip) return { kind: "clarification", message: `Choose a clip number from 1 to ${draft.clips.length}.` };
      operations.push({ type: "caption", clipId: clip.id, text: match[1] }); continue;
    }
    if ((match = command.match(/^(?:set|change|make)(?: the)? title(?: to)? ["“]([\s\S]*)["”]$/i))) { operations.push({ type: "title", text: match[1] }); continue; }
    // Negated or qualified requests never turn into accidental positive operations.
    if (/\b(?:don['’]?t|do not|not|never|without|except|unless|instead|but)\b/i.test(command))
      return { kind: "clarification", message: "Tell me the change you want directly, such as “use hard cuts.” I haven’t changed the video." };
    if ((match = command.match(/^(?:make|create|build)(?: me)? (?:a )?(vertical|portrait|landscape|horizontal|square) (?:reel|video)$/i))) {
      operations.push({ type: "highlight" }, { type: "ratio", value: /^(vertical|portrait)$/i.test(match[1]) ? "9:16" : /^square$/i.test(match[1]) ? "1:1" : "16:9" }); continue;
    }
    if ((match = command.match(/^(?:make|create|build)(?: me)? (?:a |an )?(?:(\d+(?:\.\d+)?)\s*[- ]?(?:second|sec|s) )?(?:reel|(?:listing )?highlight|video)(?: from (?:these|my|the)(?: photos| clips| media| uploads)?)?$/i))) {
      operations.push({ type: "highlight", ...(match[1] ? { targetSeconds: Number(match[1]) } : {}) }); continue;
    }
    if ((match = command.match(/^(?:make|set)(?: it| the (?:reel|video))?(?: to)? (\d+(?:\.\d+)?)\s*(?:seconds?|secs?|s)(?: long)?$/i))) { operations.push({ type: "duration", seconds: Number(match[1]) }); continue; }
    if ((match = command.match(/^(?:make (?:it|the (?:reel|video)) |)(faster|shorter|slower|longer)$/i))) { operations.push({ type: "pace", value: ["faster", "shorter"].includes(match[1].toLowerCase()) ? "faster" : "slower" }); continue; }
    if ((match = command.match(/^(?:put|move) clip (\d+) (?:to (?:position )?(\d+)|first|last)$/i))) {
      const from = Number(match[1]) - 1, to = match[2] ? Number(match[2]) - 1 : /first$/i.test(command) ? 0 : draft.clips.length - 1;
      if (from < 0 || to < 0 || from >= draft.clips.length || to >= draft.clips.length) return { kind: "clarification", message: `Choose clip positions from 1 to ${draft.clips.length}.` };
      const clipIds = currentClips.map(clip => clip.id), [id] = clipIds.splice(from, 1); clipIds.splice(to, 0, id);
      operations.push({ type: "reorder", clipIds }); continue;
    }
    if ((match = command.match(/^(?:use|add|set)(?: the)? (hard cuts|cuts|dissolves?|dissolve transitions|smooth transitions|whip transitions)$/i))) { operations.push({ type: "transition", value: /^whip/i.test(match[1]) ? "whip" : /^(dissolve|smooth)/i.test(match[1]) ? "dissolve" : "cut" }); continue; }
    if ((match = command.match(/^(?:add|use|set) (slow zooms?|gentle zooms?|push[- ]ins?|pull[- ]outs?|pan left|pan right|still photos)$/i))) { operations.push({ type: "photo-motion", value: /^pull/i.test(match[1]) ? "pull_out" : /^pan left$/i.test(match[1]) ? "pan_left" : /^pan right$/i.test(match[1]) ? "pan_right" : /^still/i.test(match[1]) ? "still" : "push_in" }); continue; }
    if ((match = command.match(/^(?:make (?:it|the (?:reel|video))|use|set(?: the)? (?:ratio|format) to) (vertical|portrait|landscape|horizontal|square|9:16|16:9|1:1)$/i))) { operations.push({ type: "ratio", value: /^(vertical|portrait|9:16)$/i.test(match[1]) ? "9:16" : /^(landscape|horizontal|16:9)$/i.test(match[1]) ? "16:9" : "1:1" }); continue; }
    if ((match = command.match(/^(?:set|make)(?: the)? music volume(?: to)? (\d+(?:\.\d+)?)\s*(?:percent|%)$/i))) {operations.push({type: "music-volume", value: Number(match[1]) / 100}); continue;}
    if (/^(?:make (?:the )?music quieter|lower (?:the )?music)$/i.test(command)) {
      const previous = [...operations].reverse().find(operation => operation.type === "music-volume");
      operations.push({type: "music-volume", value: (previous?.type === "music-volume" ? previous.value : draft.music?.volume ?? .3) / 2}); continue;
    }
    if (/^(?:duck|lower)(?: the)? music (?:under|beneath) (?:speech|speaking)$/i.test(command)) {operations.push({type: "music-ducking", value: "speech"}); continue;}
    if (/^(?:duck|lower)(?: the)? music (?:under|beneath) original (?:audio|sound)$/i.test(command)) {operations.push({type: "music-ducking", value: "original"}); continue;}
    if (/^keep (?:the )?music (?:at a )?steady level$/i.test(command)) {operations.push({type: "music-ducking", value: "none"}); continue;}
    if ((match = command.match(/^fade (?:the )?music in and out(?: over (\d+(?:\.\d+)?) seconds?)?$/i))) {operations.push({type: "music-fades", seconds: match[1] ? Number(match[1]) : 1}); continue;}
    if (/^mute(?: it| the audio| audio| the original audio)?$/i.test(command)) { operations.push({ type: "audio", value: "muted" }); continue; }
    if (/^(?:keep|use|restore)(?: the)? original (?:audio|sound)$/i.test(command)) { operations.push({ type: "audio", value: "original" }); continue; }
    if (/\b(?:generate|avatar|clone|face|voice|music|song|kitchen|bedroom|bathroom|pool|drone|sky|staging|remove|transcrib|lip[ -]?sync|camera angle|best shot)\b/i.test(command))
      return { kind: "unsupported", message: "Use Sound & captions to add licensed music, review beat cuts or caption the selected video. New scenes and camera angles need a separate generation tool. Your video is unchanged." };
    return { kind: "unsupported", message: "I haven’t changed the video. Try “make it 15 seconds,” “put clip 3 first,” or “add caption \"Open house Saturday\" to clip 1.”" };
  }
  const plan: ConversationPlan = { draftId: draft.id, expectedRevision: draft.revision, operations };
  try { applyConversationPlan(draft, plan); return { kind: "plan", plan }; }
  catch (error) { return { kind: "clarification", message: error instanceof Error ? error.message : "Review the current video before applying this edit." }; }
}
