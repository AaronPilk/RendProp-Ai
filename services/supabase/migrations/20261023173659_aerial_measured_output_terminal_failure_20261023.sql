-- SOURCE ONLY: atomic terminalization of an owned active measured-output refusal.
-- Requires the separately qualified raw-duration precision migration first.
begin;
set local lock_timeout='5s';
set local statement_timeout='30s';
do $terminal$
declare target_ regprocedure:='public.property_video_aerial_cpu_output(uuid,text,uuid,jsonb,boolean)'::regprocedure;
 before_ text;after_ text;metadata_ jsonb;after_metadata_ jsonb;
begin
 select pg_get_functiondef(target_) into before_;
 if md5(before_) is distinct from '9f2251777f9e9e475e56121c8ab07582' then raise exception 'Aerial terminal-output predecessor changed';end if;
 if md5(pg_get_functiondef('public.property_video_aerial_observe(uuid,text,uuid,text,bigint,jsonb,jsonb)'::regprocedure))is distinct from'2b60b01855672efeec027f11f48e2238'then raise exception'Aerial terminal-output failure dependency changed';end if;
 if md5(pg_get_functiondef('public.property_video_aerial_failure(uuid,text,uuid)'::regprocedure))is distinct from'55a27e16cc7897c13d8ec0cf5037df91'then raise exception'Aerial terminal-output failure dependency changed';end if;
 select(to_jsonb(p)-'prosrc')||jsonb_build_object('comment',obj_description(p.oid,'pg_proc'))into metadata_ from pg_proc p where p.oid=target_;
 after_:=$reviewed$CREATE OR REPLACE FUNCTION public.property_video_aerial_cpu_output(p_id uuid, p_phase text, p_lease uuid, p_facts jsonb, p_complete boolean)
 RETURNS property_video_aerial_openings
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare j public.property_video_aerial_openings;prior jsonb;f jsonb;asset uuid;key_ text;kind_ text;mime text;active_stage_ boolean;failure_facts_ jsonb;facts_sha_ text;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 -- Match observe's serving->job lock order before any measured failure write.
 select*into j from public.property_video_aerial_openings where id=p_id;
 if j.id is null then raise exception'RP404: Aerial processing receipt unavailable';end if;
 perform pg_advisory_xact_lock(hashtextextended('serving:'||j.billing_org_id,72452));
 perform pg_advisory_xact_lock(hashtextextended('serving:'||j.org_id,72452));
 select*into j from public.property_video_aerial_openings where id=p_id for update;j:=public.property_video_aerial_scope(p_id);
 if p_phase not in('input','qualification')or p_lease is distinct from(case p_phase when'input'then j.input_lease else j.qualification_lease end)
 or p_facts->>'manifest_sha256'is distinct from j.manifest_sha256 or p_facts->>'source_sha256'is distinct from j.manifest#>>'{source,sha256}'
 or p_facts->'producer_identity'is distinct from j.policy->'producer_identity'
 or p_facts->>'asset_id'is distinct from(case p_phase when'input'then j.input_asset_id else j.output_asset_id end)::text
 or(p_phase='input'and(p_facts->'source_bytes'is distinct from j.manifest#>'{source,bytes}'or p_facts->'reviewed_crop'is distinct from j.manifest->'reviewed_crop'))
 or(p_phase='qualification'and(p_facts->>'source_clip_sha256'is distinct from j.provider_clip->>'sha256'or p_facts->'source_clip_bytes'is distinct from j.provider_clip->'bytes'or p_facts->>'poster_asset_id'is distinct from j.poster_asset_id::text))
 then raise exception'RP409: Exact original,producer,lease and measured aerial output are required';end if;
 facts_sha_:=encode(sha256(convert_to(jsonb_build_object('facts',p_facts,'complete',p_complete)::text,'UTF8')),'hex');
 if j.state='failed'and exists(select 1 from public.property_video_aerial_observations o where o.aerial_job_id=p_id and o.phase=p_phase and o.lease_token=p_lease and o.outcome='failed'and o.facts->>'reason'='measured_output_refused'and o.facts->>'output_facts_sha256'=facts_sha_)then return j;end if;
 active_stage_:=j.cancel_requested_at is null and j.state=case p_phase when'input'then'preparing_input'else'qualifying'end;
 begin
 if coalesce(p_facts->>'sha256','')!~'^[a-f0-9]{64}$'or jsonb_typeof(p_facts->'bytes')is distinct from'number'
 or(p_facts->>'bytes')::numeric<>trunc((p_facts->>'bytes')::numeric)
 then raise exception'RP409: Measured aerial output digest and byte size are required';end if;
 if p_phase='input'then
  if j.state not in('preparing_input','queued_assessment','checking_source','queued_generation','dispatching','ambiguous','processing','queued_qualification','qualifying','queued_quality','checking_quality','ready_for_acceptance','accepted','cancelled')or j.input_lease is null
  or p_facts->'source_bytes'is distinct from j.manifest#>'{source,bytes}'or p_facts->>'mime'is distinct from'image/jpeg'or p_facts->'reviewed_crop'is distinct from j.manifest->'reviewed_crop'
  or(p_facts->>'bytes')::numeric not between 1 and 8388608
  or greatest((p_facts->>'width')::integer,(p_facts->>'height')::integer)>2048
  or(case j.manifest->>'aspect'when'16:9'then(p_facts->>'width')::bigint*9<>(p_facts->>'height')::bigint*16 or(p_facts->>'width')::integer<1920 or(p_facts->>'height')::integer<1080 else(p_facts->>'width')::bigint*16<>(p_facts->>'height')::bigint*9 or(p_facts->>'width')::integer<1080 or(p_facts->>'height')::integer<1920 end)
  then raise exception'RP409: The actual reviewed input must keep its exact aspect and native pixels';end if;
  asset:=j.input_asset_id;key_:=j.input_key;kind_:='photo';mime:='image/jpeg';prior:=j.input_output;
  f:=jsonb_build_object('asset_id',asset,'bucket','renders','storage_key',key_,'sha256',p_facts->'sha256','bytes',p_facts->'bytes','content_type',mime,'width',p_facts->'width','height',p_facts->'height','original_asset_id',j.manifest#>'{source,photo_asset_id}','original_sha256',j.manifest#>'{source,sha256}','original_bytes',j.manifest#>'{source,bytes}','aspect',j.manifest->'aspect','reviewed_crop',j.manifest->'reviewed_crop','producer_identity',p_facts->'producer_identity');
 else
  if j.state not in('qualifying','queued_quality','checking_quality','ready_for_acceptance','accepted','cancelled')or j.qualification_lease is null
  or p_facts->>'source_clip_sha256'is distinct from j.provider_clip->>'sha256'or p_facts->'source_clip_bytes'is distinct from j.provider_clip->'bytes'
  or(p_facts->>'bytes')::numeric not between 1 and 134217728
  or p_facts->'fps'is distinct from'24'::jsonb or coalesce((p_facts->>'available_frames')::integer,0)not in(120,121)or coalesce(abs((p_facts->>'duration_s')::numeric-(p_facts->>'available_frames')::numeric/24),1)>.000001
  or p_facts->'width'is distinct from to_jsonb(case j.manifest->>'aspect'when'16:9'then 1920 else 1080 end)or p_facts->'height'is distinct from to_jsonb(case j.manifest->>'aspect'when'16:9'then 1080 else 1920 end)
  or jsonb_typeof(p_facts->'source_metadata')is distinct from'object'or(select count(*)from jsonb_object_keys(p_facts->'source_metadata'))<>14
  or p_facts#>'{source_metadata,total_frames}'is distinct from p_facts->'available_frames'
  or p_facts#>'{source_metadata,fps}'is distinct from'24'::jsonb
  or coalesce(abs((p_facts#>>'{source_metadata,duration_s}')::numeric-(p_facts->>'available_frames')::numeric/24),1)>.001
  or p_facts#>>'{source_metadata,codec}'is distinct from'h264'or p_facts#>>'{source_metadata,pix_fmt}'is distinct from'yuv420p'
  or p_facts#>'{source_metadata,rotation}'is distinct from'0'::jsonb or p_facts#>'{source_metadata,audio_streams}'is distinct from'0'::jsonb
  or p_facts->>'source_color_interpretation'not in('tagged-sdr','untagged-sdr-bt709-defaults')
  or p_facts->>'codec'is distinct from'h264'or p_facts->>'pix_fmt'is distinct from'yuv420p'or p_facts->>'color_space'is distinct from'bt709'or p_facts->>'sample_aspect_ratio'is distinct from'1:1'or p_facts->'rotation'is distinct from'0'::jsonb or p_facts->'audio_streams'is distinct from'0'::jsonb
  or p_facts->'frame_indices'is distinct from jsonb_build_array(0,60,(p_facts->>'available_frames')::integer-1) or jsonb_typeof(p_facts->'frame_sha256s')is distinct from'array'or jsonb_array_length(p_facts->'frame_sha256s')<>3
  or exists(select 1 from jsonb_array_elements_text(p_facts->'frame_sha256s')v where v!~'^[a-f0-9]{64}$')
  then raise exception'RP409: The whole accepted opening must match the exact silent full-frame1080p qualification';end if;
  asset:=j.output_asset_id;key_:=j.output_key;kind_:='video';mime:='video/mp4';prior:=j.qualified_output;
  f:=(p_facts-'manifest_sha256'-'source_sha256'-'producer_identity'-'processing_wall_ms'-'etag'-'poster_etag')||jsonb_build_object('asset_id',asset,'bucket','renders','storage_key',key_,'content_type',mime,'provenance_id',coalesce(j.qualified_output->'provenance_id',to_jsonb(gen_random_uuid())),'producer_identity',p_facts->'producer_identity');
 end if;
 if p_facts->>'asset_id'is distinct from asset::text then raise exception'RP409: Keep the allocated private aerial output';end if;
 if prior is not null and(prior-array['etag','poster_etag','review_frames'])is distinct from f then raise exception'RP409: Measured aerial output facts are immutable';end if;
 if prior?'review_frames'then f:=f||jsonb_build_object('review_frames',prior->'review_frames');end if;
 if p_complete then
  if prior is null or coalesce(p_facts->>'etag','')=''or length(p_facts->>'etag')>512 then raise exception'RP409: Reserve and verify the exact aerial upload first';end if;
  f:=f||jsonb_build_object('etag',p_facts->>'etag');
  if p_phase='qualification'then
   if coalesce(p_facts->>'poster_etag','')=''then raise exception'RP409: Verify the actual aerial poster upload';end if;
   f:=f||jsonb_build_object('poster_etag',p_facts->>'poster_etag');
   update public.capture_assets set uploaded=true where id=j.poster_asset_id and listing_id=j.listing_id and storage_key=j.poster_key and sha256=f->>'poster_sha256'and bytes=(f->>'poster_bytes')::bigint;if not found then raise exception'RP409: Aerial poster receipt changed';end if;
  end if;
  if prior?'etag'then if prior is distinct from f then raise exception'RP409: Aerial upload receipt is immutable';end if;return j;end if;
  update public.capture_assets set uploaded=true where id=asset and listing_id=j.listing_id and storage_key=key_ and sha256=f->>'sha256'and bytes=(f->>'bytes')::bigint;if not found then raise exception'RP409: The allocated aerial upload changed';end if;
  if p_phase='input'then update public.property_video_aerial_openings set input_output=f,state=case when cancel_requested_at is null then'queued_assessment'else'cancelled'end,updated_at=now()where id=p_id returning*into j;
  else update public.property_video_aerial_openings set qualified_output=f,state=case when cancel_requested_at is null then'queued_quality'else'cancelled'end,updated_at=now()where id=p_id returning*into j;end if;
 else
  if prior?'etag'then return j;end if;
  perform public.media_storage_reserve(j.org_id,'renders',key_,(f->>'bytes')::bigint);
  insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded,transport_version,content_type,content_type_declared)
  values(asset,j.listing_id,kind_,'renders',key_,(f->>'bytes')::bigint,f->>'sha256',false,2,mime,true)on conflict do nothing;
  if p_phase='qualification'then
   if p_facts->>'poster_asset_id'is distinct from j.poster_asset_id::text or coalesce(p_facts->>'poster_sha256','')!~'^[a-f0-9]{64}$'or(p_facts->>'poster_bytes')::bigint not between 1 and 10485760 then raise exception'RP409: Keep the exact measured aerial poster';end if;
   perform public.media_storage_reserve(j.org_id,'renders',j.poster_key,(p_facts->>'poster_bytes')::bigint);
   insert into public.capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded,transport_version,content_type,content_type_declared)values(j.poster_asset_id,j.listing_id,'photo','renders',j.poster_key,(p_facts->>'poster_bytes')::bigint,p_facts->>'poster_sha256',false,2,'image/jpeg',true)on conflict do nothing;
  end if;
  if p_phase='input'then update public.property_video_aerial_openings set input_output=f where id=p_id returning*into j;
  else update public.property_video_aerial_openings set qualified_output=f where id=p_id returning*into j;end if;
 end if;return j;
 exception when raise_exception then
  -- Identity/auth/stale-state refusals never enter this active measured path.
  if not active_stage_ or sqlerrm not in(
   'RP409: Measured aerial output digest and byte size are required',
   'RP409: The actual reviewed input must keep its exact aspect and native pixels',
   'RP409: The whole accepted opening must match the exact silent full-frame1080p qualification',
   'RP409: Measured aerial output facts are immutable',
   'RP409: Keep the exact measured aerial poster')then raise;end if;
  failure_facts_:=jsonb_build_object('job_id',j.id,'manifest_sha256',j.manifest_sha256,'source_sha256',j.manifest#>'{source,sha256}',
   'source_mode','photo_motion_v1','composition_profile',case p_phase when'input'then'aerial-opening-input-v1'else'aerial-opening-qualify-cfr24'end,
   'phase',case p_phase when'input'then'prepare_image'else'compose'end,'code','cpu_attempt_failed','reason','measured_output_refused',
   'output_facts_sha256',facts_sha_,'producer_identity',j.policy->'producer_identity','processing_wall_ms',null);
  -- One transaction: unknown wall keeps the full started-stage liability.
  perform public.property_video_aerial_observe(p_id,p_phase,p_lease,'failed',null,j.policy->'producer_identity',failure_facts_);
  perform public.property_video_aerial_failure(p_id,p_phase,p_lease);
  select*into j from public.property_video_aerial_openings where id=p_id;
  return j;
 end;
end$function$
$reviewed$;
 if md5(after_)is distinct from'4f653429a61da574edf8aff16c9da926'then raise exception'Aerial terminal-output reviewed body changed';end if;
 execute after_;
 select(to_jsonb(p)-'prosrc')||jsonb_build_object('comment',obj_description(p.oid,'pg_proc'))into after_metadata_ from pg_proc p where p.oid=target_;
 if metadata_ is distinct from after_metadata_ or pg_get_functiondef(target_)is distinct from after_ then raise exception'Aerial terminal-output metadata/body changed';end if;
end$terminal$;
commit;
