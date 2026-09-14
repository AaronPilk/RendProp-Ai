begin;
-- Private successful narration is retained outside capture_assets. Preserve its
-- exact owned key in the existing leased account-deletion snapshot before FK
-- cascades remove that history. Shared workspaces retain their media.
create function public.studio_voice_deletion_targets(p_solo uuid[], p_upload_bucket text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare targets jsonb;
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege using message='service role required';
  end if;
  perform 1 from public.studio_creative_results where org_id=any(p_solo)
    and kind='voice' order by id for update;
  select coalesce(jsonb_agg(distinct jsonb_build_object('bucket',p_upload_bucket,'key',r.storage_key,
    'valid',r.bucket='uploads' and r.storage_key ~
      ('^ai-voice/'||r.org_id::text||'/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]mp3$'))),'[]'::jsonb)
    into targets from public.studio_creative_results r
    where r.org_id=any(p_solo) and r.kind='voice' and r.storage_key is not null;
  return targets;
end;
$$;
revoke all on function public.studio_voice_deletion_targets(uuid[],text) from public,anon,authenticated,service_role;

-- Preserve the deployed transaction, locks, queue leases and escalation rules.
-- Fail closed if its explicit inventory extension point has changed.
do $$
declare definition text; needle text := 'object_targets:=object_targets||spatial_keys;';
begin
  definition:=pg_get_functiondef('public.prepare_account_deletion(uuid,text,text)'::regprocedure);
  if (length(definition)-length(replace(definition,needle,'')))/length(needle) <> 1 then
    raise exception 'Account deletion inventory changed; review before extending it';
  end if;
  execute replace(definition,needle,
    'object_targets:=object_targets||spatial_keys||public.studio_voice_deletion_targets(solo,p_upload_bucket);');
end;
$$;
commit;
