// Plain-language failure copy (owner rule, 12 Nov 2026): when anything fails
// or is refused, an average realtor is told what happened, whether they were
// charged, and what to do next — in everyday words.
//
// Every failure answer carries:
//   error        the message. Written in plain words AT ITS SOURCE where the
//                source is TypeScript. Never changed here, because server code
//                and tests match on it.
//   code         the stable machine code. Never changed here.
//   next_step    ONE action from the small NextStep vocabulary below, so an app
//                can offer the matching button ("Try again", "Upgrade plan").
//   charge       a ChargeFact, present ONLY when the message itself states what
//                happened to the customer's edit/credit. It is read from the
//                message's own standard sentence, so the field can never say
//                more than the code that wrote the message promised.
//   user_message present ONLY when `error` is still written like an audit
//                record (it comes from a database function or an internal
//                integrity check). It is the same fact in plain words; apps
//                show `user_message ?? error`.
//
// Nothing in this file decides behaviour. It only chooses words.

export type NextStep =
  | "retry"             // try the same thing again now
  | "retry_later"       // wait a few minutes, then try again
  | "check_saved"       // open the saved edit/video again; do not start a new one
  | "resume"            // tap Resume on the saved video
  | "change_photo"      // pick another photo, or a smaller copy
  | "change_request"    // change the instruction or the selection
  | "check_connection"  // check signal / Wi-Fi
  | "refresh"           // reload, then try again
  | "review_price"      // look at the price shown, then confirm
  | "review_permission" // allow AI processing, then continue
  | "upgrade_plan"
  | "add_credits"
  | "sign_in"
  | "update_app"
  | "ask_admin"         // the workspace owner must give access
  | "contact_support"
  | "none";

export type ChargeFact =
  | "not_charged"       // nothing was taken for this request
  | "credit_returned"   // something was taken and has been handed back
  | "no_new_charge"     // paid work is saved; continuing it costs nothing more
  | "charged";          // this attempt used an edit or credits

const NEXT_STEPS: readonly string[] = ["retry", "retry_later", "check_saved", "resume", "change_photo", "change_request",
  "check_connection", "refresh", "review_price", "review_permission", "upgrade_plan", "add_credits", "sign_in",
  "update_app", "ask_admin", "contact_support", "none"];
const CHARGE_FACTS: readonly string[] = ["not_charged", "credit_returned", "no_new_charge", "charged"];

/** The action a failure class calls for when its message names none. */
export function defaultNextStep(code: string, status: number): NextStep {
  switch (code) {
    case "unauthorized": return "sign_in";
    case "forbidden": return "ask_admin";
    case "not_found": return "refresh";
    case "conflict":
    case "publication_superseded":
    case "gallery_selection_changed": return "refresh";
    case "consent_required": return "review_permission";
    case "credit_quote_required": return "review_price";
    case "plan_required":
    case "quota_exceeded": return "upgrade_plan";
    case "trial_capacity_unavailable": return "contact_support";
    case "rate_limited": return "retry_later";
    case "payload_too_large": return "change_photo";
    case "validation":
    case "unsupported_edit":
    case "photo_clarification_required": return "change_request";
    case "photo_quality_pending":
    case "photo_quality_hold": return "check_saved";
    case "photo_quality_closed":
    case "photo_quality_refused": return "retry";
    case "upstream":
    case "internal": return "retry_later";
    // Codes written by individual handlers rather than the shared ErrorCode set.
    case "processor_consent_required": return "review_permission";
    case "processor_disclosure_unpublished": return "retry_later";
    case "credit_quote_changed": return "review_price";
    case "credit_balance_low": return "add_credits";
    case "capacity_refused":
    case "plan_capacity": return "upgrade_plan";
    case "operation_abandoned":
    case "feedback_exists": return "none";
  }
  if (status === 401) return "sign_in";
  if (status === 402) return "upgrade_plan";
  if (status === 403) return "ask_admin";
  if (status === 404 || status === 409) return "refresh";
  if (status === 413) return "change_photo";
  if (status === 429 || status >= 500) return "retry_later";
  return "change_request";
}

// The standard sentences of the message style guide. The instruction that
// appears FIRST in a message is the one the app should offer; the list order
// only breaks a tie.
const NEXT_STEP_PHRASES: readonly (readonly [RegExp, NextStep])[] = [
  [/\btap resume\b|\bresume (?:it|this video|the video|the check)\b/i, "resume"],
  [/\badd credits\b/i, "add_credits"],
  [/\bupgrade\b|\bchoose a plan\b|\b(?:check|review) your plan\b|\bsubscribe\b/i, "upgrade_plan"],
  [/\bsign in\b/i, "sign_in"],
  [/\bupdate rendprop\b|\bupdate the app\b/i, "update_app"],
  [/(?<!couldn['’]t )\bcheck (?:the|this|your) (?:same |saved )*(?:edit|video|photo)\b|\bcheck it again\b/i, "check_saved"],
  [/\b(?:another|a different|a smaller|fewer) (?:photo|file)s?\b|\bsmaller (?:copy|file|photo)\b|\bresize\b/i, "change_photo"],
  [/\breview the (?:price|charge|cost)\b/i, "review_price"],
  [/\ballow ai\b|\ballow the\b.*\bprocessor/i, "review_permission"],
  [/\b(?:check|restore) your (?:internet )?connection\b/i, "check_connection"],
  [/\bcontact support\b/i, "contact_support"],
  [/\bask (?:the|your) (?:workspace |team )?(?:owner|admin)/i, "ask_admin"],
  [/\b(?:try|check)(?: it| this)? again (?:in a (?:few minutes|minute|moment)|later|shortly|tomorrow|after)\b|\bwait (?:a few minutes|a little|a minute|until)\b|\bretry (?:shortly|later)\b/i, "retry_later"],
  [/\brefresh\b|\breload\b/i, "refresh"],
  [/\bgo back\b|\bcheck what you selected\b|\bchange (?:the|your) (?:instruction|request|wording)\b|\breword\b|\btype your own\b/i, "change_request"],
  [/\b(?:try|start) (?:it |this |the edit |the video |a new edit )?again\b|\bretry\b|\bstart a new\b/i, "retry"],
  [/\bchoose\b|\bpick\b/i, "change_request"],
];

/** The action a message asks for, else the default for its failure class. */
export function nextStepFor(message: string, code: string, status: number): NextStep {
  let found: NextStep | undefined, at = Infinity;
  for (const [phrase, step] of NEXT_STEP_PHRASES) {
    const index = message.search(phrase);
    if (index >= 0 && index < at) { at = index; found = step; }
  }
  return found ?? defaultNextStep(code, status);
}

/** What the message's own standard charge sentence says, or undefined. */
export function chargeFactFor(message: string): ChargeFact | undefined {
  if (/\b(?:was|were) returned\b|\bhas been returned\b|\bwe returned\b/i.test(message)) return "credit_returned";
  if (/\bno new charge\b|\bno extra charge\b|\bwon['’]t be charged again\b|\bnot be charged again\b|\bwithout (?:another|a new) charge\b/i.test(message)) return "no_new_charge";
  if (/\byou were not charged\b|\bnot charged\b|\bnothing was charged\b|\bno edit was sent\b|\bdid not use (?:an edit|any credits|a credit)\b|\bno credits were used\b/i.test(message)) return "not_charged";
  if (/\bused one edit\b|\bused (?:an edit|your credits?)\b|\bwas charged\b|\bstill counts\b/i.test(message)) return "charged";
  return undefined;
}

// ── Technical wording that must not reach a customer ─────────────────────────
// The words the owner named, plus the internal vocabulary of the billing and
// storage layers. A message containing any of them is replaced in
// `user_message`; the original stays in `error` for code and tests.
const JARGON = new RegExp("\\b(?:" + [
  "receipts?", "evidence", "provenance", "leases?", "admission", "admitted", "envelope", "reservations?",
  "idempoten\\w*", "attestation", "authority", "identit(?:y|ies)", "custody", "journal(?:ed)?", "fenced?",
  "dispatch(?:ed)?", "manifest", "inconsistent", "bound(?:ed)?", "funded", "funding", "serving", "sponsor(?:ship)?",
  "allocation", "liabilit(?:y|ies)", "supplier", "provider", "tariff", "bytes?", "sha-?256", "hash", "digest",
  "etag", "rpc", "sql", "uuid", "json", "payload", "quarantine", "pointer", "schema", "ledger", "upstream",
  "calibration", "readback", "deterministic", "reconcil\\w*", "multipart", "durable", "reticketed", "tickets?",
  "env var", "bearer", "token", "secret", "rollout",
].join("|") + ")\\b", "i");

// Text that is not a sentence written for a person: a database or vendor
// error pasted after a colon, raw JSON, an HTTP status line, a stack trace.
const RAW_DETAIL = /\b(?:lookup|read|write|insert|update|list|query|select|delete) failed\b|\{"|\[\{|\bHTTP \d{3}\b|\bTraceback\b|^\w+ \d{3}: |\bPGRST\d+|\bat [\w$.]+ \(/i;

/** True when the text is written like an audit record. */
export function hasJargon(text: string): boolean {
  return JARGON.test(text) || RAW_DETAIL.test(text) || text.length > 400;
}

const RETRY_SENTENCE = /^(?:please )?(?:retry|try again|refresh|reload)\b[^.]*\.?$|\bplease retry\b|\bplease try again\b|\bretry (?:shortly|later)\b/i;
const PROPER = /^(?:Apple|Rendprop|Studio|Photo Motion|Photo motion|App Store|AI|MLS|I)\b/;

function sentences(text: string): string[] {
  return text.replace(/\s+/g, " ").trim().split(/(?<=[.!?])\s+(?=[A-Z“"'])/).map((s) => s.trim()).filter(Boolean);
}
function lowerFirst(text: string): string {
  return PROPER.test(text) || /^[A-Z]{2}/.test(text) ? text : text.charAt(0).toLowerCase() + text.slice(1);
}
function endStop(text: string): string {
  return /[.!?]$/.test(text) ? text : text + ".";
}

/** A short stable code so support can find the technical message behind a
 *  plain one without the customer having to read it. FNV-1a, 6 hex digits. */
export function supportCode(text: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
  return (h & 0xffffff).toString(16).toUpperCase().padStart(6, "0");
}

// Sentences worth keeping from a technical message: plain facts about what was
// NOT done or what is safe. They are true wherever the source wrote them.
function keptFacts(parts: string[]): string[] {
  return parts.slice(1).filter((s) => !hasJargon(s) && !RETRY_SENTENCE.test(s) && s.length <= 140)
    .map((s) => /^no edit was sent\.?$/i.test(s) ? "No edit was sent, so you were not charged." : endStop(s)).slice(0, 2);
}

// Database-origin messages (raised by SQL functions as `RPnnn: text`) that a
// customer can meet in the main flows. Each maps the technical sentence to the
// same fact in plain words. First match wins. Anything not listed falls through
// to the generic wording below, which is still plain and still honest.
const KNOWN: readonly (readonly [RegExp, string | ((m: RegExpMatchArray) => string)])[] = [
  // ── plan, allowance, credits ──
  [/^monthly render limit reached for the (\S+) plan \((\d+) of (\d+)\)/i, (m) => `You have used all ${m[3]} tours included in your ${m[1]} plan this month. Upgrade your plan to make more, or wait until next month.`],
  [/^monthly AI spend ceiling reached/i, "You have reached this month's AI limit for your plan. Upgrade your plan, or wait until your next billing month."],
  [/^Monthly AI clip allowance reached/i, "You have used all the video clips included in your plan this month. Upgrade your plan or add credits to make more."],
  [/^Your plan does not include AI clips/i, "AI video clips are not part of your current plan. Upgrade your plan to make this video."],
  [/^Video processing is not included in this workspace plan/i, "Video is not part of your current plan. Upgrade your plan to make this video."],
  [/^This video exceeds the current plan photo-clip allowance/i, "This video needs more clips than your plan has left this month. Choose fewer photos, or upgrade your plan."],
  [/^This video needs (\d+) photo clips; (\d+) remain/i, (m) => `This video needs ${m[1]} clips and your plan has ${m[2]} left this month. Choose fewer photos, or upgrade your plan.`],
  [/^This complete video (?:is estimated at|exceeds)/i, "This video is bigger than what your plan has left, so no clip was started. Choose fewer photos, or upgrade your plan."],
  [/^Add credits before starting/i, "You don't have enough credits for this yet, so it was not started. Add credits, then try again."],
  [/^This workspace needs an eligible credit balance/i, "You don't have enough credits for this yet. Add credits, then try again."],
  [/^This (?:photo|declutter) credit hold is unavailable/i, "We couldn't set aside the credits for this edit, so it was not started. Try again in a minute."],
  [/^AI usage limit reached/i, "You have reached the AI limit for your plan for now. Upgrade your plan, or wait until it resets."],
  [/^(?:Workspace (?:monthly )?processing budget|cost cap exceeded|Reflection batch exceeds)/i, "This would go over your plan's limit, so it was not started. Upgrade your plan, or try a smaller job."],
  [/^The included trial photo edits are exhausted/i, "You have used all the photo edits included in your free trial. Choose a plan to keep editing."],
  [/^The included trial usage is exhausted|^Free-trial AI limit reached for this month/i, "You have used everything included in your free trial. Choose a plan to keep going."],
  [/^The included trial walkthrough is already reserved|^The included trial listing is already published/i, "Your free trial includes one of these and you have already used it. Choose a plan to make more."],
  [/^(?:Photo uploads|Listing creation) start after the free week|^Unpaid access includes one listing|^Video uploads start after payment|^Video and public website creation start after payment|^Subscribe to activate hosted publication/i, "This needs a paid plan. Choose a plan to continue."],
  [/^Photo suggestions and prompt rewriting are not included|^This generation feature is not included in the subscription trial/i, "This tool is not part of the free trial. Choose an edit or type your own instruction instead."],
  [/^this team is full|^every seat on your plan is taken/i, "Every seat on your plan is in use. Remove a member or upgrade your plan to invite someone new."],
  [/^Update Rendprop to use the current Photo motion profile/i, "This version of Rendprop is too old to make this video. Update Rendprop, then try again. Your saved videos are still here."],
  // ── busy / too many at once ──
  [/^this workspace already has (\d+) renders in flight/i, "You already have tours being made. Wait for one to finish, then try again."],
  [/^Too many video jobs/i, "You have several videos in progress. Wait for one to finish, then start this one."],
  [/^too many publishes in the last hour/i, "You have published a lot in the last hour. Wait a little, then publish again."],
  [/^Photo review limit reached for this workspace/i, "You have reached today's limit for photo checks. Try again tomorrow."],
  [/^(?:Stored media allowance|Media write request allowance|Media serving allowance) exhausted|^(?:daily|monthly) (?:physical|technical) upload reservation|^workspace upload safety limit/i, "Your workspace has reached its upload limit for now. Nothing new was uploaded. Try again later, or contact support if you need more room."],
  [/^an email was just requested|^a verification email was already requested|^too many client forwards/i, "An email was just sent. Wait a few minutes before sending another."],
  // ── things that changed underneath the user ──
  [/^The listing photo selection changed/i, "The photos chosen for this listing changed while this was running. Refresh, check the selection, then try again."],
  [/^Photo Motion credit (?:quote|route) changed before admission/i, "The price for this video changed before it started. Review the price shown and confirm again."],
  [/different saved inputs/i, "This video was already started with different photos or settings. Open the saved video, or start a new one."],
  [/^Original video quota charge could not be confirmed/i, "We couldn't confirm this video against your plan, so it was not started. Try again in a minute."],
];

/**
 * The plain-words version of a message, or the message itself when it is
 * already plain. `status` picks the generic wording when nothing better fits.
 */
export function plainMessage(message: string, status: number): string {
  const text = String(message ?? "").replace(/^RP\d{3}:\s*/, "").trim();
  if (!text) return genericFor(status, "", []);
  for (const [pattern, plain] of KNOWN) {
    const m = text.match(pattern);
    if (m) return typeof plain === "string" ? plain : plain(m);
  }
  const parts = sentences(text);
  // "X could not be verified." keeps its subject: the customer learns WHAT we
  // could not check, in an active sentence, and what to do.
  const check = /^(.{3,80}?) (?:could not|couldn['’]t|cannot|can['’]t) be (verified|confirmed|checked|reconciled|read)\.?$/i.exec(parts[0] ?? "");
  if (check && !hasJargon(check[1])) {
    const verb = { verified: "check", checked: "check", confirmed: "confirm", reconciled: "update", read: "load" }[check[2].toLowerCase()] ?? "check";
    const tail = status >= 500 || status === 429 ? "Try again in a minute." : "Refresh and try again.";
    return [`We couldn't ${verb} ${lowerFirst(check[1])} just now.`, ...keptFacts(parts), tail].join(" ");
  }
  if (!hasJargon(text)) return text;
  return genericFor(status, text, keptFacts(parts));
}

function genericFor(status: number, original: string, facts: string[]): string {
  const kept = facts.length ? " " + facts.join(" ") : "";
  const code = original ? ` and mention code ${supportCode(original)}` : "";
  if (status === 401) return "You need to sign in again to continue.";
  if (status === 402) return `Your plan, trial or credits don't cover this right now.${kept} Check your plan and credits. If that looks wrong, contact support${code}.`;
  if (status === 403) return `You don't have access to do that here.${kept} Ask the workspace owner for access, or contact support${code}.`;
  if (status === 404) return `We couldn't find that item. It may have been moved or deleted.${kept} Refresh and try again.`;
  if (status === 409) return `This changed while you were working, maybe on another device.${kept} Refresh and try again.`;
  if (status === 413) return `That file is too large to use.${kept} Pick a smaller photo or file and try again.`;
  if (status === 429) return `That's a lot of requests in a short time.${kept} Wait a few minutes, then try again.`;
  if (status >= 500) return `Something went wrong on our side, so this didn't go through.${kept} Try again in a few minutes. If it keeps happening, contact support${code}.`;
  return `We couldn't use that request as it was sent.${kept} Go back, check what you selected and try again. If it keeps happening, contact support${code}.`;
}

// Shipped iOS builds recognise these exact phrases in the text they display
// (APIError.isAlreadyComplete, UploadRecovery, SpatialUploadCoordinator,
// TeamAPI.needsIdentity). A message containing one is never given a
// `user_message`, so an app that prefers `user_message` still sees the phrase.
const CLIENT_MATCHED = /already complete|parts\[\] must contain each part|not configured|Sign in with Apple/i;

/** The additive wire fields for one failure. `error` and `code` are untouched. */
export function failureFields(
  message: string,
  code: string,
  status: number,
  details?: Record<string, unknown>,
): { next_step: NextStep; charge?: ChargeFact; user_message?: string } {
  const plain = CLIENT_MATCHED.test(message) ? message : plainMessage(message, status);
  const shown = typeof details?.user_message === "string" && details.user_message ? details.user_message : plain;
  const explicitStep = typeof details?.next_step === "string" && NEXT_STEPS.includes(details.next_step) ? details.next_step as NextStep : undefined;
  const explicitCharge = typeof details?.charge === "string" && CHARGE_FACTS.includes(details.charge) ? details.charge as ChargeFact : undefined;
  const charge = explicitCharge ?? chargeFactFor(shown);
  return {
    next_step: explicitStep ?? nextStepFor(shown, code, status),
    ...(charge ? { charge } : {}),
    ...(shown !== message ? { user_message: shown } : {}),
  };
}

// ── Saved video status lines ─────────────────────────────────────────────────
// `property_video_jobs.message` is written by database functions and shown by
// both apps under the saved video ("Needs attention"). The apps cap it at 400
// bytes on one line. The app shows a Resume button when resuming is possible,
// so these say what happened and what is safe, and point at that button.
const VIDEO_KNOWN: readonly (readonly [RegExp, string])[] = [
  [/^Video quality review paused\b/i, "Your video paused while we were checking a finished clip. The clip you paid for is saved. If Resume is shown, tap it to pick up where it stopped — you won't be charged again for that clip."],
  [/^A selected photo could not be generated or approved\b/i, "We couldn't make a video clip from one of your photos, so the video stopped. Your photos are safe and what you paid for is on record. If Resume is shown, tap it. Otherwise start the video again; if the same photo stops it, leave that photo out."],
  [/^The provider receipt could not be confirmed\b/i, "We sent one clip to be made and never heard back, so the video is on hold while we check. We will not start that clip twice. Check this video again in a few minutes."],
  [/^Photo Motion could not be assembled\b|^Photo Motion could not finish\b/i, "We couldn't put your Photo Motion video together. Your photos are safe. Start the video again. If it stops a second time, contact support so we can sort it out."],
  [/^Saved Photo Motion output needs review\b/i, "Your Photo Motion video was made but could not be saved correctly. Your photos are safe. Start the video again. If it happens twice, contact support."],
  [/^The video could not be assembled\b/i, "We couldn't put your video together. Your photos are safe. Start the video again. If it stops a second time, contact support."],
  [/^Video assembly could not finish\b/i, "Your clips finished, but joining them into one video did not. The finished clips are saved. If Resume is shown, tap it — the clips are not made again. Otherwise contact support."],
  [/^Video assembly stopped\b/i, "Joining your clips into one video stopped partway. Tap Resume to finish it — your finished clips are reused and are not made again."],
  [/^Video assembly was interrupted\b/i, "Joining your clips into one video was interrupted. It will pick up again by itself using the clips already made."],
  [/^Video paused before the next unpaid clip\b/i, "Your video paused before the next clip was started. The clips already made are saved and the next one has not been paid for. If Resume is shown, tap it in a few minutes to continue."],
  [/^Background video time limit reached\b/i, "This video took too long and was stopped. Your photos are safe and what you paid for is on record. Nothing will be made twice. Start a new video, or contact support if you paid for clips you did not get."],
  [/^The saved narration could not be decoded\b/i, "We couldn't read your voice recording. Your photos are safe. Record or upload the narration again, then make the video."],
  [/^Video quality review could not finish\b/i, "We couldn't finish checking your clips. Your photos and finished clips are saved. If Resume is shown, tap it. Otherwise try again in a few minutes."],
  [/^This selected image could not be prepared for video\b/i, "One of your photos couldn't be prepared for video. The original photo is unchanged. Pick a different photo, or try again."],
  [/^Video image preparation was interrupted\b/i, "Getting a photo ready for video was interrupted. The original photo is unchanged. Try again."],
  [/^Video (?:work|image preparation) was cancelled\b/i, "You cancelled this video. Anything already finished is kept privately in your account."],
  [/^The generated clip did not pass the motion-quality check\b/i, "One clip came out with shaky or warped motion, so the video stopped. Your photos and the clips already made are saved. Start the video again without that photo, or pick a different one."],
  [/^The generated opening did not pass its property quality check\b/i, "The opening shot didn't pass our check that it still looks like your property, so it was not used. No second try was started. Make the opening again, or pick a different photo."],
  [/^This opening timed out\b/i, "The opening shot took too long and was stopped. Your original files are safe. We are checking what happened to it and to your credits. Check this again in a few minutes."],
  [/^The supplier response could not be confirmed\. Your credits were returned\b/i, "We never got the opening shot back, so it was stopped. Your credits were returned. Try the opening again."],
  [/^The supplier response could not be confirmed\. Your credits are being returned\b/i, "We never got the opening shot back, so it was stopped. Your credits are being returned to you now. Try the opening again in a few minutes."],
  [/^This opening stopped safely\b|^The opening was refused before submission\b|^The provider refused this opening\b/i, "The opening shot was not made. Your original photo is safe and nothing was sent a second time. Try the opening again, or pick a different photo."],
  [/^(?:Stopped\.|Aerial processing was stopped\b)/i, "You stopped this. Anything already finished is kept privately in your account."],
  [/^The fixed renderer release needs review\b|^Saved assembly inputs or an output reservation need review\b/i, "Your clips finished, but there is a problem on our side joining them. The finished clips are saved. Contact support so we can finish this video for you."],
];

/** The plain-words status line for a saved video, at most 400 bytes on one line. */
export function plainVideoMessage(message: unknown): string {
  const text = typeof message === "string" ? message.replace(/\s+/g, " ").trim() : "";
  if (!text) return "";
  for (const [pattern, plain] of VIDEO_KNOWN) if (pattern.test(text)) return plain;
  if (!hasJargon(text)) return text;
  return "This video stopped before it finished. Your photos are safe and finished clips are saved. If Resume is shown, tap it. Otherwise start the video again, or contact support and mention code " + supportCode(text) + ".";
}
