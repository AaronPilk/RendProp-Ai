-- A direct paid property clip owns its provenance. The legacy disclosure
-- dedupe and every historical/background binding remain unchanged.
begin;
create or replace function public.record_direct_property_video_source(
 p_actor uuid,p_org uuid,p_key text,p_listing uuid,p_asset uuid,p_photo_provenance uuid,
 p_request text,p_sha256 text,p_qc_hash text,p_label text,p_style text,p_prompt_summary text
)returns jsonb language plpgsql security definer set search_path=''as $$
declare r public.app_video_cost_reservations;s public.property_video_sources;
 g public.media_provenance;ctx jsonb;bound jsonb;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_actor is null or p_org is null or p_listing is null or p_asset is null
  or p_key is null or p_key!~'^[!-~]{8,128}$'or p_request is null or length(p_request)not between 1 and 256
  or p_request!~'^[A-Za-z0-9_-]+$'or coalesce(p_sha256,'')!~'^[a-f0-9]{64}$'
  or coalesce(p_qc_hash,'')!~'^[a-f0-9]{32}$'then raise exception'RP400: An exact paid property clip source is required';end if;
 -- Match the canonical acceptance/deletion parent order before the exact
 -- reservation lock. A late completion cannot resurrect erased scope.
 perform 1 from auth.users where id=p_actor and is_anonymous is false for share;
 if not found then raise exception'RP404: Property clip account is unavailable';end if;
 perform 1 from public.profiles where id=p_actor for share;
 if not found then raise exception'RP404: Property clip account is unavailable';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for share;
 if not found then raise exception'RP404: Property clip library is unavailable';end if;
 perform 1 from public.listings where id=p_listing and org_id=p_org and deleted_at is null for share;
 if not found or not public.listing_content_access(p_actor,p_listing,true)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))
 then raise exception'RP404: Property clip source is unavailable';end if;
 select *into r from public.app_video_cost_reservations
  where actor_id=p_actor and org_id=p_org and idempotency_key=p_key for update;
 if r.id is null or r.feature<>'reel'or r.meta->>'task'is distinct from'video.reel_clip'
  or r.provider_request_id is distinct from p_request or r.settled_at is null or r.released_at is not null
 then raise exception'RP409: Accepted property clip payment is unavailable';end if;
 perform 1 from public.cost_ledger where id=r.cost_ledger_id for share;
 perform 1 from public.app_video_allowance_receipts where reservation_id=r.id for share;
 -- Keep exact retained source/receipt proofs stable while the existing current
 -- source validator and immutable paid-source binder execute.
 perform 1 from public.capture_assets where id=p_asset for share;
 perform 1 from public.upload_reservations where asset_id=p_asset for share;
 perform 1 from public.upload_operations where asset_id=p_asset order by id for share;
 perform 1 from public.property_video_preparations where asset_id=p_asset for share;
 perform 1 from public.media_provenance where id=p_photo_provenance for share;
 ctx:=public.property_photo_reference(p_actor,p_listing,p_asset,p_photo_provenance);
 if ctx->>'org_id'is distinct from p_org::text or ctx->>'sha256'is distinct from p_sha256
 then raise exception'RP409: The selected property clip source changed';end if;
 select *into s from public.property_video_sources where request_id=p_request;
 if s.request_id is not null then
  -- Includes old shared provenance: validate and return, never rewrite/split.
  bound:=public.bind_property_video_source(p_actor,p_listing,p_asset,p_photo_provenance,
   p_request,s.generation_provenance_id,p_sha256,p_qc_hash);
  select *into g from public.media_provenance where id=s.generation_provenance_id;
 else
  insert into public.media_provenance(org_id,listing_id,kind,model_id,edit,label,style,prompt_summary,disclosure)
   values(p_org,p_listing,'reel',r.model,'reel',
    nullif(left(regexp_replace(coalesce(p_label,''),'[\r\n\t]+',' ','g'),80),''),
    nullif(lower(left(trim(coalesce(p_style,'')),40)),''),
    nullif(left(regexp_replace(coalesce(p_prompt_summary,''),'[\r\n\t]+',' ','g'),300),''),
    public.provenance_disclosure('reel','reel'))returning *into g;
  -- Any refusal rolls the new row back with this same transaction.
  bound:=public.bind_property_video_source(p_actor,p_listing,p_asset,p_photo_provenance,
   p_request,g.id,p_sha256,p_qc_hash);
 end if;
 if bound->'bound'is distinct from'true'::jsonb or g.id is null then
  raise exception'RP409: The paid property clip source could not be recorded';end if;
 return jsonb_build_object('bound',true,'request_id',p_request,'provenance_id',g.id,'disclosure',g.disclosure);
end$$;
revoke all on function public.record_direct_property_video_source(uuid,uuid,text,uuid,uuid,uuid,text,text,text,text,text,text)from public,anon,authenticated;
grant execute on function public.record_direct_property_video_source(uuid,uuid,text,uuid,uuid,uuid,text,text,text,text,text,text)to service_role;
commit;
