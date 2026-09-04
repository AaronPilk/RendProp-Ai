// SignInView lives in Screens/RenderStatusView.swift so it is always in the
// Xcode target without re-running xcodegen (see the repo's new-file-not-in-target
// rule). This file is intentionally left empty — do not re-add `struct SignInView`
// here or it will collide with the copy in RenderStatusView.swift.
//
// Contract the sheet relies on (Auth/AuthStore.swift):
//   • `AuthStore.randomNonceString()` / `AuthStore.sha256(_:)` — the raw nonce
//     is kept; its SHA256 goes on the Apple request.
//   • `AuthStore.shared.exchangeAppleIdentityToken(idToken:nonce:)` — throws
//     `APIError.server` with GoTrue's own message on a rejected exchange.
//   • `AuthStore.submitAppleAuthorizationCode(_:)` — TN3194, best-effort.
//   • `AuthStore.shared.setDisplayName(_:)` (or assigning `userName`) — Apple
//     returns `fullName` ONLY on the first authorization; the sheet must format
//     it with `PersonNameComponentsFormatter` and hand it over right away.
//   • `AuthStore.shared.onAccountChanged` — fired when a DIFFERENT Apple ID
//     signs in than the last one on this device; the app clears listings'
//     `serverID/shareSlug/shareURL` there.
// The old programmatic `signInWithApple()` + `AppleSignInCoordinator` path
// (a second, never-shipped sign-in implementation) was deleted in the
// 2026-09-03 audit — `SignInWithAppleButton` is the only sign-in surface.
