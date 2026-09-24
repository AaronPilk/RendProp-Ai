import { applyConversationPlan, CONVERSATION_LIMITS, interpretLocalEdit, type ConversationOperation } from "./conversation";
import { validateDraft, type EditDraft } from "./model";

export type PromptEnhancement = { original: string; enhanced: string; notes: string[]; method: "guided" | "ai" };
const CONTROL_CHARACTERS = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/;
function checkedText(value: unknown, limit: number, label: string): string {
  if (typeof value !== "string" || !value.trim() || value.length > limit || CONTROL_CHARACTERS.test(value))
    throw new Error(`${label} must contain 1–${limit} characters of readable text.`);
  return value;
}

/** Both local and server proposals are bound to the exact brief the user reviewed.
 * A proposal is plain text; decoding never changes an edit or dispatches a model. */
export function decodePromptEnhancement(value: unknown, original: string): PromptEnhancement {
  checkedText(original, CONVERSATION_LIMITS.messageCharacters, "Your prompt");
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      ![Object.prototype, null].includes(Object.getPrototypeOf(value)) ||
      Object.keys(value).some(key => !["original", "enhanced", "notes", "method"].includes(key)))
    throw new Error("The prompt suggestion could not be read.");
  const row = value as Record<string, unknown>;
  if (row.original !== original) throw new Error("Your prompt changed. Request a new suggestion for the current text.");
  const enhanced = checkedText(row.enhanced, CONVERSATION_LIMITS.messageCharacters, "The suggested prompt");
  if (row.method !== "guided" && row.method !== "ai") throw new Error("The prompt suggestion has an unsupported method.");
  if (!Array.isArray(row.notes) || row.notes.length > 4) throw new Error("The prompt suggestion has too many notes.");
  const notes = row.notes.map(note => checkedText(note, 300, "Each suggestion note"));
  return { original, enhanced, notes, method: row.method };
}

function commandsFor(operation: ConversationOperation, orderedIds: string[]): string[] {
  switch (operation.type) {
    case "duration": return [`Make it ${operation.seconds} seconds`];
    case "pace": return [operation.value === "faster" ? "Make it shorter" : "Make it longer"];
    case "caption": {
      const position = orderedIds.indexOf(operation.clipId);
      if (position < 0) throw new Error("The selected clip is no longer in this edit.");
      return [`Add caption "${operation.text}" to clip ${position + 1}`];
    }
    case "title": return [`Set the title to "${operation.text}"`];
    case "transition": return [operation.value === "cut" ? "Use hard cuts" : `Use ${operation.value} transitions`];
    case "photo-motion": return [{ still: "Use still photos", push_in: "Use push-ins", pull_out: "Use pull-outs", pan_left: "Use pan left", pan_right: "Use pan right" }[operation.value]];
    case "ratio": return [`Set the ratio to ${operation.value}`];
    case "audio": return [operation.value === "original" ? "Keep original audio" : "Mute the original audio"];
    case "highlight": return [operation.targetSeconds === undefined ? "Create a listing highlight" : `Make a ${operation.targetSeconds}-second reel`];
    case "reorder": {
      const commands: string[] = [];
      operation.clipIds.forEach((id, destination) => {
        const from = orderedIds.indexOf(id);
        if (from < 0) throw new Error("A requested clip is no longer in this edit.");
        if (from !== destination) {
          commands.push(`Move clip ${from + 1} to position ${destination + 1}`);
          orderedIds.splice(destination, 0, orderedIds.splice(from, 1)[0]);
        }
      });
      // Retain a harmless existing-order request so an all-no-op brief can still
      // be checked by the same parser; never introduce an unrelated operation.
      return commands.length ? commands : ["Move clip 1 to position 1"];
    }
  }
}

/** An offline wording assistant, not an LLM or media analysis. Known requests become
 * explicit executable commands only if the original and suggested plans produce
 * exactly the same validated draft. Unknown intent remains verbatim for review. */
export function enhancePromptLocally(message: string, input?: EditDraft): PromptEnhancement {
  const original = checkedText(message, CONVERSATION_LIMITS.messageCharacters, "Your prompt");
  const draft = validateDraft(input ?? { schema: 1, id: "prompt-preview", revision: 0, ratio: "9:16", title: "", audio: "original", clips: [] });
  const result = interpretLocalEdit(original, draft);
  const proposal = (enhanced: string, notes: string[]) => decodePromptEnhancement({ original, enhanced, notes, method: "guided" }, original);
  if (result.kind !== "plan") {
    const notes = result.kind === "clarification"
      ? [result.message]
      : ["Your wording is kept intact because this request cannot be safely translated into the available quick editing commands.",
        "Specify the desired length, clip numbers, exact on-screen text or transition. Generated scenes, music and alternate camera angles need a separate capability."];
    if (!draft.clips.length) notes.push("Add your photos or clips to check timing and shot references. No duration, property facts or visual effects have been invented.");
    return proposal(original, notes.map(note => note.slice(0, 300)).slice(0, 4));
  }
  try {
    const orderedIds = draft.clips.map(clip => clip.id);
    const commands = result.plan.operations.flatMap(operation => commandsFor(operation, orderedIds));
    if (commands.length > CONVERSATION_LIMITS.operations) throw new Error("The explicit version needs too many commands.");
    const enhanced = commands.join("; ");
    if (enhanced.length > CONVERSATION_LIMITS.messageCharacters) throw new Error("The explicit version is too long.");
    const roundTrip = interpretLocalEdit(enhanced, draft);
    if (roundTrip.kind !== "plan" || JSON.stringify(applyConversationPlan(draft, result.plan).draft) !== JSON.stringify(applyConversationPlan(draft, roundTrip.plan).draft))
      throw new Error("The suggested wording would change the intended edit.");
    const notes = [enhanced === original ? "This prompt already maps clearly to the available editing controls." : "Rephrased as explicit editing commands. The suggested wording produces the same edit as your original request."];
    if (result.plan.operations.some(operation => operation.type === "title" || operation.type === "caption")) notes.push("Your supplied title and caption text is preserved exactly.");
    if (result.plan.operations.some(operation => operation.type === "reorder" || operation.type === "caption")) notes.push("Clip numbers refer to this draft and account for earlier ordering changes in the same request.");
    if (result.plan.operations.some(operation => operation.type === "pace" || operation.type === "duration" || operation.type === "highlight" && operation.targetSeconds !== undefined))
      notes.push("Timing uses your existing shots. Speaker playback speed is unchanged; review any shortened video endings before sharing.");
    return proposal(enhanced, notes.slice(0, 4));
  } catch {
    return proposal(original, ["Your original wording is kept because a rewritten version could not be verified as the exact same edit. No change has been applied."]);
  }
}
