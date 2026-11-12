# Build 50 account-gate phone check

Build **1.0.4 (50) is AVAILABLE** to the existing Rendprop team, verified by Apple on **8 October 2026 at 10:30:56 UTC**, from `c9cf64e2e34cf6c00bcc7752e4b5569c7258906a`. The [delivery receipt](../releases/TESTFLIGHT-50-20261008.json) binds the uploaded package and exact-source CI. These physical-phone checks have **not** been completed. Upgrade an existing installation without deleting the app or its recordings; use a separate clean test installation for the fresh-user check.

- [ ] Confirm TestFlight shows **1.0.4 (50)** and record the iPhone model/iOS version.
- [ ] On the clean signed-out installation, confirm **Welcome to Rendprop** and the Apple button appear before business setup or Home. There is no Skip or Not now.
- [ ] Cancel Apple sign-in, then try again without connectivity. The account screen stays visible and does not create a guest account.
- [ ] Open Terms, Privacy and help before signing in. Return to the account screen normally.
- [ ] Complete real Apple sign-in. New users finish setup; returning users see their own name, listings and workspace. No trial or purchase sheet opens automatically.
- [ ] Sign out while a listing is open. Private screens close. An invite or private link waits for sign-in and setup; an old upgrade screen cannot cover the account screen.
- [ ] Sign back in to the same account and check saved work. Reopen offline: an already identified account can use local work, while remote work still needs connectivity.
- [ ] On an existing guest installation, complete Apple sign-in without deleting saved data. Check original photos, listings and pending work after transfer; switching personal/team accounts must not expose another account’s open listing.

Real camera/0.5× capture, interruption recovery, Files/Photos delivery and experimental spatial/AR quality still need separate physical-phone acceptance. Previously accepted background uploads may finish behind the account screen. This check starts no paid AI jobs, new subscription or customer email.

For a failure, retain a screenshot, the expected result, failed step, installed build and phone/iOS details.
