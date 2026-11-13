-- Internal read-only authority repair; no grants, transport guards, stored verdicts or rows change.
begin;
do $repair$
declare f record;before_metadata jsonb;target regprocedure;
begin
 target:='public.photo_publication_source(uuid,uuid,uuid,uuid)'::regprocedure;
 if(select md5(prosrc)from pg_proc where oid=target)is distinct from'6bf0cdc0a9e4636aa24b006219eac1f7'or md5(pg_get_functiondef(target))is distinct from'0e5bc1cc297316d6a8c91c6f0da3bc52'then raise exception'Review changed photo publication internal authority: photo_publication_source';end if;
 select to_jsonb(p)-'prosrc'into before_metadata from pg_proc p where p.oid=target;
 execute $definition$CREATE OR REPLACE FUNCTION public.photo_publication_source(p_actor uuid, p_org uuid, p_library uuid, p_evidence uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e public.photo_edit_evidence;q public.photo_quality_checks;m public.media_provenance;c jsonb;prefix text;
begin
 select*into e from public.photo_edit_evidence where id=p_evidence;
 select*into q from public.photo_quality_checks where evidence_id=e.id and automatic;
 select*into m from public.media_provenance where id=e.provenance_id;
 if e.id is null or e.actor_id is distinct from p_actor or e.org_id is distinct from p_org or e.library_org_id is distinct from p_library
  or e.listing_id is not null or e.purpose is distinct from'prospective'or e.state is distinct from'accept'
  or q.id is null or q.state is distinct from'accept'or q.policy is distinct from e.policy or q.result->>'action'is distinct from'accept'or q.result->>'verdict'is distinct from'pass'
  or e.original_asset_id is not null or e.original_reference is not null or m.id is null or m.org_id is distinct from e.org_id or m.listing_id is not null
  or m.photo_publication is not null or m.kind not in('photo_edit','virtual_stage','declutter')or m.qc_checked_at is null
  or m.qc->>'task'is distinct from'judge.photo_fixed_features'or m.qc->>'medium'is distinct from'photo'
  or m.qc->>'purpose'is distinct from'prospective'or m.qc->'publishable'is distinct from'true'::jsonb
  or m.qc->>'action'is distinct from'accept'or m.qc->>'evidence_id'is distinct from e.id::text
  or m.qc->>'check_id'is distinct from q.id::text or m.qc->>'prepared_sha256'is distinct from e.input->>'sha256'
  or m.qc->>'output_sha256'is distinct from e.output->>'sha256'or e.input_etag is null or e.output_etag is null
  or m.altered_key is distinct from e.output->>'key'then raise exception'RP404: This saved photo is unavailable for publication';end if;
 if not exists(select 1 from auth.users u join public.profiles p on p.id=u.id where u.id=p_actor and not u.is_anonymous)
  or not exists(select 1 from public.orgs where id=p_org and deleted_at is null)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception'RP404: This saved photo is unavailable for publication';end if;
 if public.library_content_access(p_actor,p_org,true)is distinct from true then raise exception'RP404: This saved photo is unavailable for publication';end if;
 prefix:='ai-router/'||e.org_id||'/photo-evidence/'||e.actor_id||'/'||e.id||'/';
 if e.input->>'bucket'is distinct from'renders'or e.output->>'bucket'is distinct from'renders'
  or e.input->>'key'is distinct from prefix||'input.'||(case e.input->>'mime'when'image/jpeg'then'jpg'when'image/png'then'png'else'webp'end)
  or e.output->>'key'is distinct from prefix||'candidate.'||(case e.output->>'mime'when'image/jpeg'then'jpg'when'image/png'then'png'else'webp'end)
  or e.input->>'key'~'[?#%\\[:cntrl:]]|(^|/)[.]{1,2}(/|$)'or e.output->>'key'~'[?#%\\[:cntrl:]]|(^|/)[.]{1,2}(/|$)'
  or not exists(select 1 from public.private_ai_outputs where user_id=p_actor and org_id=p_org and listing_id is null and bucket='renders'and storage_key=e.input->>'key'and bytes=(e.input->>'bytes')::bigint)
  or not exists(select 1 from public.private_ai_outputs where user_id=p_actor and org_id=p_org and listing_id is null and bucket='renders'and storage_key=e.output->>'key'and bytes=(e.output->>'bytes')::bigint)
 then raise exception'RP404: This saved photo is unavailable for publication';end if;
 return jsonb_build_object('evidence',to_jsonb(e),'check',to_jsonb(q),'provenance',to_jsonb(m),
  'source_input',(e.input-'width'-'height'-'bucket')||jsonb_build_object('etag',e.input_etag),
  'source_output',(e.output-'width'-'height'-'bucket')||jsonb_build_object('etag',e.output_etag));
end$function$
$definition$;
 if(select to_jsonb(p)-'prosrc'from pg_proc p where p.oid=target)is distinct from before_metadata then raise exception'Photo publication function metadata changed: photo_publication_source';end if;
 target:='public.photo_publication_metadata_valid(uuid)'::regprocedure;
 if(select md5(prosrc)from pg_proc where oid=target)is distinct from'327b37c4f208683c50364e8c50e22991'or md5(pg_get_functiondef(target))is distinct from'75f2010dee479504379bf22b7f7ad098'then raise exception'Review changed photo publication internal authority: photo_publication_metadata_valid';end if;
 select to_jsonb(p)-'prosrc'into before_metadata from pg_proc p where p.oid=target;
 execute $definition$CREATE OR REPLACE FUNCTION public.photo_publication_metadata_valid(p_publication uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m public.media_provenance;p jsonb;s jsonb;t jsonb;c jsonb;a public.capture_assets;b public.capture_assets;u public.upload_operations;v public.upload_operations;
begin
 select*into m from public.media_provenance where id=p_publication;p:=m.photo_publication;
 if p is null or not public.photo_publication_receipt_shape(p)or p->>'phase'<>'prepared'then return false;end if;
 s:=public.photo_publication_source((p#>>'{source,actor_id}')::uuid,(p#>>'{source,org_id}')::uuid,(p#>>'{source,library_org_id}')::uuid,(p#>>'{source,evidence_id}')::uuid);
 if m.org_id::text is distinct from p#>>'{target,org_id}'or m.listing_id::text is distinct from p#>>'{target,listing_id}'
  or p#>>'{source,org_id}'is distinct from p#>>'{target,org_id}'or p#>>'{source,library_org_id}'is distinct from p#>>'{target,library_org_id}'
  or s#>>'{evidence,provenance_id}'is distinct from p#>>'{source,provenance_id}'or s#>>'{check,id}'is distinct from p#>>'{source,automatic_check_id}'
  or s#>>'{evidence,request_key}'is distinct from p#>>'{source,request_key}'or s#>>'{evidence,request_sha256}'is distinct from p#>>'{source,request_sha256}'
  or((s->'source_input')-'key')is distinct from p->'input'or((s->'source_output')-'key')is distinct from p->'output'
  or m.qc is distinct from s#>'{provenance,qc}'or to_jsonb(m.qc_checked_at)is distinct from s#>'{provenance,qc_checked_at}'then return false;end if;
 if public.listing_content_access((p#>>'{source,actor_id}')::uuid,m.listing_id,true)is distinct from true
  or not exists(select 1 from public.listings l where l.id=m.listing_id and l.deleted_at is null and l.org_id=m.org_id)
  or public.listing_owner_library(m.listing_id)::text is distinct from p#>>'{target,library_org_id}'then return false;end if;
 select*into a from public.capture_assets where id=(p#>>'{target,output_asset_id}')::uuid;
 select*into b from public.capture_assets where id=(p#>>'{target,source_copy_asset_id}')::uuid;
 select*into u from public.upload_operations where id=(p#>>'{copy,target_output_upload_operation_id}')::uuid;
 select*into v from public.upload_operations where id=(p#>>'{copy,operation_id}')::uuid;
 if a.id is null or b.id is null or a.listing_id is distinct from m.listing_id or b.listing_id is distinct from m.listing_id
  or a.kind<>'photo'or b.kind<>'photo'or a.bucket<>'renders'or b.bucket<>'renders'or not a.uploaded or not b.uploaded or a.upload_aborted or b.upload_aborted
  or a.storage_key is distinct from m.altered_key or b.storage_key is distinct from m.original_key
  or a.bytes is distinct from(p#>>'{output,bytes}')::bigint or b.bytes is distinct from(p#>>'{input,bytes}')::bigint
  or a.content_type is distinct from p#>>'{output,mime}'or b.content_type is distinct from p#>>'{input,mime}'
  or b.sha256 is distinct from p#>>'{input,sha256}'
  or u.asset_id is distinct from a.id or v.asset_id is distinct from b.id or u.state is distinct from'retained'or v.state is distinct from'retained'
  or u.kind<>'copy'or v.kind<>'copy'or u.bucket<>'renders'or v.bucket<>'renders'or u.asset_kind<>'photo'or v.asset_kind<>'photo'
  or u.expected_bytes is distinct from a.bytes or v.expected_bytes is distinct from b.bytes or v.bytes is distinct from b.bytes
  or u.content_type is distinct from a.content_type or v.content_type is distinct from b.content_type or u.claim is null or v.claim is null
  or u.object_key is distinct from a.storage_key or v.object_key is distinct from b.storage_key
  or u.etag is distinct from p#>>'{copy,target_output_etag}'or v.etag is distinct from p#>>'{copy,source_copy_etag}'
  or not exists(select 1 from public.upload_reservations where asset_id=a.id and actor_id=(p#>>'{source,actor_id}')::uuid and state='completed')
  or not exists(select 1 from public.upload_reservations where asset_id=b.id and actor_id=(p#>>'{source,actor_id}')::uuid and state='completed')
 then return false;end if;
 return true;
exception when others then return false;
end$function$
$definition$;
 if(select to_jsonb(p)-'prosrc'from pg_proc p where p.oid=target)is distinct from before_metadata then raise exception'Photo publication function metadata changed: photo_publication_metadata_valid';end if;
end
$repair$;
commit;
