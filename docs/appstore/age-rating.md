# Age rating questionnaire — exact answers → 4+

App Store Connect → your app → **Age Rating** → Edit. Answers valid as of **2026-09-05**,
against the questionnaire Apple ships today (the one that asks for a rating per region and
adds the capability questions at the end). Target and outcome: **4+**.

`docs/APP-STORE-CHECKLIST.md` §5 says "answer None/No to everything" — that is still
almost right, but three questions now have answers that need a sentence of reasoning
rather than a reflex "No". They are marked ⚑ below.

---

## Content questions

| Question | Answer |
|---|---|
| Cartoon or Fantasy Violence | None |
| Realistic Violence | None |
| Prolonged Graphic or Sadistic Realistic Violence | None |
| Profanity or Crude Humor | None |
| Mature/Suggestive Themes | None |
| Horror/Fear Themes | None |
| Sexual Content or Nudity | None |
| Graphic Sexual Content and Nudity | None |
| Alcohol, Tobacco, or Drug Use or References | None |
| Medical/Treatment Information | None |
| Simulated Gambling | None |
| Gambling (real money) | No |
| Contests | No |

Note on the restaurant mode: a listing can describe a venue that has a bar, and the app's
amenity chips include "Full Bar" / "Happy Hour". That is a **fact about a commercial
property being advertised**, not depiction or encouragement of alcohol use, and it is
entered by the user about their own business. It does not trigger the alcohol question —
the same way a real-estate app naming a wine cellar does not.

## Capability questions

| Question | Answer | Why |
|---|---|---|
| ⚑ **Unrestricted Web Access** | **No** | The app embeds a `WKWebView` only to play Rendprop's own tour pages. `PlayerWebView`'s navigation delegate intercepts every `linkActivated` action and hands the URL to `UIApplication.shared.open`, so a tapped link leaves for Safari instead of navigating inside the app. There is no address bar, no in-app browser, and no way to reach an arbitrary site without leaving Rendprop. |
| ⚑ **User-Generated Content** | **No** | There is no feed, no profiles to browse, no comments, no ratings, and no user-to-user messaging. A user sees their own listings, tours, and photos, plus contact-form submissions addressed to them — an inbox, not a public surface. Tours are published as web pages and viewed **outside** the app, by people who were sent the link. Nothing another Rendprop user creates can appear in your copy of the app. |
| ⚑ **In-app purchases** | **Yes** | Auto-renewable subscriptions (Starter / Pro / Team, monthly or yearly). This does not change the rating; it does put the "In-App Purchases" badge on the listing. |
| Messaging / chat between users | No | None exists. |
| Advertising | No | The app shows no ads and contains no ad SDK. |
| Age assurance / parental controls needed | No | Nothing in the app is age-restricted. |
| Loot boxes / randomised items | No | — |
| Location-based features that share location with other users | No | Location is used to fill in the listing's own address; it is published as part of the listing the user chooses to publish, never shared with other Rendprop users. |

## AI-generated content

Apple's questionnaire has no age-rating question for AI content, and generative features do
not by themselves raise the rating. Rendprop's AI is constrained to property presentation
(sky, lighting, lawn, decluttering, furniture, aerial establishing shots); it does not
generate people, text conversations, or open-ended imagery from a free prompt except in the
"Custom AI edit" field, which edits the user's own photo of their own space. Disclosure is
handled in the product (see `docs/appstore/review-notes.md`), not here.

## Result

**4+ in every region.** If App Store Connect lands on anything higher, one of the answers
above was mis-clicked — the most likely culprits are Unrestricted Web Access and
User-Generated Content.
