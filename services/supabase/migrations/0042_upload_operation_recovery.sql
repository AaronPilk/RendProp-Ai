-- 0042: a cut transfer is not a dead ticket.
--
-- Layers on 0037, which is live and is never edited. What production showed:
-- once the gateway claims a single/part transfer and the body is cut (LTE
-- handover mid-part, the 10-minute deadline, a backgrounded photo PUT, a short
-- body) the operation ends `rejected` or `uncertain` and 0037 has no way back.
-- plan returned the dead row whatever its state, the (asset, kind, part) key
-- forbade a second row, recovery refused `rejected`, and every renewal answered
-- 503 until the client aborted and re-uploaded from scratch.
--
-- Same-signature replacements, so the deployed `uploads` v35 keeps calling the
-- RPCs it already calls and simply starts receiving a fresh `planned` row:
--   * plan_upload_operation    re-plans a `rejected` single/part in place: the
--                              same row, key and part, one more `attempt`, the
--                              rejected claim's bytes handed back to the same
--                              reservation so the retry re-spends them once.
--   * recover_upload_operation a null receipt is the trusted server saying it
--                              observed the registered key/part ABSENT; past the
--                              op's write deadline that retires the dispatch as
--                              `rejected`, which plan can then re-issue.
--   * finish_upload_operation  a failure verdict closes the write window at the
--                              moment the gateway reports it, so the deadline
--                              above is "now" for a reported cut and stays
--                              claim + 15 min only for a silent dispatch.
-- Server-side recorded operations (init/copy/assemble) keep 0037 semantics
-- exactly: a promotion copy or assembly is never issued twice.
--
-- Idempotent on replay (CI applies 0009+ twice); grants mirror 0037.

alter table public.upload_operations
  add column if not exists attempt integer not null default 1 check (attempt >= 1);
comment on column public.upload_operations.attempt is
  'Dispatch attempts for this exact key/part. A rejected single/part transfer is re-planned in place until the fifth attempt; after that only cancellation frees the reservation.';

create or replace function public.plan_upload_operation(p_asset uuid, p_kind text, p_part integer default 0)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare a public.capture_assets; r public.upload_reservations; op public.upload_operations; n bigint; k text; uid uuid := gen_random_uuid();
begin
  if current_setting('role', true) is distinct from 'service_role' then raise exception 'RP403: upload service role required'; end if;
  a := public.lock_upload_asset(p_asset);
  select * into strict r from public.upload_reservations where asset_id=p_asset for update;
  if a.uploaded or a.upload_aborted or r.state <> 'open' or r.expires_at <= clock_timestamp() then
    raise exception 'RP409: upload is terminal or expired';
  end if;
  if not exists(select 1 from public.listings where id=a.listing_id and org_id=r.org_id and deleted_at is null)
     or not exists(select 1 from public.orgs where id=r.org_id and deleted_at is null) then raise exception 'RP403: workspace changed'; end if;
  select * into op from public.upload_operations where asset_id=p_asset and kind=p_kind and part=p_part for update;
  if op.id is not null then
    if op.state in ('planned','stored') then
      update public.upload_operations set expires_at=least(r.expires_at,clock_timestamp()+interval '1 hour') where id=op.id returning * into op;
    elsif op.state = 'rejected' and op.kind in ('single','part') and op.etag is null
          and (op.write_deadline is null or op.write_deadline <= clock_timestamp()) then
      -- Only client-driven transfers come back. The gateway rejected this
      -- dispatch without a receipt and its write window has closed, so nothing
      -- of it can still land; the retry re-sends the same bytes to the same
      -- registered key/part, which is also the only key cleanup knows.
      if op.attempt >= 5 then return to_jsonb(op) || '{"attempts_exhausted":true}'::jsonb; end if;
      if op.claim is not null then
        -- The rejected claim spent these bytes. Hand them back to the SAME open
        -- reservation (and its original day window) so the next claim re-spends
        -- them: one op is paid for once, never twice, and never by a refund.
        if r.spent_bytes < op.bytes then raise exception 'RP409: rejected transfer has no spent authority to release'; end if;
        update public.upload_budget_windows set held_bytes=held_bytes+op.bytes, spent_bytes=spent_bytes-op.bytes where org_id=r.org_id and day=r.day;
        update public.upload_reservations set held_bytes=held_bytes+op.bytes, spent_bytes=spent_bytes-op.bytes where asset_id=a.id;
      end if;
      -- The old claim stays on the row: the next claim overwrites it, and
      -- cleanup reads a non-null claim as "a write was once authorized here",
      -- so an abandoned retry still gets its staging key deleted (404 is fine).
      update public.upload_operations set state='planned', attempt=attempt+1, etag=null, write_deadline=null,
        cleanup_after=null, cleanup_claim=null, expires_at=least(r.expires_at,clock_timestamp()+interval '1 hour')
        where id=op.id returning * into op;
    end if;
    return to_jsonb(op);
  end if;
  if p_kind = 'init' and a.parts_total is not null and p_part=0 and a.upload_id is null then n:=0; k:=a.storage_key;
  elsif p_kind = 'part' and a.upload_id is not null and p_part between 1 and a.parts_total then
    n:=least(a.part_size,a.bytes-(p_part-1)*a.part_size); k:=a.storage_key;
  elsif p_kind = 'single' and a.parts_total is null and p_part=0 then
    n:=a.bytes; k:='_staging/' || a.storage_key || '-' || uid;
  elsif p_kind = 'copy' and a.parts_total is null and p_part=0 and exists
    (select 1 from public.upload_operations where asset_id=p_asset and kind='single' and state='stored') then
    n:=a.bytes; k:=regexp_replace(a.storage_key,'(\.[^.]+)$','-complete-' || uid || '\1');
  elsif p_kind='assemble' and a.parts_total is not null and p_part=0 and a.completion_parts is not null then
    n:=0; k:=a.storage_key;
  else raise exception 'RP409: operation does not match the upload'; end if;
  insert into public.upload_operations(id,asset_id,kind,part,bucket,object_key,upload_id,bytes,expected_bytes,content_type,content_type_declared,asset_kind)
    values(uid,p_asset,p_kind,p_part,a.bucket,k,a.upload_id,n,a.bytes,a.content_type,a.content_type_declared,a.kind) returning * into op;
  if p_kind='copy' then
    update public.upload_operations set content_type=(select content_type from public.upload_operations where asset_id=p_asset and kind='single')
      where id=op.id returning * into op;
  end if;
  return to_jsonb(op);
end $$;

create or replace function public.finish_upload_operation(p_operation uuid, p_claim uuid, p_result text, p_etag text default null, p_upload_id text default null, p_content_type text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare op public.upload_operations; a public.capture_assets; r public.upload_reservations;
begin
  if current_setting('role', true) is distinct from 'service_role' then raise exception 'RP403: upload service role required'; end if;
  select * into strict op from public.upload_operations where id=p_operation;
  a:=public.lock_upload_asset(op.asset_id);
  select * into strict r from public.upload_reservations where asset_id=a.id for update;
  select * into strict op from public.upload_operations where id=p_operation for update;
  if op.claim is distinct from p_claim or p_result not in ('stored','uncertain','rejected') then raise exception 'RP409: operation claim/result mismatch'; end if;
  if op.state <> 'dispatching' then
    if op.state=p_result and op.etag is not distinct from p_etag and (op.kind<>'init' or op.upload_id is not distinct from p_upload_id) then return to_jsonb(op); end if;
    raise exception 'RP409: operation already settled';
  end if;
  if p_result='stored' and (p_etag is null or length(p_etag) not between 1 and 256) then raise exception 'RP400: receipt ETag required'; end if;
  if p_content_type is not null and (p_content_type !~ '^[a-z0-9.+-]+/[a-z0-9.+-]+$' or
     (op.content_type_declared and p_content_type <> op.content_type)) then raise exception 'RP400: receipt type mismatch'; end if;
  if op.kind='init' and p_result='stored' then
    if p_upload_id is null or length(p_upload_id) not between 1 and 2048 then raise exception 'RP400: upload ID required'; end if;
    update public.capture_assets set upload_id=p_upload_id where id=a.id and not uploaded;
  end if;
  -- A failure verdict is the gateway saying its request is over. Nothing of
  -- this dispatch can still be writing, so its write window closes now instead
  -- of at claim + 15 minutes; a silent dispatch keeps the full window.
  -- cleanup_after still reads the pre-update deadline, as 0037 did.
  update public.upload_operations set state=p_result,etag=p_etag,upload_id=coalesce(p_upload_id,upload_id),content_type=coalesce(p_content_type,content_type),
    write_deadline=case when p_result in ('uncertain','rejected') then least(write_deadline,clock_timestamp()) else write_deadline end,
    cleanup_after=case when r.state='cancelled' and kind not in ('part','assemble') then greatest(clock_timestamp(),write_deadline)+interval '1 hour' else null end
    where id=op.id returning * into op;
  return to_jsonb(op);
end $$;

-- Only the trusted server may acknowledge a read-only storage observation for
-- this immutable, pre-dispatch identity. It never grants a second write.
-- p_etag null: the server observed the registered key/part ABSENT. Once the
-- op's write window has closed that retires the dispatch as `rejected`; while
-- the window is open the row comes back unchanged (still unprovable). Only the
-- client-driven single/part transfers take that path; a recorded init/copy/
-- assemble without a receipt stays an error exactly as in 0037.
create or replace function public.recover_upload_operation(p_operation uuid,p_etag text,p_upload_id text default null,p_content_type text default null)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare op public.upload_operations; a public.capture_assets; r public.upload_reservations;
begin
  if current_setting('role', true) is distinct from 'service_role' then raise exception 'RP403: upload service role required'; end if;
  select * into strict op from public.upload_operations where id=p_operation;
  a:=public.lock_upload_asset(op.asset_id);
  select * into strict r from public.upload_reservations where asset_id=a.id for update;
  select * into strict op from public.upload_operations where id=p_operation for update;
  if r.state<>'open' or a.uploaded or a.upload_aborted or r.expires_at<=clock_timestamp() then raise exception 'RP409: recovery is terminal or expired'; end if;
  if op.state='stored' then
    if op.etag is distinct from p_etag or (op.kind='init' and op.upload_id is distinct from p_upload_id) then raise exception 'RP409: recovery receipt changed'; end if;
    return to_jsonb(op);
  end if;
  if p_etag is null and op.kind in ('single','part') and op.state in ('planned','rejected') then return to_jsonb(op); end if;
  if p_etag is null and op.kind in ('single','part') and op.state in ('dispatching','uncertain') and op.claim is not null then
    if op.write_deadline is null or op.write_deadline > clock_timestamp() then return to_jsonb(op); end if;
    update public.upload_operations set state='rejected',etag=null,cleanup_after=null where id=op.id returning * into op;
    return to_jsonb(op);
  end if;
  if op.state not in ('dispatching','uncertain') or op.claim is null or p_etag is null or length(p_etag) not between 1 and 256 then
    raise exception 'RP409: no uncertain recorded dispatch to recover';
  end if;
  if p_content_type is not null and (p_content_type !~ '^[a-z0-9.+-]+/[a-z0-9.+-]+$' or
    (op.content_type_declared and p_content_type<>op.content_type)) then raise exception 'RP400: recovered type mismatch'; end if;
  if op.kind='init' then
    if p_upload_id is null or length(p_upload_id) not between 1 and 2048 then raise exception 'RP400: recovered multipart ID required'; end if;
    update public.capture_assets set upload_id=p_upload_id where id=a.id;
  end if;
  update public.upload_operations set state='stored',etag=p_etag,upload_id=coalesce(p_upload_id,upload_id),
    content_type=coalesce(p_content_type,content_type),cleanup_after=null where id=op.id returning * into op;
  return to_jsonb(op);
end $$;

revoke execute on function public.plan_upload_operation(uuid,text,integer),
  public.finish_upload_operation(uuid,uuid,text,text,text,text),
  public.recover_upload_operation(uuid,text,text,text) from public, anon, authenticated;
grant execute on function public.plan_upload_operation(uuid,text,integer),
  public.finish_upload_operation(uuid,uuid,text,text,text,text),
  public.recover_upload_operation(uuid,text,text,text) to service_role;
