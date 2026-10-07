# App Store screenshots — current 1.0.3 set

The 2 October 2026 plan contains **five representative native screenshots**, at
**1320 × 2868 portrait**, RGB, each below 8 MiB. These use Apple's
`APP_IPHONE_67` display type. Rendprop is iPhone-only; no iPad set is required.
[Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).

| Order | Frame | Headline |
| --- | --- | --- |
| 1 | `02-every-tool.png` | Listing content in one place |
| 2 | `03-every-business.png` | Venues, gyms and restaurants too |
| 3 | `05-one-link.png` | One link. Leads land in the app. |
| 4 | `08-social-reel.png` | Photos become a social reel |
| 5 | `09-start-in-a-minute.png` | Add the home. Film it. Share it. |

The retained native pixels came from actual approved screenshots, checked
against App Store Connect's original checksums. Captions were recomposed from
[plan.json](plan.json). No camera capture, generation, purchase or publishing
was performed for the composition. The listing and leads are fictional samples.
The five final files and their order, hashes and dimensions are recorded in the
private 1.0.3 release manifest. Apple readback verified all five assets in this
order with matching checksums, dimensions and `COMPLETE` delivery states. They
are attached to the submitted 1.0.3 (42) version; released 1.0.1's nine assets
were verified unchanged. See the [release receipt](../../releases/APPSTORE-42-20261002.json).

The old nine-frame 1.0.1 set is historical. Three hosted-page captures and the
old Photo Studio capture are omitted because their UI/disclosures no longer
represent the release. Never upload the old paywall review screenshot as a
marketing frame: its allowances are outdated. Approved subscription assets are
not changed in this release.

## Capture and composition

Native capture uses [StoreShots.swift](../../../apps/ios/RendpropUITests/StoreShots.swift).
The bridge script historically targeted `~/Rendprop AI/repo`; inspect the actual
checkout, simulator, generated project and scheme before invoking it. Test-only
sample fixtures are simulator UI aids, not evidence of physical camera quality.
Do not replace missing screenshots with mock product UI.

Compose retained actual captures with the repository tool:

```bash
python3 tools/screenshots/compose.py --src <actual-captures> --plan docs/appstore/screenshots/plan.json --out <private-final-set>
python3 tools/screenshots/compose.py --src <actual-captures> --plan docs/appstore/screenshots/plan.json --out <private-final-set> --check
```

Review every final image visually and verify RGB dimensions, byte size, readable
copy and representative native pixels. The first frame shows Home and tools.
Keep the explicit plan order; gaps in historical filenames do not create
missing frames.

## Upload boundary

The launch-era `asc.py screenshots apply` can select another editable version
and alter review staging. The current release uses an exact-version helper for
only the new 1.0.3 en-US set. It protects released 1.0.1 asset IDs, journals every
mutation, stops on uncertain results and verifies five ordered checksums and
`COMPLETE` delivery states. Do not run the broad launch bridge to refresh these
screenshots. See [release target caution](../../../tools/asc/README.md#release-target-caution).
