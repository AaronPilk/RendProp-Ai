-- A plan quote must not say a recipe is included after the actual legacy
-- clip/processing allowance has been exhausted. Review reuses the same
-- read-only whole-recipe capacity gate as admission; no hold or job is made.
begin;
do $guard$ begin
  if (select md5(prosrc) from pg_proc where oid=
      'public.credit_photo_motion_review_quote(uuid,jsonb)'::regprocedure)
      is distinct from '0217d1e35317942bd4cb40dccb5e1290' then
    raise exception 'Review changed Photo Motion plan quote predecessor';
  end if;
end $guard$;

create or replace function public.credit_photo_motion_review_quote(
  p_actor uuid,p_manifest jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare checked jsonb; supplier jsonb; route text; quote jsonb;
  billing uuid; wallet jsonb; available integer; credits integer;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege;end if;
  checked:=public.property_video_photo_motion_manifest(p_actor,p_manifest);
  supplier:=public.property_video_photo_motion_quote(p_actor,p_manifest);
  route:=public.credit_photo_motion_environment(p_actor,
    (checked->>'org_id')::uuid,p_manifest,(supplier->>'estimated_cents')::numeric);
  if route is null then
    begin
      perform public.property_video_recipe_capacity(p_actor,
        (p_manifest->>'listing_id')::uuid,
        jsonb_array_length(p_manifest->'sources'),
        (supplier->>'estimated_cents')::numeric);
    exception when others then
      if sqlerrm like 'RP402:%' then
        return jsonb_build_object('mode','plan','active',false,
          'affordable',false);
      end if;
      raise;
    end;
    return jsonb_build_object('mode','plan','active',false);
  end if;
  quote:=public.credit_photo_motion_quote(p_actor,p_manifest,route);
  if quote->'active' is distinct from 'true'::jsonb then
    raise exception 'RP503: Photo Motion credit route changed during review';end if;
  billing:=public.library_actor_billing_org(p_actor,(checked->>'org_id')::uuid);
  wallet:=public.credit_wallet_state(billing,route);
  available:=(wallet->>'total_available')::integer;
  credits:=(quote->>'credits')::integer;
  return jsonb_build_object('mode','credits','active',true,
    'credits',credits,'available_credits',available,
    'affordable',available>=credits,'environment',route,
    'manifest_sha256',quote->>'manifest_sha256',
    'quote_sha256',quote->>'quote_sha256');
end$$;
revoke all on function public.credit_photo_motion_review_quote(uuid,jsonb)
  from public,anon,authenticated;
grant execute on function public.credit_photo_motion_review_quote(uuid,jsonb)
  to service_role;
commit;
