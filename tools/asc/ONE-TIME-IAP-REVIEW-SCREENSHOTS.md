# One-time IAP App Review screenshots

Use a genuine **final TestFlight build** on the owner's iPhone. Capture each in-app purchase offer with the exact product, credit or site benefit, Apple price, and purchase action visible. Inspect both PNGs before any upload. A StoreKit simulator fixture is not a substitute for these release screenshots.

Apple requires the IAP review screenshot to show the item offered; it is private to App Review. The API flow is [reserve → PUT → commit → GET](https://developer.apple.com/documentation/appstoreconnectapi/managing-in-app-purchases). The upload attaches the image to the parent IAP, not to its version. It does **not** submit the IAP or app for review.

Save each native, opaque PNG outside the repository. The uploader accepts only the two exact consumable IDs, one per invocation, and never replaces an existing different screenshot. `status` and `plan` make GET requests only; `plan` is the dry run. Capture the digest printed by `plan`, then supply it verbatim to `apply`:

```bash
python3 tools/asc/one_time_iap_review_screenshot.py status --product com.rendprop.app.credits.100
python3 tools/asc/one_time_iap_review_screenshot.py plan --product com.rendprop.app.credits.100 --image '/absolute/path/credits-offer.png'
python3 tools/asc/one_time_iap_review_screenshot.py apply --product com.rendprop.app.credits.100 --image '/absolute/path/credits-offer.png' --confirm-sha256 EXACT_DIGEST_FROM_PLAN

python3 tools/asc/one_time_iap_review_screenshot.py status --product com.rendprop.app.website.premium.property
python3 tools/asc/one_time_iap_review_screenshot.py plan --product com.rendprop.app.website.premium.property --image '/absolute/path/luxury-site-offer.png'
python3 tools/asc/one_time_iap_review_screenshot.py apply --product com.rendprop.app.website.premium.property --image '/absolute/path/luxury-site-offer.png' --confirm-sha256 EXACT_DIGEST_FROM_PLAN
```

`apply` checks the local PNG structure, native iPhone portrait dimensions, SHA-256, and the exact Apple product before reserving. It stages the checked bytes privately, reads the relationship a second time, then uses the existing `asc.upload_asset` helper for the reserved upload. After commit it reads the screenshot by ID and through the exact parent relationship, checking Apple's MD5 and delivery state. Exit 0 means `COMPLETE` or an already complete identical image; exit 3 means Apple has the exact image but is still processing it. In the latter case, use `status` later. If a different or uncommitted screenshot already exists, stop and inspect App Store Connect manually. This tool never deletes or replaces it.

Focused offline contract tests:

```bash
python3 -m unittest -v tools/asc/test_one_time_iap_review_screenshot.py
```
