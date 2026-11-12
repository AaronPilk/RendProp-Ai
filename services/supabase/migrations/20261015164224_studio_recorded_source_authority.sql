-- Known server-owned photo-video outputs and video-only preparations cannot
-- enter the recorded-walkthrough publication/paid-render path. No filename or
-- client presentation hint establishes this authority. Typed publication keeps
-- its existing source/QC/attestation validation and calls unchanged app creation.
begin;
create or replace function public.assert_recorded_render_source(p_listing uuid,p_asset uuid)
returns void language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();a public.capture_assets;o uuid;
begin
 if actor is null then raise insufficient_privilege;end if;
 select l.org_id into o from public.listings l where l.id=p_listing and l.deleted_at is null;
 if o is null or not public.listing_content_access(actor,p_listing,true)then raise exception 'RP404: Recorded source is unavailable';end if;
 -- Shared with attestation's asset lock: identity cannot be reclassified while
 -- a recorded publication is deciding which retained source it may expose.
 select * into a from public.capture_assets where id=p_asset and listing_id=p_listing for update;
 if a.id is null then raise exception 'RP404: Recorded source is unavailable';end if;
 if exists(select 1 from public.property_video_job_outputs output join public.property_video_jobs job on job.id=output.job_id
   where output.asset_id=a.id and job.listing_id=p_listing and job.org_id=o
    and ((output.kind='video'and job.output_asset_id=a.id)or(output.kind='photo'and job.poster_asset_id=a.id))
    and output.storage_key=a.storage_key and output.bytes=a.bytes and output.sha256=a.sha256)
  or exists(select 1 from public.property_video_preparations prepared where prepared.asset_id=a.id and prepared.listing_id=p_listing and prepared.org_id=o
    and prepared.storage_key=a.storage_key and prepared.bytes=a.bytes and prepared.sha256=a.sha256)
  or exists(select 1 from public.property_video_attestations attested where attested.asset_id=a.id and attested.listing_id=p_listing and attested.org_id=o
    and attested.storage_key=a.storage_key and attested.bytes=a.bytes)
  or exists(select 1 from public.property_video_compositions composition where composition.asset_id=a.id and composition.listing_id=p_listing and composition.org_id=o)
 then raise exception 'RP409: Publish the saved photo video using its typed source receipts';end if;
 -- An inconsistent retained type record is a refusal, never authority to call
 -- an edited/generated object recorded footage. These tables are service-only.
 if exists(select 1 from public.property_video_job_outputs where asset_id=a.id)
  or exists(select 1 from public.property_video_preparations where asset_id=a.id)
  or exists(select 1 from public.property_video_attestations where asset_id=a.id)
  or exists(select 1 from public.property_video_compositions where asset_id=a.id)
 then raise exception 'RP409: The retained video-source identity changed';end if;
end$$;
revoke all on function public.assert_recorded_render_source(uuid,uuid)from public,anon,authenticated;
grant execute on function public.assert_recorded_render_source(uuid,uuid)to service_role;

do $patch$declare definition text;actual text;begin
 select md5(prosrc)into actual from pg_proc where oid='public.create_render_job(uuid,uuid,text,jsonb,text,text)'::regprocedure;
 if actual='c9579f7e8039ea199980fad2272bd2c4'then return;end if;
 if actual is distinct from 'bf33e3111e92ceb230cd8b3e3cb85787'then raise exception 'Review changed public.create_render_job(uuid,uuid,text,jsonb,text,text) before applying recorded-source authority';end if;
 definition:=pg_get_functiondef('public.create_render_job(uuid,uuid,text,jsonb,text,text)'::regprocedure);
 if length(definition)-length(replace(definition,$old$  -- Fast path: an already-recorded idempotent replay.$old$,''))<>length($old$  -- Fast path: an already-recorded idempotent replay.$old$)then raise exception 'Recorded-source patch anchor changed';end if;
 execute replace(definition,$old$  -- Fast path: an already-recorded idempotent replay.$old$,$new$  -- Derived photo-video assets never become new paid recorded work.
  if v_source = 'worker' then perform public.assert_recorded_render_source(p_listing,p_asset); end if;
  -- Fast path: an already-recorded idempotent replay.$new$);
end$patch$;

do $patch$declare definition text;actual text;begin
 select md5(prosrc)into actual from pg_proc where oid='public.publish_recorded_render(uuid,boolean,numeric,numeric,jsonb,uuid)'::regprocedure;
 if actual='72e6665c31d00a258bcc6f59f1cb028e'then return;end if;
 if actual is distinct from '77e56a855d8267a75e39f6d0fe6305e8'then raise exception 'Review changed public.publish_recorded_render(uuid,boolean,numeric,numeric,jsonb,uuid) before applying recorded-source authority';end if;
 definition:=pg_get_functiondef('public.publish_recorded_render(uuid,boolean,numeric,numeric,jsonb,uuid)'::regprocedure);
 if length(definition)-length(replace(definition,$old$ if auth.uid()is null then raise insufficient_privilege;end if;$old$,''))<>length($old$ if auth.uid()is null then raise insufficient_privilege;end if;$old$)then raise exception 'Recorded-source patch anchor changed';end if;
 execute replace(definition,$old$ if auth.uid()is null then raise insufficient_privilege;end if;$old$,$new$ if auth.uid()is null then raise insufficient_privilege;end if;
 perform public.assert_recorded_render_source(j.listing_id,j.capture_asset_id) from public.render_jobs j where j.id=p_job;$new$);
end$patch$;
commit;
