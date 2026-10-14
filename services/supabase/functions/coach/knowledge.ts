// coach — the customer-service knowledge base.
//
// Facts are drawn from the documented sources below or the actual application
// contract/source, named on each entry. Keep these facts aligned with their
// sources rather than carrying forward stale account or publication claims:
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
  /** Documentation or implementation source, for anyone auditing drift. */
  source: string;
  fact: string;
}

export const KNOWLEDGE: KnowledgeEntry[] = [
  {
    topic: "How Rendprop works",
    source: "description.txt",
    fact:
      "Start a home with its address and details. Add landscape property photos, edit from Original if needed, review and select the versions, make and review a landscape property video, then Publish and share the website. Recording/importing a slow, steady walkthrough is optional. These are separate tools; one walkthrough does not automatically produce every asset. Photo reels use simulated AI camera motion or disclosed still-photo motion, not real drone footage or a measured 3D reconstruction. Publishing creates branded and unbranded property links; available branded contact forms send enquiries to the app.",
  },
  {
    topic: "Signing in — what needs an account",
    source:
      "GPT-AGENT-BRIEF.md §2 + FlythroughDetailView.swift publishNow/FeatureSessionAction",
    fact:
      "Local recording and saved photo work can remain on the phone. Cloud publishing and online AI tools require an identified account, an internet connection and the required AI consent/access. Sign in with Apple opens or adopts the account; a guest/anonymous session cannot use paid AI or publish until sign-in. Do not describe Apple sign-in as optional for those online tools.",
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
      "Disclosure describes the actual effects: virtually staged, digitally decluttered, other AI edits, AI aerial/reel motion or still-photo motion. Retained sources and saved versions support comparison; do not claim every edit is staging or that an unverified original is always available. Staged/custom previews require comparison approval before listing/reel/platform use. A label, approval or automated check is not a guarantee that fixed features are unchanged or that every MLS accepts it. Review against the source and follow local broker/MLS requirements.",
  },
  {
    topic: "AI Photo Studio — what it does",
    source: "description.txt + features.html",
    fact:
      "Start each new edit or staging style from the Original tab. Choose Sky, Twilight, Lawn, Declutter or virtual staging, or type Ask anything instructions. Updated staging choices are Modern, Rustic, Minimalist and Contemporary; retained Scandinavian versions keep their historical style. Use the choices actually shown on the installed app. Decluttered and Staged are finished-result tabs for review, listing selection and sharing; earlier styles remain saved when another style is created. Custom requests may ask one clarification before generation. Changes are saved as separate copies/versions; basic Enhanced is a local brightness/color/sharpness copy, not virtual staging. Original, saved edits and the listing-selected version can differ. Use the comparison/review flow for staged/custom outputs; inspect structure, doors, finishes and property condition before sharing. Ask AI is text-only and cannot visually approve an edit.",
  },
  {
    topic: "Reels — what they do",
    source: "description.txt + features.html",
    fact:
      "Make a video uses reviewed photos for Listing landscape 16:9 or Social media portrait 9:16. Automatic arranges scenes and chooses gentle movement; four optional motion presets include Fly-through. Each generated shot is five seconds and consumes one applicable generated-shot allowance, not one whole finished-video allowance. AI motion does not prove room-to-room geometry. Review the actual crop and finished output; no platform acceptance is certified. Optional voice, music, text and transitions start as choices, not requirements. A saved operation is not an accepted server job: Check status before generating again. Only an acknowledged saved server job can continue after closing the app or locking the phone; reopen Make a video to refresh it without regeneration. Resume saved video is available only when the returned job explicitly permits it, retaining completed shots. Older device-owned batches and exports may pause in the background and must use their displayed recovery action; never promise durable background completion for those. Eligible disclosed saved-photo motion is different from an AI clip.",
  },
  {
    topic: "Aerial intro — what it does",
    source: "LaunchFeatureAvailability.swift + ai-video Aerial launch gate (build 72)",
    fact:
      "Aerial intro is Coming soon for launch; no launch plan includes new Aerial generation. " +
      "Previously saved clips and already accepted jobs remain available. Photos, reels and " +
      "published listings work without an aerial intro. Any existing AI aerial clip must be " +
      "reviewed and disclosed as AI-generated, never described as real drone footage.",
  },
  {
    topic: "Measurements and floor plans — current availability",
    source:
      "FlythroughDetailView.swift ListingToolboxGrid + RendpropApp.swift Home tiles (build 57) + support.html",
    fact:
      "Measurements, 3D floor plans and 3D walkthroughs are Coming soon. The Measurements card " +
      "on Home and in each listing's toolbox does not open yet, no plan includes it, and nothing " +
      "else in the app waits on it: photos, AI Photo Studio, reels and published " +
      "listings work without any measurements. When measurements ship, the user will be able to " +
      "enter room dimensions, draw measured outlines and upload an existing PDF or image; app " +
      "calculations will not be a certified survey or appraisal and will not set advertised " +
      "living area. The separate TestFlight Lab keeps local capture tests available; it is " +
      "not the normal listing workflow. The ordinary listing detail no longer has a Plan your " +
      "video entry; agency and Studio capture planning remain available in their own workflows.",
  },
  {
    topic: "Filming tips for a good walkthrough",
    source: "features.html + SettingsView's own capture guidance",
    fact:
      "Walk at a normal, steady pace, keep the phone level at chest height, turn lights on and open blinds. Use a wide lens when available and avoid fast spins. Capture one continuous walkthrough, up to the app's displayed limit, ending on the best shot. The walkthrough uses captured footage; this does not guarantee the accuracy of separate AI-generated photo/reel/aerial outputs.",
  },
  {
    topic: "Not only homes — other business types",
    source: "description.txt + INDUSTRY-LOGIC.md + features.html",
    fact:
      "Rendprop ships modes for real estate, event venues, restaurants and bars, retail stores, " +
      'and gyms and studios (plus a general "other business" mode). Switching the business ' +
      "type — from the menu at the top-left of Home — re-themes the business-specific fields and words: the fields to " +
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
      'app, Settings → Plan & usage → "Manage subscription" opens the same sheet as the ' +
      "device's own Settings → your name → Subscriptions → Rendprop. Cancelling stops the NEXT " +
      "renewal — the plan keeps working until the end of the period already paid for. Deleting " +
      "the app does NOT cancel a subscription. Refunds are handled by Apple at " +
      "reportaproblem.apple.com, never by Rendprop directly.",
  },
  {
    topic: "Free trial",
    source: "Subscription-confirmed trial policy (2026-10-01)",
    fact:
      "Eligible customers can start a 7-day introductory trial by choosing a subscription " +
      "and confirming it in Apple's purchase sheet. Apple determines eligibility; creating " +
      "an account or installing Rendprop does not start that trial. The selected plan's " +
      "allowances apply after confirmation, subject to the shared trial AI limit and trial availability. It renews at the displayed subscription price " +
      "unless cancelled through Apple. Existing previously granted trial windows keep their " +
      "original end date. Plan & usage shows the current access and Apple's offer terms.",
  },
  {
    topic: "Deleting an account",
    source: "SettingsView.swift deleteAccount + me/index.ts handleDelete",
    fact:
      'In the app: Settings → "Your data" → "Delete account". Guests using an anonymous ' +
      "session also have a server account: this is not a local-only wipe. Account deletion " +
      "requests removal of that account and its solo-workspace data; the phone clears its " +
      "local data after server confirmation. Shared-team data is not all deleted with your " +
      "account, and server cleanup may remain pending. Deleting the account does NOT cancel " +
      "an App Store subscription — cancel that with Apple separately.",
  },
  {
    topic: "What the app needs to run",
    source: "support.html",
    fact:
      "An iPhone on iOS 16 or later. The app is free to download. No LiDAR is needed for " +
      "anything the app offers today. Measurements, 3D floor plans and 3D walkthroughs are " +
      "Coming soon; LiDAR capture experiments belong to the separate TestFlight Lab.",
  },
  {
    topic: "A render or upload failed",
    source: "support.html",
    fact:
      "Open the affected project/tool and use its displayed saved recovery action. For a saved video operation, Check status checks the same operation before any new request; a saved operation alone is not proof of server acceptance. Resume saved video requires the acknowledged returned job to permit it. Older local jobs may show Recover request, Finish saved clips or Continue saved reel; follow the displayed action to preserve their sources/options. A quality refusal may offer one explicit safer retry or saved-photo motion. For an upload, reconnect and keep the saved file until it completes. Review access/facts conflicts before trying again. Plan & usage shows allowances and shared AI limits; do not promise every failure is refunded, every retry is free or a completion time. Contact support if the available recovery action still fails.",
  },
  {
    topic: "Your content and privacy",
    source: "description.txt + support.html",
    fact:
      "Videos and photos stay the agent's own. Rendprop never uses them for its own marketing, " +
      "and never to train AI models, without written permission. The app only records spaces " +
      "the person has the right to record and publish. There is no public in-app feed. " +
      "Personal accounts keep their own listings; a team owner can switch authorized agent " +
      "libraries, while agents cannot browse teammates' listings.",
  },
  {
    topic: "Contacting support",
    source: 'support.html + SettingsView\'s own "Contact support" row',
    fact:
      "A person answers support email directly — there is no ticket bot. It is the same address " +
      'as the app\'s own Settings → "Contact support" row. Billing and refunds go through Apple ' +
      "at reportaproblem.apple.com; everything else about the app or a plan goes to support.",
  },
];

/**
 * Monthly allowances by plan — COUNTS ONLY, never a price. Source:
 * description.txt "WHAT A PLAN INCLUDES", which mirrors plan_entitlements as
 * migration 0044 (2026-09-12) sizes it — tests/invariants.sql pins the table.
 * Seats is Team-only (starter/pro seat count is implicitly 1 and not stated in
 * copy, so it is left out rather than guessed).
 */
export const PLAN_ALLOWANCES: Array<{
  plan: string;
  renders: number;
  photoEdits: number;
  reels: number;
  aerials: number;
  seats?: number;
}> = [
  { plan: "Starter", renders: 4, photoEdits: 100, reels: 30, aerials: 2 },
  { plan: "Pro", renders: 10, photoEdits: 200, reels: 60, aerials: 4 },
  {
    plan: "Team",
    renders: 25,
    photoEdits: 400,
    reels: 150,
    aerials: 8,
    seats: 2,
  },
];

/** Aerial counters remain internal compatibility data, not a launch allowance. */
function allowanceLine(a: (typeof PLAN_ALLOWANCES)[number]): string {
  const seats = a.seats ? `, ${a.seats} seats` : "";
  return `${a.plan} — ${a.renders} tour renders, ${a.photoEdits} AI photo edits, ${a.reels} generated five-second shots${seats} a month. ` +
    "Aerial intro is Coming soon.";
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
    "• Property websites: Classic is included. One verified per-property website purchase unlocks Signature Estate and Coastal Luxe for that property; switching between the two does not require another purchase. The app shows current StoreKit price and availability. Purchases can be unavailable while the product or server setting is off. Preview uses already-published content, is marked Preview/noindex and has no enquiry form; it neither publishes nor changes the live design. Explicit Publish/Republish is separate. Sites provide Home, Gallery, Location and Contact, the chosen landscape property video, and an optional recorded walkthrough. Never invent nearby businesses, promise automatic MLS/Zillow syndication or guarantee MLS acceptance.",
    "",
    "• Plan allowances (NEVER state a price — every price comes from the App Store, never from " +
    "you): " + allowances +
    " These are current catalog examples, not a replacement for the verified account snapshot. Existing funded/grant windows retain their own caps. Use Plan & usage for actual remaining generated-shot/edit allowance and shared AI capacity; never promise all meter maxima can be used together. An eligible trial can have 20 photo edits, 20 generated shots and a shared usage ceiling, but only its effective snapshot grants access. An eligible 7-day introductory trial starts only after the " +
    "user selects a subscription and confirms Apple's purchase sheet, never on signup. For " +
    "the current plan, this month's usage, or any price, tell the user to open Plan & usage.",
  ].join("\n");
}
