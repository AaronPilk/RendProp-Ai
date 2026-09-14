begin;

-- Reserve the exact private audio key before dispatching a paid provider. This
-- inventory exists even if generation fails, its response is lost, or the later
-- best-effort creative-history write is unavailable. An unused key is harmless.
create table public.voice_storage_reservations (
  id uuid primary key,
  -- Retain the cleanup identity when its creator leaves a shared workspace.
  -- The RPC verifies/locks auth.users; an Auth FK cascade here would orphan the
  -- team's retained audio before the workspace's eventual deletion inventory.
  actor_id uuid not null,
  org_id uuid not null references public.orgs(id) on delete cascade,
  listing_id uuid references public.listings(id) on delete set null,
  storage_key text not null unique,
  created_at timestamptz not null,
  write_deadline timestamptz not null,
  constraint voice_storage_exact_key check (
    storage_key='ai-voice/'||org_id::text||'/'||id::text||'.mp3'),
  constraint voice_storage_fixed_window check (
    write_deadline=created_at+interval '15 minutes')
);
create index voice_storage_reservations_org on public.voice_storage_reservations(org_id,write_deadline);
alter table public.voice_storage_reservations enable row level security;
revoke all on public.voice_storage_reservations from public,anon,authenticated,service_role;
grant select on public.voice_storage_reservations to service_role;

create function public.reserve_voice_storage(p_actor uuid,p_org uuid,p_id uuid,p_listing uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare reservation public.voice_storage_reservations%rowtype; reserved_at timestamptz;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege using message='service role required';
  end if;
  if p_actor is null or p_org is null or p_id is null then
    raise exception 'RP400: invalid voice storage scope';
  end if;
  -- Match prepare_account_deletion's parent-lock order. Deletion cannot capture
  -- an empty inventory while this transaction reserves a future audio write.
  perform 1 from auth.users where id=p_actor for update;
  if not found then raise exception 'RP401: account no longer exists';end if;
  perform 1 from public.orgs where id=p_org and deleted_at is null for update;
  if not found then raise exception 'RP404: voice workspace unavailable';end if;
  if exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed') then
    raise exception 'RP409: account deletion is in progress';
  end if;
  if not exists(select 1 from public.memberships where user_id=p_actor and org_id=p_org and role in('owner','admin','agent')) then
    raise exception 'RP403: workspace does not permit voice generation';
  end if;
  if p_listing is not null then
    perform 1 from public.listings where id=p_listing and org_id=p_org and deleted_at is null for key share;
    if not found then raise exception 'RP404: voice listing unavailable';end if;
  end if;
  reserved_at:=clock_timestamp();
  insert into public.voice_storage_reservations(id,actor_id,org_id,listing_id,storage_key,created_at,write_deadline)
    values(p_id,p_actor,p_org,p_listing,'ai-voice/'||p_org::text||'/'||p_id::text||'.mp3',reserved_at,reserved_at+interval '15 minutes')
    on conflict(id) do nothing;
  select * into strict reservation from public.voice_storage_reservations where id=p_id for update;
  if reservation.actor_id<>p_actor or reservation.org_id<>p_org or reservation.listing_id is distinct from p_listing then
    raise exception 'RP409: voice storage reservation belongs to another request';
  end if;
  if reservation.write_deadline<=clock_timestamp() then
    raise exception 'RP409: voice storage reservation expired';
  end if;
  return jsonb_build_object('reservation_id',reservation.id,'key',reservation.storage_key,'write_deadline',reservation.write_deadline);
end;
$$;
revoke all on function public.reserve_voice_storage(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.reserve_voice_storage(uuid,uuid,uuid,uuid) to service_role;

create or replace function public.studio_voice_deletion_targets(p_solo uuid[], p_upload_bucket text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare targets jsonb;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege using message='service role required';
  end if;
  perform 1 from public.studio_creative_results where org_id=any(p_solo) and kind='voice' order by id for update;
  perform 1 from public.voice_storage_reservations where org_id=any(p_solo) order by id for update;
  with voices as (
    select r.org_id,r.storage_key,r.bucket from public.studio_creative_results r
      where r.org_id=any(p_solo) and r.kind='voice' and r.storage_key is not null
    union all
    select r.org_id,r.storage_key,'uploads'::text from public.voice_storage_reservations r where r.org_id=any(p_solo)
  ) select coalesce(jsonb_agg(distinct jsonb_build_object('bucket',p_upload_bucket,'key',v.storage_key,
    'valid',v.bucket='uploads' and v.storage_key ~
      ('^ai-voice/'||v.org_id::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]mp3$'))),'[]'::jsonb)
    into targets from voices v;
  return targets;
end;
$$;
revoke all on function public.studio_voice_deletion_targets(uuid[],text) from public,anon,authenticated,service_role;

-- Keep the deployed transaction/leases unchanged. Extend only its checked
-- inventory point, after it locks the reservations and before parent FK purges.
-- A provider may return late; the Edge caller must refuse PUT after the original
-- deadline. Deletion waits another hour before deleting those reserved keys.
do $$
declare definition text;
  needle text:='object_targets:=object_targets||spatial_keys||public.studio_voice_deletion_targets(solo,p_upload_bucket);';
begin
  definition:=pg_get_functiondef('public.prepare_account_deletion(uuid,text,text)'::regprocedure);
  if (length(definition)-length(replace(definition,needle,'')))/length(needle)<>1 then
    raise exception 'Account deletion inventory changed; review before extending voice reservations';
  end if;
  execute replace(definition,needle,needle||E'\n  select greatest(storage_after,max(write_deadline)+interval ''1 hour'') into storage_after\n    from public.voice_storage_reservations where org_id=any(solo);');
end;
$$;
commit;
