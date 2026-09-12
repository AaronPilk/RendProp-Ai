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
// An operator-composed message still wins: if a payload carries an explicit
// `title`/`body`, render() returns those untouched. Nothing in the product
// writes them today.
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
  | "first_tour_nudge";

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

/**
 * The message for one outbox row.
 *
 * `payload.title` / `payload.body` win when present (an operator-composed
 * message); otherwise the six templates below render from `payload.data`.
 * Every template degrades: an unknown lead name, a listing with no address and
 * a missing count all produce a sentence that still reads properly.
 */
export function render(category: string, payload: Data): RenderedMessage {
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
export function emailText(message: RenderedMessage, link: string | null): string {
  const lines = [message.body];
  if (link) lines.push("", link);
  lines.push(
    "",
    "— Rendprop",
    "You can turn any of these off in the app under Settings → Notifications.",
  );
  return lines.join("\n");
}
