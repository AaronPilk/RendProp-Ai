// copy.ts — the actual words. All six categories, in one file.
//
// WHY THE WORDS LIVE HERE AND NOT IN THE OUTBOX ROW. Migration 0047 stores
// FACTS in notification_outbox.payload — which lead, which listing, how many
// hours of trial are left — and nothing else. Rendering them into a sentence
// happens at SEND time, here, for three reasons:
//
//   • A typo can be fixed with a function deploy instead of a migration, and
//     the fix reaches rows that were queued before it.
//   • One event produces one wording whether it goes out as a push or as an
//     e-mail; the subject line of the mail IS the title of the push.
//   • The outbox stays small and free of anything worth redacting.
//
// Known admin alerts are rendered from their facts too. Other operator-composed
// messages retain their explicit title/body. Admin recipient checks and dedupe
// remain in the database; wording never grants permission to receive an alert.
//
// THE VOICE (apps/ios/Rendprop/Plan/PlanBanner.swift, functions/coach/knowledge.ts):
// plain, human, specific. Say the fact, then say what it means for them. No
// exclamation marks. No "Don't miss out", no "Act now", no countdown theatre —
// the banner's own rule is "nagging someone on day one of a trial is how you
// lose day two", and a notification is far more intrusive than a banner. Never
// a price: prices come from StoreKit only.
//
// Every string below is deterministic given the payload, which is what makes
// notify.test.ts able to assert it.

/** The six categories notification_outbox.category is constrained to. */
export type NotificationCategory =
  | "lead_received"
  | "render_ready"
  | "upload_stuck"
  | "free_week_ending"
  | "allowance_low"
  | "first_tour_nudge"
  | "team_invite"
  | "client_lead_received"
  | "ops_alert";

export interface RenderedMessage {
  /** Push alert title; e-mail subject. */
  title: string;
  /** Push alert body; the first paragraph of the e-mail. */
  body: string;
}

type Data = Record<string, unknown>;

function str(data: Data, key: string): string | null {
  const v = data[key];
  if (typeof v !== "string") return null;
  const s = v.trim();
  return s.length > 0 ? s : null;
}

function num(data: Data, key: string): number | null {
  const v = data[key];
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : null;
}

/** What a person calls the meter that is running out. */
const FEATURE_LABELS: Record<string, string> = {
  renders: "tours",
  photo_edits: "photo edits",
  reels: "reels",
  aerials: "aerial intros",
  drone: "drone-glide clips",
};

/**
 * "within the hour" / "in 9 hours" / "tomorrow".
 * Deliberately coarse: the exact minute is not useful and a countdown reads as
 * pressure.
 */
function endsWhen(hoursLeft: number | null): string {
  if (hoursLeft === null) return "soon";
  if (hoursLeft <= 1) return "within the hour";
  if (hoursLeft < 24) return `in ${Math.round(hoursLeft)} hours`;
  return "tomorrow";
}

/** UTC makes the observation's age clear without guessing the owner's zone. */
function alertTime(value: unknown): string | null {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T/.test(value)) return null;
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return null;
  return date.toISOString().slice(0, 16).replace("T", " ") + " UTC";
}

function adminAlert(payload: Data): RenderedMessage | null {
  const code = str(payload, "code");
  const data = payload.data && typeof payload.data === "object" && !Array.isArray(payload.data)
    ? payload.data as Data : {};
  const checked = alertTime(payload.observed_at);
  const checkedCopy = checked ? ` Checked ${checked}.` : " Check time was not recorded.";
  if (code?.startsWith("provider_dead:")) {
    const model = str(data, "model") ?? "";
    const provider = str(data, "provider");
    const providerName = provider === "fal" ? "FAL" : provider === "openai" ? "OpenAI"
      : provider === "gemini" ? "Google" : "The connected AI service";
    const feature = /image-to-video/.test(model) ? "Photo-to-video"
      : /text-to-video|video\//.test(model) ? "AI video creation"
      : /image|kontext|flux/.test(model) ? "AI photo editing" : "AI generation";
    const failures = num(data, "consecutive_failures");
    const count = failures !== null && Number.isInteger(failures) && failures > 0
      ? `${failures} requests failed in a row` : "Repeated requests failed";
    const failed = alertTime(data.last_fail_at);
    const last = failed ? ` Last failure ${failed}.` : "";
    const status = num(data, "last_status");
    const reason = status === 401 ? " The service rejected our access key."
      : status === 402 ? " The provider account needs funds."
      : status === 403 ? " The provider refused this account or model."
      : status === 429 ? " The provider is limiting requests."
      : data.last_error_class === "timeout" ? " The service took too long to respond." : "";
    return {title: `Admin: ${feature} needs attention`,
      body: `${providerName}: ${count}.${last}${reason} Check the connected provider account before testing this feature again.${checkedCopy}`};
  }
  if (code?.startsWith("org_near_ceiling:")) {
    const spent = num(data, "spent_cents"), cap = num(data, "ceiling_cents");
    const reached = spent !== null && cap !== null && cap > 0 && spent >= cap;
    const name = str(data, "org_name") ?? /^(?:Admin alert: )?Workspace near its AI (?:ceiling|envelope): (.{1,100})$/.exec(str(payload, "title") ?? "")?.[1];
    const subject = name ? `AI generation for ${name}` : "This workspace's AI generation";
    const allowance = data.kind === "free" ? "free AI spending allowance" : "AI spending allowance for this period";
    return {title: `Admin: Workspace AI limit ${reached ? "reached" : "nearly used"}`,
      body: `${subject} has ${reached ? "used up" : "nearly used up"} its ${allowance}. ${reached ? "New AI requests are paused." : "New AI requests pause when it is used up."} Check the account's plan or testing access before adding more usage.${checkedCopy}`};
  }
  if (code === "holds_unledgered") {
    const holds = num(data, "holds");
    const subject = holds !== null && Number.isInteger(holds) && holds > 0
      ? `${holds} AI request${holds === 1 ? " has" : "s have"}` : "Some AI requests have";
    return {title: "Admin: AI cost tracking needs attention",
      body: `${subject} an incomplete saved cost record. The budget reserved for these requests has not been released. Check the job's cost details and account-deletion history before correcting the record.${checkedCopy}`};
  }
  return null;
}

/**
 * The message for one outbox row.
 *
 * Known admin alerts use plain copy. Otherwise `payload.title` / `payload.body` win when present (an operator-composed
 * message); otherwise the six templates below render from `payload.data`.
 * Every template degrades: an unknown lead name, a listing with no address and
 * a missing count all produce a sentence that still reads properly.
 */
export function render(category: string, payload: Data): RenderedMessage {
  if (category === "ops_alert") {
    const message = adminAlert(payload);
    if (message) return message;
  }
  const explicitTitle = str(payload, "title");
  const explicitBody = str(payload, "body");
  if (explicitTitle && explicitBody) return { title: explicitTitle, body: explicitBody };

  const data = (payload.data && typeof payload.data === "object" && !Array.isArray(payload.data)
    ? payload.data
    : {}) as Data;

  switch (category) {
    // THE MESSAGE THAT SAVES THE SUBSCRIPTION. It carries the lead's name and
    // the listing, because "Rendprop got me a lead" is the sentence that
    // renews, and a notification that only says "you have a new lead" makes the
    // agent open the app to find out whether it matters.
    case "lead_received": {
      const who = str(data, "lead_name") ?? "Someone";
      const what = str(data, "listing_address") ?? "your tour";
      const hasPhone = data.has_phone === true;
      const hasEmail = data.has_email === true;
      const contact = hasPhone && hasEmail
        ? "They left a phone number and an email address"
        : hasPhone
        ? "They left a phone number"
        : hasEmail
        ? "They left an email address"
        : "They asked you to get in touch";
      return {
        title: `${who} asked about ${what}`,
        body: `${contact}. The details are on your Leads screen.`,
      };
    }

    case "render_ready": {
      const what = str(data, "listing_address") ?? "your listing";
      return {
        title: `Your tour of ${what} is ready`,
        body:
          "The share link is live. Open the tour to copy the branded link, or the unbranded one for the MLS.",
      };
    }

    case "upload_stuck": {
      const what = str(data, "listing_address") ?? "a listing";
      return {
        title: `The upload for ${what} did not finish`,
        body:
          "It stopped before the file was fully sent, so nothing was published. Your recording is still on the phone — open the listing and send it again.",
      };
    }

    case "free_week_ending": {
      return {
        title: `Your free week ends ${endsWhen(num(data, "hours_left"))}`,
        body:
          "Nothing is deleted when it does. Tours you have already published stay up and their links keep working. Picking a plan is what lets you make new ones.",
      };
    }

    case "allowance_low": {
      const feature = str(data, "feature") ?? "";
      const label = FEATURE_LABELS[feature] ?? "items";
      const used = num(data, "used");
      const cap = num(data, "cap");
      const left = num(data, "left") ?? 0;
      const counted = used !== null && cap !== null
        ? `${used} of ${cap} ${label} used this cycle`
        : `You are close to this cycle's ${label} allowance`;
      return {
        title: counted,
        body: left > 0
          ? `${left} left before it resets. Tours you have already published are not affected.`
          : "The allowance resets at the start of your next cycle. Tours you have already published are not affected.",
      };
    }

    // THE ONLY MESSAGE THAT GOES TO A STRANGER. Everything else here is
    // addressed to someone who already has an account and asked for the app;
    // this one lands cold, in the inbox of an agent whose broker signed a
    // contract they may not have heard about yet. So it says who, and from
    // where, before it says what to do — and it carries the code in the body
    // rather than behind a link, because a twelve-character code is something
    // a person can act on from a phone in a car.
    case "team_invite": {
      const org = str(data, "org_name") ?? "a team";
      const who = str(data, "inviter");
      const code = str(data, "code") ?? "";
      const opener = who ? `${who} added you to ${org} on Rendprop` : `You have been added to ${org} on Rendprop`;
      // LEAD WITH THE LINK, NOT THE CODE. The link is the whole point — it
      // lands on a page that copies the code and opens the app, so the code
      // below it is the fallback for a mail client that strips links or a
      // person reading this on the wrong device, not the instruction.
      return {
        title: opener,
        body: code
          ? `Tap the link below to join — it fills your code in for you. If you would rather type it, the code is ${code}. It works once and expires in 14 days.`
          : "Tap the link below to join.",
      };
    }

    case "first_tour_nudge": {
      return {
        title: "Your first tour is still waiting",
        body:
          "Walk the space at a normal pace for a few minutes, tag the rooms as you go, and Rendprop builds the flythrough and the share link. That is the whole thing.",
      };
    }

    default:
      // Unreachable: the database CHECK on notification_outbox.category is the
      // same six values. If a seventh ever arrives, say something true rather
      // than throw inside a drain.
      return {
        title: "Rendprop",
        body: "There is an update waiting in the app.",
      };
  }
}

/**
 * The absolute link for a row, or null.
 *
 * The producers store a PATH (`/f/<slug>`) rather than a URL so the public base
 * can change without rewriting queued rows — the same reason TOUR_PUBLIC_BASE_URL
 * exists for functions/me. An absolute link that is already absolute is passed
 * through; anything that is not a http(s) URL or a leading-slash path is
 * dropped, because a bad link in a notification is worse than none.
 */
export function absoluteLink(payload: Data, base: string): string | null {
  const raw = str(payload, "deep_link");
  if (!raw) return null;
  if (/^https?:\/\//i.test(raw)) return raw;
  if (!raw.startsWith("/")) return null;
  return `${base.replace(/\/+$/, "")}${raw}`;
}

/** Plain-text e-mail body: the message, the link if there is one, and a footer. */
export function emailText(
  message: RenderedMessage,
  link: string | null,
  category?: string,
): string {
  const lines = [message.body];
  if (link) lines.push("", link);
  lines.push("", "— Rendprop");
  // An invitee has no account and no Settings screen, so the standard footer
  // would be pointing them at something that does not exist for them yet. It
  // is also the one category that is never suppressible (migration 0053), so
  // offering to turn it off would be a lie.
  if (category === "team_invite") {
    lines.push("You received this because someone added you to their team. If you were not expecting it, ignore this email — the invite expires on its own.");
  } else if (category === "ops_alert") {
    // Operator alert (migration 20261008204500): sent to admins only, at most
    // once per finding per day, and deliberately not suppressible.
    lines.push("Operational alert for Rendprop admins. One message per finding per day; it stops when the finding clears.");
  } else {
    lines.push("You can turn any of these off in the app under Settings → Notifications.");
  }
  return lines.join("\n");
}
