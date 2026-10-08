# Account-first access — next public review draft

This is an unsubmitted draft for the account-first source follow-up. It does not change the published build 42 metadata, the submitted build 42 review notes, subscription products or an Apple review state. Internal **1.0.4 (50)** is available to the existing Rendprop team, verified on 8 October 2026 at 10:30:56 UTC; see the [delivery receipt](../releases/TESTFLIGHT-50-20261008.json). Internal availability does not select or submit a public build. Populate the next public version/build and its physical-phone validation evidence before submission.

## Proposed access explanation

Rendprop is an account-based property media workspace. The initial screen requires Continue with Apple to create or sign in to a Rendprop account before business setup, the dashboard, capture tools, publishing or subscription actions. The same account owns the person's cloud listings, hosted pages, AI usage, Studio access and team membership. The Apple button handles both a new account and a returning account; there is no separate password form or guest-skip button.

New account creation does not activate a paid plan or a funded AI trial. StoreKit purchases require a separate explicit user action and the existing verified funding and workspace checks. Existing subscriptions retain their receipt-processing and recovery paths. No subscription price, allowance or trial configuration is changed by the entry screen.

An already signed-in identified account can use its saved work offline. A new sign-in needs connectivity. Previously captured guest work is retained for the existing verified account-transfer flow; displaying the entry screen does not erase it. Cancelling Apple sign-in leaves the entry screen visible. Signing out returns to that screen.

Account deletion remains available after sign-in in Settings > Your data > Delete account. Terms, Privacy and help must remain accessible from the entry screen before account creation. Shared property pages continue to be publicly accessible on the website; they do not require a website account to view.

## Review consideration

Earlier source and review records document a registration-gate rejection. [Apple guideline 5.1.1(v)](https://developer.apple.com/app-store/review/guidelines/#data-collection-and-storage) ties mandatory registration to significant account-based features and requires in-app deletion where accounts can be created. This draft explains the current account-based workspace behavior; it is not an assurance of approval. The reviewer must be able to create an account using the real Apple flow and reach the documented review features. Do not invent a password-based demo credential for an Apple-only client, or present a local mock as a live reviewer account.

Before public submission, verify actual Apple sign-in/cancellation, prior-work recovery, purchase restoration and deletion on a physical iPhone; provide truthful reviewer-access instructions and required access through the supported account/funding process. Internal TestFlight delivery and a simulator preview do not complete those checks.
