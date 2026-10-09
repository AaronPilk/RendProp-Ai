-- A provider receipt may settle only the exact successful attempt it bills.
-- Missing identity stays held for reconciliation; no FIFO, cross-provider or
-- uncertain-predecessor substitution can release a different liability.
begin;
create function pg_temp.rp_patch(fn regprocedure,needle text,replacement text)returns void
language plpgsql as $$
declare def text;n integer;
begin
 def:=pg_get_functiondef(fn);
 n:=(length(def)-length(replace(def,needle,'')))/length(needle);
 if n<>1 then raise exception 'settlement-identity migration: anchor for % found % times',fn,n;end if;
 execute replace(def,needle,replacement);
end$$;
-- Durable video writers know their exact request and stage. Record those facts
-- on the receipt instead of asking the settlement trigger to guess them.
do $$begin
 perform pg_temp.rp_patch('public.app_video_cost_settle(uuid,uuid,text,text)'::regprocedure,
  $a$'app_video_reservation_id',r.id,'billing_org_id',r.org_id,$a$,
  $a$'app_video_reservation_id',r.id,'billing_org_id',r.org_id,'request_key',r.idempotency_key,'stage',r.feature,$a$);
 perform pg_temp.rp_patch('public.video_erase_finish(uuid,text,jsonb,text,text,text,boolean)'::regprocedure,
  $a$'erase_job_id',j.id,'batch_id',j.batch_id,'request_id',p_ref->>'request_id',$a$,
  $a$'erase_job_id',j.id,'batch_id',j.batch_id,'request_key',j.idempotency_key::text,'stage','reflection.fal','request_id',p_ref->>'request_id',$a$);
 perform pg_temp.rp_patch('public.video_erase_finish_stage(uuid,text,text,jsonb,text,boolean)'::regprocedure,
  $a$'erase_job_id',j.id,'batch_id',j.batch_id,'stage',p_stage,$a$,
  $a$'erase_job_id',j.id,'batch_id',j.batch_id,'request_key',j.id::text,'stage','reflection.'||p_stage,$a$);
end$$;
create or replace function public.cost_ledger_settle_serving_hold()returns trigger
language plpgsql security definer set search_path='' as $$
declare holds uuid[];key text;v_stage text;
begin
 key:=nullif(new.meta->>'request_key','');v_stage:=nullif(new.meta->>'stage','');
 if new.org_id is null or key is null or v_stage is null or new.provider is null or new.model is null then return new;end if;
 -- Actor is not recorded on the receipt. If different actors reuse this
 -- identity, retain every liability rather than choosing one implicitly.
 select array_agg(m.id) into holds from(
  select r.id from public.serving_cost_reservations r
   where r.org_id=new.org_id and r.request_key=key and r.stage=v_stage
    and r.provider=new.provider and r.model=new.model and r.budget_source='ceiling'
    and r.state<>'rejected' for update
 )m;
 if cardinality(holds)=1 then
  update public.serving_cost_reservations set ledger_id=new.id
   where id=holds[1] and state='succeeded' and ledger_id is null;
 end if;
 return new;
end$$;
revoke all on function public.cost_ledger_settle_serving_hold()from public,anon,authenticated;
grant execute on function public.cost_ledger_settle_serving_hold()to service_role,postgres;
-- Restore liabilities that an older permissive trigger matched without exact
-- evidence. Their ledger rows remain counted; reconciliation can repair them.
update public.serving_cost_reservations r set ledger_id=null
 from public.cost_ledger c where r.ledger_id=c.id and r.budget_source='ceiling'
 and (r.org_id is distinct from c.org_id or r.request_key is distinct from c.meta->>'request_key'
  or r.stage is distinct from c.meta->>'stage' or r.provider is distinct from c.provider
  or r.model is distinct from c.model or r.state is distinct from 'succeeded'
  or exists(select 1 from public.serving_cost_reservations other
   where other.id<>r.id and other.org_id=r.org_id and other.request_key=r.request_key
    and other.stage=r.stage and other.provider=r.provider and other.model=r.model
    and other.budget_source='ceiling' and other.state<>'rejected'));
commit;
