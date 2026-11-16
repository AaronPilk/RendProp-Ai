-- Correct the bound-output ledger seam missed by the prior guarded migration.
-- NULL-listing sources retain the same ledger predicate; a listing-bound
-- accepted output must have a private output row for that exact listing.
begin;
do $repair$
declare d text;needle text;replacement text;before_metadata jsonb;target regprocedure;
begin
 target:='public.photo_publication_source(uuid,uuid,uuid,uuid)'::regprocedure;
 if (select md5(prosrc) from pg_proc where oid=target) is distinct from 'f344866bb5791ecbd2e2662154c39dea' then
  raise exception 'Review changed listing-bound publication source before output custody repair';
 end if;
 select to_jsonb(p)-'prosrc',pg_get_functiondef(p.oid) into before_metadata,d from pg_proc p where p.oid=target;
 needle:='where user_id=p_actor and org_id=p_org and listing_id is null and bucket=''renders''and storage_key=e.output->>''key''';
 replacement:='where user_id=p_actor and org_id=p_org and listing_id is not distinct from e.listing_id and bucket=''renders''and storage_key=e.output->>''key''';
 if length(d)-length(replace(d,needle,''))<>length(needle) then raise exception 'Review publication output custody seam'; end if;
 execute replace(d,needle,replacement);
 if (select to_jsonb(p)-'prosrc' from pg_proc p where p.oid=target) is distinct from before_metadata then
  raise exception 'Photo publication source metadata changed';
 end if;
end
$repair$;
commit;
