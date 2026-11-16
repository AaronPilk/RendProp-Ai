# Internal link pass, 2026-11-16

The "site:rendprop.com \"keyword\"" method applied to the blog: find posts that already talk about a product page's topic but do not link to it, and add one contextual link inside a sentence that is about that topic. Branch `claude/seo-sop-20261112`.

## Rules used

- At most two new links in any post, and never more than five internal links in a post body (the limit `scripts/check-blog-content.mjs` enforces).
- The link wraps words that were already in the sentence. No sentence or paragraph was added to make room for a link, and no boilerplate.
- Only sentences that are about the target's topic. Sentences that describe a bad edit or a mistake were skipped, as were sentences that already carry a link.
- Anchors vary: 80 different anchors across 107 links, and no anchor is used more than five times.
- Strongest matches only: candidates were scored on title, keywords and body mentions, and picked from the top of each list. 104 of 433 posts changed.
- `modified` dates on the posts were left alone. A new link is not a content update.

Scripts used to find, apply and check the links are not in the repo. The same checks are repeatable with `node scripts/check-blog-content.mjs` and the build.

## Counts

| Target | New links |
| --- | --- |
| `/listing-video-from-photos` | 32 |
| `/single-property-website` | 31 |
| `/real-estate-photo-editing-app` | 32 |
| `/pricing` | 6 |
| `/compare` | 4 |
| `/blog/is-ai-virtual-staging-worth-it-for-listings` | 2 |
| **Total** | **107** (in 104 posts) |

The product pages already linked to 2 to 5 related posts each, so no new post links were added to them, apart from `/real-estate-photo-editing-app` now linking to the new staging objections post.

## Click depth

Crawled the static build from `/`. Every URL in `/sitemap-site.xml` is 0 or 1 click from the home page. Every URL in `/sitemap-blog.xml` is within 3 clicks (home, `/blog`, topic page, post): 1 at depth 1, 126 at depth 2, 327 at depth 3. No broken internal links.

The two customer listings in `/sitemap-properties.xml` are not linked from any marketing page. They are customer pages with the agent's name and number, so linking them from the marketing site is an owner decision (see README, known follow-ups).

## Every link added

### `/listing-video-from-photos`

| Post | Anchor |
| --- | --- |
| `/blog/9-16-or-16-9-picking-the-format-for-instagram-tiktok-youtube-and-the-mls` | 9:16 listing video |
| `/blog/adding-video-to-a-real-estate-photography-package-without-a-videographer` | video from the photos you already shoot |
| `/blog/captions-for-a-listing-reel-short-specific-one-call-to-action` | listing reel |
| `/blog/do-i-need-a-videographer-for-a-listing-video` | photo-based video built from the listing photos you already have |
| `/blog/do-listing-videos-help-a-home-sell-faster` | photo-based listing video |
| `/blog/from-photo-shoot-to-posted-reel-on-the-same-day` | vertical social video |
| `/blog/generated-video-is-not-a-recording-explaining-it-to-a-seller` | well-made photo-based video |
| `/blog/how-long-should-a-listing-video-be` | horizontal listing video |
| `/blog/how-many-photos-does-a-listing-video-need` | photo-based video |
| `/blog/how-much-does-a-listing-video-cost` | listing video from the landscape photos |
| `/blog/how-to-create-a-landscape-listing-video-in-rendprop` | listing video that plays on the property page |
| `/blog/how-to-create-a-vertical-social-video-in-rendprop` | vertical video |
| `/blog/how-to-record-a-walkthrough-in-rendprop` | photo-based listing video |
| `/blog/landscape-or-portrait-shooting-photos-for-listing-video-and-social-video` | vertical social video |
| `/blog/listing-page-video-that-does-not-autoplay-why-that-is-the-right-choice` | listing video |
| `/blog/listing-video-for-a-luxury-home-restraint-beats-effects` | luxury listing video |
| `/blog/offering-social-reels-to-agents-the-pitch-and-the-delivery` | vertical video to post the day the listing goes live |
| `/blog/photo-based-listing-video-what-it-is-and-when-it-beats-a-walkthrough` | video built from the still photos of a listing |
| `/blog/pricing-a-listing-video-add-on-as-a-photographer` | photo-based listing video |
| `/blog/recorded-walkthrough-versus-photo-video-when-to-film-the-home-yourself` | photo-based video |
| `/blog/reels-from-vertical-photos-shooting-with-the-format-in-mind` | vertical social video |
| `/blog/repurposing-a-landscape-listing-video-for-vertical-platforms` | 16:9 listing video |
| `/blog/should-a-listing-video-have-music` | photo-based video |
| `/blog/vertical-social-video-for-a-listing-a-nine-step-recipe` | vertical social video for a listing |
| `/blog/video-versus-photos-what-to-do-when-the-seller-wants-both` | listing video on the property page |
| `/blog/what-is-9-16-video` | listing reel |
| `/blog/what-is-a-listing-walkthrough-video` | photo-based video |
| `/blog/what-is-a-photo-based-listing-video` | property video assembled from still photographs |
| `/blog/what-is-a-social-reel-for-a-listing` | short vertical video |
| `/blog/what-is-a-voiceover-for-a-listing-video` | listing video |
| `/blog/word-by-word-captions-why-listing-reels-need-them` | Listing reels |
| `/blog/writing-a-30-second-voiceover-script-for-a-listing-reel` | listing reel |

### `/single-property-website`

| Post | Anchor |
| --- | --- |
| `/blog/a-property-page-that-works-on-a-phone-what-buyers-tap-first` | property website |
| `/blog/a-property-website-in-the-listing-presentation-showing-the-seller-the-li` | live property page |
| `/blog/branded-and-unbranded-listing-links-why-you-need-both` | one property page |
| `/blog/can-a-photographer-send-me-a-property-website-for-my-listing` | property website |
| `/blog/delivering-a-property-website-with-every-photo-shoot` | property website |
| `/blog/directional-signs-qr-codes-and-the-property-page` | property page |
| `/blog/does-a-listing-page-need-a-contact-form` | property website published from Rendprop |
| `/blog/how-much-does-a-single-property-website-cost` | property website from the listing you already built in the app |
| `/blog/posting-the-unbranded-link-versus-the-branded-link-on-social` | full property page |
| `/blog/pricing-changes-and-the-property-page` | single property page |
| `/blog/property-details-that-belong-on-the-page-price-beds-baths-and-square-fee` | property page |
| `/blog/property-page-for-a-new-construction-listing-progress-photos-and-the-fin` | publish the property page |
| `/blog/putting-a-property-website-link-in-your-mls-listing-the-right-way` | Publish the property page |
| `/blog/qr-codes-on-the-yard-sign-and-the-flyer-send-people-to-the-property-page` | branded property page for that exact home |
| `/blog/sending-the-property-page-before-the-showing` | branded property page with the gallery |
| `/blog/single-property-websites-build-buy-or-get-one-with-the-listing` | single-property website |
| `/blog/the-9-150-a-month-you-can-stop-paying-for-single-property-sites` | property website from the same listing |
| `/blog/the-link-in-bio-sending-followers-to-the-property-page` | that listing's property page |
| `/blog/the-property-page-as-the-home-of-the-listing-video` | property page |
| `/blog/what-a-single-property-website-should-include` | single-property website |
| `/blog/what-happens-to-my-listing-page-after-the-home-sells` | property page |
| `/blog/what-is-a-branded-listing-page` | web page for a single property |
| `/blog/what-is-a-property-page-contact-card` | property website Rendprop publishes |
| `/blog/what-is-a-property-page-gallery` | single-property website |
| `/blog/what-is-an-mls-virtual-tour-field` | property website |
| `/blog/what-is-an-unbranded-virtual-tour-link` | property page with a gallery, a listing video and your contact card |
| `/blog/what-is-on-a-rendprop-property-page` | Rendprop property page |
| `/blog/what-is-the-difference-between-a-branded-and-an-unbranded-tour-link` | property website |
| `/blog/where-do-enquiries-from-a-listing-page-go` | property page you publish yourself |
| `/blog/writing-the-property-page-story-section` | property page |
| `/blog/your-contact-card-on-every-listing-page-name-business-number-one-tap` | branded property page |

### `/real-estate-photo-editing-app`

| Post | Anchor |
| --- | --- |
| `/blog/a-photographers-ai-photo-edit-policy-that-agents-will-trust` | Sky, lawn, twilight, decluttering and custom edits |
| `/blog/a-photographers-checklist-before-sending-ai-edits-to-an-agent` | AI edits |
| `/blog/ai-edited-listing-photos-what-to-disclose-and-where` | AI edit in Rendprop |
| `/blog/ai-edits-on-rental-listings-tenants-screenshots-and-expectations` | Virtual staging of an empty unit |
| `/blog/before-and-after-what-an-ai-twilight-edit-changes-and-what-it-should-not` | twilight edit |
| `/blog/can-ai-change-my-listing-photos-in-ways-i-did-not-ask-for` | AI edit |
| `/blog/can-i-use-ai-edited-photos-in-the-mls` | twilight exterior |
| `/blog/decluttered-versus-staged-labelling-two-different-edits` | decluttered and then staged |
| `/blog/delivering-twilight-edits-at-scale` | twilight edit |
| `/blog/describing-ai-edited-photos-in-the-listing-text` | AI edits |
| `/blog/editing-on-the-phone-between-shoots` | AI edits the agent asked for |
| `/blog/green-lawn-edits-fixing-a-brown-yard-honestly` | green lawn edit |
| `/blog/how-to-compare-an-ai-edited-listing-photo-against-the-original` | edited photo |
| `/blog/how-to-review-ai-edits-in-rendprop-and-compare-them-with-the-original` | every AI edit |
| `/blog/is-virtual-staging-allowed-in-listing-photos` | virtual staging |
| `/blog/photo-edits-buyers-notice-five-changes-that-cause-trouble-at-the-showing` | saves each AI edit as a separate version |
| `/blog/rainy-day-listing-photos-and-the-edits-that-fix-them` | blue sky edit |
| `/blog/sellers-and-ai-staging-the-conversation-before-the-listing-goes-live` | add furniture as an AI edit |
| `/blog/snow-on-the-lawn-winter-exterior-photos-that-still-work` | blue sky edit |
| `/blog/the-difference-between-enhancement-and-alteration-in-listing-photos` | Rendprop's AI edits |
| `/blog/twilight-edits-and-misrepresentation-where-the-line-sits` | twilight edit |
| `/blog/twilight-photo-edits-when-they-help-a-listing-and-when-they-look-fake` | AI edit inside an app |
| `/blog/virtual-staging-as-a-photographer-service-labelling-pricing-limits` | Virtual staging |
| `/blog/virtually-staged-the-two-words-that-keep-a-listing-honest` | add furniture |
| `/blog/what-is-a-custom-edit-prompt` | optional AI edits |
| `/blog/what-is-a-decluttering-edit` | decluttering edit |
| `/blog/what-is-a-twilight-photo-edit` | twilight photo edit |
| `/blog/what-is-an-ai-disclosure-on-a-listing-photo` | AI edit |
| `/blog/what-is-photo-history-in-a-listing-app` | sky replacement |
| `/blog/what-should-i-check-before-publishing-an-ai-edited-photo` | three AI edits |
| `/blog/why-every-ai-photo-edit-should-carry-a-disclosure` | twilight exterior and two staged interiors |
| `/blog/writing-the-virtually-staged-note-that-keeps-everyone-honest` | staged photo |

### `/pricing`

| Post | Anchor |
| --- | --- |
| `/blog/ai-generated-aerial-openings-what-they-are-and-what-they-are-not` | current plan features and included usage |
| `/blog/do-i-need-an-account-to-try-a-listing-marketing-app` | Current plan features |
| `/blog/hosting-a-property-page-without-a-web-designer-or-a-monthly-site-tool` | Rendprop pricing page |
| `/blog/property-pages-for-agents-who-list-twenty-homes-a-year` | current plans and prices |
| `/blog/sign-in-with-apple-in-rendprop-what-it-does-and-why` | compare or change plans |
| `/blog/what-is-an-ai-aerial-opening` | Plan features and included usage |

### `/compare`

| Post | Anchor |
| --- | --- |
| `/blog/can-i-use-one-app-for-homes-and-for-my-gym` | whether it has a mode for that business |
| `/blog/how-much-does-a-listing-video-cost` | whatever the app you use charges |
| `/blog/pricing-a-listing-video-add-on-as-a-photographer` | whatever tool builds it |
| `/blog/what-is-a-listing-mode-in-a-marketing-app` | one app for all of them |

### `/blog/is-ai-virtual-staging-worth-it-for-listings`

| Post | Anchor |
| --- | --- |
| `/blog/is-virtual-staging-allowed-in-listing-photos` | ends up as a complaint |
| `/blog/what-is-virtual-staging` | most complaints |
