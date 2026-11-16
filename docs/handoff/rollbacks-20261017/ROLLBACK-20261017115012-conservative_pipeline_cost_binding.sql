-- Rollback for services/supabase/migrations/20261017115012_conservative_pipeline_cost_binding.sql
--
-- Undoes exactly that migration's catalog changes and nothing else:
--   1. restores the predecessor body of public.serving_ceiling_spent_cents (md5 d053fe5bd094d958041a48f0c02dfa4f)
--   2. restores the predecessor body of public.serving_cost_finish         (md5 8a15681fa25434571b4d7439731a6d3e)
--   3. drops public.pipeline_record_provider_cost and public.pipeline_cost_covered_cents
--   4. drops public.pipeline_provider_cost_bindings
-- No row of cost_ledger or serving_cost_reservations is read, written or deleted: the
-- ledger rows the RPC wrote stay exactly as recorded (their `pipeline:<reservation>`
-- idempotency key and meta.pipeline_reservation_id keep the attempt link readable).
-- The ONLY rows this script can remove are binding rows in the migration's own relation,
-- and it refuses to do so unless the operator opts in (see step 4). After the rollback
-- the predecessor ceiling counts bound holds in full again (more conservative, never less).
--
-- Each restore is the exact inverse of the migration's single-splice patch: the current
-- body must contain the migration's replacement text exactly once, and reversing it must
-- reproduce the pinned predecessor md5, otherwise nothing is executed. CREATE OR REPLACE
-- keeps owner, ACL, SECURITY DEFINER and SET search_path, because pg_get_functiondef
-- emits them and the function identity is unchanged.
begin;

-- 1. serving_ceiling_spent_cents: reverse the summand splice.
do $unpatch$declare def text;needle text;replacement text;body text;begin
 select pg_get_functiondef(oid),prosrc into def,body from pg_proc where oid='public.serving_ceiling_spent_cents(uuid,timestamptz,timestamptz)'::regprocedure;
 needle:=$n$select sum(hold_cents) from public.serving_cost_reservations r where r.billing_org_id=public.library_billing_org(p_org) and r.budget_source='ceiling' and r.ledger_id is null$n$;
 replacement:=$n$select sum(case when exists(select 1 from public.pipeline_provider_cost_bindings b where b.reservation_id=r.id)
   then greatest(0,r.hold_cents-public.pipeline_cost_covered_cents(r.id,p_start,p_end))else r.hold_cents end)
  from public.serving_cost_reservations r where r.billing_org_id=public.library_billing_org(p_org) and r.budget_source='ceiling'
   and(r.ledger_id is null or exists(select 1 from public.pipeline_provider_cost_bindings b where b.reservation_id=r.id))$n$;
 if md5(body)='d053fe5bd094d958041a48f0c02dfa4f'then
  raise notice 'serving_ceiling_spent_cents already at the predecessor body; nothing to restore';
 elsif(length(body)-length(replace(body,replacement,'')))/length(replacement)=1
   and md5(replace(body,replacement,needle))='d053fe5bd094d958041a48f0c02dfa4f'then
  if(length(def)-length(replace(def,replacement,'')))/length(replacement)<>1 then raise exception 'Review changed pipeline ceiling summand before rollback';end if;
  execute replace(def,replacement,needle);
 else raise exception 'Review changed serving ceiling authority: not the 20261017115012 body, refusing to rewrite';end if;
 select prosrc into body from pg_proc where oid='public.serving_ceiling_spent_cents(uuid,timestamptz,timestamptz)'::regprocedure;
 if md5(body)<>'d053fe5bd094d958041a48f0c02dfa4f'then raise exception 'serving_ceiling_spent_cents restore did not reproduce the predecessor pin';end if;
end$unpatch$;

-- 2. serving_cost_finish: reverse the RP409 guard splice.
do $unpatch$declare def text;needle text;replacement text;body text;begin
 select pg_get_functiondef(oid),prosrc into def,body from pg_proc where oid='public.serving_cost_finish(uuid,uuid,text,text,text,integer)'::regprocedure;
 needle:=$n$ if r.id is null then raise exception 'RP404: Provider attempt not found';end if;$n$;
 replacement:=needle||E'\n if p_state=\'rejected\'and exists(select 1 from public.pipeline_provider_cost_bindings where reservation_id=r.id)then raise exception\'RP409: An incurred pipeline cost cannot be relabeled rejected\';end if;';
 if md5(body)='8a15681fa25434571b4d7439731a6d3e'then
  raise notice 'serving_cost_finish already at the predecessor body; nothing to restore';
 elsif(length(body)-length(replace(body,replacement,'')))/length(replacement)=1
   and md5(replace(body,replacement,needle))='8a15681fa25434571b4d7439731a6d3e'then
  if(length(def)-length(replace(def,replacement,'')))/length(replacement)<>1 then raise exception 'Review changed pipeline finish guard before rollback';end if;
  execute replace(def,replacement,needle);
 else raise exception 'Review changed serving finish authority: not the 20261017115012 body, refusing to rewrite';end if;
 select prosrc into body from pg_proc where oid='public.serving_cost_finish(uuid,uuid,text,text,text,integer)'::regprocedure;
 if md5(body)<>'8a15681fa25434571b4d7439731a6d3e'then raise exception 'serving_cost_finish restore did not reproduce the predecessor pin';end if;
end$unpatch$;

-- 3. The two helpers added by the migration.
drop function if exists public.pipeline_record_provider_cost(uuid,uuid,uuid,text,text,text,text,text,uuid,text,numeric,numeric,numeric,jsonb);
drop function if exists public.pipeline_cost_covered_cents(uuid,timestamptz,timestamptz);

-- 4. The binding relation. Binding rows are the only data this script can remove.
--    They are recoverable from cost_ledger (idempotency_key = 'pipeline:'||reservation_id
--    and meta->>'pipeline_reservation_id'), but the drop is refused unless the operator
--    runs `set local rendprop.rollback_allow_binding_loss = 'on';` in this transaction.
do $guard$declare n bigint;begin
 if to_regclass('public.pipeline_provider_cost_bindings')is null then
  raise notice 'pipeline_provider_cost_bindings already absent';return;end if;
 execute 'select count(*) from public.pipeline_provider_cost_bindings' into n;
 if n>0 and coalesce(current_setting('rendprop.rollback_allow_binding_loss',true),'')<>'on'then
  raise exception 'RP409: % pipeline cost binding row(s) exist; set local rendprop.rollback_allow_binding_loss=''on'' to drop them (ledger and hold rows are never touched)',n;
 end if;
end$guard$;
drop table if exists public.pipeline_provider_cost_bindings;

commit;
