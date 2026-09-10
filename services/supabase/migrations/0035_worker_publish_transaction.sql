-- 0035 — publish worker output under the SAME database lock as its lease check.
-- Uploads stay outside this short transaction. A heartbeat is not a publication
-- fence: the lease can expire/reassign after the check but before a renders PATCH.
-- Apply before deploying the new worker; there is deliberately no legacy fallback.

alter table public.render_jobs
  add column if not exists worker_publish_receipt jsonb;

comment on column public.render_jobs.worker_publish_receipt is
  'Exact worker publication request/result bound to worker_id + attempts. Enables '
  'safe retries after a committed RPC response was lost; not an artifact cleanup queue.';

create or replace function public.publish_worker_render(
  p_job uuid,
  p_worker text,
  p_attempt integer,
  p_render jsonb,
  p_enhancement_result jsonb,
  p_photos jsonb default '[]'::jsonb
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_listing_id uuid;
  v_listing public.listings;
  v_job public.render_jobs;
  v_render public.renders;
  v_id uuid;
  v_slug text;
  v_prefix text;
  v_request jsonb;
  v_receipt jsonb;
  v_photo jsonb;
  v_duration numeric;
  v_speed numeric;
  v_staged boolean;
  v_constraint text;
  v_try integer;
begin
  -- Grants are the boundary; this explicit guard also prevents accidental future
  -- EXECUTE grants from making an ordinary member's chosen worker_id authoritative.
  if current_user <> 'service_role' then
    raise exception using errcode = '42501', message = 'worker publication requires service_role';
  end if;
  if p_worker is null or length(p_worker) not between 1 and 200
     or p_attempt is null or p_attempt < 1
     or jsonb_typeof(p_render) is distinct from 'object'
     or jsonb_typeof(p_enhancement_result) is distinct from 'object'
     or jsonb_typeof(p_photos) is distinct from 'array' then
    raise exception using errcode = 'WP003', message = 'invalid worker publication envelope';
  end if;
  if jsonb_array_length(p_photos) > 100
     or octet_length(p_render::text) + octet_length(p_enhancement_result::text)
        + octet_length(p_photos::text) > 262144 then
    raise exception using errcode = 'WP003', message = 'worker publication envelope exceeds bounds';
  end if;

  -- Listing first, then job, then render/photos: a soft-delete already locks
  -- the listing before unpublishing renders. Sharing that order prevents an
  -- inverse-lock deadlock and prevents publication from undoing a tombstone.
  select listing_id into v_listing_id from public.render_jobs where id = p_job;
  select * into v_listing from public.listings where id = v_listing_id for update;
  if not found or v_listing.deleted_at is not null then
    raise exception using errcode = 'WP001', message = 'worker publication listing is unavailable';
  end if;
  select * into v_job from public.render_jobs where id = p_job for update;
  if not found or v_job.listing_id is distinct from v_listing_id
     or v_job.source is distinct from 'worker'
     or v_job.worker_id is distinct from p_worker
     or v_job.attempts is distinct from p_attempt then
    raise exception using errcode = 'WP001', message = 'worker publication claim is no longer owned';
  end if;
  v_request := jsonb_build_object('render', p_render,
    'enhancement_result', p_enhancement_result, 'photos', p_photos);

  if v_job.status = 'ready' then
    v_receipt := v_job.worker_publish_receipt;
    select * into v_render from public.renders where job_id = p_job;
    -- A successful exact replay is read-only, even after its former lease
    -- expires. A different output from the same process/attempt is NOT a retry.
    if not found or v_receipt is null
       or v_receipt->'request' is distinct from v_request
       or v_receipt->>'worker_id' is distinct from p_worker
       or v_receipt->'attempt' is distinct from to_jsonb(p_attempt)
       or v_receipt->'render' is distinct from to_jsonb(v_render) then
      raise exception using errcode = 'WP002', message = 'worker publication conflicts with the committed output';
    end if;
    return jsonb_build_object('job_id', p_job, 'status', 'ready', 'render', to_jsonb(v_render), 'receipt', v_receipt);
  end if;
  -- clock_timestamp(), not now(): a call may have waited for either row lock.
  -- The time when its transaction BEGAN is not proof its lease is still alive.
  if v_job.status is distinct from 'processing'
     or v_job.lease_expires_at is null or v_job.lease_expires_at <= clock_timestamp() then
    raise exception using errcode = 'WP001', message = 'worker publication lease is expired or job is not processing';
  end if;
  if not exists (select 1 from public.capture_assets a
    where a.id = v_job.capture_asset_id and a.listing_id = v_listing_id
      and a.uploaded is true and coalesce(a.bucket, 'uploads') = 'uploads') then
    raise exception using errcode = 'WP003', message = 'worker publication requires an uploaded raw capture';
  end if;

  begin
    v_id := (p_render->>'id')::uuid;
    v_duration := (p_render->>'duration_s')::numeric;
    v_speed := (p_render->>'speed_factor')::numeric;
    v_staged := (p_enhancement_result->>'staged')::boolean;
  exception when invalid_text_representation or numeric_value_out_of_range then
    raise exception using errcode = 'WP003', message = 'invalid worker publication scalar';
  end;
  v_slug := p_render->>'slug';
  v_prefix := 'renders/' || v_listing_id::text || '/' || v_id::text;
  if v_id is null or v_slug is null or v_slug !~ '^[a-zA-Z0-9_-]{6,80}$'
     or v_duration is null or not (v_duration > 0 and v_duration <= 7200)
     or v_speed is null or not (v_speed >= 0.25 and v_speed <= 8)
     or jsonb_typeof(p_enhancement_result->'staged') is distinct from 'boolean'
     or jsonb_typeof(p_enhancement_result->'ran') is distinct from 'boolean'
     or p_render->>'video_key' is distinct from v_prefix || '.mp4'
     or p_render->>'poster_key' is distinct from v_prefix || '-poster.jpg'
     or (p_render->>'hero_key' is not null and p_render->>'hero_key' <> v_prefix || '-hero.mp4')
     or length(coalesce(p_render->>'stream_uid', '')) > 200 then
    raise exception using errcode = 'WP003', message = 'invalid worker publication media or outcome';
  end if;

  select * into v_render from public.renders where job_id = p_job for update;
  if found then
    -- Recovery of a pre-0035 partial publish keeps the customer's existing URL.
    -- Only the current fenced attempt can replace it; ready jobs were handled above.
    update public.renders set duration_s = v_duration, speed_factor = v_speed,
      video_key = p_render->>'video_key', poster_key = p_render->>'poster_key',
      stream_uid = p_render->>'stream_uid', hero_key = p_render->>'hero_key',
      staged = v_staged, published_at = clock_timestamp()
    where id = v_render.id returning * into v_render;
  else
    for v_try in 1..5 loop
      begin
        insert into public.renders (id, job_id, listing_id, slug, duration_s, speed_factor,
          video_key, stream_uid, poster_key, hero_key, staged, published_at)
        values (v_id, p_job, v_listing_id, v_slug, v_duration, v_speed,
          p_render->>'video_key', p_render->>'stream_uid', p_render->>'poster_key',
          p_render->>'hero_key', v_staged, clock_timestamp()) returning * into v_render;
        exit;
      exception when unique_violation then
        get stacked diagnostics v_constraint = constraint_name;
        if v_constraint <> 'renders_slug_key' or v_try = 5 then raise; end if;
        v_slug := left(replace(gen_random_uuid()::text, '-', ''), 12);
      end;
    end loop;
  end if;

  for v_photo in select value from jsonb_array_elements(p_photos) loop
    if jsonb_typeof(v_photo) is distinct from 'object'
       or v_photo->>'listing_id' is distinct from v_listing_id::text
       or v_photo->'is_staged' is distinct from 'true'::jsonb
       or v_photo->>'enhanced_key' is null
       or v_photo->>'enhanced_key' !~ ('^' || v_prefix || '-staged-[0-9]+[.]jpg$')
       or (v_photo->>'original_key' is not null and
         v_photo->>'original_key' !~ ('^' || v_prefix || '-staged-[0-9]+-orig[.]jpg$')) then
      raise exception using errcode = 'WP003', message = 'invalid worker publication photo';
    end if;
    insert into public.photos (listing_id, original_key, enhanced_key, is_staged, caption, sort)
    values (v_listing_id, v_photo->>'original_key', v_photo->>'enhanced_key', true,
      v_photo->>'caption', (v_photo->>'sort')::smallint);
  end loop;

  -- An unrelated constraint/trigger may have delayed a write. Recheck at the
  -- final state transition so expiry during that wait rolls every row back.
  if v_job.lease_expires_at <= clock_timestamp() then
    raise exception using errcode = 'WP001', message = 'worker publication lease expired during transaction';
  end if;

  v_receipt := jsonb_build_object('version', 1, 'job_id', p_job, 'worker_id', p_worker,
    'attempt', p_attempt, 'request', v_request, 'render', to_jsonb(v_render));
  update public.render_jobs set enhancement_result = p_enhancement_result,
    worker_publish_receipt = v_receipt, status = 'ready', current_step = 'ready',
    progress = 1, finished_at = clock_timestamp(), error = null
  where id = p_job;
  update public.listings set status = 'ready' where id = v_listing_id;
  -- Final-row triggers can wait too. The pre-transition check alone cannot
  -- prove these last writes completed before expiry; roll them all back if not.
  if v_job.lease_expires_at <= clock_timestamp() then
    raise exception using errcode = 'WP001', message = 'worker publication lease expired during final state writes';
  end if;
  return jsonb_build_object('job_id', p_job, 'status', 'ready', 'render', to_jsonb(v_render), 'receipt', v_receipt);
end;
$$;

revoke execute on function public.publish_worker_render(uuid, text, integer, jsonb, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.publish_worker_render(uuid, text, integer, jsonb, jsonb, jsonb)
  to service_role;
