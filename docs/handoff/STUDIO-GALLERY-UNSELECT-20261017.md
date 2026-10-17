# Studio gallery unselect — October 17, 2026

A selected gallery photo previously showed a disabled Selected button in Studio. It now has an enabled Remove from listing action. This changes publication selection and clears its cover when applicable, while preserving the original, edits, captions and history. Removal does not require an altered photo to pass publication review again.

The client checks current account, exact photo mapping and full saved selection before one idempotent mutation. A lost reply gets one scoped read; it never resends the removal or undoes a later re-add. The backend delegates to the existing shared removal authority. A guarded SQL correction preserves saved Studio order when removing from an older NULL-selection listing, retaining the same first100 candidates and unknown anchors.

Verified:49 Node cases,34 composed Deno cases, actual SQL57+57 assertions/12controls/3races and shared native removal33+33/5controls/2races. Actual headless browser suites pass21 checks, including Enter removal, Space re-add, stale state and lost reply. The actual Studio41 package plus2 overlays and2 existing imported dependencies passes a normal entrypoint check and12 new handler cases.

Delivered: migration record20261017112759, exact body5d70d5ef with all other catalog fields preserved. Studio42 contains the exact tested62-file package:58 old files unchanged,2 overlays and2 added dependencies; JWT/import-map/entrypoint policy and31 unselected function metadata rows remain exact. Root receipt71a68ba7.

Frontend48 is LIVE:467 exact source inputs/121 tool hashes,39 frozen files/38 shipping,393889gzip bytes. Root artifact receiptdf1268ab; final156-pin deployment review99b6dbd3 verifies36 public bodies/4 routes and exact policy preservation. Actual owner-admin desktop QA on a private fixture removes and restores one selected photo, with visible success and exact SQL restoration of selection/cover; both full photo rows and all5 capture rows remain unchanged. Automatic orientation resolves all5 portrait images after decode. This does not establish ordinary-account, Safari, iPhone or new-landscape quality acceptance. Final native delivery remains open. The initial missing runtime dependency preparation and erased type-edge checker refusals are preserved separately; neither was a product pass.

External evidence: `build88-studio-gallery-unselect-candidate/REVIEW-READY.json`21085c31; browserb2e740bf; package/artifact75c55eec; root integrationc155acf3. This does not close new-house, ordinary-account isolation or phone acceptance.
