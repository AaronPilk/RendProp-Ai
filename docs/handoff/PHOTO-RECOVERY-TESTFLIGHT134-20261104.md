# Photo recovery: TestFlight 1.0.6 (134) preparation

This is a **pre-upload** checklist for the photo recovery update. It does not
claim that Build 134 has been archived, uploaded, installed, or reviewed on a
physical iPhone. Public App Store version 1.0.5 remains untouched.

## What to Test (en-US)

> On a listing created in an earlier install, open Photos and tap **View cloud
> photos**. Confirm saved cloud files appear for the correct account and listing.
> An available copy without its original should offer **Save available copy to
> Photos** and explain that original/edit history is not restored. In Studio,
> open the same listing and use **Check and prepare saved photos**; eligible
> photos should become available for review, while unverified copies should
> remain separate. Nothing should be placed on a published listing automatically.

Do not include a customer's address or account email in public TestFlight notes.

## Release observations

- App Store Connect read-only check on November 4, 2026: public iOS 1.0.5 is
  `READY_FOR_DISTRIBUTION`; no 1.0.6 prerelease version or Build 134 exists yet.
  Latest uploaded build is 1.0.5 (133), `VALID`.
- The checked-in iOS project and `project.yml` now both declare 1.0.6 (134).
  Xcode `-showBuildSettings` and the unsigned Release device app `Info.plist`
  independently read 1.0.6 (134).
- On isolated source commit `58b1ece6`, the full Release iOS Simulator and
  unsigned generic-iPhone Release builds succeeded. Focused cloud-photo-save
  and private-media gateway tests passed. These are source checks, not a signed
  archive or a device acceptance test.
- The native runtime files tested here match the photo-recovery integration
  source through `dbffc981`; that later integration commit changes only the
  database audit runner. Reconfirm the final integrated HEAD before archiving.
- `tools/asc/asc.py` still targets public App Store version 1.0.5. It must be
  updated to 1.0.6 before preparing a *later* public 1.0.6 update. Uploading a
  TestFlight 1.0.6 build does not submit or release a public App Store update.

## Before upload

1. Wait for the backend rollout and exact integrated CI to pass.
2. Archive and export once from the exact committed, pushed integration HEAD.
   Save source SHA, archive/IPA hashes, dSYM UUID and signed entitlements.
3. Upload one 1.0.6 (134) IPA to TestFlight, then read back Apple's processed
   build/version, group eligibility and the en-US What to Test note.
4. Test the recovery flow with the customer on a physical iPhone before any
   public App Store update. Preserve the cloud files and avoid relabeling
   unverified copies as originals.
