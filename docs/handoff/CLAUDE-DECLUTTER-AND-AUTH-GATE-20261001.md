# Declutter supersession + mandatory Apple sign-in — handoff

Branch: `claude/call-fixes-20260917`
Author: Claude (Cowork), 2026-10-01
Files: `apps/ios/Rendprop/Screens/FlythroughDetailView.swift`,
`apps/ios/Rendprop/RendpropApp.swift`

## ⚠️ NOT COMPILED

I have no Swift toolchain. Brace/paren balance checks pass and every symbol I
call was read out of the tree first, but **nothing here has been through
`xcodebuild`.** Bridge script `_bridge/cmd/1659-declutter-supersede-build.sh` is
queued and does the build plus a `ReviewerWalk` run; treat its log as the first
real evidence. If you build before the bridge runs, your result supersedes this
doc.

Also unverified: no simulator run, no visual check of the gate screen, no
device test of the declutter→stage sequence.

---

## 1. An AI photo edit now SUPERSEDES its source instead of appending

**Why.** Staging a cluttered room is the worst input you can hand the stager —
it arranges furniture around someone's laundry. The product wants
declutter-then-stage. The pipeline was *already* right (`performEdit` reads
`let source = p.enhancedURL`, so edits chain); the defect was purely that each
edit did `photos.insert(newPhoto, at: 0)` and left the source in the grid. The
agent ended up with cluttered and decluttered side by side and had to remember
which one to stage, and either could reach the listing.

**Change.** In `performEdit`, the new photo takes the source's index. Three
things this had to get right, each of which would have failed silently:

1. **The grid is disk-backed.** `loadExisting` → `EnhancedPhoto.loadAll` globs
   `enh-*` and derives everything from the `enh-`/`orig-` filename convention.
   Removing the photo from the array alone would resurrect the pre-edit version
   on next launch, so the superseded `enh-` file is deleted with it.
2. **The main-photo pointer is a file path** (`mainRelPath` vs
   `FileStore.relativePath(for: p.enhancedURL)`). Superseding the cover photo
   would leave the listing pointing at a deleted file. It re-points to the
   survivor. This is the same hazard `delete(_:)` already guards.
3. **Restaging.** With supersession, a second style would furnish on top of the
   furniture. New `stageBases: [String: URL]` records what a staging started
   from, and `source` for `edit == "stage"` prefers it. Session-scoped: nothing
   on disk records which edit produced a file and a sidecar format isn't worth
   it for this, so after a relaunch a restyle chains like any other edit — the
   pre-existing behaviour, not a regression.

**Compliance is intact, and this was the thing to check.** `orig-<newid>.jpg` is
a copy of the source's own pixels written on every edit, so `originalURL` still
points at a real separate file. Before/after compare and the AB 723 "View
original" link keep working, `publishOriginalForDisclosure` is untouched, and the
camera original stays on disk. Nothing is destroyed — only the *grid entry* is
replaced.

**Batch safety.** `runBatchWithSession` iterates `targets: [EnhancedPhoto]`, a
captured value array, not the live `photos`. Mutating `photos` mid-batch is safe.

Copy at the studio footer updated — it said "Each change saves as a new photo.
The original stays", which is now false.

### Worth a second opinion
- Supersession applies to **all** edits (twilight/sky/lawn/declutter/stage), not
  just declutter. I believe that's right — every edit produces the version that
  should go on the tour — but it's a product call, not a technical one.
- Orphaned `orig-<oldid>.jpg` files accumulate (the camera original of a
  superseded photo). ~1–2 MB each, deliberately kept for provenance. Trivial next
  to 4K60 capture, but it is unbounded.

---

## 2. Hard sign-in gate — Apple only

**Why (the real reason).** `signInAnonymouslyIfNeeded()` minted a real
`auth.users` row at launch, and `handle_new_user` hands that row an org with
`trial_ends_at` set. So **delete-and-reinstall produced a fresh 7-day trial with
a fresh per-org COGS ceiling, repeatable forever.** ~$0.64 of provider spend per
farm, unbounded and trivially automated, and it also makes signup/DAU numbers
meaningless. An Apple ID is stable across reinstalls; that's the fix.

**Change.**
- New `IdentityGate<Content>` + `SignInGateView` in `RendpropApp.swift`.
  `WindowGroup`'s content is wrapped in the gate.
- Both launch calls to `signInAnonymouslyIfNeeded()` removed (the `.task` and the
  `scenePhase == .active` one). The method stays on `AuthStore` but now has **no
  call sites** — an already-anonymous install still has its token in the
  Keychain, so `AnonymousAdoptionRecovery` has a session to adopt from.
- Gate predicate is `!auth.isIdentified`, **not** `!isSignedIn` —
  `isSignedIn` is true for anonymous sessions (AuthStore line 29).
  `isIdentified` reads the `is_anonymous` JWT claim and answers "no" on an
  unparseable token, which is the safe direction for a gate.

**Both test flags bypass the gate:** `Config.isUITesting || Config.isSessionNetworkTesting`.
Deliberately *not* the `isUITesting && !isSessionNetworkTesting` pairing used in
`AuthStore` init — my first draft used that and it would have gated
`PhaseOneFixtureRoot`, hiding the exact thing the session-network test exercises.
**This is the highest-risk part of the change**: five UI harnesses (ReviewerWalk,
IndustryWalk, PaywallShot, SpatialProductIntegration, the non-camera walks) drive
the app with no Apple ID and cannot tap a system sign-in sheet. If any of them
fail, the gate predicate is why.

`SignInGateView` lives in `RendpropApp.swift`, not a new file — the repo's
new-file-not-in-target rule (`Auth/SignInView.swift` is kept deliberately empty
for the same reason). The Apple exchange mirrors `SignInView` in
`Screens/RenderStatusView.swift` verbatim, **including the TN3194
`authorizationCode` capture** — without it Delete account cannot revoke the
Apple grant (audit P0-4, which was previously shipped broken for exactly this
reason). No `dismiss()`, no "Not now".

### ⚠️ This reverses a deliberate 5.1.1(v) decision — needs review notes
The removed code carried `// GUIDELINE 5.1.1(v)` and existed specifically so
every feature worked "without anybody registering". That guideline bars forcing
registration on an app whose core features don't require it.

My read: Rendprop's core features **do** require an account — cloud rendering, a
hosted public page per tour, seats, and a billed trial all have to belong to
someone, and 5.1.1(iv)'s in-app account deletion requirement already ships
(Settings → Delete account). Dropbox/Figma/Canva all hard-wall on the same basis.

**But the App Review notes must now say this explicitly and carry a demo
account**, or a reviewer hits a wall with no explanation on a build that
previously had none. Someone should own that before submission.

### Apple-only, against the stated ask
Aaron asked for "Apple or email and password, preferably Apple". I shipped Apple
only. `AuthStore` has `exchangeAppleIdentityToken` and **no email/password method
at all** — adding one means the GoTrue password grant plus verification mail,
reset flow, credential-stuffing surface and support load. On an iOS-only product
every user already has an Apple ID, so that buys access for a population of zero.
Revisit when there's an Android or web client. Flagged to Aaron; he may overrule.

---

## Verify in this order
1. `_bridge/cmd/1659-*.sh` — build, then `ReviewerWalk`.
2. The other four UI harnesses, if 1 is green.
3. On device: declutter a cluttered room → confirm one grid entry, confirm the
   before/after compare still shows the clutter, then stage it.
4. Restage with a second style → confirm it restyles rather than stacking.
5. Supersede the cover photo → confirm the listing cover follows.
6. Fresh install → confirm the gate, and that no anonymous org is created before
   sign-in (check `orgs` for new rows during a gated launch).
7. Existing anonymous install with local listings → sign in, confirm adoption
   migrates the work rather than stranding it.

## Not touched
Pricing/entitlements, the spatial viewer (`keep_names = false` is already on this
branch), upload recovery, migrations, Apple/ASC config, the tour-host Worker.
