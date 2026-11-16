-- Hourly operational health check that PAGES the admins — 2026-10-08.
--
-- Why: the reel provider failed 28 times in a row from Sep 7 with the count
-- sitting in provider_health the whole time, and nothing read it. On Oct 6 a
-- deploy refused AI for 38 of 40 workspaces and no row recorded a refusal.
-- This function turns the signals that already exist into push + e-mail
-- rows in the existing notification outbox, once per finding per day, for
-- every admin. It reads only; it never changes product state.
begin;

alter table public.notification_outbox drop constraint if exists notification_outbox_category_check;
alter table public.notification_outbox add constraint notification_outbox_category_check
  check (category in ('lead_received','render_ready','upload_stuck','free_week_ending','allowance_low',
                      'first_tour_nudge','team_invite','client_lead_received','client_recipient_verification','ops_alert'));

create or replace function public.ops_health_findings()returns table(code text,title text,body text,data jsonb)
language plpgsql stable security definer set search_path='' as $$
declare r record;attempts bigint;successes bigint;n bigint;spent numeric;
begin
 -- Read-only; executable by service_role and the cron owner (postgres) only.

 -- 1. A provider/model with a failure streak and no success since (the Seedance class).
 for r in select provider,model,consecutive_failures,last_error_class,last_ok_at,last_fail_at from public.provider_health
   where consecutive_failures>=3 and last_fail_at>now()-interval '7 days'
    and last_fail_at>coalesce(last_ok_at,'-infinity'::timestamptz)
 loop
  code:='provider_dead:'||r.provider||':'||r.model;
  title:='AI provider failing: '||r.provider||' / '||r.model;
  body:=r.consecutive_failures||' failures in a row ('||coalesce(r.last_error_class,'unknown')||'). Last success '
   ||coalesce(to_char(r.last_ok_at at time zone 'UTC','YYYY-MM-DD HH24:MI')||' UTC','never')||'. Check the provider dashboard (balance, lock, key) and run one real generation.';
  data:=jsonb_build_object('provider',r.provider,'model',r.model,'consecutive_failures',r.consecutive_failures,'last_ok_at',r.last_ok_at,'last_fail_at',r.last_fail_at);
  return next;
 end loop;

 -- 2. Video attempts in the last 24h with no settled success.
 select count(*),count(*)filter(where cost_ledger_id is not null) into attempts,successes
  from public.app_video_cost_reservations where created_at>now()-interval '24 hours';
 if attempts>=2 and successes=0 then
  code:='video_no_success_24h';title:='Video generations: '||attempts||' attempts, 0 successes in 24h';
  body:='Reels, aerials or drone renders were attempted '||attempts||' times in the last 24 hours and none settled. Customers are seeing failures.';
  data:=jsonb_build_object('attempts',attempts,'successes',successes);return next;
 end if;

 -- 3. Journaled AI operations (photo/copy/voice/chapters/coach) in 24h with no completion.
 select count(*),count(*)filter(where state='completed') into attempts,successes
  from public.serving_operations where created_at>now()-interval '24 hours';
 if attempts>=3 and successes=0 then
  code:='ai_ops_no_success_24h';title:='AI requests: '||attempts||' started, 0 completed in 24h';
  body:='Photo, copy, voice, chapter or coach requests were started '||attempts||' times in the last 24 hours and none completed. Check the serving mode, provider keys and function logs.';
  data:=jsonb_build_object('attempts',attempts,'completed',successes);return next;
 end if;

 -- 4. Server render jobs stuck longer than 30 minutes.
 select count(*) into n from public.render_jobs where source='worker' and status in('created','queued','claimed','processing') and created_at<now()-interval '30 minutes';
 if n>0 then
  code:='render_jobs_stuck';title:=n||' server render job(s) stuck over 30 minutes';
  body:='Jobs are waiting on the render worker. If no worker is running, customers who chose a server tier are waiting on nothing.';
  data:=jsonb_build_object('stuck',n);return next;
 end if;

 -- 5. Apple notifications still pending after an hour (entitlements not applied).
 select count(*) into n from public.apple_notifications where pending and received_at<now()-interval '1 hour';
 if n>0 then
  code:='apple_notifications_pending';title:=n||' Apple subscription notification(s) pending over 1h';
  body:='Subscription changes from Apple have not been applied. Check the apple-subscriptions function logs and replay pending notifications.';
  data:=jsonb_build_object('pending',n);return next;
 end if;

 -- 6. Notification delivery failing (the alert channel itself).
 select count(*) into n from public.notification_outbox where state='failed' and created_at>now()-interval '24 hours';
 if n>=5 then
  code:='notifications_failing';title:=n||' notifications failed in 24h';
  body:='Push or e-mail delivery is failing. Check APNs/Resend secrets and the notify function logs.';
  data:=jsonb_build_object('failed',n);return next;
 end if;

 -- 7. Funded serving mode with nothing funded (the Oct 6 outage class).
 if public.serving_mode()='funded' and not exists(select 1 from public.serving_funding where revoked_at is null and ends_at>now())
  and (select count(*) from public.orgs where deleted_at is null)>(select count(*) from public.org_internal_testing_grants where revoked_at is null)+1 then
  code:='funded_mode_unfunded';title:='Serving mode is funded but nothing is funded';
  body:='Every workspace without a testing grant is being refused AI generation. Either provision funding or switch app_config.serving_mode back to ceiling.';
  data:='{}'::jsonb;return next;
 end if;

 -- 8. Spend anomalies: more than $50 of provider cost in 24h, or any workspace at 80% of its ceiling.
 select coalesce(sum(total_cents),0) into spent from public.cost_ledger where created_at>now()-interval '24 hours';
 if spent>5000 then
  code:='spend_spike_24h';title:='Provider spend '||to_char(spent/100,'FM999990.00')||' USD in 24h';
  body:='More than $50 of AI provider cost was recorded in the last 24 hours. Check the cost ledger for a runaway workspace or a pricing bug.';
  data:=jsonb_build_object('cents',spent);return next;
 end if;
 for r in select o.id,o.name,public.org_month_spend_cents(o.id) as spent,e.cogs_ceiling_cents as ceiling,e.plan
   from public.orgs o cross join lateral public.org_entitlement(o.id) e
   where o.deleted_at is null and e.cogs_ceiling_cents>0 and e.cogs_ceiling_cents<2147483647
    and public.org_month_spend_cents(o.id)>=0.8*e.cogs_ceiling_cents
 loop
  code:='org_near_ceiling:'||r.id;title:='Workspace near its monthly AI ceiling: '||coalesce(r.name,r.id::text);
  body:=to_char(r.spent/100.0,'FM999990.00')||' of '||to_char(r.ceiling/100.0,'FM999990.00')||' USD used this month on plan '||r.plan||'. Further AI requests will be refused at the ceiling.';
  data:=jsonb_build_object('org_id',r.id,'spent_cents',r.spent,'ceiling_cents',r.ceiling,'plan',r.plan);return next;
 end loop;
 return;
end$$;
revoke all on function public.ops_health_findings()from public,anon,authenticated;
grant execute on function public.ops_health_findings()to service_role,postgres;

-- Queue one push and one e-mail per admin per finding per UTC day. Bypasses
-- notification preferences on purpose: an outage alert is not marketing.
create or replace function public.ops_health_check()returns jsonb
language plpgsql security definer set search_path='' as $$
declare f record;a record;queued integer:=0;findings integer:=0;day text:=to_char(now()at time zone 'UTC','YYYY-MM-DD');
begin
 for f in select * from public.ops_health_findings() loop
  findings:=findings+1;
  for a in select p.id,p.email,exists(select 1 from public.notification_devices d where d.user_id=p.id and d.disabled_at is null) as has_device
    from public.profiles p where p.is_admin loop
   if a.has_device then
    insert into public.notification_outbox(org_id,user_id,category,channel,dedupe_key,payload)
    values(null,a.id,'ops_alert','push','ops_alert:'||f.code||':'||day||':'||a.id||':push',
      jsonb_build_object('title',f.title,'body',f.body,'code',f.code,'data',f.data,'observed_at',now()))
    on conflict(dedupe_key)do nothing;
    if found then queued:=queued+1;end if;
   end if;
   if coalesce(btrim(a.email),'')<>'' then
    insert into public.notification_outbox(org_id,user_id,category,channel,dedupe_key,payload)
    values(null,a.id,'ops_alert','email','ops_alert:'||f.code||':'||day||':'||a.id||':email',
      jsonb_build_object('title',f.title,'body',f.body,'code',f.code,'data',f.data,'observed_at',now()))
    on conflict(dedupe_key)do nothing;
    if found then queued:=queued+1;end if;
   end if;
  end loop;
 end loop;
 return jsonb_build_object('findings',findings,'queued',queued,'checked_at',now());
end$$;
revoke all on function public.ops_health_check()from public,anon,authenticated;
grant execute on function public.ops_health_check()to service_role,postgres;

do $$
declare v_id bigint;
begin
 if not exists(select 1 from pg_extension where extname='pg_cron')then
  raise notice 'ops_health_alert: pg_cron is not available; call public.ops_health_check() from an external scheduler.';return;
 end if;
 select jobid into v_id from cron.job where jobname='ops-health-check';
 if v_id is not null then perform cron.unschedule(v_id);end if;
 perform cron.schedule('ops-health-check','7 * * * *',$job$ select public.ops_health_check(); $job$);
exception when others then
 raise notice 'ops_health_alert: scheduling did not finish (% — %). public.ops_health_check() exists and can be called externally.',SQLSTATE,SQLERRM;
end$$;

commit;
