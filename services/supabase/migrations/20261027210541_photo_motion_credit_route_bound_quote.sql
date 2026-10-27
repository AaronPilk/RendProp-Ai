-- Bind the displayed Photo Motion price to the exact actor, operation,
-- canonical billing library and funding environment. The original digest
-- covered only the supplier cost estimate. It could be reused across wallets.
begin;
do $patch$ declare definition text; anchor text; replacement text; begin
  definition:=pg_get_functiondef(
    'public.credit_photo_motion_quote(uuid,jsonb,text)'::regprocedure);
  anchor:='encode(sha256(convert_to(q::text,''UTF8'')),''hex'')';
  replacement:='encode(sha256(convert_to(jsonb_build_object(''supplier_quote'',q,''manifest_sha256'',encode(sha256(convert_to(p_manifest::text,''UTF8'')),''hex''),''actor_id'',p_actor,''billing_org_id'',public.library_actor_billing_org(p_actor,(public.property_video_photo_motion_manifest(p_actor,p_manifest)->>''org_id'')::uuid),''environment'',p_environment,''tariff_version'',''photo-motion-quoted-v1'',''credits'',credits)::text,''UTF8'')),''hex'')';
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed Photo Motion credit quote identity';end if;
  execute replace(definition,anchor,replacement);
end $patch$;
revoke all on function public.credit_photo_motion_quote(uuid,jsonb,text)
  from public,anon,authenticated;
grant execute on function public.credit_photo_motion_quote(uuid,jsonb,text)
  to service_role;

-- Edge's read-only preflight and the actual hold are separate transactions.
-- Recheck the displayed digest after admission takes its operation and wallet
-- locks, before it can allocate credits or enqueue work. A direct legacy call
-- can still replay an existing job, but cannot create a newly funded job.
do $admission$ declare definition text; anchor text; replacement text; begin
  definition:=pg_get_functiondef(
    'public.property_video_job_admit_photo_motion(uuid,jsonb)'::regprocedure);
  anchor:='credit_env:=public.credit_photo_motion_environment(p_actor,org,p_manifest,(q->>''estimated_cents'')::numeric);';
  replacement:=anchor||$added$
 if credit_env is not null then
   if current_setting('rendprop.photo_motion_expected_quote',true) is distinct from
      (public.credit_photo_motion_quote(p_actor,p_manifest,credit_env)->>'quote_sha256') then
     raise exception 'RP409: Photo Motion credit quote changed before admission';end if;
 elsif nullif(current_setting('rendprop.photo_motion_expected_quote',true),'') is not null then
   raise exception 'RP409: Photo Motion credit route changed before admission';
 end if;
$added$;
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 then
    raise exception 'Review changed Photo Motion atomic admission identity';end if;
  execute replace(definition,anchor,replacement);
end $admission$;

create function public.property_video_job_admit_photo_motion_quoted(
  p_actor uuid,p_manifest jsonb,p_quote_sha256 text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare prior text;admitted jsonb;
begin
  if current_setting('role',true) is distinct from 'service_role' or
     (p_quote_sha256 is not null and
       p_quote_sha256 !~ '^[a-f0-9]{64}$') then raise insufficient_privilege;end if;
  prior:=current_setting('rendprop.photo_motion_expected_quote',true);
  perform set_config('rendprop.photo_motion_expected_quote',
    coalesce(p_quote_sha256,''),true);
  admitted:=public.property_video_job_admit_photo_motion(p_actor,p_manifest);
  perform set_config('rendprop.photo_motion_expected_quote',coalesce(prior,''),true);
  return admitted;
end$$;
revoke all on function public.property_video_job_admit_photo_motion_quoted(uuid,jsonb,text)
  from public,anon,authenticated;
grant execute on function public.property_video_job_admit_photo_motion_quoted(uuid,jsonb,text)
  to service_role;
commit;
