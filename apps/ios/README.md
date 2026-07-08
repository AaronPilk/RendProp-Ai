# ROAM iOS App

Native Swift + SwiftUI. iOS 16+, iPhone 11+ performance floor. Full spec: Master Build Prompt Parts 4, 34, Appendix B/D.

## Module map (Part 4.1)

| Module | Key tech | Notes |
|---|---|---|
| Onboarding & auth | Sign in with Apple, email/phone OTP | JWT in Keychain |
| Home / My Listings | SwiftUI list, status chips | Draft/Uploading/Processing/Ready/Expired |
| New Listing | MapKit address autocomplete | or listing-URL import |
| **Capture** | AVCaptureSession + CoreMotion | The crown jewel — see below |
| Import | PHPicker/Files | drone-clip flag skips stabilization |
| Room tagging | live buttons + post scrubber | timestamps → chapters |
| Review & submit | duration-band pricing UI | tier selector, credit balance |
| Render status | APNs push on ready | step labels |
| Flythrough detail | WKWebView player embed | share/QR/embed/analytics |
| Leads inbox | one-tap call/text/email | CRM sync indicator |
| Billing | StoreKit 2 | consumable credits + auto-renew subs |
| Settings | brand kit, account deletion | App Store requirement |

## Capture non-negotiables (Part 4.2)

- 4K/60 when thermals allow; fall back 4K/30 → 1080p/60; store true fps in metadata
- `preferredVideoStabilizationMode = .cinematicExtended`
- **Gyro/IMU sidecar** time-synced via CMSampleBuffer PTS — the #1 quality lever (enables Gyroflow-grade stabilization). Do not skip.
- 60fps guidance overlays: level bubble, pace metronome + haptics, light check, framing grid, live room-tag buttons
- Interruption-safe: never lose a recording (calls, backgrounding, low storage)
- Resumable background upload: tus/multipart → signed R2 URL, background URLSession, survives app kill + reboot, cellular warning at large sizes

## Acceptance (Part 4.9)

Overlays hold 60fps on iPhone 12+ · zero lost recordings in 100-interruption soak · upload survives kill/network-loss/reboot · cold start < 1.5s · VoiceOver/Dynamic Type/dark mode complete · zero IAP-compliance rejection risks.

## Getting started

Xcode project not yet generated. Next step: `xcodegen` or manual Xcode project with capabilities per Appendix D (Sign in with Apple, APNs, Background Modes, Associated Domains, IAP) and all Info.plist purpose strings.
