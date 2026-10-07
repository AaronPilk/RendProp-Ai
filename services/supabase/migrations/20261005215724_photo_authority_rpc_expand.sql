begin;
-- Expand first. Deploy the request-owned Studio RPC adapter before applying
-- the separate photo privilege contraction. No old client authority is added.
create or replace function public.studio_photo_authority(p_actor uuid,p_org uuid,p_listing uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 if current_setting('role',true)is distinct from 'service_role'then
  raise insufficient_privilege using message='service role required';end if;
 perform 1 from public.profiles where id=p_actor for update;
 if not found or not exists(select 1 from auth.users where id=p_actor and is_anonymous is false)then
  raise exception 'RP403: A current signed-in account is required to edit photos';end if;
 if exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then
  raise exception 'RP409: This account is being deleted';end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP404: Property not found';end if;
 perform 1 from public.listings where id=p_listing and org_id=p_org and deleted_at is null for update;
 if not found then raise exception 'RP404: Property not found';end if;
 perform 1 from public.memberships where user_id=p_actor and org_id=p_org and role in('owner','admin','agent')for share;
 if not found then raise exception 'RP403: Your role does not permit editing photos';end if;
end$$;
revoke all on function public.studio_photo_authority(uuid,uuid,uuid)from public,anon,authenticated,service_role;

create or replace function public.studio_photo_asset_key(p_asset uuid,p_org uuid,p_listing uuid)
returns text language plpgsql stable security definer set search_path='' as $$
declare a public.capture_assets;prefix text:='renders/'||p_org::text||'/'||p_listing::text||'/';
begin
 select * into a from public.capture_assets where id=p_asset and listing_id=p_listing;
 if not found or a.kind<>'photo'or a.bucket<>'renders'or a.uploaded is distinct from true
  or a.storage_key is null or left(a.storage_key,length(prefix))<>prefix or length(a.storage_key)not between length(prefix)+1 and 1023
  or position('..'in a.storage_key)>0 or position('/contact-'in a.storage_key)>0
  or a.storage_key ~ '[?#%\\]'or a.storage_key ~ '[[:cntrl:]]'then
  raise exception 'RP400: Choose a completed photo belonging to this property';end if;
 return a.storage_key;
end$$;
revoke all on function public.studio_photo_asset_key(uuid,uuid,uuid)from public,anon,authenticated,service_role;

create or replace function public.studio_attach_photo(
 p_actor uuid,p_org uuid,p_listing uuid,p_asset uuid,p_caption text,p_provenance uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare key text;original text;disclosure text;mp public.media_provenance;prior public.photos;result public.photos;staged boolean:=false;
begin
 perform public.studio_photo_authority(p_actor,p_org,p_listing);
 if p_caption is null or length(p_caption)>500 then raise exception 'RP400: Use a caption of 500 characters or fewer';end if;
 key:=public.studio_photo_asset_key(p_asset,p_org,p_listing);
 select * into mp from public.media_provenance where org_id=p_org and listing_id=p_listing and altered_key=key
  and(p_provenance is null or id=p_provenance)order by created_at desc,id limit 1 for share;
 if p_provenance is not null and not found then raise exception 'RP400: Attach this photo to its disclosure first';end if;
 if mp.id is not null then
  staged:=true;original:=mp.original_key;disclosure:=left(btrim(mp.disclosure),1000);
  if original is null or original=key or disclosure is null or disclosure=''or
   not exists(select 1 from public.capture_assets a where a.listing_id=p_listing and a.storage_key=original
    and public.studio_photo_asset_key(a.id,p_org,p_listing)=original)then
   raise exception 'RP400: Upload the untouched original before publishing this altered photo';end if;
 else original:=key;end if;
 select * into prior from public.photos where id=p_asset for update;
 if found then
  if prior.listing_id<>p_listing or prior.original_key is distinct from original or
   prior.enhanced_key is distinct from(case when staged then key else null end)or prior.is_staged is distinct from staged then
   raise exception 'RP409: The saved photo changed. Refresh the gallery';end if;
  return jsonb_build_object('ok',true,'created',false,'photo',to_jsonb(prior));
 end if;
 insert into public.photos(id,listing_id,original_key,enhanced_key,is_staged,caption,sort)
 values(p_asset,p_listing,original,case when staged then key else null end,staged,
  case when staged then case when btrim(p_caption)=''then disclosure else btrim(p_caption)||' · '||disclosure end else nullif(btrim(p_caption),'')end,0)
 returning * into result;
 return jsonb_build_object('ok',true,'created',true,'photo',to_jsonb(result));
end$$;

create or replace function public.studio_photo_caption(
 p_actor uuid,p_org uuid,p_listing uuid,p_photo uuid,p_expected text,p_caption text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare photo public.photos;key text;disclosure text;label text;desired text;staged boolean;
begin
 perform public.studio_photo_authority(p_actor,p_org,p_listing);
 if p_caption is null or length(p_caption)>2000 or length(p_expected)>4000 then
  raise exception 'RP400: Use a caption of 500 characters or fewer, excluding its disclosure';end if;
 select * into photo from public.photos where id=p_photo and listing_id=p_listing for update;
 if not found then raise exception 'RP404: Gallery photo not found';end if;
 key:=coalesce(nullif(photo.enhanced_key,''),photo.original_key);
 if key is null or left(key,length('renders/'||p_org::text||'/'||p_listing::text||'/'))<>'renders/'||p_org::text||'/'||p_listing::text||'/'
  or length(key)>1023 or position('..'in key)>0 or key ~ '[?#%\\]'or key ~ '[[:cntrl:]]'then
  raise exception 'RP400: Choose a published gallery photo';end if;
 select left(btrim(mp.disclosure),1000)into disclosure from public.media_provenance mp
  where mp.org_id=p_org and mp.listing_id=p_listing and mp.altered_key=key order by mp.created_at desc,mp.id limit 1;
 staged:=coalesce(photo.is_staged,false)or nullif(photo.enhanced_key,'')is not null or nullif(disclosure,'')is not null;
 if staged and nullif(disclosure,'')is null then disclosure:='Virtually staged / AI-altered photo';end if;
 label:=btrim(p_caption);
 if disclosure is not null and right(label,length(disclosure))=disclosure then
  label:=btrim(left(label,length(label)-length(disclosure)));label:=btrim(regexp_replace(label,'·\s*$',''));
 end if;
 if length(label)>500 then raise exception 'RP400: Use a caption of 500 characters or fewer, excluding its disclosure';end if;
 desired:=case when disclosure is not null then case when label=''then disclosure else label||' · '||disclosure end else nullif(label,'')end;
 if photo.caption is distinct from p_expected and photo.caption is distinct from desired then
  raise exception 'RP409: This caption changed on another device. Refresh before saving again';end if;
 update public.photos set caption=desired,is_staged=staged where id=p_photo returning * into photo;
 return jsonb_build_object('ok',true,'photo',to_jsonb(photo));
end$$;

create or replace function public.studio_gallery_update_v2(
 p_actor uuid,p_org_id uuid,p_listing_id uuid,p_action text,p_photo_id uuid default null,
 p_expected jsonb default null,p_value jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare current_key text;chosen_key text;current_order jsonb;next_ids uuid[];
begin
 perform public.studio_photo_authority(p_actor,p_org_id,p_listing_id);
 if p_action is null or p_action not in('cover','reorder')then raise exception 'RP400: Invalid gallery action';end if;
 select main_photo_key into current_key from public.listings where id=p_listing_id and org_id=p_org_id;
 perform 1 from public.photos where listing_id=p_listing_id order by id for update;
 if p_action='cover'then
  if jsonb_typeof(coalesce(p_expected,'null'::jsonb))not in('null','string')then raise exception 'RP400: Cover reference is required';end if;
  select coalesce(nullif(enhanced_key,''),original_key)into chosen_key from public.photos where id=p_photo_id and listing_id=p_listing_id;
  if not found then raise exception 'RP404: Gallery photo not found';end if;
  if chosen_key is null or left(chosen_key,length('renders/'||p_org_id::text||'/'||p_listing_id::text||'/'))<>'renders/'||p_org_id::text||'/'||p_listing_id::text||'/'
   or length(chosen_key)>1023 or position('..'in chosen_key)>0 or chosen_key ~ '[?#%\\]'or chosen_key ~ '[[:cntrl:]]'then
   raise exception 'RP400: Choose a published gallery photo for the cover';end if;
  if coalesce(to_jsonb(current_key),'null'::jsonb)is distinct from coalesce(p_expected,'null'::jsonb)and current_key is distinct from chosen_key then
   raise exception 'RP409: The cover changed on another device. Refresh before choosing again';end if;
  update public.photos set is_main=(id=p_photo_id)where listing_id=p_listing_id and is_main is distinct from(id=p_photo_id);
  update public.listings set main_photo_key=chosen_key where id=p_listing_id and org_id=p_org_id;
  return jsonb_build_object('ok',true,'photo_id',p_photo_id,'main_photo_key',chosen_key);
 end if;
 if jsonb_typeof(p_expected)is distinct from 'array'or jsonb_typeof(p_value)is distinct from 'array'then raise exception 'RP400: Gallery order is required';end if;
 if jsonb_array_length(p_expected)not between 1 and 500 or jsonb_array_length(p_value)<>jsonb_array_length(p_expected)
  or exists(select 1 from jsonb_array_elements(p_expected||p_value)x where jsonb_typeof(x)is distinct from 'string'or(x#>>'{}')!~'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')then
  raise exception 'RP400: Choose a complete gallery of up to 500 photos';end if;
 select array_agg(value::uuid order by n)into next_ids from jsonb_array_elements_text(p_value)with ordinality x(value,n);
 if cardinality(next_ids)<>(select count(distinct id)from unnest(next_ids)id)
  or(select count(distinct value)from jsonb_array_elements_text(p_expected))<>jsonb_array_length(p_expected)
  or not p_expected @> p_value or not p_value @> p_expected then raise exception 'RP400: Gallery order must contain each photo exactly once';end if;
 select coalesce(jsonb_agg(id order by sort,id),'[]'::jsonb)into current_order from public.photos where listing_id=p_listing_id;
 if current_order=p_value then return jsonb_build_object('ok',true,'photo_ids',p_value);end if;
 if current_order is distinct from p_expected then raise exception 'RP409: The gallery changed on another device. Refresh before reordering';end if;
 update public.photos p set sort=(x.n-1)::smallint from unnest(next_ids)with ordinality x(id,n)where p.id=x.id and p.listing_id=p_listing_id;
 return jsonb_build_object('ok',true,'photo_ids',p_value);
end$$;
revoke all on function public.studio_attach_photo(uuid,uuid,uuid,uuid,text,uuid),
 public.studio_photo_caption(uuid,uuid,uuid,uuid,text,text),
 public.studio_gallery_update_v2(uuid,uuid,uuid,text,uuid,jsonb,jsonb)from public,anon,authenticated;
grant execute on function public.studio_attach_photo(uuid,uuid,uuid,uuid,text,uuid),
 public.studio_photo_caption(uuid,uuid,uuid,uuid,text,text),
 public.studio_gallery_update_v2(uuid,uuid,uuid,text,uuid,jsonb,jsonb)to service_role;
commit;
