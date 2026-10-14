-- All sitemap pages and boundary cursors use exactly one opt-in authority.
create or replace function public.public_property_tour_rows()returns table(id uuid,slug text,published_at timestamptz,address text,space_type text)language plpgsql security definer set search_path=''as $$begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 return query with latest as(select distinct on(r.listing_id)r.id,r.listing_id,r.slug,r.published_at from public.renders r where r.published_at is not null and r.published_at<=now()order by r.listing_id,r.published_at desc,r.id desc)
  select r.id,r.slug,r.published_at,l.address,l.space_type from latest r join public.listings l on l.id=r.listing_id join public.orgs o on o.id=l.org_id
  where l.deleted_at is null and o.deleted_at is null and l.status<>'archived'
   and coalesce(case when l.details?'allow_indexing'then l.details->'allow_indexing'else o.brand_kit->'allow_indexing'end,'false'::jsonb)in('true'::jsonb,'"true"'::jsonb)
   and not exists(select 1 from public.deletion_requests d where d.user_id=l.agent_id and d.status in('pending','processing'))
   and(public.hosting_retention_state(l.org_id)->>'hosting_available')::boolean
   and public.studio_presenter_render_access(r.id)
;end$$;
create or replace function public.public_property_tour_index(p_after uuid default null,p_limit integer default 100)returns jsonb language plpgsql security definer set search_path=''as $$declare rows jsonb;next_id uuid;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_limit is null or p_limit not between 1 and 200 then raise exception'RP400: Use a bounded tour index page';end if;
 with eligible as(select * from public.public_property_tour_rows()where p_after is null or id>p_after order by id limit p_limit+1),page as(select * from eligible order by id limit p_limit)
 select coalesce(jsonb_agg(jsonb_build_object('slug',slug,'published_at',published_at,'allow_indexing',true,'address',address,'space_type',space_type)order by id),'[]'::jsonb),case when(select count(*)from eligible)>p_limit then(select id from page order by id desc limit 1)else null end into rows,next_id from page;
 return jsonb_build_object('tours',rows,'portfolios','[]'::jsonb,'next_cursor',next_id);end$$;
create or replace function public.public_property_tour_index_pages()returns jsonb language plpgsql security definer set search_path=''as $$declare pages jsonb;more boolean;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 with bounded as(select id,row_number()over(order by id)n from public.public_property_tour_rows()order by id limit 50001),bounds as(select null::uuid cursor,0::bigint n where exists(select 1 from bounded)union all select id,n from bounded where n%200=0 and n<50000 and exists(select 1 from bounded b where b.n>bounded.n))
 select coalesce((select jsonb_agg(jsonb_build_object('cursor',cursor)order by n)from bounds),'[]'::jsonb),exists(select 1 from bounded where n>50000)into pages,more;
 return jsonb_build_object('page_size',200,'pages',pages,'truncated',more);end$$;
revoke all on function public.public_property_tour_rows(),public.public_property_tour_index(uuid,integer),public.public_property_tour_index_pages()from public,anon,authenticated;
grant execute on function public.public_property_tour_rows(),public.public_property_tour_index(uuid,integer),public.public_property_tour_index_pages()to service_role;
