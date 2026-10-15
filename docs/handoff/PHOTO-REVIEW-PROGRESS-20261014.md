# Photo review and honest progress — build80 source

The photo-version review now follows system Light/Dark appearance with adaptive
Rendprop tokens and native glass materials. A larger aspect-fit image leads
review; Original/Enhanced/Decluttered/Staged choices remain available and All edits
retains every saved style. One Compare opens full-size source inspection. Required
staging/custom confirmations are compact 44-point buttons. Save and Use on listing
stay in a bottom safe-area footer, stacking for compact width/accessibility text.
Disclosure remains accessible and missing comparison sources still block selection.
The display height uses the loaded, orientation-corrected image and available
content width, capped at the viewport/560 points. Landscape images no longer
reserve a tall blank box; unavailable photos use a bounded compact placeholder.
Photo files, crop, export dimensions and review callbacks are unchanged.

The actual Save/Use callbacks, source/hash review policy, selected-publication
version and original storage are unchanged. No automatic publication, style
replacement, deletion, billing or AI generation path was added. Edited/current
preview is distinct from the explicitly chosen listing version.

Photo AI is currently one synchronous POST: the API returns no supplier percentage
or intermediate queue/QC receipt. Progress is therefore native observable phases:
Preparing, retained-source Upload (when required), Generating and checking, checking
returned bytes, then Saving version/disclosure. The supplier phase is indeterminate;
the batch bar/count describes completed attempts and separately names saved/failed
photos. No elapsed-time percentage or fake separate server QC status is produced.
Callbacks require current queue job UUID, photo ID, actor/library and an uncancelled
operation; older phases cannot regress the active photo. Finish/cancel clears the
active phase. Existing consent revocation, uncertain-request behavior, finite iOS
photo-background execution and notification policies remain unchanged.

Validation recorded under the root-private `_bridge/build80-photo-review`:

- Real iPhoneOS Release build and iOS UI-test bundle build-for-testing passed.
  The final parent-reviewed staging check wording was then source-validated and
  parsed; it changes no binding, accessibility label, callback or type.
  No Simulator UI, phone controls, paid model calls or live deployment performed.
- Actual queue 19 runtime assertions and layout 86 policy assertions passed, with 5
  source controls for forced Dark, missing fixed footer, cropped preview, bypassed
  review and stale-account action. Save/Use bodies match approved 1955b70.
- Existing actual consent/photo batch 48 assertions and revoked/renewed-grant controls
  passed. Full unchanged photo history/export proof plus 77 actual gallery-sync
  assertions passed; originals, earlier styles, comparison hashes and explicit
  selection remain protected.
- UI tests were updated for the compact checkbox buttons and compiled appearance/
  larger-text footer checks. They were not UI-executed; parent checks the integrated
  build on the actual mirrored iPhone before public acceptance.

Files deliberately avoid the support80 staging-style/menu/AskAI fragments. Parent
may integrate both commits before updating the normal public candidate. No build
number, Store74 review state or shared Theme was changed.
