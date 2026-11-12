-- Customer-credit Photo Motion quote foundation. This migration is deliberately
-- dormant: no existing video, allowance, supplier reservation or retail catalog
-- is redirected by installing it. A later verified admission/terminal migration
-- must explicitly replace the activation block below before it may be enabled.
begin;

insert into public.app_config(key,value) values(
  'credit_photo_motion',
  '{"enabled":false,"revision":"photo-motion-quoted-v1","cents_per_credit":5,"max_quote_cents":100,"activation_ready":false}'::jsonb)
on conflict(key) do nothing;

create or replace function public.credit_photo_motion_credits_for_cents(
  p_maximum_cents numeric
) returns integer language plpgsql immutable security definer set search_path='' as $$
begin
  if p_maximum_cents is null or
     p_maximum_cents::text in('NaN','Infinity','-Infinity') or
     p_maximum_cents<=0 or p_maximum_cents>100 or
     p_maximum_cents<>round(p_maximum_cents,4) then
    raise exception 'RP402: Photo Motion supplier quote exceeds the approved credit range';end if;
  return ceil(p_maximum_cents/5)::integer;
end$$;
revoke all on function public.credit_photo_motion_credits_for_cents(numeric)
  from public,anon,authenticated;
grant execute on function public.credit_photo_motion_credits_for_cents(numeric)
  to service_role;

create or replace function public.credit_photo_motion_quote(
  p_actor uuid,p_manifest jsonb,p_environment text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare q jsonb; cents numeric; credits integer; policy jsonb;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege; end if;
  if p_environment not in('Production','Sandbox') or p_manifest is null then
    raise exception 'RP400: A saved Apple environment and video recipe are required';end if;
  select value into policy from public.app_config where key='credit_photo_motion';
  if policy->>'revision' is distinct from 'photo-motion-quoted-v1' or
     policy->>'cents_per_credit' is distinct from '5' or
     policy->>'max_quote_cents' is distinct from '100' then
    raise exception 'RP503: Photo Motion credit tariff needs review';end if;
  q:=public.property_video_photo_motion_quote(p_actor,p_manifest);
  if not coalesce(q->>'quality_profile' in
      ('photo-motion-v2-cfr24','photo-motion-v2-opening-cfr24'),false) or
     q->>'tariff_version' is distinct from 'container-standard3-20261021' or
     q->>'rate_evidence_sha256' is distinct from
       '8b8db0d3d1925f1ce48a96a944bba5c66b4e0a3d8561ebba9c9c3add8460588a' or
     q->>'generation_cents' is distinct from '0' then
    raise exception 'RP503: Photo Motion cost model changed before credit pricing';end if;
  cents:=(q->>'estimated_cents')::numeric;
  credits:=public.credit_photo_motion_credits_for_cents(cents);
  return jsonb_build_object(
    'operation','video.photo_motion','tariff_version','photo-motion-quoted-v1',
    'environment',p_environment,'credits',credits,
    'maximum_supplier_cents',cents,'quote_sha256',
      encode(sha256(convert_to(q::text,'UTF8')),'hex'),
    'manifest_sha256',encode(sha256(convert_to(p_manifest::text,'UTF8')),'hex'),
    'active',policy->'enabled'='true'::jsonb and
      policy->'activation_ready'='true'::jsonb);
end$$;
revoke all on function public.credit_photo_motion_quote(uuid,jsonb,text)
  from public,anon,authenticated;
grant execute on function public.credit_photo_motion_quote(uuid,jsonb,text)
  to service_role;

-- A catalog switch cannot activate an incomplete credit-video path. This
-- update guard is removed only by the later migration which installs atomic
-- admission, partial-ledger matching, all terminal outcomes and a reconciler.
create or replace function public.credit_photo_motion_activation_guard()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.key='credit_photo_motion' and new.value->'enabled'='true'::jsonb then
    raise exception 'RP409: Photo Motion credit terminal accounting is not installed';end if;
  return new;
end$$;
revoke all on function public.credit_photo_motion_activation_guard()
  from public,anon,authenticated;
create trigger credit_photo_motion_activation_guard before update
  on public.app_config for each row
  when (new.key='credit_photo_motion')
  execute function public.credit_photo_motion_activation_guard();
commit;
