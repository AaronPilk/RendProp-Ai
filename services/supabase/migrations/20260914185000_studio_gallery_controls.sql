-- Small, atomic gallery changes keep the existing native photos/listings model.
begin;
create function public.studio_named_account_active()
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from auth.users u where u.id=auth.uid() and u.is_anonymous is false)
    and not exists(select 1 from public.deletion_requests d where d.user_id=auth.uid() and d.status in ('pending','processing'));
$$;
revoke all on function public.studio_named_account_active() from public,anon;
grant execute on function public.studio_named_account_active() to authenticated;

create function public.studio_gallery_update(
  p_org_id uuid,p_listing_id uuid,p_action text,p_photo_id uuid default null,
  p_expected jsonb default null,p_value jsonb default null
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare current_key text; chosen_key text; current_order jsonb; next_ids uuid[];
begin
  if not public.studio_named_account_active() or public.org_role(p_org_id) is null
    or public.org_role(p_org_id) not in ('owner','admin','agent') then
    raise exception 'RP403: Your account cannot edit this property gallery';
  end if;
  if p_action is null or p_action not in ('reorder','cover') then raise exception 'RP400: Invalid gallery action'; end if;
  -- Listing first, then sorted photos, matches the native deletion/publish lock
  -- order. The parent lock also fences concurrent FK inserts during reordering.
  select l.main_photo_key into current_key from public.listings l
    join public.orgs o on o.id=l.org_id
    where l.id=p_listing_id and l.org_id=p_org_id and l.deleted_at is null and o.deleted_at is null
    for update of l;
  if not found then raise exception 'RP404: Property not found'; end if;
  perform 1 from public.photos where listing_id=p_listing_id order by id for update;
  if p_action='cover' then
    if jsonb_typeof(coalesce(p_expected,'null'::jsonb)) not in ('null','string') then raise exception 'RP400: Cover reference is required'; end if;
    select coalesce(nullif(enhanced_key,''),original_key) into chosen_key from public.photos
      where id=p_photo_id and listing_id=p_listing_id;
    if not found then raise exception 'RP404: Gallery photo not found'; end if;
    if chosen_key is null or chosen_key not like 'renders/'||p_org_id::text||'/'||p_listing_id::text||'/%'
      or length(chosen_key)>1024 or position('..' in chosen_key)>0 or chosen_key ~ '[?#\\]' then
      raise exception 'RP400: Choose a published gallery photo for the cover';
    end if;
    if coalesce(to_jsonb(current_key),'null'::jsonb) is distinct from coalesce(p_expected,'null'::jsonb) and current_key is distinct from chosen_key then
      raise exception 'RP409: The cover changed on another device. Refresh before choosing again';
    end if;
    update public.photos set is_main=(id=p_photo_id) where listing_id=p_listing_id and is_main is distinct from (id=p_photo_id);
    update public.listings set main_photo_key=chosen_key where id=p_listing_id and org_id=p_org_id;
    return jsonb_build_object('ok',true,'photo_id',p_photo_id,'main_photo_key',chosen_key);
  end if;
  if jsonb_typeof(p_expected) is distinct from 'array' or jsonb_typeof(p_value) is distinct from 'array' then raise exception 'RP400: Gallery order is required'; end if;
  if jsonb_array_length(p_expected) not between 1 and 500 or jsonb_array_length(p_value)<>jsonb_array_length(p_expected)
    or exists(select 1 from jsonb_array_elements(p_expected||p_value) x where jsonb_typeof(x) is distinct from 'string' or (x#>>'{}') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then
    raise exception 'RP400: Choose a complete gallery of up to 500 photos';
  end if;
  select array_agg(value::uuid order by n) into next_ids from jsonb_array_elements_text(p_value) with ordinality x(value,n);
  if cardinality(next_ids)<>(select count(distinct id) from unnest(next_ids) id)
    or (select count(distinct value) from jsonb_array_elements_text(p_expected))<>jsonb_array_length(p_expected)
    or not p_expected @> p_value or not p_value @> p_expected then raise exception 'RP400: Gallery order must contain each photo exactly once'; end if;
  select coalesce(jsonb_agg(id order by sort,id),'[]'::jsonb) into current_order from public.photos where listing_id=p_listing_id;
  -- Repeating a confirmed move is safe; a changed membership/order is a conflict.
  if current_order=p_value then return jsonb_build_object('ok',true,'photo_ids',p_value); end if;
  if current_order is distinct from p_expected then raise exception 'RP409: The gallery changed on another device. Refresh before reordering'; end if;
  update public.photos p set sort=(x.n-1)::smallint from unnest(next_ids) with ordinality x(id,n)
    where p.id=x.id and p.listing_id=p_listing_id;
  return jsonb_build_object('ok',true,'photo_ids',p_value);
end;
$$;
revoke all on function public.studio_gallery_update(uuid,uuid,text,uuid,jsonb,jsonb) from public,anon;
grant execute on function public.studio_gallery_update(uuid,uuid,text,uuid,jsonb,jsonb) to authenticated;
commit;
