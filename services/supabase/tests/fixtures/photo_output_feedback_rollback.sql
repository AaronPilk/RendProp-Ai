-- Rollback for migrations/20261017200000_photo_output_feedback.sql, proven on a
-- disposable cluster by services/supabase/tests/photo_feedback_pg.py (catalog
-- returns to the exact pre-migration boundary; the migration re-applies after).
--
-- ORDER: reverse the deploy first. Redeploy the previous ai-photo (the current
-- one records photo_quality_set_recipe before every dispatch and, without
-- this SQL, refuses to dispatch at all), the previous admin, and remove the
-- photo-feedback function; THEN run this file.
--
-- Removes only this migration's own, exactly pinned objects. Feedback rows,
-- signals, regression cases and recipe identities are observations, never
-- authority: no evidence, provenance, check, delivery, hold or ledger row is
-- touched. Because dropping them is irreversible, the rollback refuses while
-- any exist unless the operator confirms in the same session:
--   set rendprop.photo_feedback_rollback = 'discard-observations';
begin;
do $rollback_guard$
declare e record;p pg_catalog.pg_proc;n bigint:=0;c bigint;
begin
 for e in select *from(values
  ('public.photo_quality_set_recipe(uuid,uuid,text,text)','a0da42a32dfd40ed164661174d4c26e1'),
  ('public.photo_feedback_resolve(uuid,uuid,uuid)','1949e0d144fe8a538baf34a0d15f82d7'),
  ('public.photo_feedback_attribution(uuid,uuid)','5e189f1e47ece7566c493aef4c5ec9d2'),
  ('public.photo_feedback_submit(uuid,uuid,uuid,text,text,integer,text,text[],text,text)','10fd653227b7438fd093546bfe2b7a13'),
  ('public.photo_feedback_signal(uuid,uuid,uuid,text,text,text,text)','3bb19af4fb47ebe00f0f6be690f339fb'),
  ('public.photo_feedback_state(uuid,uuid,uuid)','5d04e0ac05c04c506ed0a53b63042164'),
  ('public.photo_regression_case_mark(uuid,uuid,uuid,text,text,boolean,boolean)','d6d2f35d63e5e1f3962d787928f0a514'),
  ('public.photo_regression_cases_for_review(text)','6c69bce0613b63b1fb77b4913e789da3'),
  ('public.photo_feedback_report(timestamptz,timestamptz)','8c5df8f177478c5d95df5040d2238835')
 )v(signature,body_md5)loop
  if to_regprocedure(e.signature)is not null then
   select *into p from pg_catalog.pg_proc where oid=to_regprocedure(e.signature);
   if md5(p.prosrc)<>e.body_md5 then raise exception 'Rollback refuses a changed photo feedback helper: %',e.signature;end if;
  end if;
 end loop;
 if to_regclass('public.photo_output_feedback')is not null then n:=n+(select count(*)from public.photo_output_feedback);end if;
 if to_regclass('public.photo_output_signals')is not null then n:=n+(select count(*)from public.photo_output_signals);end if;
 if to_regclass('public.photo_regression_cases')is not null then n:=n+(select count(*)from public.photo_regression_cases);end if;
 if exists(select 1 from pg_catalog.pg_attribute where attrelid='public.photo_edit_evidence'::regclass and attname='recipe_revision'and not attisdropped)then
  execute 'select count(*)from public.photo_edit_evidence where recipe_revision is not null or prompt_sha256 is not null'into c;n:=n+c;
 end if;
 if n>0 and current_setting('rendprop.photo_feedback_rollback',true)is distinct from'discard-observations'then
  raise exception 'Rollback would discard % recorded photo feedback observations; set rendprop.photo_feedback_rollback=discard-observations to confirm',n;
 end if;
end$rollback_guard$;
drop function if exists public.photo_feedback_report(timestamptz,timestamptz);
drop function if exists public.photo_regression_cases_for_review(text);
drop function if exists public.photo_regression_case_mark(uuid,uuid,uuid,text,text,boolean,boolean);
drop function if exists public.photo_feedback_state(uuid,uuid,uuid);
drop function if exists public.photo_feedback_signal(uuid,uuid,uuid,text,text,text,text);
drop function if exists public.photo_feedback_submit(uuid,uuid,uuid,text,text,integer,text,text[],text,text);
drop function if exists public.photo_feedback_attribution(uuid,uuid);
drop function if exists public.photo_feedback_resolve(uuid,uuid,uuid);
drop function if exists public.photo_quality_set_recipe(uuid,uuid,text,text);
drop table if exists public.photo_regression_cases;
drop table if exists public.photo_output_signals;
drop table if exists public.photo_output_feedback;
alter table public.photo_edit_evidence drop constraint if exists photo_edit_evidence_recipe_pair_check;
alter table public.photo_edit_evidence drop constraint if exists photo_edit_evidence_recipe_revision_check;
alter table public.photo_edit_evidence drop constraint if exists photo_edit_evidence_prompt_sha256_check;
alter table public.photo_edit_evidence drop column if exists recipe_revision;
alter table public.photo_edit_evidence drop column if exists prompt_sha256;
commit;
