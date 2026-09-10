-- 0036: upload completion is a one-way publication, not just a boolean CAS.
-- Single PUTs publish a unique copy key; multipart fixes its exact part/ETag
-- manifest before assembly (no >5 GiB copy or buffering is introduced).
-- These fields are service-written only: 0007 already revokes tenant writes.
alter table public.capture_assets
  add column if not exists upload_aborted boolean not null default false,
  add column if not exists completion_parts jsonb;

create or replace function public.guard_capture_asset_publication()
returns trigger language plpgsql set search_path = public as $$
begin
  -- Completion bytes/identity are immutable even if a stale pre-upgrade route
  -- later attempts its old unconditional abort/mismatch UPDATE. DELETE remains
  -- the separately authorized deletion path; this is not a delete trigger.
  if old.uploaded is true and
     (new.id, new.listing_id, new.uploaded, new.storage_key, new.bucket, new.kind, new.bytes,
      new.content_type, new.upload_id, new.upload_aborted, new.completion_parts)
     is distinct from
     (old.id, old.listing_id, old.uploaded, old.storage_key, old.bucket, old.kind, old.bytes,
      old.content_type, old.upload_id, old.upload_aborted, old.completion_parts) then
    raise exception 'RP409: completed upload publication is immutable';
  end if;
  if old.upload_aborted and (not new.upload_aborted or new.uploaded is true) then
    raise exception 'RP409: aborted upload cannot be completed or reopened';
  end if;
  if new.upload_aborted and new.uploaded is true then
    raise exception 'RP409: upload cannot be both aborted and complete';
  end if;
  if old.completion_parts is not null and
     new.completion_parts is distinct from old.completion_parts then
    raise exception 'RP409: multipart completion manifest is immutable';
  end if;
  if new.completion_parts is not null then
    if jsonb_typeof(new.completion_parts) <> 'array' then
      raise exception 'RP400: completion_parts must be an array';
    end if;
    if jsonb_array_length(new.completion_parts) < 1 or
       jsonb_array_length(new.completion_parts) > 10000 then
      raise exception 'RP400: completion_parts must contain 1..10000 parts';
    end if;
  end if;
  if old.uploaded is not true and new.uploaded is true and
     old.upload_id is not null and new.completion_parts is null then
    raise exception 'RP409: freeze multipart parts before publication';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_capture_asset_publication on public.capture_assets;
create trigger trg_capture_asset_publication before update on public.capture_assets
for each row execute function public.guard_capture_asset_publication();
revoke execute on function public.guard_capture_asset_publication() from public, anon, authenticated, service_role;

comment on column public.capture_assets.completion_parts is
  'Canonical part number/ETag manifest frozen before R2 assembly; retries must match it.';
comment on column public.capture_assets.upload_aborted is
  'Terminal abort/validation fence. A stale complete may never publish after this becomes true.';
