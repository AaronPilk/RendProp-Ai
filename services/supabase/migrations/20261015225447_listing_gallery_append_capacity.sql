-- Align service-only append with the existing100-photo validator/site.
-- Cover keys already named by an addition must not duplicate its100-key visibility batch.
-- No new authority/order/cover behavior; preserve exact prior owner/ACL/security/config.
begin;
do $capacity$
declare definition text; prior text; needle text; replacement text;
begin
 select md5(prosrc)into prior from pg_proc where oid='public.append_listing_gallery(uuid,uuid,uuid,uuid[],boolean,text)'::regprocedure;
 if prior='99b61e49ddd2ff1125c872c1daa2a729'then return;end if;
 if prior is distinct from '6cbd2e96784303cb42521b2b6ab0d296'then raise exception'Review changed append_listing_gallery before capacity alignment';end if;
 definition:=pg_get_functiondef('public.append_listing_gallery(uuid,uuid,uuid,uuid[],boolean,text)'::regprocedure);
 needle:='cardinality(p_add)>40';replacement:='cardinality(p_add)>100';
 if(length(definition)-length(replace(definition,needle,'')))<>length(needle)then raise exception'Review changed gallery capacity anchor';end if;
 definition:=replace(definition,needle,replacement);
 needle:='Choose up to 40 distinct uploaded gallery photos.';replacement:='Choose up to 100 distinct uploaded gallery photos.';
 if(length(definition)-length(replace(definition,needle,'')))<>length(needle)then raise exception'Review changed gallery capacity anchor';end if;
 definition:=replace(definition,needle,replacement);
 needle:='order by a.created_at,a.id limit 40';replacement:='order by a.created_at,a.id limit 100';
 if(length(definition)-length(replace(definition,needle,'')))<>length(needle)then raise exception'Review changed gallery capacity anchor';end if;
 definition:=replace(definition,needle,replacement);
 needle:='cardinality(selected)>40';replacement:='cardinality(selected)>100';
 if(length(definition)-length(replace(definition,needle,'')))<>length(needle)then raise exception'Review changed gallery capacity anchor';end if;
 definition:=replace(definition,needle,replacement);
 needle:='The published gallery can contain up to 40 photos. Review the selection before adding more.';replacement:='The published gallery can contain up to 100 photos. Review the selection before adding more.';
 if(length(definition)-length(replace(definition,needle,'')))<>length(needle)then raise exception'Review changed gallery capacity anchor';end if;
 definition:=replace(definition,needle,replacement);
 needle:='if p_set_main and p_main_photo_key is not null then';replacement:='if p_set_main and p_main_photo_key is not null and not(p_main_photo_key=any(candidate_keys))then';
 if(length(definition)-length(replace(definition,needle,'')))<>length(needle)then raise exception'Review changed gallery capacity anchor';end if;
 definition:=replace(definition,needle,replacement);
 execute definition;
 if(select md5(prosrc)from pg_proc where oid='public.append_listing_gallery(uuid,uuid,uuid,uuid[],boolean,text)'::regprocedure)is distinct from '99b61e49ddd2ff1125c872c1daa2a729'then raise exception'Gallery append capacity body did not match';end if;
end;
$capacity$;
commit;
