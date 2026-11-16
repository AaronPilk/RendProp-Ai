-- Assessment runs before the customer selects an image edit. Bound its real
-- Gemini liability independently of photo-generation credits, including when
-- every reviewed photo is skipped. Retried request keys never consume twice.
begin;

create table public.photo_declutter_assessment_admissions(
  billing_org_id uuid not null references public.orgs(id) on delete cascade,
  request_key text not null check(request_key ~ '^[A-Za-z0-9:_-]{8,128}$'),
  actor_id uuid references public.profiles(id) on delete set null,
  source_sha256 text not null check(source_sha256 ~ '^[a-f0-9]{64}$'),
  admitted_at timestamptz not null default now(),
  primary key(billing_org_id,request_key)
);
create index photo_assess_org_time
  on public.photo_declutter_assessment_admissions(billing_org_id,admitted_at);
alter table public.photo_declutter_assessment_admissions enable row level security;
revoke all on public.photo_declutter_assessment_admissions from public,anon,authenticated,service_role;
grant select on public.photo_declutter_assessment_admissions to service_role;

create or replace function public.photo_declutter_assessment_admit(
  p_actor uuid,p_org uuid,p_key text,p_source_sha256 text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare bill uuid; old public.photo_declutter_assessment_admissions;
  sku text; plan_name text; tier text; daily_cap integer; monthly_cap integer;
  daily_used integer; monthly_used integer;
  day_start timestamptz; month_start timestamptz;
begin
  if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege; end if;
  if p_actor is null or p_org is null or p_key is null or
     p_key !~ '^[A-Za-z0-9:_-]{8,128}$' or p_source_sha256 is null or
     p_source_sha256 !~ '^[a-f0-9]{64}$' then
    raise exception 'RP400: A verified photo assessment is required'; end if;
  bill:=public.library_actor_billing_org(p_actor,p_org);
  if bill is null or not public.library_financial_actor(p_actor,p_org) or
     not exists(select 1 from public.orgs where id=bill and deleted_at is null) then
    raise exception 'RP403: Current photo workspace required'; end if;
  perform pg_advisory_xact_lock(hashtextextended('declutter-assessment:'||bill,71004));
  select * into old from public.photo_declutter_assessment_admissions
    where billing_org_id=bill and request_key=p_key;
  if found then
    if old.actor_id is distinct from p_actor or old.source_sha256 is distinct from p_source_sha256 then
      raise exception 'RP409: This photo review request belongs to another image'; end if;
    return jsonb_build_object('admitted',true,'replay',true,'tier','saved');
  end if;
  select s.product_id into sku from public.apple_subscriptions s
    where s.org_id=bill and s.environment='Production' and s.status='active'
      and s.expires_at>now()
    order by s.expires_at desc limit 1;
  if sku='com.rendprop.app.pro29.monthly' then
    tier:='pro';daily_cap:=40;monthly_cap:=60;
  elsif sku='com.rendprop.app.starter.monthly' then
    tier:='max';daily_cap:=60;monthly_cap:=100;
  elsif sku='com.rendprop.app.pro.monthly' then
    tier:='ultra';daily_cap:=100;monthly_cap:=250;
  elsif sku='com.rendprop.app.team.monthly' then
    tier:='team';daily_cap:=150;monthly_cap:=600;
  elsif (public.subscription_trial_active(bill,p_actor)).id is not null then
    tier:='trial';daily_cap:=5;monthly_cap:=10;
  else
    plan_name:=public.effective_plan(bill);
    if plan_name='team' then
      tier:='team_legacy';daily_cap:=150;monthly_cap:=600;
    elsif plan_name<>'free' then
      tier:='included_legacy';daily_cap:=60;monthly_cap:=100;
    else
      tier:='topup_only';daily_cap:=30;monthly_cap:=50;
    end if;
  end if;
  day_start:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  month_start:=date_trunc('month',now() at time zone 'UTC') at time zone 'UTC';
  select count(*) filter(where admitted_at>=day_start),count(*)
    into daily_used,monthly_used
    from public.photo_declutter_assessment_admissions
    where billing_org_id=bill and admitted_at>=month_start;
  if daily_used>=daily_cap or monthly_used>=monthly_cap then
    raise exception 'RP429: Photo review limit reached for this workspace. Try again after the daily or monthly reset'; end if;
  insert into public.photo_declutter_assessment_admissions(
    billing_org_id,request_key,actor_id,source_sha256)
    values(bill,p_key,p_actor,p_source_sha256);
  return jsonb_build_object('admitted',true,'replay',false,'tier',tier,
    'daily_remaining',daily_cap-daily_used-1,
    'monthly_remaining',monthly_cap-monthly_used-1,
    'daily_resets_at',(day_start+interval '1 day'),
    'monthly_resets_at',(month_start+interval '1 month'));
end$$;
revoke all on function public.photo_declutter_assessment_admit(uuid,uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.photo_declutter_assessment_admit(uuid,uuid,text,text)
  to service_role;

commit;
