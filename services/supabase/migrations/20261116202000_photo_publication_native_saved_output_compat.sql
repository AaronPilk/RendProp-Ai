-- Native saved edits attach their retained render upload to the accepted
-- provenance before listing selection. That normal upload uses key_role
-- default; Studio uses gallery. Admit both established output roles only
-- after the existing exact accepted-output and retained-copy checks.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $repair$
declare d text; needle text; replacement text; before_metadata jsonb; target regprocedure; current_body_md5 text;
begin
 target:='public.photo_publication_source(uuid,uuid,uuid,uuid)'::regprocedure;
 select md5(prosrc) into current_body_md5 from pg_proc where oid=target;
 if current_body_md5='21c9e4e699d371f2a2c1c66b02eb99a4' then return; end if;
 if current_body_md5 is distinct from '7320436e2ec027c83f3a2eddf50dc7af' then
  raise exception 'Review changed accepted-photo source before native saved-output compatibility';
 end if;
 select to_jsonb(p)-'prosrc'-'prosqlbody',pg_get_functiondef(p.oid) into before_metadata,d from pg_proc p where p.oid=target;
 needle:=$old$and r.state='completed' and r.spec->>'key_role'='gallery'$old$;
 replacement:=$new$and r.state='completed' and r.spec->>'key_role' in ('gallery','default')$new$;
 if length(d)-length(replace(d,needle,''))<>length(needle) then
  raise exception 'Review exact retained native output role seam';
 end if;
 execute replace(d,needle,replacement);
 if (select to_jsonb(p)-'prosrc'-'prosqlbody' from pg_proc p where p.oid=target) is distinct from before_metadata then
  raise exception 'Accepted-photo source metadata changed';
 end if;
 if (select md5(prosrc) from pg_proc where oid=target) is distinct from '21c9e4e699d371f2a2c1c66b02eb99a4' then
  raise exception 'Native accepted-photo source result changed';
 end if;
end
$repair$;
commit;
