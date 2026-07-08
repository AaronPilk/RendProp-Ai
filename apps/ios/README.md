# Rendprop iOS App

Native Swift + SwiftUI, iOS 16+, iPhone-only. Phase 1 bring-up per `docs/MASTER-BUILD-PROMPT.md` Parts 4/34 and the Xcode build prompt. **Runs fully offline** — the backend is stubbed (MockAPIClient + Simulate uploads), while camera, gyro logging, media import, and background upload are real.

## Run it on your iPhone

Prereqs: a Mac with **Xcode 15+** and an Apple ID (free tier = 7-day installs; paid dev account = TestFlight).

```bash
cd apps/ios
brew install xcodegen      # once
xcodegen generate
open Rendprop.xcodeproj
```

1. In Xcode: target **Rendprop → Signing & Capabilities** → check **Automatically manage signing** → pick your **Team** (a personal team works). If `com.rendprop.app` is taken, change the bundle id (e.g. `com.pilk.rendprop`).
2. Plug in your iPhone → select it as the run destination → **⌘R**.
3. First run on the phone: **Settings → General → VPN & Device Management → Trust** your developer cert.
4. Grant camera / mic / photos / motion permissions when prompted.

Try the loop: **New Listing → Record now** (watch the level bubble + pace haptics + room tags) → **Review & Submit** (duration-band price) → simulated render → **Flythrough** (the real scroll-scrub player in a WKWebView) → Share.

## What's real vs stubbed

| Real today | Stubbed (Phase 2, behind Config flags) |
|---|---|
| 4K/60 capture, cinematicExtended stabilization, thermal fallback | Sign in with Apple (`enableAuth`) |
| 100Hz gyro sidecar → `<video>.motion.json` (Gyroflow input) | Apple IAP / StoreKit 2 (`enableIAP`) |
| Level bubble, pace ring + haptic metronome, light meter, thirds grid | APNs push (`enablePush`) |
| Live room tagging → chapter timestamps | MLS/RESO import |
| PHPicker + Files import (file URLs, no memory load) | Real analytics beacons |
| Background resumable upload (simulate + presigned-PUT modes), cellular guard, SHA-256 | tus mode (TUSKit) — add when a tus server exists |
| Bundled scroll-scrub player in WKWebView | Signed playback URLs |

## Upload modes (Settings → Upload mode)

- **Simulate** (default): chunk-reads the real file from disk with realistic progress; persists offset; survives app kill + relaunch. Zero backend.
- **Direct**: requests a presigned PUT from the API and streams the file via background `URLSession` (continues when backgrounded/killed). Falls back to Simulate when no API is configured.
- **tus**: TODO — wire TUSKit + a tus server (package stub commented in `project.yml`).

## Architecture notes

- `project.yml` is the source of truth — regenerate with `xcodegen generate` after adding files. Never hand-edit the `.xcodeproj`.
- All API access goes through the `APIClient` protocol; point `Config.apiBaseURL` at `services/api` and swap in `LiveAPIClient` when the backend exists.
- The flythrough preview is the actual web player from `apps/web/player`, bundled at `Resources/player/` (folder reference). Keep the two in sync when the player evolves.
- Money is integer cents everywhere.
