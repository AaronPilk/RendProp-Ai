begin;
-- Prospective hosting access only; nothing here deletes customer content or
-- rewrites legacy funding/plan/QA grants. Cutoffs come from immutable funding.
create index if not exists serving_funding_hosting_deadline on public.serving_funding(org_id,retention_ends_at desc,id) where source in('retail','trial');
create or replace function public.hosting_retention_state(p_org uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare deadline timestamptz;qa boolean;
begin
 if current_setting('role',true)not in('service_role','postgres','supabase_admin')and not(current_setting('role',true)='none'and session_user in('postgres','supabase_admin'))then raise insufficient_privilege using message='service role required';end if;
 if not exists(select 1 from public.orgs where id=p_org and deleted_at is null)then raise exception 'RP404: Workspace unavailable';end if;
 qa:=public.org_has_internal_testing_grant(p_org)or public.org_has_private_internal_testing(p_org);
 -- Refund/revocation does not erase the already promised grace. A renewal can
 -- extend it, while App Review grants never impose a retail retention policy.
 select max(retention_ends_at)into deadline from public.serving_funding where org_id=p_org and source in('retail','trial');
 if qa or deadline is null then return jsonb_build_object('org_id',p_org,'policy','preserved','protected',qa,'retention_ends_at',null,'hosting_available',true);end if;
 return jsonb_build_object('org_id',p_org,'policy','prospective_90_day_grace','protected',false,'retention_ends_at',deadline,'hosting_available',clock_timestamp()<deadline);
end$$;
revoke all on function public.hosting_retention_state(uuid)from public,anon,authenticated;
grant execute on function public.hosting_retention_state(uuid)to service_role;

create or replace function public.queue_hosting_retention_notices()
returns jsonb language plpgsql security definer set search_path='' as $$
declare item record;stage integer;receipt jsonb;queued integer:=0;
begin
 if current_setting('role',true)not in('service_role','postgres','supabase_admin')and not(current_setting('role',true)='none'and session_user in('postgres','supabase_admin'))then raise insufficient_privilege using message='service role required';end if;
 -- Keep the newest deadline; only one stage is due per run, so delayed drains
 -- never emit three notices at once. Existing allowance-alert preferences and
 -- the global mute govern these hosting/service allowance warnings.
 for item in
  with latest as(select distinct on(org_id)id,org_id,retention_ends_at from public.serving_funding where source in('retail','trial')order by org_id,retention_ends_at desc,id)
  select f.id,f.org_id,f.retention_ends_at,m.user_id from latest f
  join public.orgs o on o.id=f.org_id and o.deleted_at is null
  join public.memberships m on m.org_id=f.org_id and m.role in('owner','admin','agent')
  where f.retention_ends_at>clock_timestamp()and f.retention_ends_at<=clock_timestamp()+interval '30 days'
   and not(public.org_has_internal_testing_grant(f.org_id)or public.org_has_private_internal_testing(f.org_id))
   and exists(select 1 from auth.users where id=m.user_id and is_anonymous is false) and not exists(select 1 from public.deletion_requests where user_id=m.user_id and status in('pending','processing'))
  order by f.retention_ends_at,f.org_id,m.user_id limit 500
 loop
  stage:=case when item.retention_ends_at<=clock_timestamp()+interval '1 day'then 1 when item.retention_ends_at<=clock_timestamp()+interval '7 days'then 7 else 30 end;
  receipt:=public.notification_enqueue(item.org_id,item.user_id,'allowance_low',jsonb_build_object(
   'title','Your workspace hosting period is ending',
   'body','Public tours for this workspace stop being hosted on '||to_char(item.retention_ends_at at time zone 'UTC','YYYY-MM-DD')||' UTC. Renew to extend hosting. Download original files from Library and your account JSON from Settings > Account data.',
   'hosting_retention',jsonb_build_object('grant_id',item.id,'deadline',item.retention_ends_at,'stage_days',stage)),
   'hosting-retention:'||item.id::text||':'||stage::text||':'||item.user_id::text,null);
  if receipt->>'state'='queued'then queued:=queued+1;end if;
 end loop;
 return jsonb_build_object('queued',queued,'limit',500);
end$$;
revoke all on function public.queue_hosting_retention_notices()from public,anon,authenticated;
grant execute on function public.queue_hosting_retention_notices()to service_role;

create or replace function public.hosting_retention_notice_current(p_outbox uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare row public.notification_outbox;state jsonb;grant_id uuid;deadline timestamptz;current_grant uuid;valid boolean:=false;
begin
 if current_setting('role',true)<>'service_role'then raise insufficient_privilege using message='service role required';end if;
 select * into row from public.notification_outbox o where o.id=p_outbox and o.state in('queued','sending','failed')for update;
 if not found or not(row.payload?'hosting_retention')then return false;end if;
 begin
  grant_id:=(row.payload->'hosting_retention'->>'grant_id')::uuid;deadline:=(row.payload->'hosting_retention'->>'deadline')::timestamptz;
  state:=public.hosting_retention_state(row.org_id);
  select id into current_grant from public.serving_funding where org_id=row.org_id and source in('retail','trial')order by retention_ends_at desc,id limit 1;
  valid:=row.category='allowance_low'and row.user_id is not null and grant_id=current_grant
   and state->>'policy'='prospective_90_day_grace'and(state->>'hosting_available')::boolean
   and(state->>'retention_ends_at')::timestamptz=deadline
   and exists(select 1 from auth.users where id=row.user_id and is_anonymous is false) and not exists(select 1 from public.deletion_requests where user_id=row.user_id and status in('pending','processing'))
   and exists(select 1 from public.memberships where org_id=row.org_id and user_id=row.user_id and role in('owner','admin','agent'));
 exception when invalid_text_representation or datetime_field_overflow then valid:=false;
 end;
 if valid is not true then update public.notification_outbox set state='expired'where id=p_outbox;return false;end if;
 return true;
end$$;
revoke all on function public.hosting_retention_notice_current(uuid)from public,anon,authenticated;
grant execute on function public.hosting_retention_notice_current(uuid)to service_role;

-- The already scheduled lifecycle tick now queues notices. A replay adds the
-- hook once; a changed upstream function shape fails instead of silently
-- leaving the retention policy without a producer.
do $$declare definition text;needle text:='  v_sweep := notification_sweep();';begin
 definition:=pg_get_functiondef('public.notification_tick()'::regprocedure);
 if position('perform public.queue_hosting_retention_notices();'in definition)=0 then
  if position(needle in definition)=0 then raise exception 'notification_tick changed; review retention integration';end if;
  execute replace(definition,needle,E'  perform public.queue_hosting_retention_notices();\n'||needle);
 end if;
end$$;
commit;
