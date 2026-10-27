# Exact 1.0.5 App Store copy reconciliation

`catalog_copy.py` is limited to Rendprop app `6808982413`, iOS version
`1.0.5`, and ten monthly subscription localizations. It reads native
`Products.swift` and the local candidate metadata before making a plan. It
also verifies an exact non-preserved USA price row and an open seven-day
introductory offer for every product. The existing Max, Ultra and Team price
rows are scheduled for **30 October 2026**; the script does not make them
effective sooner or change existing subscriber treatment.

```sh
python3 tools/asc/catalog_copy.py plan
```

This command makes authenticated GET requests only. The current plan has 12
copy resources to change: ten subscription en-US display names/descriptions,
the 1.0.5 listing description/promotional text/What's New, and the 1.0.5 App
Review notes. It never changes prices, products, territories, offers, builds,
screenshots, staging or release type. Run `plan` again immediately before
applying because Apple state can change.

The candidate copy promises 60/120/250/600 monthly credits, plus 100 credits
for each extra Team seat through nine seats. **Do not apply it while the
deployed monthly credit catalog or combined serving policy is disabled.**
First verify the deployed `credit_monthly_catalog`,
`team_paid_seat_variants`, `credit_combined_budget`, exact USA/USD funding
schedules and a sandbox purchase/renewal against the signed product. The
native paywall and the review notes must agree on whether Team 4-9 is sold.
The script refuses review notes that say those variants are unavailable if
the native allowlist has opened them, and vice versa.

After that readback and the final source/build alignment, the explicit
write command is:

```sh
python3 tools/asc/catalog_copy.py apply \
  --confirm-app-id 6808982413 \
  --confirm-version-id c15af3a3-8cf3-44ef-93ca-6d0d1777d1e3 \
  --confirm-credit-activation
```

Each changed resource is PATCHed once and GET read back before the next one.
An uncertain result stops the run; inspect Apple before retrying. Repeated
plans and applies are idempotent after readback. Existing approved Max, Ultra
and Team localization changes require Apple review; their old public text
continues to display until Apple approves the new copy.

The App Review screenshot is a separate field on each subscription. Capture
the actual TestFlight purchase UI on a physical phone after the scheduled
prices are effective. The phone's native supported iPhone PNG dimensions are
accepted by `asc.py`, without resizing. The present `paywall.png` is denied
because it shows the retired plan names and yearly picker. The new Pro product
and any Team-seat variants opened for sale need their review screenshots before
they can be submitted. Follow [the capture notes](../../docs/appstore/iap-review/README.md).
