# Applied migration history drift — October 26, 2026

This is a **read-only source audit** of RendProp Supabase project `ymgqpbnjpztwjsyvceld` against `services/supabase/migrations` on `codex/video-backend-parity-20261026`. The database was queried with `SELECT`; no migration was applied, replayed, repaired, or marked applied. The comparison covers the 55 applied rows dated October 14–20 and October 26 found in this audit, and the corresponding repository files. The 24 October 21–24 rows are separately reconciled in [VIDEO-BACKEND-SOURCE-PARITY-20261026.md](VIDEO-BACKEND-SOURCE-PARITY-20261026.md).

Of those 55 applied rows, 27 have the same local version/name, and **28 do not**. The 28 consist of 26 older timestamp differences and two October 26 timestamp/name differences. SQL content matches byte-for-byte for 25 of the 28. Two differ only in final newlines. One has a substantive guard difference. The table's MD5 is the live `statements[1]` MD5; `same bytes` means the repository file has that exact MD5.

| Applied version and name | Repository file in `services/supabase/migrations` | SQL relation | Live MD5 |
| --- | --- | --- | --- |
| `20261015030406_property_video_structural_fallback_cpu_recovery` | `20261015023751_property_video_structural_fallback_cpu_recovery.sql` | `same bytes` | `bd1913d139c26314b70750eb94e9b78a` |
| `20261015034631_prospective_photo_quality_evidence` | `20261015031824_prospective_photo_quality_evidence.sql` | `same bytes` | `e3cbb7eaf973c19f5f47c2dfb0ab04f4` |
| `20261015035024_property_video_cpu_retained_recovery_capacity` | `20261015034421_property_video_cpu_retained_recovery_capacity.sql` | `same bytes` | `912e9a0750654be29e2ae84001ff7eb2` |
| `20261015040811_photo_quality_existing_calibration` | `20261015035100_photo_quality_existing_calibration.sql` | `same bytes` | `feb7bb0a8ec48ea3435339ca436360e6` |
| `20261015042151_property_video_one_quality_retry` | `20261015040518_property_video_one_quality_retry.sql` | `same bytes` | `e74c1f2b3be9bd8b9edb73cca54a13b3` |
| `20261015042453_photo_quality_judge_context` | `20261015041036_photo_quality_judge_context.sql` | `same bytes` | `9cf60c4b51fa445521f9522dbc9cdea0` |
| `20261015045910_photo_input_legacy_9mb` | `20261015045028_photo_input_legacy_9mb.sql` | `whitespace only` | `8e105161a4712fb077a223f9cd423105` |
| `20261015052211_property_video_parallel_admission_fair_poll` | `20261015051455_property_video_parallel_admission_fair_poll.sql` | `same bytes` | `dc30c8dd56c615135ead5fbc8b3ee22e` |
| `20261015063446_photo_output_25mib` | `20261015062213_photo_output_25mib.sql` | `same bytes` | `26ecae7266b875e634b8982863d2e4fc` |
| `20261015063456_property_video_failed_supplier_terminal_reconciliation` | `20261015062943_property_video_failed_supplier_terminal_reconciliation.sql` | `same bytes` | `02284a5e6d237554a6f14340703949b2` |
| `20261015080011_normal_photo_pro4k_quality_profile` | `20261015074002_normal_photo_pro4k_quality_profile.sql` | `same bytes` | `fd030ce835a75d34e9c0d63a0108630a` |
| `20261015080200_property_video_immutable_quality_profile` | `20261015073835_property_video_immutable_quality_profile.sql` | `same bytes` | `ca49addc04b3de3ca7b633961fc49e2b` |
| `20261015082239_paid_quality_monthly_processing_allowance` | `20261015080552_paid_quality_monthly_processing_allowance.sql` | `same bytes` | `0202ba13e1e256a3f07f850363443581` |
| `20261016193802_native_photo_family_selection` | `20261016163911_native_photo_family_selection.sql` | `same bytes` | `7778d6dee882f057fc97db86703c4f5e` |
| `20261016194131_native_photo_family_abandon_cover` | `20261016171912_native_photo_family_abandon_cover.sql` | `same bytes` | `581acfe29e4a03ed46f53f5517c96f4e` |
| `20261016202008_provider_attempt_receipts` | `20261016192846_provider_attempt_receipts.sql` | `same bytes` | `8f295db9990fab7020f9c2d1a536481b` |
| `20261017040043_property_video_steady_v2` | `20261016002000_property_video_steady_v2.sql` | `same bytes` | `269d3575569ed3169e868e8b5d85a81d` |
| `20261017040214_property_video_kie_kling3_4k_profile` | `20261016100000_property_video_kie_kling3_4k_profile.sql` | `same bytes` | `af4e772aafdf9b9436424b3d22f27ab7` |
| `20261017040320_property_video_kie_scope_consent_drain` | `20261016110000_property_video_kie_scope_consent_drain.sql` | `same bytes` | `9af7a3522ed3ede018092915e120dbcf` |
| `20261017112759_preserve_gallery_removal_projection_order` | `20261017110321_preserve_gallery_removal_projection_order.sql` | `same bytes` | `5aa68c07d5e918577d23e955fff4e935` |
| `20261017113856_freeze_property_attempt_liability` | `20261017110114_freeze_property_attempt_liability.sql` | `guard differs` | `3177ca9a7139303413b1419e65df8ff6` |
| `20261017175731_conservative_pipeline_cost_binding` | `20261017115012_conservative_pipeline_cost_binding.sql` | `whitespace only` | `f9d1a9e0045564996bed927c067ed7ff` |
| `20261017214119_provider_attempt_supplier_reference` | `20261017190000_provider_attempt_supplier_reference.sql` | `same bytes` | `ca8d3e501240c974f4003b01ada81976` |
| `20261017214130_app_video_rp402_copy` | `20261017190100_app_video_rp402_copy.sql` | `same bytes` | `2e621ecd9a79f39f4c252e150d39674c` |
| `20261017214219_property_video_temporal_verdict` | `20261017191000_property_video_temporal_verdict.sql` | `same bytes` | `801b94bab59f2a6ca7727b67ab9674eb` |
| `20261017214253_photo_output_feedback` | `20261017200000_photo_output_feedback.sql` | `same bytes` | `79f3caffed3d77ec17a1d2d6574bbf92` |
| `20261026194816_limited_intro_trial_creative_spend_20261026` | `20261026165813_limit_intro_trial_creative_spend.sql` | `same bytes` | `1c6da147097a3c199833f0908bb10961` |
| `20261026200053_public_property_address_lookup_20261026` | `20261026175227_public_property_address_lookup.sql` | `same bytes` | `238152879346cb2e778f4b1802a54af2` |

The two whitespace differences were isolated by comparing the live SQL text and repository files:
- `photo_input_legacy_9mb`: live SQL has one additional blank line at EOF. Live MD5 `8e105161a4712fb077a223f9cd423105`; repository MD5 `33acefb871dc5e594c469fa9e60bb995`. No SQL token differs.
- `conservative_pipeline_cost_binding`: live SQL has no final newline; repository SQL has one. Live MD5 `f9d1a9e0045564996bed927c067ed7ff`; repository MD5 `6170437e44824206b8b36e7fc562a96b`. No SQL token differs.

The material difference is `freeze_property_attempt_liability`. Live version `20261017113856` permits only predecessor `stamp_library_financial_liability()` body MD5 `3976c4aaf6cea5185df1e133475fb83f`. The repository's earlier-timestamped file also permits `73882a6e41ff1dee0d8b6b0ee3f1609c`, the body's MD5 after this migration, so the file can be replayed. Live MD5 is `3177ca9a7139303413b1419e65df8ff6`; repository MD5 is `0bdbf47075a85faba3685c102f90d5ea`. The October 17 [integrated audit](../handoff/CLAUDE-INTEGRATED-AUDIT-20261017.md) records a disposable PostgreSQL replay test of that broader guard. Replacing it with the strict live bytes would discard that tested replay property. This audit leaves it intact.

**Fresh-database replay is not proven for the current tree.** Sorting the 55 live rows by applied version and their mapped repository files by filename gives **11 pairwise order inversions**. The important ones are:
- The repository's three October 16 `property_video_steady_v2` / `property_video_kie_kling3_4k_profile` / `property_video_kie_scope_consent_drain` files sort before the native photo-family and `provider_attempt_receipts` files. Live applied all three after those files, on October 17.
- The repository sorts `property_video_immutable_quality_profile` before `normal_photo_pro4k_quality_profile`; live applied them in the reverse order.
- The repository sorts `freeze_property_attempt_liability` before `preserve_gallery_removal_projection_order`; live applied them in the reverse order.

Renaming these files to live versions would make previously applied SQL appear new to a database with the repository versions in its history, and may change fresh-database execution order. Adding duplicate live-version files would run the same DDL twice. Neither is a safe source-only correction without a current disposable-database replay and a migration-history transition plan.

The October 26 live trial-spend and public address-lookup statements are byte-identical to the mapped local files above, but both live versions (and names) differ from local. Local `20261026225116_property_address_reservations.sql` had **no applied counterpart** at the time of the read-only query. This audit does not assert whether a concurrent rollout will apply it later. It has not been copied, renamed, or run here.

Verification for this map: 55/55 applied rows have a corresponding local file; 28/28 version/name differences are enumerated; all 28 SQL MD5 comparisons were made against the live saved statement; the three nonidentical files were diffed; 11 order inversions were counted. No production mutation or paid generation occurred.
