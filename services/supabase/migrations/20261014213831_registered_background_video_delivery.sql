-- Registered background masters only: exact retained output authority.
-- Generic media_delivery_admit keeps its256MiB request bound. A larger verified
-- object's byte budget is admitted through bounded chunks in ONE transaction;
-- any later refusal rolls back every preceding chunk and rate/request debit.
do $$declare body text;begin
 body:=pg_get_functiondef('public.property_video_job_outputs_reserve(uuid,uuid,bigint,text,bigint,text)'::regprocedure);
 if position('p_bytes not between 1 and 1073741824'in body)>0 then
  execute replace(body,'p_bytes not between 1 and 1073741824','p_bytes not between 1 and 1610612736');
 elsif position('p_bytes not between 1 and 1610612736'in body)=0 then
  raise exception'Review changed background-output reserve before aligning its admitted size';
 end if;
end$$;

create or replace function public.background_video_delivery(p_actor uuid,p_org uuid,p_listing uuid,p_key text,p_bytes bigint default 0)returns jsonb
language plpgsql security definer set search_path=''as $$
declare j public.property_video_jobs;o public.property_video_job_outputs;a public.capture_assets;ctx jsonb;remaining bigint;part bigint;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_org is null or p_listing is null or p_key is null or p_bytes is null or p_bytes not between 0 and 1610612736 then raise exception'RP400: Use exact bounded background-video delivery';end if;
 select output.*into o from public.property_video_job_outputs output join public.property_video_jobs job on job.id=output.job_id
  where output.storage_key=p_key and output.kind='video'and output.state='ready'and job.state='ready'
  and job.org_id=p_org and job.listing_id=p_listing and job.output_asset_id=output.asset_id and job.compose_lease=output.lease_token;
 if o.asset_id is null then if p_bytes>268435456 then raise exception'RP403: Large media is not a registered background master';end if;return null;end if;
 select *into j from public.property_video_jobs where id=o.job_id;
 select *into a from public.capture_assets where id=o.asset_id and listing_id=p_listing and kind='video'and bucket='renders'and storage_key=p_key and uploaded and not upload_aborted;
 if a.id is null or o.bytes not between 1 and 1610612736 or o.sha256!~'^[a-f0-9]{64}$'or o.etag is null
  or a.bytes is distinct from o.bytes or a.sha256 is distinct from o.sha256 or a.content_type is distinct from'video/mp4'
  or j.result->>'asset_id'is distinct from o.asset_id::text or j.result->>'sha256'is distinct from o.sha256
  or(j.result->>'bytes')::bigint is distinct from o.bytes then raise exception'RP409: Background video receipt changed';end if;
 -- The existing output authority rechecks exact source/QC/withdrawal and its
 -- originalactor. Private reads additionally keep the current reader boundary.
 ctx:=public.property_owned_upload(j.actor_id,p_listing,o.asset_id,'video');
 if ctx->>'etag'is distinct from o.etag or(ctx->>'bytes')::bigint is distinct from o.bytes or ctx->>'sha256'is distinct from o.sha256
  or ctx->>'org_id'is distinct from p_org::text or ctx->>'storage_key'is distinct from p_key then raise exception'RP409: Registered background output is unavailable';end if;
 if p_actor is not null and not public.listing_content_access(p_actor,p_listing,false)then raise exception'RP404: This private background video is unavailable';end if;
 if not public.studio_presenter_key_access(p_listing,p_key)then raise exception'RP404: Background video was withdrawn';end if;
 if p_bytes>o.bytes then raise exception'RP400: A delivery cannot exceed its exact registered object';end if;
 remaining:=p_bytes;
 -- Metadata reads are already admitted by the calling Edge handler; only its
 -- exact large byte request uses this atomic additional admission.
 if remaining>268435456 then
  while remaining>0 loop part:=least(remaining,268435456);
   if p_actor is null then perform public.media_delivery_admit(p_org,part,true);
   else perform public.library_media_delivery_admit(p_actor,p_org,part,true);end if;
   remaining:=remaining-part;
  end loop;
 end if;
 return jsonb_build_object('kind','registered_background_video','asset_id',o.asset_id,'bytes',o.bytes,'sha256',o.sha256,'max_object_bytes',1610612736);
end$$;
revoke all on function public.background_video_delivery(uuid,uuid,uuid,text,bigint)from public,anon,authenticated;
grant execute on function public.background_video_delivery(uuid,uuid,uuid,text,bigint)to service_role;
