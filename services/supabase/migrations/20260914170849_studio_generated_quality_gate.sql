begin;
-- The publishing RPC is also used directly by native clients. Enforce this at
-- the database boundary, for Studio-generated still-to-video assets only.
create index studio_creative_results_asset
  on public.studio_creative_results((metadata->>'asset_id')) where kind='video';
create index studio_creative_results_import_asset
  on public.studio_creative_results((metadata->>'import_asset_id')) where kind='video';
create or replace function public.assert_studio_asset_quality(p_asset uuid)
returns void language plpgsql security definer set search_path=public as $$
declare
  result studio_creative_results;
  asset capture_assets;
  source capture_assets;
  proof media_provenance;
begin
  for result in
    select * from studio_creative_results
    where kind='video' and metadata->>'video_kind' in ('reel','aerial')
      and (metadata->>'asset_id'=p_asset::text or metadata->>'import_asset_id'=p_asset::text)
  loop
    select * into asset from capture_assets where id=p_asset;
    select * into source from capture_assets
      where id::text=result.metadata->>'source_asset_id' and listing_id=result.listing_id;
    select * into proof from media_provenance
      where id=result.provenance_id and org_id=result.org_id and listing_id=result.listing_id;
    if result.metadata->>'state' is distinct from 'completed'
      or result.storage_key is distinct from asset.storage_key
      or asset.listing_id is distinct from result.listing_id
      or asset.uploaded is distinct from true
      or source.kind is distinct from 'photo'
      or source.uploaded is distinct from true
      or source.bucket is distinct from 'renders'
      or proof.original_key is distinct from source.storage_key
      or proof.altered_key is distinct from asset.storage_key
      or proof.qc->>'verdict' is distinct from 'pass'
      or proof.qc->'publishable' is distinct from 'true'::jsonb
      or nullif(proof.qc->>'request_id','') is null
      or proof.qc->>'request_id' is distinct from result.metadata->>'request_id'
    then
      raise exception 'RP409: Review property accuracy in Creative Studio before publishing this generated clip.';
    end if;
  end loop;
end;
$$;
revoke all on function public.assert_studio_asset_quality(uuid) from public,anon,authenticated;

create or replace function public.guard_studio_render_job_quality()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform public.assert_studio_asset_quality(new.capture_asset_id);
  return new;
end;
$$;
revoke all on function public.guard_studio_render_job_quality() from public,anon,authenticated;
create trigger studio_generated_job_quality before insert or update of capture_asset_id,listing_id on public.render_jobs
for each row execute function public.guard_studio_render_job_quality();

create or replace function public.guard_studio_render_quality()
returns trigger language plpgsql security definer set search_path=public as $$
declare source_id uuid;
begin
  select capture_asset_id into source_id from render_jobs where id=new.job_id;
  if source_id is not null then perform public.assert_studio_asset_quality(source_id); end if;
  return new;
end;
$$;
revoke all on function public.guard_studio_render_quality() from public,anon,authenticated;
create trigger studio_generated_publish_quality before insert or update of job_id,video_key on public.renders
for each row execute function public.guard_studio_render_quality();
comment on function public.assert_studio_asset_quality(uuid) is
  'Require the trusted, matching source/result/request quality verdict before publishing a Studio-generated property animation. Ordinary recorded video is unchanged.';
commit;
