-- Freeze new RentCast cost attribution to the server-owned admitted attempt.
-- No historical ledger/receipt update, price change, grant, or Team-binding change.
begin;
do $pin$declare h text;begin
 select md5(prosrc)into h from pg_catalog.pg_proc where oid='public.stamp_library_financial_liability()'::regprocedure;
 if h is null or h not in('3976c4aaf6cea5185df1e133475fb83f','73882a6e41ff1dee0d8b6b0ee3f1609c') then raise exception 'Review changed function stamp_library_financial_liability';end if;
 if to_regclass('public.provider_attempt_receipts')is null then raise exception 'Provider attempt receipts must exist before liability binding';end if;
end$pin$;
CREATE OR REPLACE FUNCTION public.stamp_library_financial_liability()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid;b uuid;matches integer;attempt public.provider_attempt_receipts;attempt_ledger public.cost_ledger;row_data jsonb:=to_jsonb(new);begin
 if tg_op='UPDATE'then if new.billing_org_id is distinct from old.billing_org_id then raise exception 'RP409: Billing liability identity is immutable';end if;return new;end if;
 actor:=coalesce(nullif(row_data->>'actor_id','')::uuid,nullif(row_data->>'user_id','')::uuid);
 if tg_table_name='cost_ledger'then
  -- A RentCast attempt captures its paying organization before supplier dispatch.
  -- An old in-flight writer has no actor metadata; check it whenever available.
  if new.meta ? 'provider_attempt_id' then
   if jsonb_typeof(new.meta->'provider_attempt_id') is distinct from 'string'
    or new.meta->>'provider_attempt_id' !~* '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'
    or (new.meta ? 'actor_id' and (jsonb_typeof(new.meta->'actor_id') is distinct from 'string'
      or new.meta->>'actor_id' !~* '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$')) then
    raise exception 'RP403: Provider attempt ledger identity is invalid';
   end if;
   select * into attempt from public.provider_attempt_receipts r
    where r.id=(new.meta->>'provider_attempt_id')::uuid for update;
   if attempt.id is null or attempt.org_id is distinct from new.org_id
    or attempt.provider is distinct from new.provider or attempt.model is distinct from new.model
    or attempt.stage is distinct from 'property.lookup' or new.feature is distinct from 'property_lookup'
    or new.job_id is not null or coalesce(new.meta->>'result','') not in ('hit','no_record')
    or (new.billing_org_id is not null and new.billing_org_id is distinct from attempt.billing_org_id)
    or (new.idempotency_key is not null and new.idempotency_key is distinct from 'provider-attempt:'||attempt.id::text)
    or (new.meta ? 'actor_id' and attempt.actor_id is distinct from (new.meta->>'actor_id')::uuid)
    or (actor is not null and actor is distinct from attempt.actor_id) then
    raise exception 'RP403: Provider attempt does not match this ledger identity';
   end if;
   -- A repeated exact settlement recognizes the existing row, including an old
   -- writer's null-key row. Never move or rewrite that row or invent a charge.
   select count(*) into matches from public.cost_ledger l where l.org_id=new.org_id
    and l.meta->>'provider_attempt_id'=attempt.id::text;
   if matches>0 then
    select * into attempt_ledger from public.cost_ledger l where l.org_id=new.org_id
     and l.meta->>'provider_attempt_id'=attempt.id::text limit 1;
    if matches<>1 or attempt.outcome not in ('intent','hit','no_record')
     or row(attempt_ledger.job_id,attempt_ledger.org_id,attempt_ledger.billing_org_id,attempt_ledger.feature,attempt_ledger.provider,attempt_ledger.model,attempt_ledger.units,attempt_ledger.unit_cost_cents,attempt_ledger.total_cents)
       is distinct from row(new.job_id,new.org_id,attempt.billing_org_id,new.feature,new.provider,new.model,new.units,new.unit_cost_cents,new.total_cents)
     or attempt_ledger.meta->>'result' is distinct from new.meta->>'result'
     or (attempt_ledger.meta ? 'actor_id' and attempt_ledger.meta->>'actor_id' is distinct from attempt.actor_id::text) then
     raise exception 'RP409: Existing provider attempt cost does not match';
    end if;
    return null;
   end if;
   if attempt.outcome is distinct from 'intent' then raise exception 'RP409: Terminal provider attempt cannot add a cost';end if;
   if new.idempotency_key is not null and new.idempotency_key is distinct from 'provider-attempt:'||attempt.id::text then
    raise exception 'RP403: Provider attempt ledger key is server-owned';
   end if;
   new.idempotency_key:='provider-attempt:'||attempt.id::text;
   b:=attempt.billing_org_id;
  end if;
  -- Exact existing request/stage/provider/model is accounting authority. Never
  -- choose a FIFO predecessor or the most convenient current Team relationship.
  if b is null then
  select count(*),min(r.billing_org_id::text)::uuid into matches,b from public.serving_cost_reservations r
  where r.org_id=new.org_id and r.request_key=coalesce(nullif(new.meta->>'request_key',''),new.idempotency_key)and r.stage=new.meta->>'stage'and r.provider=new.provider and r.model=new.model
    and (new.meta->>'actor_id'is null or r.actor_id::text=new.meta->>'actor_id');
  if matches<>1 then b:=null;end if;
  end if;
  if b is null and new.meta->>'app_video_reservation_id'~'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'then
   select r.billing_org_id into b from public.app_video_cost_reservations r where r.id=(new.meta->>'app_video_reservation_id')::uuid
    and(r.org_id=new.org_id or(new.org_id is null
      and not exists(select 1 from public.orgs o where o.id=r.org_id)
      -- A deleted-org receipt may inherit liability only from this exact
      -- immutable reservation and its deterministic writer identity.
      and new.idempotency_key='app-video:'||r.id::text
      and new.feature=r.feature and new.units=r.units
      and new.unit_cost_cents=r.unit_cost_cents and new.total_cents=r.total_cents))
    and r.provider=new.provider and r.model=new.model
    and r.idempotency_key=new.meta->>'request_key'and r.feature=new.meta->>'stage';
  end if;
  if b is null and new.meta->>'erase_job_id'~'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'then
   select j.billing_org_id into b from public.video_erase_jobs j where j.id=(new.meta->>'erase_job_id')::uuid and j.org_id=new.org_id and j.provider=new.provider and new.meta->>'stage'in('reflection.fal','reflection.mask','reflection.erase');
  end if;
  if b is null and new.job_id is not null then select j.billing_org_id,l.agent_id into b,actor from public.render_jobs j join public.listings l on l.id=j.listing_id where j.id=new.job_id;end if;
 end if;
 if tg_table_name='media_storage_receipts'then actor:=new.actor_id;b:=case when actor is null then public.library_storage_billing_org(new.org_id,new.bucket,new.object_key)else public.library_actor_billing_org(actor,new.org_id)end;end if;
 b:=coalesce(b,case when actor is null then public.library_billing_org(new.org_id)else public.library_actor_billing_org(actor,new.org_id)end);
 if new.billing_org_id is not null and new.billing_org_id<>b then raise exception 'RP403: Billing org is server-owned';end if;
 new.billing_org_id:=b;return new;
end$function$
;
commit;
