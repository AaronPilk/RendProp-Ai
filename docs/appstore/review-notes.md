# App Review notes — next 1.0.5 candidate

The text below mirrors [review_notes.txt](metadata/en-US/review_notes.txt), the file the uploader reads by default. It is an **unsubmitted source draft**. At the 28 October readback, App Store Connect still held older review notes with Apple-only sign-in, and its `demoAccountRequired` value was false. Neither a funded owner demo account nor an expired-subscription demo account had been rehearsed on the exact public build. The two consumable production gates and Team 4–9 gates were off. Do not apply the metadata or review helper until the release conditions in [submission-metadata-readiness-20261028.md](submission-metadata-readiness-20261028.md) are met.

If Team 4–9 is activated and included in the exact build, use [review_notes_team_seats.txt](metadata/en-US/review_notes_team_seats.txt) only after its separate screenshots, funding and Sandbox device route are verified. Apple approval is required before the public gate opens. Its current wording describes a conditional route and must be reconciled with the final gate state. Do not place reviewer credentials in Git. Enter the paid owner account in App Store Connect's private App Review Information. After the source notes are applied, add the expired-subscription account details directly in that private UI as the last review-note edit; a later `review apply` would replace the notes field.

---

Rendprop helps agents prepare property photos, make videos, publish a property website and manage enquiries.

ACCESS: The entry screen offers Sign in with Apple and Sign in with email for an existing account. Email uses a password; there is no email sign-up or guest skip. For paid-feature review, use the provisioned owner credentials supplied privately in App Review Information. A new Apple ID does not inherit that paid workspace. Introduction, Terms, Privacy and help are available before sign-in. Delete account: Account > Settings & plan > Your data.

REVIEW PATH: Home > See it in action opens a hosted sample. For your own listing, choose Home > Get started, enter details and add photos. Review edits before use. A paid owner can publish a website with a landscape Listing video or a recorded/uploaded walkthrough; the walkthrough is optional if a Listing video is selected. Camera capture needs a physical device.

VIDEO AND AERIAL: In a listing, Make a video offers landscape Listing and portrait Social media. Choose photos, framing and optional audio, then review the result. Photo Motion animates photos; it is not drone footage or a 3D tour. Aerial intro can generate an opening from a front exterior photo for eligible paid accounts with consent. Activity shows saved work.

ONE-TIME PURCHASES: Account > Settings & plan > Credits & extra usage shows the workspace balance. An eligible owner/admin sees Add 100 credits only when its funded server gate and StoreKit product are active. This $39.99 U.S. consumable adds nonexpiring credits to that workspace; Check pending purchase recovers interrupted transactions. On a saved listing, Website design shows included Classic and Signature Estate/Coastal Luxe samples; live property previews require publication. Upgrade this property appears only when the property is eligible and the $25 U.S. Luxury Property Website consumable is active. It unlocks both luxury designs for that property, adding no credits or hosting. Both offers are server-gated; when a production gate is off, its purchase control is absent. Previews and Sandbox purchases do not establish a public upgrade. Apple shows localized prices before confirmation.

SUBSCRIPTIONS: StoreKit 2 has four monthly products: Pro (60 credits, one seat), Max (120, one), Ultra (250, one) and Team (600, three). U.S. target prices are $29.99, $49.00, $99.99 and $249.99; Apple's current Product.displayPrice controls the charge, including Team's scheduled price change. Annual products are not offered. Team 4–9-seat variants are prepared but gated and unavailable in this default review path. An eligible seven-day Apple trial permits one draft listing and limited AI photo edits. Video, aerial and website publication require the first paid renewal; full allowances begin afterward. Restore purchases and Manage subscription are at Account > Settings & plan > Plan & usage. Apple manages cancellation; deleting the app or account does not cancel a subscription.

AI AND PRIVACY: Consent names providers before media is sent; revoke it in Your data > AI processing. Review altered media; exports carry disclosure. Ask AI uses text context, not a screenshot.

NOT IN THIS BUILD: Floor plans, measurements and 3D tours are Coming soon. No RoomPlan/LiDAR or experimental spatial capture is reachable or sold in a plan.

FILES AND DELETION: Share everything exports eligible local files and disclosure notes, not cloud-only files. Account deletion can retain shared content for other members.

Contact: aaron@pilk.ai
