-- A prepared accepted photo must be readable under the owner's authenticated
-- capture_assets RLS policy. The listing-bound source branch accidentally
-- calls a service-role-only scope helper from inside that policy. Preserve
-- its actor, active listing, org and library checks using the underlying
-- security-definer content predicates, without changing grants or proofs.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $repair$
declare d text; needle text; replacement text; before_metadata jsonb; target regprocedure; current_body_md5 text;
begin
 target:='public.photo_publication_source(uuid,uuid,uuid,uuid)'::regprocedure;
 select md5(prosrc) into current_body_md5 from pg_proc where oid=target;
 -- A replay accepts only the exact reviewed result, never an unknown body.
 if current_body_md5='7320436e2ec027c83f3a2eddf50dc7af' then return; end if;
 if current_body_md5 is distinct from '1fc4ef9f9702ca88d958915ee3ca5f2e' then
  raise exception 'Review changed accepted-photo source before authenticated read repair';
 end if;
 select to_jsonb(p)-'prosrc'-'prosqlbody',pg_get_functiondef(p.oid) into before_metadata,d from pg_proc p where p.oid=target;
 needle:=$old$  c:=public.listing_library_scope(p_actor,e.listing_id);
  if c is null or c->>'can_write' is distinct from 'true'
   or c->>'org_id' is distinct from p_org::text
   or c->>'library_org_id' is distinct from p_library::text then
   raise exception 'RP404: This saved photo is unavailable for publication';
  end if;$old$;
 replacement:=$new$  if public.listing_content_access(p_actor,e.listing_id,true) is distinct from true
   or not exists(select 1 from public.listings l where l.id=e.listing_id and l.deleted_at is null and l.org_id=p_org)
   or public.listing_owner_library(e.listing_id) is distinct from p_library then
   raise exception 'RP404: This saved photo is unavailable for publication';
  end if;$new$;
 if length(d)-length(replace(d,needle,''))<>length(needle) then
  raise exception 'Review exact listing-bound accepted-photo scope seam';
 end if;
 execute replace(d,needle,replacement);
 if (select to_jsonb(p)-'prosrc'-'prosqlbody' from pg_proc p where p.oid=target) is distinct from before_metadata then
  raise exception 'Accepted-photo source metadata changed';
 end if;
 if (select md5(prosrc) from pg_proc where oid=target) is distinct from '7320436e2ec027c83f3a2eddf50dc7af' then
  raise exception 'Accepted-photo source result changed';
 end if;
 if (select prosrc from pg_proc where oid=target) like '%c:=public.listing_library_scope(p_actor,e.listing_id);%' then
  raise exception 'Accepted-photo source still calls the service-only listing scope';
 end if;
end
$repair$;
commit;
