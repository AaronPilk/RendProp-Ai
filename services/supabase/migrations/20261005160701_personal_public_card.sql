-- CLI-generated; source only. A reviewed personal card belongs to an account,
-- never to the selected team. NULL means no explicit card has been saved.
alter table public.profiles add column if not exists public_card jsonb;
alter table public.profiles drop constraint if exists profiles_public_card_object;
alter table public.profiles add constraint profiles_public_card_object
 check(public_card is null or (jsonb_typeof(public_card)='object' and octet_length(public_card::text)<=8192));
revoke update(public_card) on public.profiles from public,anon,authenticated;

create or replace function public.personal_card_receipt(p_actor uuid,p_card jsonb)
returns jsonb language sql immutable security invoker set search_path='' as $$
 select jsonb_build_object('user_id',p_actor,'space_type',p_card->>'space_type','public_card',p_card-'space_type');
$$;

create or replace function public.read_personal_public_card(p_actor uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare p public.profiles;
begin
 perform public.upload_service_only();
 select * into p from public.profiles where id=p_actor for share;
 if not found or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed') then
  raise exception 'RP403: account is unavailable'; end if;
 return public.personal_card_receipt(p_actor,p.public_card);
end $$;

create or replace function public.merge_personal_public_card(p_actor uuid,p_changes jsonb,p_expected jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare p public.profiles; current_card jsonb; desired jsonb; k text; v jsonb; e jsonb; s text; lim integer;
begin
 perform public.upload_service_only();
 select * into p from public.profiles where id=p_actor for update;
 if not found or exists(select 1 from public.deletion_requests where user_id=p_actor and status<>'completed') then
  raise exception 'RP403: account is unavailable'; end if;
 if p_changes is null or jsonb_typeof(p_changes)<>'object' or p_expected is null or jsonb_typeof(p_expected)<>'object'
  or p_changes='{}'::jsonb or octet_length(p_changes::text)>8192 or octet_length(p_expected::text)>16384
  or (select array_agg(key order by key)from jsonb_object_keys(p_changes)key) is distinct from (select array_agg(key order by key)from jsonb_object_keys(p_expected)key)
 then raise exception 'RP400: explicit personal card changes and exact saved values are required';end if;
 current_card:=coalesce(p.public_card,'{}'); desired:=current_card;
 for k,v in select * from jsonb_each(p_changes) loop
  lim:=case k when 'name' then 120 when 'title' then 120 when 'brokerage' then 160 when 'phone' then 80 when 'email' then 254
   when 'website' then 2048 when 'instagram' then 500 when 'linkedin' then 500 when 'tiktok' then 500 when 'space_type' then 32 else null end;
  if lim is null or jsonb_typeof(v) not in('string','null') then raise exception 'RP400: invalid personal card field';end if;
  if v<>'null'::jsonb then
   s:=v#>>'{}';
   if length(s)>lim or s~'[[:cntrl:]]' or (k='name' and position('@'in s)>0)
    or (k='space_type' and s not in('real_estate','venue','restaurant','retail','fitness','other'))
    or (k='email' and s<>'' and s!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')
    or (k in('website','instagram','linkedin','tiktok') and s<>'' and (s!~'^https://[^/[:space:]@?#\\]+([/?#]|$)' or s~'[[:space:]\\]'))
   then raise exception 'RP400: invalid personal card value; links must use https';end if;
   desired:=jsonb_set(desired,array[k],v,true);
  else desired:=desired-k;end if;
  e:=p_expected->k;
  if jsonb_typeof(e) is distinct from 'object' or jsonb_typeof(e->'present') is distinct from 'boolean'
   or ((e->>'present')::boolean and ((select count(*)from jsonb_object_keys(e))<>2 or jsonb_typeof(e->'value') is distinct from 'string'))
   or (not (e->>'present')::boolean and (select count(*)from jsonb_object_keys(e))<>1)
  then raise exception 'RP400: invalid saved personal card value';end if;
 end loop;
 -- A lost matching receipt never rolls back a newer unrelated field.
 if p.public_card is not null and desired=current_card then return public.personal_card_receipt(p_actor,current_card);end if;
 for k,e in select * from jsonb_each(p_expected) loop
  if (current_card?k) is distinct from (e->>'present')::boolean or
   ((e->>'present')::boolean and current_card->k is distinct from e->'value') then
   raise exception 'RP409: your personal card changed; reload before saving';end if;
 end loop;
 update public.profiles set public_card=desired where id=p_actor;
 return public.personal_card_receipt(p_actor,desired);
end $$;

-- Public tours use only the listing's current member. A team join cannot make
-- another person's account card inherit the inviter's contact information.
create or replace function public.public_listing_agent_identity(p_listing uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare l public.listings; p public.profiles; o public.orgs; member_role text; sole boolean; business jsonb; legacy jsonb; portrait jsonb;
begin
 perform public.upload_service_only();
 select * into l from public.listings where id=p_listing and deleted_at is null;
 if not found then raise exception 'RP404: listing is unavailable';end if;
 select * into p from public.profiles where id=l.agent_id for share;
 if not found then return jsonb_build_object('personal_card',null,'profile_name',null,'legacy_owned_single_member',false);end if;
 select * into o from public.orgs where id=l.org_id and deleted_at is null for share;
 if not found then raise exception 'RP404: listing workspace is unavailable';end if;
 perform 1 from public.listings where id=p_listing and org_id=o.id and agent_id=p.id and deleted_at is null for share;
 if not found then raise exception 'RP409: listing identity changed';end if;
 business:=jsonb_strip_nulls(jsonb_build_object('brokerage',o.brand_kit->'brokerage','accent',o.brand_kit->'accent','business_logo_url',
  (select to_jsonb(public_url)from public.org_brand_assets where org_id=o.id and state='published' and public_url=o.brand_kit->>'business_logo_url')));
 select role into member_role from public.memberships where org_id=o.id and user_id=p.id for share;
 if not found or exists(select 1 from public.deletion_requests where user_id=p.id and status<>'completed') then
  return jsonb_build_object('personal_card',null,'profile_name',null,'legacy_owned_single_member',false,'org_business',business,'org_handle',o.handle);end if;
 sole:=member_role='owner' and p.public_card is null and (select count(*)from public.memberships where org_id=o.id)=1;
 -- Retain only a proved own uploaded portrait on this property. Edge also
 -- compares the URL to its configured public object origin before exposing it.
 if member_role='owner' and (select count(*)from public.memberships where org_id=o.id)=1 then
  select jsonb_build_object('asset_id',a.id,'storage_key',a.storage_key,'url',v.url)into portrait
   from public.capture_assets a cross join lateral(values(o.brand_kit->>'headshot_url'),(o.brand_kit->>'avatar_url'))v(url)
   where a.listing_id=l.id and a.kind='photo' and a.bucket='renders' and a.uploaded is true
    and a.storage_key like 'renders/'||o.id||'/'||l.id||'/%' and a.storage_key!~'[?#[:cntrl:]]'
    and v.url~'^https://[^/[:space:]@?#\\]+/' and v.url!~'[?#[:space:]\\]' and right(v.url,length(a.storage_key))=a.storage_key
    and public.studio_presenter_media_access(a.id) and public.studio_presenter_key_access(l.id,a.storage_key)
   order by a.created_at,a.id limit 1;
 end if;
 select coalesce(jsonb_object_agg(key,value),'{}')into legacy from jsonb_each(o.brand_kit)where sole and key in('name','title','brokerage','phone','email','website','instagram','linkedin','tiktok','accent');
 return jsonb_build_object('personal_card',p.public_card-'space_type','profile_name',p.name,'legacy_owned_single_member',sole,'org_business',business,'org_handle',o.handle,'legacy_brand',legacy,'legacy_portrait',portrait);
end $$;

revoke all on function public.personal_card_receipt(uuid,jsonb),public.read_personal_public_card(uuid),public.merge_personal_public_card(uuid,jsonb,jsonb),public.public_listing_agent_identity(uuid) from public,anon,authenticated;
grant execute on function public.personal_card_receipt(uuid,jsonb),public.read_personal_public_card(uuid),public.merge_personal_public_card(uuid,jsonb,jsonb),public.public_listing_agent_identity(uuid) to service_role;
comment on column public.profiles.public_card is 'Explicitly reviewed account-owned public contact fields and hosted space_type. Never copied from workspace branding or private sign-in email.';
