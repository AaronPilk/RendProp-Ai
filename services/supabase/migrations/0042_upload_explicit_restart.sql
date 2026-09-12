-- Created with `supabase migration new upload_explicit_restart`, then numbered
-- 0042 to follow this repository's migrations. Apply with the paired handler.
-- A restart is an explicit new reservation, NOT a second dispatch permission
-- for the old key. Its spent bytes and cleanup obligation survive cancellation.
alter table public.upload_reservations
  add column if not exists restart_generation smallint not null default 0
    check (restart_generation between 0 and 3),
  add column if not exists replacement_asset_id uuid,
  add column if not exists restart_key uuid;
do $$ begin
  if not exists(select 1 from pg_constraint where conrelid='public.upload_reservations'::regclass and conname='upload_restart_link_pair') then
    alter table public.upload_reservations add constraint upload_restart_link_pair check
      ((replacement_asset_id is null) = (restart_key is null));
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.upload_reservations'::regclass and conname='upload_restart_not_self') then
    alter table public.upload_reservations add constraint upload_restart_not_self check (replacement_asset_id is distinct from asset_id);
  end if;
end $$;
create unique index if not exists idx_upload_restart_child on public.upload_reservations(replacement_asset_id)
  where replacement_asset_id is not null;
-- Deliberately no cascading FK: 0039 snapshots ALL reservations/operations in
-- the workspace before retiring any of them, including every restart child.

create or replace function public.upload_restart_state(p_asset uuid, p_actor uuid)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare a public.capture_assets; r public.upload_reservations; reason text; retry_seconds integer;
begin
  a := public.lock_upload_asset(p_asset);
  select * into strict r from upload_reservations where asset_id=a.id for update;
  if r.listing_id <> a.listing_id
     or not exists(select 1 from listings where id=a.listing_id and org_id=r.org_id and deleted_at is null)
     or not exists(select 1 from orgs where id=r.org_id and deleted_at is null)
     or not exists(select 1 from memberships where org_id=r.org_id and user_id=p_actor and role in ('owner','admin','agent'))
     or exists(select 1 from deletion_requests where user_id=p_actor and status<>'completed') then
    raise exception 'RP403: upload workspace is not writable';
  end if;
  -- A completed receipt always wins. We do not infer failure from a stale phone
  -- journal or a generic 409/503; only these durable transport states qualify.
  if not a.uploaded then
    if r.state='cancelled' or a.upload_aborted then reason := 'cancelled';
    elsif r.expires_at <= clock_timestamp() then reason := 'expired';
    elsif exists(select 1 from upload_operations where asset_id=a.id and
      (state in ('uncertain','rejected') or
       (state='dispatching' and write_deadline <= clock_timestamp()))) then reason := 'interrupted';
    end if;
  end if;
  if not a.uploaded and reason is null then
    select greatest(1,least(900,ceil(extract(epoch from max(write_deadline)-clock_timestamp()))::integer))
      into retry_seconds from upload_operations
      where asset_id=a.id and state='dispatching' and write_deadline>clock_timestamp()
      having count(*)>0;
  end if;
  return jsonb_build_object('asset',to_jsonb(a),'restart_required',reason is not null,
    'restart_reason',reason,'restart_generation',r.restart_generation,'retry_after_seconds',retry_seconds);
end $$;

create or replace function public.restart_upload_asset(p_asset uuid, p_actor uuid, p_restart uuid)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  state jsonb; a public.capture_assets; r public.upload_reservations; child jsonb;
  child_id uuid := gen_random_uuid(); spec jsonb; prefix text; extension text;
  d date := (clock_timestamp() at time zone 'UTC')::date;
begin
  if p_restart is null then raise exception 'RP400: restart idempotency UUID required'; end if;
  state := public.upload_restart_state(p_asset,p_actor);
  select * into strict a from capture_assets where id=p_asset;
  select * into strict r from upload_reservations where asset_id=p_asset;
  if a.uploaded then return state; end if;
  -- The old row is the durable idempotency anchor, even when its child is now
  -- complete/expired or a second device used a different request UUID. A retry
  -- of this HTTP request NEVER silently advances to a grandchild.
  if r.replacement_asset_id is not null then
    return public.upload_restart_state(r.replacement_asset_id,p_actor);
  end if;
  if not (state->>'restart_required')::boolean then
    raise exception 'RP409: upload_restart_not_required';
  end if;
  if r.restart_generation >= 3 then
    raise exception 'RP409: upload_restart_exhausted';
  end if;
  if r.spec ? 'legacy_physical_bytes' then
    raise exception 'RP409: legacy upload requires its explicit rollout recovery';
  end if;
  -- Both settlement and admission lock their budget. Take old/new days in one
  -- deterministic order before either call, avoiding midnight lock inversion.
  insert into upload_budget_windows(org_id,day) values(r.org_id,d) on conflict do nothing;
  perform 1 from upload_budget_windows where org_id=r.org_id and day in (r.day,d) order by day for update;
  if r.state='open' then perform public.settle_upload_reservation(p_asset,false);
  elsif r.state<>'cancelled' then raise exception 'RP409: opposing terminal settlement'; end if;
  prefix := case r.spec->>'key_role' when 'original' then 'original-' when 'gallery' then 'gallery-' else '' end;
  extension := substring(a.storage_key from '\.([a-zA-Z0-9]{1,8})$');
  if extension is null then raise exception 'RP409: stored upload extension is invalid'; end if;
  spec := (r.spec - 'key_role') || jsonb_build_object('id',child_id,'sha256',a.sha256,
    'storage_key',a.bucket || '/' || r.org_id || '/' || r.listing_id || '/' || prefix || child_id || '.' || extension,
    'idem_key','restart:' || p_asset || ':' || p_restart);
  -- Existing caps and immutable spec validation apply, in this SAME transaction.
  -- Admission failure rolls back old cancellation too; there is no lost-ticket
  -- interval and no refund of a dispatched (possibly still arriving) old write.
  child := public.reserve_upload_assets(p_actor,jsonb_build_array(spec))->0;
  update upload_reservations set restart_generation=r.restart_generation+1 where asset_id=child_id;
  update upload_reservations set replacement_asset_id=child_id,restart_key=p_restart where asset_id=p_asset;
  return public.upload_restart_state(child_id,p_actor);
end $$;

revoke all on function public.upload_restart_state(uuid,uuid), public.restart_upload_asset(uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.upload_restart_state(uuid,uuid), public.restart_upload_asset(uuid,uuid,uuid)
  to service_role;
