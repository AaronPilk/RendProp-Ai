-- Putting an AI-edited photo on a listing no longer needs a "reviewed" flag
-- from the client (12 Nov 2026).
--
-- OWNER DECISION, 12 Nov 2026: the agent is responsible for what they post; no
-- review tick may block using an AI result.
--
-- Before: native_gallery_selection_target refused every AI edit chosen for a
-- cloud listing unless the request carried reviewed = true. iOS build 147 sends
-- false from the photo grid's "set as cover", from the first publication of a
-- listing and from the browser-copy repair, so those choices were refused with
-- "Compare the accepted edit with its retained original before choosing it"
-- for every AI edit, decluttered ones included.
--
-- After: the flag is not read. p_reviewed stays in the signature so the two
-- callers (native_gallery_selection_change and native_gallery_selection_change_v2)
-- are untouched; they still validate that the request carries a boolean
-- "reviewed" and still store the request exactly as the client sent it in
-- native_gallery_selection_operations.request, so the record of what the
-- client said is unchanged.
--
-- Everything else this function requires of an AI edit is untouched: the edit
-- record belongs to this workspace, is a photo edit with a non-empty AI
-- disclosure and a separate retained original; a recorded check result, if
-- any, is publishable with action accept/pass; its evidence is accepted and is
-- not calibration evidence; the original is present, owned and visible. The
-- one remaining refusal keeps its RP409 status and gets wording that no longer
-- tells the user to compare (comparing would not clear it).
--
-- Rewrites one function and no other. None of 20261112193000, 210000, 213000,
-- 214000, 220000, 223000 or 223100 touches it, so this file has no ordering
-- dependency on them.
--
-- Safe to run more than once: the function is pinned to its production md5
-- (read 12 Nov 2026); a second run finds the rewritten body and does nothing;
-- any other body aborts the migration untouched. Owner, grants, SECURITY
-- DEFINER and search_path are kept (CREATE OR REPLACE of the stored definition)
-- and verified.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $rewrite$
declare
 signature constant text := 'public.native_gallery_selection_target(uuid,uuid,uuid,text,bigint,boolean)';
 before_md5 constant text := 'c9457011c3ae8bb39a9599bcad6f38c8';
 after_md5 constant text := '0eaf78cb5c019531ed1da8872e77f943';
 review_clause constant text := $n$p_reviewed is distinct from true or $n$;
 old_refusal constant text := $n$raise exception'RP409: Compare the accepted edit with its retained original before choosing it'$n$;
 new_refusal constant text := $n$raise exception'RP409: This edited photo cannot be used on the listing yet. Its AI-edit record is incomplete or the edit was not accepted. Make the edit again, then choose the new version'$n$;
 current_md5 text;
 definition text;
 before_meta jsonb;
begin
 select md5(prosrc) into current_md5 from pg_proc where oid = to_regprocedure(signature);
 if current_md5 is null then
  raise exception '% is missing; review the review-not-required rewrite before applying', signature;
 end if;
 if current_md5 = after_md5 then
  raise notice '% already accepts an AI edit without a review flag; nothing to do', signature;
  return;
 end if;
 if current_md5 <> before_md5 then
  raise exception '% changed since 2026-11-12; review the review-not-required rewrite before applying', signature;
 end if;
 select to_jsonb(p) - 'prosrc' - 'prosqlbody', pg_get_functiondef(p.oid) into before_meta, definition
  from pg_proc p where p.oid = signature::regprocedure;
 if length(definition) - length(replace(definition, review_clause, '')) <> length(review_clause) then
  raise exception '% review clause not found exactly once', signature;
 end if;
 if length(definition) - length(replace(definition, old_refusal, '')) <> length(old_refusal) then
  raise exception '% review refusal not found exactly once', signature;
 end if;
 execute replace(replace(definition, review_clause, ''), old_refusal, new_refusal);
 if (select to_jsonb(p) - 'prosrc' - 'prosqlbody' from pg_proc p where p.oid = signature::regprocedure) is distinct from before_meta then
  raise exception '% metadata changed', signature;
 end if;
 if (select md5(prosrc) from pg_proc where oid = signature::regprocedure) is distinct from after_md5 then
  raise exception '% rewrite is not the reviewed body', signature;
 end if;
 if (select prosrc from pg_proc where oid = signature::regprocedure) like '%p_reviewed%' then
  raise exception '% still reads the review flag', signature;
 end if;
 if (select prosrc from pg_proc where oid = signature::regprocedure) not like '%publishable%'
  or (select prosrc from pg_proc where oid = signature::regprocedure) not like '%purpose=''calibration''%'
  or (select prosrc from pg_proc where oid = signature::regprocedure) not like '%nullif(btrim(m.disclosure),'''')is null%' then
  raise exception '% lost its disclosure, publishable or accepted-evidence requirement', signature;
 end if;
end
$rewrite$;
commit;
