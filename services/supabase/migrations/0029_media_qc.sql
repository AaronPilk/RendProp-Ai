-- 0029: THE DRIFT VERDICT BECOMES COMPLIANCE EVIDENCE (2026-09-07).
--
-- Adds `media_provenance.qc` + `qc_checked_at` and one service-role RPC that
-- writes them, so the machine check that says "the architecture did not change"
-- is stored next to the disclosure sentence it qualifies.
--
-- ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
--
-- The owner sent a screenshot of a generated aerial: smeared, warped roof tiles
-- over invented geometry. "the photo to reel generator is changing how the
-- house looks and that's false advertising — it has AI slop left over." It was
-- not his house.
--
-- services/supabase/functions/ai-video/ now judges every generated clip against
-- the photograph it was generated from (`judge.qc_drift`, seeded in 0018 and
-- until now with zero callers) and refuses the ones that changed the property.
-- That verdict is the single most useful row in the compliance story this table
-- already tells:
--
--   CA AB 723 (in force 1 Jan 2026) requires AI-altered listing media to be
--   disclosed. media_provenance.disclosure says WHAT was altered. `qc` says
--   what was CHECKED and what it scored — which is the difference between
--   "we told the buyer this was AI" and "we told the buyer this was AI, and
--   here is the evidence it is still the same building".
--
--   NorthstarMLS requires a before image per altered room. `original_key`
--   already carries the before; `qc.scores.same_room` is the assertion that
--   the after is the same room, made by something other than the seller.
--
-- ── WHY SERVICE-ROLE ONLY, WHICH IS THE WHOLE POINT ─────────────────────────
--
-- record_provenance() and set_provenance_media() (0012) are executed AS THE
-- CALLER, because they record what the agent themselves did: "I generated this
-- clip", "here is the original". That is a declaration, and the declarer should
-- make it.
--
-- A QC verdict is the opposite. It is evidence ABOUT the agent's media, and
-- evidence a party can write about itself is worth nothing — a broker, an MLS
-- or a plaintiff would be right to ignore a passing score the seller was able
-- to type. So this RPC is revoked from `authenticated` and granted to
-- `service_role` alone, exactly like log_job_cost (0006/0010/0024), bump_rate
-- (0004/0006) and refund_rate (0014). The edge function calls it with the
-- service key, passing the org id the CALLER'S OWN JWT resolved to, and the
-- function refuses any row that does not belong to that org.
--
-- The consequence, stated plainly: a tenant can read their qc verdicts (the
-- existing "org provenance read" RLS policy covers the new column) and can
-- never write one.
--
-- ── WHAT THIS DELIBERATELY DOES NOT DO ──────────────────────────────────────
--
-- NO ai_routes SEED. `judge.qc_drift` has been seeded since 0018 with three
-- steps (claude-haiku-4-5 0.66c, claude-sonnet-5 1.3c "escalation",
-- gpt-5.6-luna 0.12c). This work is that seed finally being used; re-seeding it
-- would assert a routing decision that was already made. No `note = 'legacy'`
-- row either, for 0027's and 0028's reason: a legacy row carries the
-- provider/model a SHIPPED edge function hardcodes TODAY, and nothing shipped
-- has ever called this task. With the flag off resolveRoute() therefore answers
-- `[]` and ai-video's own two-step in-code chain runs, which mirrors rows 1 and
-- 2 of 0018 verbatim.
--
-- NO CHANGE TO THE DISCLOSURE. provenance_disclosure() is untouched: the
-- sentence a consumer reads does not change because a clip passed a check, and
-- a clip that FAILS one is never published at all.
--
-- NO CHANGE TO /me/compliance. The export names its columns explicitly
-- (functions/me/index.ts), so `qc` does not appear in the broker's CSV until
-- that file adds it — a one-line follow-up owned by that function, not
-- something this migration can or should reach into. Until then the column is
-- readable by every org member through PostgREST and by an operator in SQL, and
-- the same verdict is also on the cost_ledger row (feature 'qc') that the admin
-- spend console already labels "QC drift judge".
--
-- Idempotent throughout: `add column if not exists` + `create or replace`, so
-- the replay CI performs on every migration from 0009 onward is a no-op.

-- ── 1. The columns ──────────────────────────────────────────────────────────

alter table public.media_provenance
  add column if not exists qc jsonb,
  add column if not exists qc_checked_at timestamptz;

comment on column public.media_provenance.qc is
  'The drift check''s verdict for this generated media: per-category scores (architecture, contents, additions, artifacts, same_room), the thresholds they were judged against, confidence, the judge model, and the action taken (accept|retry|refuse|hold). Written ONLY by record_media_qc() under the service role — a tenant can read it and can never write it. Absent means the media was never checked, which is not the same as passing.';
comment on column public.media_provenance.qc_checked_at is
  'When the drift check ran. Null = never checked.';

-- Operator query: "show me everything published this month that failed or was
-- never checked". Partial, because the rows that matter are the exceptions.
create index if not exists idx_provenance_qc_unchecked
  on public.media_provenance (org_id, created_at desc)
  where qc is null;

-- ── 2. record_media_qc(): the only way a verdict is ever written ────────────

create or replace function public.record_media_qc(
  p_id uuid,
  p_org uuid,
  p_qc jsonb
) returns public.media_provenance
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_row media_provenance;
begin
  if p_id is null or p_org is null then
    raise exception 'RP400: record_media_qc needs both a provenance id and an org id';
  end if;

  -- The verdict is machine-written and bounded by the caller, but this is the
  -- last line of defence for a column every org member can read: an object, and
  -- a small one. 4 kB is roughly ten times the verdict the edge function sends.
  if p_qc is null or jsonb_typeof(p_qc) <> 'object' then
    raise exception 'RP400: qc must be a JSON object';
  end if;
  if length(p_qc::text) > 4096 then
    raise exception 'RP400: qc verdict is too large';
  end if;

  -- ORG SCOPE. The org comes from the edge function, which resolved it from the
  -- caller's own JWT; a row belonging to anyone else is reported as missing
  -- rather than as forbidden, the same way set_provenance_media() refuses to
  -- confirm that another workspace's row exists.
  select mp.* into v_row
    from media_provenance mp
   where mp.id = p_id and mp.org_id = p_org;
  if not found then
    raise exception 'RP404: provenance record not found';
  end if;

  update media_provenance
     set qc = jsonb_strip_nulls(p_qc),
         qc_checked_at = now()
   where id = p_id
  returning * into v_row;

  return v_row;
end;
$fn$;

-- Evidence a party can write about itself is worth nothing: `authenticated`
-- never gets this, only the server does. See the header.
revoke execute on function public.record_media_qc(uuid, uuid, jsonb) from public, anon, authenticated;
grant  execute on function public.record_media_qc(uuid, uuid, jsonb) to service_role;

comment on function public.record_media_qc(uuid, uuid, jsonb) is
  'Stamp the AI drift check''s verdict onto a media_provenance row. SERVICE ROLE ONLY: a tenant must not be able to write a passing quality verdict about their own listing media. Called by POST /ai-video/drift with the org id resolved from the caller''s JWT.';
