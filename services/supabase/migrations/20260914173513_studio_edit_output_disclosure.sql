begin;
-- A browser export is assembled locally. Source declarations can be checked
-- against scoped records; they never certify the final pixels or audio.
create unique index studio_edit_output_asset on public.studio_creative_results((metadata->>'asset_id'))
where kind='video' and metadata->>'video_kind'='edit';

create or replace function public.assert_studio_edit_quality(p_asset uuid, p_seen uuid[] default '{}')
returns void language plpgsql security definer set search_path=public as $$
declare result studio_creative_results; asset capture_assets; source capture_assets; proof media_provenance; source_id text;
begin
  if p_asset=any(p_seen) or cardinality(p_seen)>=8 then
    raise exception 'RP409: The saved edit has a cyclic or overly nested source history.';
  end if;
  -- Also protects an ordinary output that was subsequently registered as a
  -- generated animation. The existing exact generation/source/output gate wins.
  perform public.assert_studio_asset_quality(p_asset);
  select * into result from studio_creative_results where kind='video'
    and metadata->>'video_kind'='edit' and metadata->>'asset_id'=p_asset::text;
  if not found then return; end if;
  select * into asset from capture_assets where id=p_asset;
  select * into proof from media_provenance where id=result.provenance_id
    and org_id=result.org_id and listing_id=result.listing_id;
  if result.metadata->>'state' is distinct from 'completed'
    or asset.uploaded is distinct from true or asset.kind is distinct from 'video'
    or asset.bucket is distinct from 'renders' or asset.listing_id is distinct from result.listing_id
    or asset.storage_key is distinct from result.storage_key
    or proof.kind is distinct from 'other' or proof.original_key is not null
    or proof.altered_key is distinct from asset.storage_key
    or proof.disclosure is distinct from result.metadata->>'disclosure'
    or jsonb_typeof(result.metadata->'source_asset_ids') is distinct from 'array'
  then raise exception 'RP409: Finish saving the edited video and its disclosure before publishing.'; end if;
  if jsonb_array_length(result.metadata->'source_asset_ids') not between 1 and 24 then
    raise exception 'RP409: The edited video needs a bounded source record.';
  end if;
  for source_id in select jsonb_array_elements_text(result.metadata->'source_asset_ids') loop
    select * into source from capture_assets where id::text=source_id and listing_id=result.listing_id;
    if not found or source.uploaded is distinct from true then
      raise exception 'RP409: A source of the edited video is no longer available.';
    end if;
    perform public.assert_studio_edit_quality(source.id, array_append(p_seen,p_asset));
    -- Native generated media may predate the private Studio result table.
    if exists(select 1 from media_provenance p where p.org_id=result.org_id and p.listing_id=result.listing_id
      and p.altered_key=source.storage_key and p.kind in ('reel','aerial') and
      (p.qc->>'verdict' is distinct from 'pass' or p.qc->'publishable' is distinct from 'true'::jsonb
       or nullif(p.qc->>'request_id','') is null)) then
      raise exception 'RP409: A generated source needs property accuracy review before publication.';
    end if;
  end loop;
end;
$$;
revoke all on function public.assert_studio_edit_quality(uuid,uuid[]) from public,anon,authenticated;
grant execute on function public.assert_studio_edit_quality(uuid,uuid[]) to service_role;

create or replace function public.guard_studio_render_job_quality()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform public.assert_studio_edit_quality(new.capture_asset_id);
  return new;
end;
$$;
revoke all on function public.guard_studio_render_job_quality() from public,anon,authenticated;

create or replace function public.guard_studio_render_quality()
returns trigger language plpgsql security definer set search_path=public as $$
declare source_id uuid;
begin
  select capture_asset_id into source_id from render_jobs where id=new.job_id;
  if source_id is not null then
    perform public.assert_studio_edit_quality(source_id);
    -- Existing app publishing defaults staged=false. Preserve a known visual
    -- AI disclosure when it has been assembled into a local output.
    if exists(select 1 from studio_creative_results where kind='video'
      and metadata->>'video_kind'='edit' and metadata->>'asset_id'=source_id::text
      and metadata->'has_visual_ai'='true'::jsonb) then new.staged:=true; end if;
  end if;
  return new;
end;
$$;
revoke all on function public.guard_studio_render_quality() from public,anon,authenticated;

create or replace function public.guard_studio_edit_provenance()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if exists(select 1 from studio_creative_results where provenance_id=old.id and kind='video'
    and metadata->>'video_kind'='edit' and metadata->>'state'='completed') and
    (new.org_id is distinct from old.org_id or new.listing_id is distinct from old.listing_id
     or new.original_key is distinct from old.original_key or new.altered_key is distinct from old.altered_key
     or new.kind is distinct from old.kind or new.disclosure is distinct from old.disclosure) then
    raise exception 'RP409: The source disclosure of a completed Studio edit cannot be reassigned.';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_studio_edit_provenance() from public,anon,authenticated;
create trigger studio_edit_provenance_immutable before update of org_id,listing_id,original_key,altered_key,kind,disclosure
on public.media_provenance for each row execute function public.guard_studio_edit_provenance();
commit;
