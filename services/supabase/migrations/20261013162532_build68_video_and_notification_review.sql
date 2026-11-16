-- Private content identities retain server-owned billing receipts.
begin;
create or replace function public.app_video_cost_reserve_v2(
 p_actor uuid,p_org uuid,p_key text,p_feature text,p_provider text,p_model text,p_input_sha256 text,
 p_hold_cents numeric,p_units numeric,p_unit_cost_cents numeric,p_meta jsonb,
 p_monthly_window_start timestamptz,p_burst_window_start timestamptz,p_listing uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;monthly text;burst text;billing uuid;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 -- The existing writer retains every priced admission, authority, immutable
 -- key, provider, monthly budget and uncertain-dispatch guard.
 r:=public.app_video_cost_reserve(p_actor,p_org,p_key,p_feature,p_provider,p_model,p_input_sha256,p_hold_cents,p_units,p_unit_cost_cents,p_meta);
 if p_listing is not null and not exists(select 1 from public.listings where id=p_listing and org_id=p_org and deleted_at is null)then raise exception 'RP403: Video property is unavailable in this workspace';end if;
 billing:=public.library_actor_billing_org(p_actor,p_org);
 monthly:=(case p_feature when 'drone_render'then 'dronemo'when 'aerial'then 'aerialmo'else 'reelmo'end)||':'||billing::text;burst:='aivideo:'||billing::text;
 if p_monthly_window_start is null or p_burst_window_start is null or not exists(select 1 from public.rate_limits where key=monthly and window_start=p_monthly_window_start and window_seconds=2592000 and count>0)
  or not exists(select 1 from public.rate_limits where key=burst and window_start=p_burst_window_start and window_seconds=300 and count>0)then raise exception 'RP409: Original video quota charge could not be confirmed';end if;
 insert into public.app_video_allowance_receipts(reservation_id,listing_id,monthly_key,monthly_window_start,burst_key,burst_window_start)
 values((r->>'id')::uuid,p_listing,monthly,p_monthly_window_start,burst,p_burst_window_start);
 return r;
end$$;
revoke all on function public.app_video_cost_reserve_v2(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb,timestamptz,timestamptz,uuid)from public,anon,authenticated;
grant execute on function public.app_video_cost_reserve_v2(uuid,uuid,text,text,text,text,text,numeric,numeric,numeric,jsonb,timestamptz,timestamptz,uuid)to service_role;

-- The delegated Team owner retains the same current private-library authority
-- when restoring an original allowance; supplier spend remains settled.
create or replace function public.app_video_refund_drift(p_actor uuid,p_org uuid,p_request text,p_feature text)
returns jsonb language plpgsql security definer set search_path=''as $$
declare r public.app_video_cost_reservations;a public.app_video_allowance_receipts;refunded boolean;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 perform 1 from public.orgs where id=p_org and deleted_at is null for update;
 if not found or not exists(select 1 from auth.users where id=p_actor and is_anonymous is false)
  or not public.library_financial_actor(p_actor,p_org)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception 'RP403: Current video workspace authority is required';end if;
 select * into r from public.app_video_cost_reservations where org_id=p_org and actor_id=p_actor and provider_request_id=p_request and feature=p_feature and settled_at is not null and released_at is null order by created_at limit 1 for update;
 if not found then return jsonb_build_object('refunded',false,'reason','No owned charged clip receipt was found');end if;
 select * into a from public.app_video_allowance_receipts where reservation_id=r.id for update;
 if not found then return jsonb_build_object('refunded',false,'reason','This older clip has no original quota receipt');end if;
 if a.drift_refunded_at is not null then return jsonb_build_object('refunded',false,'reason','This clip was already refunded');end if;
 if not public.bump_rate('aidriftrefmo:'||p_org::text,2592000,20,1)then return jsonb_build_object('refunded',false,'reason','The monthly clip refund limit was reached');end if;
 refunded:=public.refund_rate_receipt(a.monthly_key,2592000,a.monthly_window_start,1);
 if refunded then perform public.refund_rate_receipt(a.burst_key,300,a.burst_window_start,1);end if;
 update public.app_video_allowance_receipts set drift_refunded_at=now()where reservation_id=r.id;
 return jsonb_build_object('refunded',refunded,'reason',case when refunded then 'The rejected clip allowance was restored'else 'The original allowance window has ended'end);
end$$;
revoke all on function public.app_video_refund_drift(uuid,uuid,text,text)from public,anon,authenticated;
grant execute on function public.app_video_refund_drift(uuid,uuid,text,text)to service_role;

-- Every completed HOLD permits a fresh manual, paid check. An abandoned
-- execution claim can reopen; its old serving liability remains untouched.
create table if not exists public.app_video_drift_checks(
 reservation_id uuid primary key references public.app_video_cost_reservations(id),
 actor_id uuid not null,org_id uuid not null,listing_id uuid not null,
 source_sha256 text not null check(source_sha256 ~ '^[0-9a-f]{32}$'),
 check_id uuid not null unique default gen_random_uuid(),
 ordinal integer not null default 1 check(ordinal > 0),
 state text not null default 'running' check(state in('running','hold','accept','retry','refuse')),
 result jsonb,created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
alter table public.app_video_drift_checks enable row level security;
revoke all on public.app_video_drift_checks from public,anon,authenticated,service_role;
grant select on public.app_video_drift_checks to service_role;

create or replace function public.app_video_drift_check_begin(p_actor uuid,p_org uuid,p_request text,p_feature text,p_source_sha256 text,p_listing uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.app_video_cost_reservations;a public.app_video_allowance_receipts;c public.app_video_drift_checks;paid public.cost_ledger;matches integer;op public.serving_operations;saved_result jsonb;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_source_sha256 is null or p_source_sha256 !~ '^[0-9a-f]{32}$' or p_request is null or length(p_request)not between 1 and 256 or p_feature is null or p_feature not in('reel','aerial')then raise exception 'RP400: Invalid saved quality check';end if;
 if not exists(select 1 from auth.users where id=p_actor and not is_anonymous)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))
  or not public.library_financial_actor(p_actor,p_org)then raise exception 'RP403: Current video library authority is required';end if;
 perform pg_advisory_xact_lock(hashtextextended('video_drift_check:'||p_org::text||':'||p_request,42));
 select count(*)into matches from public.app_video_cost_reservations where org_id=p_org and actor_id=p_actor and provider_request_id=p_request and feature=p_feature;
 if matches<>1 then raise exception 'RP404: This saved clip is unavailable for this account';end if;
 select *into r from public.app_video_cost_reservations where org_id=p_org and actor_id=p_actor and provider_request_id=p_request and feature=p_feature for update;
 select *into a from public.app_video_allowance_receipts where reservation_id=r.id;
 if r.released_at is not null or r.cost_ledger_id is null or r.settled_at is null
  or r.meta->>'task' is distinct from(case p_feature when 'aerial'then 'video.aerial'else 'video.reel_clip'end)
  or a.listing_id is null or(p_listing is not null and p_listing<>a.listing_id)
  or not exists(select 1 from public.listings where id=a.listing_id and org_id=p_org and deleted_at is null)
  or not public.listing_content_access(p_actor,a.listing_id,true)then raise exception 'RP404: This saved clip is unavailable for this listing';end if;
 select *into paid from public.cost_ledger where id=r.cost_ledger_id;
 if not found or paid.org_id<>r.org_id or paid.billing_org_id<>r.billing_org_id or paid.feature<>r.feature
  or paid.provider<>r.provider or paid.model<>r.model or paid.total_cents<=0
  or paid.meta->>'app_video_reservation_id' is distinct from r.id::text
  or paid.meta->>'request_id' is distinct from r.provider_request_id
  or paid.meta->>'billing_org_id' is distinct from r.org_id::text
  or paid.meta->>'request_key' is distinct from r.idempotency_key
  or paid.meta->>'stage' is distinct from r.feature then raise exception 'RP404: This saved clip paid receipt could not be verified';end if;
 select *into c from public.app_video_drift_checks where reservation_id=r.id for update;
 if found then
  if c.actor_id<>p_actor or c.org_id<>p_org or c.listing_id<>a.listing_id or c.source_sha256<>p_source_sha256 then raise exception 'RP409: The saved quality check does not match this clip and source photo';end if;
  if c.state in('accept','retry','refuse')then return jsonb_build_object('id',c.check_id,'replay',true,'result',c.result);end if;
  if c.state='running'then
   select *into op from public.serving_operations where actor_id=p_actor and org_id=p_org and request_key='drift-check:'||c.check_id;
   select result into saved_result from public.serving_operation_results where actor_id=p_actor and org_id=p_org and request_key='drift-check:'||c.check_id;
   if op.state='completed'and saved_result#>>'{drift,action}'in('accept','retry','refuse')then
    update public.app_video_drift_checks set state=saved_result#>>'{drift,action}',result=saved_result,updated_at=now()where reservation_id=r.id;
    return jsonb_build_object('id',c.check_id,'replay',true,'result',saved_result);
   end if;
   -- A completed HOLD or a confirmed pre-dispatch abort may reopen now. An
   -- abandoned execution claim may reopen after eight minutes: longer than
   -- Supabase's documented 400-second maximum worker life. This never releases
   -- or expires ANY serving_cost_reservation, including uncertain liabilities.
   if not coalesce(((op.state='completed'and saved_result#>>'{drift,action}'='hold')
    or(op.state='not_dispatched'and not exists(select 1 from public.serving_cost_reservations where actor_id=p_actor and org_id=p_org and request_key='drift-check:'||c.check_id))
    or c.updated_at<clock_timestamp()-interval '8 minutes'),false)then
    raise exception 'RP409: This quality check is already running. Recover this saved clip shortly';
   end if;
  end if;
  update public.app_video_drift_checks set check_id=gen_random_uuid(),ordinal=ordinal+1,state='running',result=null,updated_at=now()where reservation_id=r.id returning *into c;
 else
  insert into public.app_video_drift_checks(reservation_id,actor_id,org_id,listing_id,source_sha256)
   values(r.id,p_actor,p_org,a.listing_id,p_source_sha256)returning *into c;
 end if;
 return jsonb_build_object('id',c.check_id,'replay',false,'ordinal',c.ordinal);
end$$;

create or replace function public.app_video_drift_check_finish(p_actor uuid,p_org uuid,p_check uuid,p_action text,p_result jsonb)
returns boolean language plpgsql security definer set search_path='' as $$
declare c public.app_video_drift_checks;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
 if p_action is null or p_action not in('hold','accept','retry','refuse')
  or(p_result is not null and(jsonb_typeof(p_result)<>'object' or octet_length(p_result::text)>16384
   or p_result#>>'{drift,action}' is distinct from p_action
   or p_result#>>'{drift,publishable}' is distinct from(case when p_action='accept'then 'true'else 'false'end)))
  or(p_action<>'hold'and p_result is null)then raise exception 'RP400: Invalid quality check result';end if;
 select *into c from public.app_video_drift_checks where check_id=p_check and actor_id=p_actor and org_id=p_org for update;
 if not found then raise exception 'RP404: This quality check is unavailable for this account';end if;
 if not exists(select 1 from auth.users where id=p_actor and not is_anonymous)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))
  or not public.library_financial_actor(p_actor,p_org)or not public.listing_content_access(p_actor,c.listing_id,true)then raise exception 'RP403: Current video library authority is required';end if;
 if c.state<>'running'then
  if c.state=p_action and c.result is not distinct from p_result then return true;end if;
  raise exception 'RP409: This quality check result is immutable';
 end if;
 update public.app_video_drift_checks set state=p_action,result=p_result,updated_at=now()where reservation_id=c.reservation_id;
 return true;
end$$;
revoke all on function public.app_video_drift_check_begin(uuid,uuid,text,text,text,uuid),public.app_video_drift_check_finish(uuid,uuid,uuid,text,jsonb)from public,anon,authenticated;
grant execute on function public.app_video_drift_check_begin(uuid,uuid,text,text,text,uuid),public.app_video_drift_check_finish(uuid,uuid,uuid,text,jsonb)to service_role;

-- Transactional push permission is not marketing consent.
do $$declare body text;old text;patched text;begin
 body:=pg_get_functiondef('public.notification_enqueue(uuid,uuid,text,jsonb,text,timestamptz)'::regprocedure);
 old:='if v_channel = ''email'' and v_cat in (''first_tour_nudge'',''free_week_ending'') then';
 patched:='if v_cat in (''first_tour_nudge'',''free_week_ending'') then';
 if position(patched in body)=0 then
  if position(old in body)=0 or(length(body)-length(replace(body,old,'')))/length(old)<>1 then raise exception 'RP409: unexpected notification producer body';end if;
  body:=replace(body,old,patched);
  body:=replace(body,'''promotional_email_disabled''','case when v_channel = ''email'' then ''promotional_email_disabled'' else ''promotional_push_disabled'' end');
  execute body;
 end if;
end$$;
update public.notification_outbox set state='skipped',last_error='Promotional lifecycle messages are disabled.',claimed_at=null
 where category in('first_tour_nudge','free_week_ending')and state in('queued','sending');

-- Auth must verify an allowlisted address before it grants admin authority.
do $$declare body text;old text;patched text;begin
 body:=pg_get_functiondef('public.handle_new_user()'::regprocedure);
 old:='if v_email <> '''' then';
 patched:='if v_email <> '''' and new.email_confirmed_at is not null and not new.is_anonymous then';
 if position(patched in body)=0 then
  if position(old in body)=0 or(length(body)-length(replace(body,old,'')))/length(old)<>1 then raise exception 'RP409: unexpected account enrollment body';end if;
  execute replace(body,old,patched);
 end if;
end$$;
create or replace function public.promote_verified_allowlisted_user()returns trigger
language plpgsql security definer set search_path=''as $$begin
 if new.email_confirmed_at is null or new.is_anonymous then
  update public.profiles set is_admin=false where id=new.id and is_admin is true;
 elsif new.email_confirmed_at is not null and not new.is_anonymous
  and exists(select 1 from public.admin_allowlist where email=lower(btrim(new.email)))then
  update public.profiles set is_admin=true where id=new.id and is_admin is not true;
 end if;
 return new;
end$$;
drop trigger if exists trg_verified_admin_enrollment on auth.users;
create trigger trg_verified_admin_enrollment after update of email_confirmed_at,email on auth.users
 for each row execute function public.promote_verified_allowlisted_user();
revoke all on function public.promote_verified_allowlisted_user()from public,anon,authenticated,service_role;
-- Existing unverified rows receive no admin authority. Confirmed owners and
-- manually granted, confirmed admins are preserved without inspecting secrets.
update public.profiles p set is_admin=false from auth.users u where p.id=u.id and p.is_admin is true and(u.email_confirmed_at is null or u.is_anonymous);
create or replace function public.is_admin()returns boolean language sql stable security definer set search_path=''as $$
 select exists(select 1 from public.profiles p join auth.users u on u.id=p.id
  where p.id=auth.uid()and p.is_admin is true and u.email_confirmed_at is not null and not u.is_anonymous);
$$;
commit;
