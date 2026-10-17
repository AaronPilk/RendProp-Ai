# AI photo feedback and improvement loop — design and client contract (2026-10-17)

Branch `claude/photo-feedback-20261017` (base: launch head `b57ba713`).
Owner scope: `/home/claude/feedback-evidence/PHOTO-FEEDBACK-OWNER-SCOPE.txt`.
This document is the contract the iOS lane builds against. Sections 1–6 are
frozen once published; later changes are appended under "Amendments" only.

No part of this feature makes a paid AI/provider call. Feedback never
triggers a regeneration. There is no recurring evaluator and no training.

---

## 1. What exists today (inspected, not assumed)

### 1.1 The exact output version
Every prospective AI photo generation runs through the strict `ai-photo`
handler (`services/supabase/functions/ai-photo/index.ts`; `ai-photo-v2` is a
transport alias) and the SQL photo-quality journal
(`services/supabase/migrations/20261015031824_prospective_photo_quality_evidence.sql`):

| Record | Table | Identity | What it binds |
|---|---|---|---|
| Serving operation | `serving_operations(org_id, actor_id, request_key)` | client `Idempotency-Key` (`studio-photo:<uuid>` from Studio; iOS sends its own) | the whole request (input sha) |
| Generation evidence | `photo_edit_evidence.id` | one per operation (`unique(org_id,actor_id,request_key)`) | `listing_id`, `edit`, `style`, `input`/`output` (bucket/key/sha256/bytes/geometry), `generation_stage` (`photo.<edit>:<chain index>`), `generation_provider`, `generation_model`, `provenance_id`, `state` |
| Quality check | `photo_quality_checks` | one automatic row per evidence | judge verdict (`accept`/`refuse`/`hold`), its own reservation/ledger |
| Provenance | `media_provenance.id` | inserted by `photo_quality_evidence_receipt` when the candidate bytes are retained | `org_id`, `listing_id`, `kind`, `model_id`, `edit`, `style`, public disclosure; later `altered_key`/altered asset via `PATCH /me/compliance/:id` on gallery save |
| Delivery receipt | `private_ai_outputs(storage_key unique)` | the retained candidate key | org/user/listing/bytes |
| Paid attempts | `serving_cost_reservations(org_id, actor_id, request_key, stage)` | one per chain step actually admitted | `provider`, `model`, `hold_cents`, `state` (`reserved`/`succeeded`/`uncertain`/`rejected`), `ledger_id` (bound by trigger) |
| Recorded cost | `cost_ledger` | `meta.request_key` + `meta.stage` (`feature='photo_edit'`), plus judge rows (`request_key='photo-qc:<check>'`) | modeled/estimated cents (never an invoice) |

Both clients already carry `provenance.id` for every result they can save:
Studio `PhotoDelivery.provenanceId` (`apps/studio/src/features/creative/photo-lineage.ts`),
iOS `PhotoVersionHistory.Version.provenanceID` (+ `provenanceRecorded`).
Gallery save (`studio/photos`, `PATCH /me/compliance/:id`) requires it. The
accepted response also exposes `evidence_id`, `check_id`,
`generation_request_key`, and the exact output bytes (so the client can hash
them).

Historical outputs (pre-2026-10-15 `photo_output` receipts) have a
`media_provenance` row but **no** `photo_edit_evidence` row: provider/model
(beyond `media_provenance.model_id`), stage, request key, attempt and cost are
unknown for them and stay null.

### 1.2 Existing review flows (kept exactly as they are)
* Studio "Review your edit" (`CreativeWorkspace.tsx` ≈ line 1412): custom
  edits require the fixed-features acknowledgment checkbox before save/export.
* iOS `PhotoVersionHistory.StagingReview` / `CustomReview` (local flags
  `stagingReviewed`, `customReviewed`); `canAutomaticallySelectForListing`
  is the **automatic selection** rule (non-stage, non-custom-pending).
* Publication safeguards: `photo_quality` accept gate, provenance requirement
  on gallery save, listing gallery selection RPCs. None are touched; the
  existing harnesses prove it (see §7).

### 1.3 Cost and attribution conventions reused
`provider_attempt_receipts` (20261016192846), `freeze_property_attempt_liability`
(20261017110114), `conservative_pipeline_cost_binding` (20261017115012):
security definer + `set search_path=''`, service_role-only execute, RLS on
with no policies, own-replay guard with md5 pins, no historical DML, ledger
amounts described as modeled estimates, never reconciled invoices.

### 1.4 Admin console
`services/supabase/functions/admin/index.ts`: `requireAdmin()` (JWT →
`profiles.is_admin` via service role, fails closed), 60/min durable rate
limit, GET-only except the two routing switches, org-level aggregates only.
Studio has **no** admin surface today (the console is the iOS screen frozen in
`docs/ADMIN-CONSOLE-CONTRACT.md`); the report page is therefore a new,
admin-only Studio route that calls `GET /admin/photo-feedback`.

### 1.5 Prompt versioning
The Studio prompt library (`apps/studio/src/features/prompts`) targets copy/
video prompts only — it does not model photo recipes. Photo prompts are code
constants in `ai-photo/index.ts` (`RE_PROMPTS`, `prompts(profile)`,
`customPrompt`, `guardrailsFor`). There is no stored revision today.

---

## 2. What this feature adds

1. **Recipe revision on new generations.** `photo_edit_evidence` gains
   `recipe_revision text` and `prompt_sha256 text` (nullable; null = unknown,
   which is every historical row). `ai-photo` records them through the new
   service-role RPC `photo_quality_set_recipe` immediately after
   `beginPhotoQuality` and **before** any provider dispatch (a failure aborts
   the operation with the existing refund/abort path — no paid call is made).
   The constant `PHOTO_RECIPE_REVISION` lives in
   `services/supabase/functions/ai-photo/photo-recipe.ts` and must be bumped
   whenever any prompt template, guardrail text or composition changes.
   `prompt_sha256` is the SHA-256 of the exact final prompt string sent.
2. **Explicit feedback** table `photo_output_feedback` (one row per
   actor × output version, revised in place).
3. **Separate signals** table `photo_output_signals` (accuracy
   acknowledgments, manual selection, automatic selection, export,
   publication) — append-only, idempotent, never mixed with feedback.
4. **Regression cases** table `photo_regression_cases` referencing existing
   evidence only (no bytes copied; retention follows the photo).
5. **Submit RPCs** (service_role only, called by the new `photo-feedback`
   edge function), **report RPC** `photo_feedback_report` (called by
   `GET /admin/photo-feedback`).
6. Studio: Useful / Needs work control in "Review your edit", offline queue,
   admin report page. iOS: second lane, from this contract.

---

## 3. Data model

### 3.1 `photo_edit_evidence` (extended)
```
recipe_revision text   check (recipe_revision ~ '^[a-z0-9][a-z0-9./_-]{1,79}$')
prompt_sha256   text   check (prompt_sha256 ~ '^[a-f0-9]{64}$')
```
Set once by `photo_quality_set_recipe(p_actor, p_evidence, p_revision, p_prompt_sha256)`;
a different value on replay → `RP409`. Historical rows stay null.

### 3.2 `photo_output_feedback`
```
id                  uuid pk
provenance_id       uuid not null references media_provenance(id) on delete cascade   -- THE exact output version id
evidence_id         uuid references photo_edit_evidence(id) on delete cascade          -- null = historical/unknown
org_id              uuid not null references orgs(id) on delete cascade
listing_id          uuid references listings(id) on delete cascade
actor_id            uuid not null references auth.users(id) on delete cascade
client_key          text not null  check(client_key ~ '^[A-Za-z0-9:_-]{8,128}$')
idempotency_key     text not null unique                 -- 'photo-feedback:'||provenance_id||':'||client_key (server-derived)
output_sha256       text check(~ '^[a-f0-9]{64}$')       -- client-pinned bytes hash, verified when evidence exists
edit                text not null                        -- from provenance/evidence, never from the client
provider            text,  model text, generation_stage text, request_key text   -- copied from evidence; null = unknown
recipe_revision     text,  prompt_sha256 text                                   -- copied from evidence; null = unknown
attribution         text not null check in ('evidence','provenance_only')        -- explicit "unknown" marker for historical rows
verdict             text not null check in ('useful','needs_work')
reasons             text[] not null default '{}'  (each in the reason list below; empty unless needs_work)
note                text check(length<=500)
revision            integer not null check(revision>=1)
revision_count      integer not null default 1
platform            text check in ('ios','studio','other')
created_at, updated_at timestamptz
unique(provenance_id, actor_id)         -- one live verdict per person per output
unique(actor_id, client_key)            -- a client key can never move to another image
```
Reasons (exact strings, in the scope's order):
`changed_permanent_features`, `moved_or_changed_appliance`, `blocked_doorway_or_opening`,
`inconsistent_furniture_between_views`, `visible_visual_artifacts`,
`requested_edit_incomplete`, `personal_style_preference`, `other`.
Fidelity reasons = the first six; `personal_style_preference` is taste;
`other` is neither. The report keeps these groups apart.

### 3.3 `photo_output_signals`
```
id uuid pk, provenance_id (cascade), evidence_id (cascade, nullable), org_id, listing_id, actor_id (cascade)
signal text check in ('accuracy_ack','manual_selection','automatic_selection','export','publication')
detail text check in ('staging_review','custom_review','gallery_save','listing_selection','kit_export','download','published_tour') -- optional
client_key text, idempotency_key text unique ('photo-signal:'||provenance_id||':'||signal||':'||client_key)
created_at
unique(actor_id, client_key)
```
Selection/export/publication **do not** imply quality; they are counted on
their own axis and never folded into the useful rate.

### 3.4 `photo_regression_cases`
```
id uuid pk
provenance_id (cascade)  evidence_id (cascade, nullable)  feedback_id references photo_output_feedback(id) on delete set null
org_id (cascade) listing_id (cascade)
defect text  (one of the fidelity reasons or 'other')
expected_behavior text not null check(length between 10 and 1000)
recipe_revision text, prompt_sha256 text, provider text, model text, edit text  -- snapshot from evidence; null = unknown
input_ref  jsonb   -- {bucket,key,sha256,bytes} copied from evidence.input  (reference only, no bytes)
output_ref jsonb   -- {bucket,key,sha256,bytes} copied from evidence.output
protocol text not null default 'photo-fixed-features-v1'   -- the existing photo evaluation protocol
authorized_by uuid references auth.users(id) on delete set null
authorization_basis text not null check in ('library_owner_consent')
authorized_at timestamptz, created_at, withdrawn_at timestamptz
unique(provenance_id)
```
Only an `owner`/`admin` of the library org can mark a case, and only with an
explicit `retain_for_evaluation: true` in the request. Nothing is copied: the
case points at the evidence objects the library already owns; if the listing,
org or photo is deleted the case cascades. Withdrawal sets `withdrawn_at`.

### 3.5 Authorization (identical to the media)
Every submit RPC resolves the output through `media_provenance` and, when
present, `photo_edit_evidence`, then requires:
`listing_library_scope(actor, listing_id)->>'can_write' = 'true'` and
`(->>'org_id') = provenance.org_id` when the provenance has a listing;
otherwise `library_access(actor, org_id)->>'can_write' = 'true'`;
plus a named (non-anonymous) user with no pending deletion request. A valid
id in another library → `RP404` (never a 403 that confirms existence).

RLS is enabled on all three tables with no policies; only `service_role` may
`select`. Nothing is readable through PostgREST.

### 3.6 Deletion / retention
All three tables cascade from `media_provenance`, `orgs`, `listings` and the
actor's `auth.users` row. `media_provenance` itself cascades from `orgs` and
`listings`, so feedback can never outlive the photo's provenance. Proven by
`photo_feedback_pg.py` (delete listing → zero rows; delete user → zero rows).

---

## 4. Client contract — `photo-feedback` edge function

Base: `POST|GET /functions/v1/photo-feedback[...]`. Auth: the user's bearer
JWT (same as `photo-quality-review`). Header `x-rendprop-org` (the selected
library, as every other library-scoped call sends via `preferredOrg`). JSON
bodies. Responses: `cache-control: no-store`. CORS: same allow-list as
`photo-quality-review` plus `Idempotency-Key` is **not** used — the key is in
the body so it is persisted with the queued item.

### 4.1 `POST /photo-feedback` — submit or revise explicit feedback
Request:
```json
{
  "output": { "provenance_id": "<uuid>", "output_sha256": "<64 hex, optional>" },
  "client_key": "<8..128 [A-Za-z0-9:_-], generated ONCE per (output, actor) and stored locally>",
  "revision": 1,
  "verdict": "useful" | "needs_work",
  "reasons": ["changed_permanent_features", ...],   // required non-empty for needs_work, must be [] for useful
  "note": "optional, <= 500 chars",
  "platform": "ios" | "studio"
}
```
Response `200`:
```json
{
  "feedback_id": "<uuid>", "provenance_id": "<uuid>", "revision": 1, "revision_count": 1,
  "state": "recorded" | "replayed" | "revised",
  "verdict": "needs_work", "reasons": [...], "note": null,
  "attribution": {
    "basis": "evidence" | "provenance_only",
    "evidence_id": "<uuid>|null", "edit": "stage", "provider": "gemini|null", "model": "...|null",
    "generation_stage": "photo.stage:0|null", "recipe_revision": "...|null", "prompt_sha256": "...|null",
    "attempts_known": true|false
  }
}
```
Idempotency rule (server-enforced):
* `idempotency_key = 'photo-feedback:' || provenance_id || ':' || client_key`.
* Same actor + same `client_key` for a **different** `provenance_id` → `409 feedback_key_conflict`.
  A key is bound to one image forever.
* Same key, same `revision`, identical content → `200 state:"replayed"`, nothing written.
* Same key, same `revision`, different content → `409 feedback_revision_conflict`
  (the client must bump `revision`).
* Same key, higher `revision` → `200 state:"revised"`; the row is updated in
  place (`revision`, `revision_count+1`, `updated_at`). Row count never grows.
* Same key, lower `revision` → `200 state:"replayed"` returning the newer
  stored row (a late retry of an old revision never regresses the verdict).
* A second feedback row for the same `(provenance_id, actor)` under a *new*
  client key is refused with `409 feedback_exists` carrying the existing
  `client_key`; the client adopts it.
* `output_sha256`, when sent and when evidence exists, must equal
  `evidence.output->>'sha256'`; mismatch → `409 output_mismatch`. For
  historical rows it is stored as sent and marked `provenance_only`.

### 4.2 `POST /photo-feedback/signal` — non-feedback signals
```json
{ "output": {"provenance_id":"<uuid>"}, "client_key":"<...>", "signal":"accuracy_ack"|"manual_selection"|"automatic_selection"|"export"|"publication", "detail":"staging_review"|"custom_review"|"gallery_save"|"listing_selection"|"kit_export"|"download"|"published_tour"|null, "platform":"ios"|"studio" }
```
`200 {"signal_id":"<uuid>","state":"recorded"|"replayed"}`. Same-key
different-output → `409 feedback_key_conflict`. Signals are append-only; a
replay is a no-op.

### 4.3 `GET /photo-feedback?provenance_id=<uuid>` — current state for the caller
`200 { "provenance_id", "feedback": <4.1 response body or null>, "signals": [{"signal","detail","created_at"}], "regression_case": {"id","defect","withdrawn_at"}|null, "attribution": {...} }`.
Used by a client that lost its local state (new device) to re-sync.

### 4.4 `POST /photo-feedback/regression-case` — mark / withdraw
```json
{ "output": {"provenance_id":"<uuid>"}, "defect":"blocked_doorway_or_opening", "expected_behavior":"...10..1000 chars...", "retain_for_evaluation": true, "withdraw": false }
```
Requires `owner`/`admin` membership in the library org and
`retain_for_evaluation: true` (else `403 evaluation_consent_required`).
Historical outputs without evidence objects → `409 evidence_unavailable` (there is
nothing to evaluate against). `200 {"case_id","state":"recorded"|"replayed"|"withdrawn","protocol":"photo-fixed-features-v1"}`.

### 4.5 Error codes (HTTP → `error.code`)
| Status | code | Meaning |
|---|---|---|
| 400 | `invalid_request` | shape/enum/length violation (message says which field) |
| 401 | `unauthorized` | no/invalid JWT |
| 403 | `forbidden` | anonymous user, pending deletion, or no write access to that library |
| 403 | `evaluation_consent_required` | regression case without explicit retention consent |
| 404 | `output_not_found` | provenance id unknown **or** not in the selected/accessible library (deliberately indistinguishable) |
| 409 | `feedback_key_conflict` | client_key already bound to another output |
| 409 | `feedback_revision_conflict` | same revision, different content |
| 409 | `feedback_exists` | another client_key already holds this actor's verdict for this output |
| 409 | `output_mismatch` | pinned output_sha256 differs from the retained candidate |
| 409 | `evidence_unavailable` | regression case on an output with no retained evidence |
| 429 | `rate_limited` | 120 submits / 10 min / user |
| 503 | `upstream` | database unavailable; safe to retry with the same key |

### 4.6 Offline / retry semantics (client)
1. On tap, write the queued item `{client_key, provenance_id, revision, verdict, reasons, note}`
   to durable local storage **before** any network call; show the chosen state immediately.
2. Send; on `200` mark delivered (keep `client_key` + `revision` for later revisions).
3. On network failure, `429`, `5xx`: keep queued, retry with exponential backoff
   (same body, same key). Any number of retries yields one row.
4. On a later change by the user: bump `revision` locally, overwrite the queued
   body, send. If an older revision is still in flight the server keeps the
   highest revision it has seen.
5. On `404 output_not_found`: drop the item (the photo or its library is gone).
6. On `409 feedback_key_conflict`: a local bug — drop the item and generate a new key.
7. On `409 feedback_exists`: adopt the returned `client_key` and resend with
   `revision = returned.revision_count + 1` if the local verdict differs.
8. Never block saving, exporting, selecting or publishing on feedback delivery.

### 4.7 Revision semantics (summary)
`revision` is a client-owned monotonically increasing integer per `(output, actor)`
starting at 1. The server stores the highest revision and `revision_count`
(number of distinct accepted revisions). Historical verdict text is not kept;
the row is the current opinion. The report counts each `(output, actor)` once.

---

## 5. Admin report — `GET /admin/photo-feedback?window=7d|30d|90d`
Admin-gated exactly like every other `/admin` route. Calls
`public.photo_feedback_report(p_from, p_to)` (service_role). Response:
```json
{
  "generated_at": "...", "window": "30d", "from": "...", "to": "...",
  "basis": "Generated = photo_edit_evidence rows created in the window (all states). Explicitly reviewed = distinct outputs with at least one explicit verdict. Ledger amounts are internal modeled estimates, not supplier invoices. Observational breakdowns are not evidence that one setting is better.",
  "generated": {"outputs": 0, "accepted": 0, "refused": 0, "held": 0, "pending": 0},
  "explicit": {"reviewed_outputs": 0, "useful": 0, "needs_work": 0, "useful_rate": null, "coverage": null, "unreviewed_outputs": 0, "reviewers": 0},
  "signals": {"accuracy_ack": 0, "manual_selection": 0, "automatic_selection": 0, "export": 0, "publication": 0, "note": "Selection, export and publication are not quality judgments."},
  "reasons": [{"reason":"...", "group":"fidelity|taste|other", "feedback_rows": 0, "outputs": 0}],
  "by_edit": [{"key":"stage", "generated":0, "reviewed":0, "useful":0, "needs_work":0, "useful_rate":null}],
  "by_provider_model": [{"key":"gemini/gemini-2.5-flash-image", "generated":0, "reviewed":0, "useful":0, "needs_work":0, "useful_rate":null}],
  "by_recipe_revision": [{"key":"photo-recipe/2026-10-17.1" | "unknown", ...}],
  "cost": {
    "attributable_attempts": 0, "succeeded_attempts": 0, "failed_or_rejected_attempts": 0, "uncertain_attempts": 0,
    "recorded_cents": 0, "outstanding_hold_cents": 0, "unknown_attribution_outputs": 0,
    "attempts_per_useful": null, "recorded_cents_per_useful": null,
    "basis": "recorded_cents = cost_ledger rows bound to this window's generation attempts (photo_edit + photo-qc), each settlement counted once by ledger id. outstanding_hold_cents = reservations not yet bound to a ledger row and not rejected. Internal modeled estimates, never invoices."
  },
  "regression_cases": {"active": 0, "withdrawn": 0, "by_defect": [], "by_recipe_revision": []},
  "sample_note": "n < 30 reviewed outputs in any cell is too small to read as a rate."
}
```
Rates are `null` when the denominator is 0. Every cell carries its own `n`.
Studio renders the honesty wording verbatim.

Cost accounting rules (proven in `photo_feedback_pg.py`):
* Attempts = `serving_cost_reservations` rows whose `(org_id, actor_id, request_key)` match a
  window evidence row and whose stage starts with `photo.`; plus the judge
  reservation `photo-qc:<check>`. Each reservation counted once.
* `recorded_cents` sums **distinct** `cost_ledger.id` reached either via
  `reservation.ledger_id` or via `meta.request_key+meta.stage` (whichever exists) — a
  settlement bound both ways counts once.
* Failed/rejected attempts are counted in `failed_or_rejected_attempts`; a
  rejected reservation contributes no hold and (by trigger rule) no ledger.
* `uncertain` reservations keep their hold in `outstanding_hold_cents`.
* Outputs with no evidence (historical) are `unknown_attribution_outputs` and
  contribute nothing to attempts or cents.

---

## 6. Studio
* Control: `PhotoFeedbackControl` inside the existing "Review your edit"
  block, below the export panel: two small buttons (Useful / Needs work), the
  eight reasons as checkboxes when Needs work, optional note, "Saved" /
  "Will send when online" status. Changing a verdict re-opens the reasons and
  bumps `revision`.
* Queue: `features/creative/photo-feedback-queue.ts` — IndexedDB store
  `rendprop-photo-feedback-v1`, same style as `photo-request-journal.ts`;
  flushed on load, on `online`, and after each submit. Idempotent by design.
* Admin page: route `admin/photo-feedback` visible only when
  `GET /admin/photo-feedback` answers 200 (the server is the gate); shows the
  JSON above with sample sizes, date range and the basis wording.
* Budget: `scripts/check-dist.mjs` gzip budget 400 kB (currently ≈394.7 kB);
  the control and page are written without new dependencies.

---

## 7. Tests
* `services/supabase/tests/photo_feedback.sql` + `photo_feedback_pg.py`
  (disposable PG): wrong user / wrong listing refused as 404; exact-version
  attribution (two outputs from one source, feedback lands on the chosen
  provenance); duplicate submit → one row; revision in place; historical
  provenance-only row keeps nulls; report denominators with fixtures that
  include a rejected attempt, an uncertain attempt and a retried stage (two
  reservations, one ledger); cascade on listing delete and on user delete;
  existing `photo_quality_evidence.sql`, `studio_photo_history.sql`,
  `native_photo_family_selection.sql` and `negative_upload_publication.sql`
  still pass on the same cluster.
* `services/supabase/functions/photo-feedback/handler.test.ts` and
  `admin/photo-feedback.test.ts` (Deno, RPC stubbed): routing, validation,
  consent requirement, error mapping, zero network.
* `apps/studio`: `photo-feedback-queue.test.ts` (unit), browser test for the
  control + offline replay (`STUDIO_BROWSER_EXECUTABLE`).
* Fixture dataset: `services/supabase/tests/fixtures/photo_feedback_report_demo.sql`
  clearly labeled synthetic; demonstrates the report with zero provider calls.

---

## 8. What this learns now vs later
Now: recurring defect reasons per edit / provider+model / recipe revision,
useful rate among explicit reviews with honest coverage, recorded cost and
attempts per explicitly useful result, and a private regression set tied to
the exact evidence objects and recipe revision. Later (needs a funded
experiment): any causal claim that a prompt or provider is better — that needs
a controlled A/B or a paid re-run of the regression set against a candidate
recipe, which this version deliberately does not schedule.

---

## Amendments
(none yet)
