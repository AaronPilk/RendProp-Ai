// coach — the customer-service knowledge base.
//
// EVERY fact in this file is copied or tightly paraphrased from one of six
// sources, named on each entry. Nothing here is invented, and nothing here
// should ever drift from its source without this file changing too:
//
//   description.txt   docs/appstore/metadata/en-US/description.txt
//   review_notes.txt   docs/appstore/metadata/en-US/review_notes.txt
//   INDUSTRY-LOGIC.md  docs/INDUSTRY-LOGIC.md
//   UPLOAD-CONTRACT.md docs/UPLOAD-AND-PUBLISH-CONTRACT.md
//   LAUNCH-CONTRACT.md docs/LAUNCH-CONTRACT.md
//   support.html       services/edge/tour-host/public/support.html
//   features.html      services/edge/tour-host/public/features.html
//
// NEVER A PRICE. Every dollar figure in the sources above is deliberately
// left out — prices come from StoreKit only (Products.swift), never from a
// string an LLM can misquote or a docs file that can go stale the day Apple's
// price points change. `PLAN_ALLOWANCES` below carries the COUNTS (renders,
// edits, reels, aerials) because those are product facts, not prices.
//
// iOS carries a hand-mirrored copy of this same set of facts for the offline
// fallback — `apps/ios/Rendprop/Coach/CoachModel.swift` `CoachOffline`. The
// two are independent (Deno/TypeScript vs Swift can't share a source file),
// so a fact that changes here must change there too — see docs/COACH-CONTRACT.md.
//
// This file holds ONLY facts (plus one small formatter). No prompt phrasing,
// no persona, no action rules — those belong to prompt.ts.

/** One knowledge-base entry: a short topic label plus the fact(s) it covers. */
export interface KnowledgeEntry {
  topic: string;
  /** Which of the six sources this was drawn from, for anyone auditing drift. */
  source: string;
  fact: string;
}

export const KNOWLEDGE: KnowledgeEntry[] = [
  {
    topic: "How Rendprop works",
    source: "description.txt",
    fact:
      "Film a walkthrough on an iPhone. Tag the rooms or areas to jump to. Rendprop builds a " +
      "smooth, drone-style flythrough and gives a share link — no drone, no crew, no editor. " +
      "Sending the link is the whole distribution: anyone who opens it scrolls to fly through " +
      "the space, and the contact form on that page drops enquiries into the app's inbox.",
  },
  {
    topic: "Signing in — what needs an account",
    source: "review_notes.txt + description.txt",
    fact:
      "Recording, on-device rendering, the AI Photo Studio, reels, aerial intros and floor " +
      "plans all work fully signed out. Sign in with Apple is needed only to PUBLISH a tour to " +
      "the web, because publishing is the step that creates the hosted link and the contact " +
      "form. Any Apple ID can sign in — there is no invite list.",
  },
  {
    topic: "The two links every published tour gets",
    source: "features.html + UPLOAD-CONTRACT.md",
    fact:
      "Publishing gives two links. The BRANDED link carries the agent's card, accent colour and " +
      "contact form — the one to text, post or print. The UNBRANDED link has no name, no phone " +
      "number, no contact form and no Rendprop branding — that is the one an MLS virtual-tour " +
      "field asks for (most MLSs fine for branding in that field). Copy either from the tour's " +
      "Share sheet in the app. MLS rules differ by market, so the agent should check theirs.",
  },
  {
    topic: "How AI-generated content is disclosed",
    source: "description.txt + support.html + UPLOAD-CONTRACT.md",
    fact:
      "Every AI photo edit is labelled \"Virtually staged\" on the published tour, and the " +
      "untouched original is published right beside it so anyone can compare. The AI aerial " +
      "intro is always disclosed as AI-generated, never presented as real drone footage. A " +
      "listing's Compliance section lists every AI asset with its disclosure and can export the " +
      "full audit log for a broker.",
  },
  {
    topic: "AI Photo Studio — what it does",
    source: "description.txt + features.html",
    fact:
      "One tap each for: a blue sky, a twilight sky, a green lawn, a tidied (decluttered) room, " +
      "or added furniture (virtual staging). A free-text \"custom\" edit is also available, and " +
      "an \"improve my prompt\" button sharpens rough wording first. Every edit is a COPY — the " +
      "untouched original photo is always kept and published alongside it, never replaced.",
  },
  {
    topic: "Reels — what they do",
    source: "description.txt + features.html",
    fact:
      "Reels turn a handful of a listing's photos into a short vertical video: each photo " +
      "becomes a gliding camera move, stitched together with a voiceover (record your own, or " +
      "let an AI voice read a script) and word-by-word captions that land on the beat. Exports " +
      "in both 9:16 and 16:9 for Instagram, TikTok, YouTube and the MLS.",
  },
  {
    topic: "Aerial intro — what it does",
    source: "description.txt + features.html",
    fact:
      "The aerial intro is an AI-generated establishing shot — 4 to 8 seconds, in the time of " +
      "day and camera move the agent picks — that lifts off an exterior photo already in the " +
      "listing. It is optional and always disclosed as AI-generated, never real drone footage, " +
      "so a viewer's trust in the rest of the tour stays intact.",
  },
  {
    topic: "Floor plans — what they do",
    source: "description.txt + features.html + support.html",
    fact:
      "Scan a room in 3D with RoomPlan by walking it with the phone — this needs an iPhone with " +
      "a LiDAR sensor. Any other iPhone can instead upload a floor plan the agent already has " +
      "(PDF or image) and skip the scan entirely. Either way the output is clean and labelled: " +
      "rooms, dimensions and furniture footprints, no clutter.",
  },
  {
    topic: "Filming tips for a good walkthrough",
    source: "features.html + SettingsView's own capture guidance",
    fact:
      "Walk at a normal, steady pace — no fast spins, turn the way you would showing a friend " +
      "around. Hold the phone upright at chest height and keep it level. Turn the lights on and " +
      "open the blinds first. The app guides filming at a wide 0.5× lens so rooms read as rooms, " +
      "not closets. One continuous take, up to about ten minutes, ending on the best shot — the " +
      "engine enhances real footage, it never invents a room, window or piece of furniture.",
  },
  {
    topic: "Not only homes — other business types",
    source: "description.txt + INDUSTRY-LOGIC.md + features.html",
    fact:
      "Rendprop ships modes for real estate, event venues, restaurants and bars, retail stores, " +
      "and gyms and studios (plus a general \"other business\" mode). Switching the business " +
      "type — from the menu at the top-left of Home — re-themes the whole app: the fields to " +
      "fill in, the words on screen, the area tags in the room tagger, and the sample tour.",
  },
  {
    topic: "Enquiries / leads",
    source: "features.html",
    fact:
      "Every branded tour ends with a contact form (name, phone, email, plus fields that fit " +
      "the business). Enquiries never get resold — they land in the app's own Leads list, per " +
      "listing and all together, with the date the visitor asked for.",
  },
  {
    topic: "Managing or cancelling a subscription",
    source: "support.html + description.txt",
    fact:
      "Subscriptions are sold and billed by Apple, so they are managed through Apple: in the " +
      "app, Settings → Plan & usage → \"Manage subscription\" opens the same sheet as the " +
      "device's own Settings → your name → Subscriptions → Rendprop. Cancelling stops the NEXT " +
      "renewal — the plan keeps working until the end of the period already paid for. Deleting " +
      "the app does NOT cancel a subscription. Refunds are handled by Apple at " +
      "reportaproblem.apple.com, never by Rendprop directly.",
  },
  {
    topic: "Free trial",
    source: "description.txt",
    fact:
      "Every plan starts with a 7-day free trial, available once per Apple ID. Any unused " +
      "portion of a trial is forfeited if the person buys a subscription before it ends.",
  },
  {
    topic: "Deleting an account",
    source: "support.html + review_notes.txt",
    fact:
      "In the app: Settings → \"Your data\" → \"Delete account\" (this is offered whether the " +
      "person is signed in or not). It removes the server account, unpublishes every shared " +
      "tour link, and deletes listings, tours, uploaded media and leads from the server, then " +
      "wipes local data on the phone. It also works for guests who never signed in (a local " +
      "wipe only, since there is no server account to remove). Deleting the account does NOT " +
      "cancel an App Store subscription — cancel that with Apple separately.",
  },
  {
    topic: "What the app needs to run",
    source: "support.html",
    fact:
      "An iPhone on iOS 16 or later. The app is free to download. Scanning a room into a floor " +
      "plan needs an iPhone with a LiDAR sensor; on any other iPhone, upload a plan instead.",
  },
  {
    topic: "A render or upload failed",
    source: "support.html",
    fact:
      "Uploads resume on their own, so a dropped connection mid-upload is usually fixed by " +
      "reopening the app on a better connection. A job that fails gives its monthly allowance " +
      "back automatically. If the same walkthrough fails twice, contact support with the " +
      "listing name and roughly when it was tried.",
  },
  {
    topic: "Your content and privacy",
    source: "description.txt + support.html",
    fact:
      "Videos and photos stay the agent's own. Rendprop never uses them for its own marketing, " +
      "and never to train AI models, without written permission. The app only records spaces " +
      "the person has the right to record and publish. There is no in-app feed and no way to " +
      "browse anyone else's content.",
  },
  {
    topic: "Contacting support",
    source: "support.html + SettingsView's own \"Contact support\" row",
    fact:
      "A person answers support email directly — there is no ticket bot. It is the same address " +
      "as the app's own Settings → \"Contact support\" row. Billing and refunds go through Apple " +
      "at reportaproblem.apple.com; everything else about the app or a plan goes to support.",
  },
];

/**
 * Monthly allowances by plan — COUNTS ONLY, never a price. Source:
 * description.txt "WHAT A PLAN INCLUDES". Seats is Team-only (solo/pro seat
 * count is implicitly 1 and not stated in copy, so it is left out rather than
 * guessed).
 */
export const PLAN_ALLOWANCES: Array<{
  plan: string;
  renders: number;
  photoEdits: number;
  reels: number;
  aerials: number;
  seats?: number;
}> = [
  { plan: "Starter", renders: 8, photoEdits: 150, reels: 8, aerials: 2 },
  { plan: "Pro", renders: 25, photoEdits: 300, reels: 20, aerials: 6 },
  { plan: "Team", renders: 80, photoEdits: 600, reels: 40, aerials: 15, seats: 3 },
];

/** One line per plan, e.g. "Pro — 25 tour renders, 300 AI photo edits, 20 reels, 6 aerial intros a month." */
function allowanceLine(a: (typeof PLAN_ALLOWANCES)[number]): string {
  const seats = a.seats ? `, ${a.seats} seats` : "";
  return `${a.plan} — ${a.renders} tour renders, ${a.photoEdits} AI photo edits, ${a.reels} reels, ` +
    `${a.aerials} aerial intros${seats} a month.`;
}

/**
 * The whole knowledge base, formatted as one block of plain text ready to
 * paste into the system prompt. Deterministic order (declaration order) so
 * the prompt — and its token count — never shifts between requests.
 */
export function knowledgeBlock(): string {
  const facts = KNOWLEDGE.map((e) => `• ${e.topic}: ${e.fact}`).join("\n");
  const allowances = PLAN_ALLOWANCES.map(allowanceLine).join(" ");
  return [
    facts,
    "",
    "• Plan allowances (NEVER state a price — every price comes from the App Store, never from " +
      "you): " + allowances + " Every plan includes a 7-day free trial, once per Apple ID. For " +
      "the current plan, this month's usage, or any price, tell the user to open Plan & usage.",
  ].join("\n");
}
