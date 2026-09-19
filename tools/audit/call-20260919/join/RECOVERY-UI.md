# Focused saved-take UI test

Use a **new** simulator, named `Rendprop Capture Recovery Audit <date>`. Never
erase or seed an existing simulator, and never connect this test to a phone or
customer account. `CaptureRecoveryTests` uses the app's existing `-uiTesting`
mock and refuses to exercise uploads, generation, account deletion, or sharing
to a recipient.

1. Generate the normal iOS project with `xcodegen generate --spec project.yml`.
2. Run `xcodebuild build-for-testing` with scheme `Rendprop`, Debug configuration,
   the new simulator's explicit UUID, and a dedicated or idle DerivedData path.
3. Install that built `Rendprop.app` into the new simulator using `simctl install`.
4. From the repository root, run:

   ```sh
   python3 tools/audit/call-20260919/join/seed_recovery_ui.py --simulator NEW_UUID
   ```

   The script refuses pre-existing capture directories. It generates three
   colored 0.3-second movies, a two-piece recovery journal with synthetic room
   metadata, and a SHA-256 receipt outside Git.
5. Explicitly revoke camera and microphone for `com.rendprop.app` on this new
   simulator with `simctl privacy`. The case must recover without camera access.
6. Run `xcodebuild test-without-building` against the generated `.xctestrun`, with
   the same explicit simulator destination and:

   ```text
   -only-testing:RendpropUITests/CaptureRecoveryTests
   -parallel-testing-enabled NO
   -collect-test-diagnostics never
   -resultBundlePath UNIQUE_RESULT.xcresult
   ```

The test traverses the normal Add a home → Record a walkthrough route, opens
Saved takes, dismisses and relaunches the app, retries the join, verifies the
review is usable despite denied camera access, then opens the system share
sheets for an unindexed legacy recording and an ordered part. It verifies that
Save to Files is offered; it does **not** claim that a destination file was
written. Screenshots and the final accessibility tree are retained as test
attachments. Export them using `xcresulttool export attachments`.

Afterward, compare the three seeded source hashes with the receipt and confirm
the journal still exists. Leave the isolated simulator and evidence intact;
shut down only this test simulator when finished.
