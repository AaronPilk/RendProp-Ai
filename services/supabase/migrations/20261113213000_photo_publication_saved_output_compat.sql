-- A listing-bound accepted edit may have been linked to its completed Studio
-- gallery upload before the publication bridge ran. Preserve the paid evidence
-- and original provenance; admit only that same actor's exact retained output
-- upload as an alternate source-row pointer. Publication still copies and
-- verifies the submitted original and remains mandatory for visibility.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $repair$
declare d text;needle text;replacement text;before_metadata jsonb;target regprocedure;
begin
 target:='public.photo_publication_source(uuid,uuid,uuid,uuid)'::regprocedure;
 if (select md5(prosrc) from pg_proc where oid=target) is distinct from 'aa0c5bc785a397f018d005a950f0fc93' then
  raise exception 'Review changed accepted-photo publication source before saved-output compatibility';
 end if;
 select to_jsonb(p)-'prosrc'-'prosqlbody',pg_get_functiondef(p.oid) into before_metadata,d from pg_proc p where p.oid=target;
 needle:='or m.altered_key is distinct from e.output->>''key''then raise exception''RP404: This saved photo is unavailable for publication'';end if;';
 replacement:=$guard$or (m.altered_key is distinct from e.output->>'key' and
  (e.listing_id is null or not exists(
   select 1 from public.capture_assets saved_asset
   join public.upload_reservations r on r.asset_id=saved_asset.id
   join public.upload_operations o on o.asset_id=saved_asset.id and o.kind='copy' and o.part=0
   where saved_asset.storage_key=m.altered_key and saved_asset.listing_id=e.listing_id
    and saved_asset.kind='photo' and saved_asset.bucket='renders' and saved_asset.transport_version=2
    and saved_asset.uploaded is true and saved_asset.upload_aborted is false
    and saved_asset.sha256=e.output->>'sha256' and to_jsonb(saved_asset.bytes)=e.output->'bytes'
    and saved_asset.content_type=e.output->>'mime'
    and saved_asset.storage_key~('^renders/'||p_org::text||'/'||e.listing_id::text||'/[^/]+$')
    and saved_asset.storage_key!~'[?#%\\[:cntrl:]]|(^|/)[.]{1,2}(/|$)'
    and r.actor_id=p_actor and r.org_id=p_org and r.listing_id=e.listing_id
    and r.state='completed' and r.spec->>'key_role'='gallery'
    and o.state='retained' and o.bucket='renders' and o.object_key=saved_asset.storage_key
    and o.expected_bytes=saved_asset.bytes and o.content_type=saved_asset.content_type
    and o.claim is not null and nullif(o.etag,'') is not null and length(o.etag)<=256
  )))then raise exception'RP404: This saved photo is unavailable for publication';end if;$guard$;
 if length(d)-length(replace(d,needle,''))<>length(needle) then
  raise exception 'Review exact accepted-photo source pointer seam';
 end if;
 execute replace(d,needle,replacement);
 if (select to_jsonb(p)-'prosrc'-'prosqlbody' from pg_proc p where p.oid=target) is distinct from before_metadata then
  raise exception 'Accepted-photo publication source metadata changed';
 end if;
end
$repair$;
commit;
