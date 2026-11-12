-- The photo judge's verdict no longer decides whether an accepted AI photo edit
-- can be used in a Photo Motion property video (12 Nov 2026).
--
-- Owner decisions of 6 and 12 Nov 2026: the photo review is advisory. An edit
-- is delivered and marked publishable whatever the judge found; the verdict and
-- its findings stay on the disclosure record for the agent to read. Two
-- functions on the Photo Motion video path still asked for verdict = 'pass'
-- whenever a verdict was present, so a staged or twilight photo that the judge
-- commented on (3 of 4 judged twilight edits and 1 of 5 judged staging edits in
-- production) was accepted, shown to the agent, and then refused as a video
-- source with "Keep the exact quality-approved saved edit master", or dropped
-- at publication.
--
-- This removes exactly that one clause from each function. Everything else they
-- check is untouched: the disclosure row exists for the same org and listing,
-- qc.publishable is true, qc.action is 'accept' (or the older 'pass'), and
-- qc.output_sha256 equals the exact saved bytes.
--
-- Safe to apply more than once: each function is patched only when the clause
-- is present exactly once; when it is already gone the block does nothing;
-- anything else (a changed predecessor) aborts the whole migration untouched.
-- Signature, owner, SECURITY DEFINER, search_path and grants are compared
-- before and after and must be identical.
--
-- Rollback (restores the two clauses; run as one transaction):
--   re-insert  or(proof.qc?'verdict'and proof.qc->>'verdict'is distinct from'pass')
--     after    or proof.qc->>'output_sha256'is distinct from ctx->>'sha256'
--     in public.property_video_photo_motion_manifest_before_opening_20261022(uuid,jsonb)
--   re-insert  and(not(p.qc?'verdict')or p.qc->>'verdict'='pass')
--     after    and p.qc->>'output_sha256'=a.sha256
--     in public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)
--   (the exact statements are in /home/claude/reports/staging-guardrails.md)
begin;

do $advisory$
declare
  item record;
  target regprocedure;
  def text;
  before_meta jsonb;
  occurrences integer;
begin
  for item in
    select * from (values
      ('public.property_video_photo_motion_manifest_before_opening_20261022(uuid,jsonb)',
       $n$or(proof.qc?'verdict'and proof.qc->>'verdict'is distinct from'pass')$n$),
      ('public.property_video_photo_motion_publication(uuid,uuid,uuid,uuid,jsonb)',
       $n$and(not(p.qc?'verdict')or p.qc->>'verdict'='pass')$n$)
    ) as t(signature, needle)
  loop
    target := item.signature::regprocedure;
    select to_jsonb(p) - 'prosrc' - 'prosqlbody', pg_get_functiondef(p.oid)
      into before_meta, def
      from pg_proc p where p.oid = target;
    occurrences := (length(def) - length(replace(def, item.needle, ''))) / length(item.needle);
    if occurrences = 0 and position('verdict' in def) = 0 then
      raise notice '% already ignores the photo verdict; nothing to change', item.signature;
      continue;
    end if;
    if occurrences <> 1 then
      raise exception '% changed: expected the photo verdict clause exactly once, found % (review before applying)', item.signature, occurrences;
    end if;
    execute replace(def, item.needle, '');
    if (select to_jsonb(p) - 'prosrc' - 'prosqlbody' from pg_proc p where p.oid = target) is distinct from before_meta then
      raise exception '% metadata changed while removing the photo verdict clause', item.signature;
    end if;
    if position('verdict' in (select prosrc from pg_proc where oid = target)) <> 0 then
      raise exception '% still refers to the photo verdict', item.signature;
    end if;
    if position('publishable' in (select prosrc from pg_proc where oid = target)) = 0
       or position('output_sha256' in (select prosrc from pg_proc where oid = target)) = 0 then
      raise exception '% lost its publishable / exact-bytes requirement', item.signature;
    end if;
  end loop;
end
$advisory$;

commit;
