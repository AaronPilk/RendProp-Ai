-- Keep late accepted video receipts chargeable after actual account purge.
-- No metadata-only billing inference: match the original immutable reserve.
-- Missing/mismatched identity remains held; uncertain holds are not released.
begin;
do $pin$declare h text;begin
 select md5(prosrc)into h from pg_catalog.pg_proc where oid='public.stamp_library_financial_liability()'::regprocedure;
 if h not in('8c7925c25a309307dc92c82c6b2f8780','3976c4aaf6cea5185df1e133475fb83f')then raise exception 'Review changed function stamp_library_financial_liability';end if;
end$pin$;
CREATE OR REPLACE FUNCTION public.stamp_library_financial_liability()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid;b uuid;matches integer;row_data jsonb:=to_jsonb(new);begin
 if tg_op='UPDATE'then if new.billing_org_id is distinct from old.billing_org_id then raise exception 'RP409: Billing liability identity is immutable';end if;return new;end if;
 actor:=coalesce(nullif(row_data->>'actor_id','')::uuid,nullif(row_data->>'user_id','')::uuid);
 if tg_table_name='cost_ledger'then
  -- Exact existing request/stage/provider/model is accounting authority. Never
  -- choose a FIFO predecessor or the most convenient current Team relationship.
  select count(*),min(r.billing_org_id::text)::uuid into matches,b from public.serving_cost_reservations r
  where r.org_id=new.org_id and r.request_key=coalesce(nullif(new.meta->>'request_key',''),new.idempotency_key)and r.stage=new.meta->>'stage'and r.provider=new.provider and r.model=new.model
    and (new.meta->>'actor_id'is null or r.actor_id::text=new.meta->>'actor_id');
  if matches<>1 then b:=null;end if;
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
