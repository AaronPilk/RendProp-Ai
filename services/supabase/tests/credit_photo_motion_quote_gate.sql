-- Dormant Photo Motion quote conversion and activation guard, on disposable PG.
begin;
create temporary table pm_credit_checks(n integer not null default 0);
insert into pm_credit_checks default values;
create function pg_temp.pm_credit_ok(v boolean,label text)
returns void language plpgsql as $$begin
  if v is distinct from true then raise exception 'PHOTO MOTION CREDIT FAIL: %',label;end if;
  update pm_credit_checks set n=n+1;
end$$;
create function pg_temp.pm_credit_refuses(statement text,needle text,label text)
returns void language plpgsql as $$begin
  begin execute statement;exception when others then
    if position(needle in sqlerrm)>0 then perform pg_temp.pm_credit_ok(true,label);return;end if;
    raise;
  end;
  raise exception 'PHOTO MOTION CREDIT FAIL: admitted %',label;
end$$;

select pg_temp.pm_credit_ok(
  (select value->>'revision'='photo-motion-quoted-v1' and
    value->>'enabled'='false' and value->>'activation_ready'='false'
   from public.app_config where key='credit_photo_motion'),
  'Photo Motion credit route stays dormant');
select pg_temp.pm_credit_ok(not has_function_privilege('authenticated',
  'public.credit_photo_motion_quote(uuid,jsonb,text)','execute') and
  not has_function_privilege('authenticated',
  'public.credit_photo_motion_credits_for_cents(numeric)','execute'),
  'a client cannot invoke the quote or price converter directly');
select pg_temp.pm_credit_ok(public.credit_photo_motion_credits_for_cents(39.3668)=8,
  'silent whole-video upper quote costs eight credits');
select pg_temp.pm_credit_ok(public.credit_photo_motion_credits_for_cents(62.7848)=13,
  'narrated whole-video upper quote costs thirteen credits');
select pg_temp.pm_credit_ok(public.credit_photo_motion_credits_for_cents(5.0001)=2,
  'fractional supplier cents round up rather than underfund');
select pg_temp.pm_credit_ok(public.credit_photo_motion_credits_for_cents(100)=20,
  'maximum approved supplier quote is exactly bounded');
select pg_temp.pm_credit_refuses(
  'select public.credit_photo_motion_credits_for_cents(100.0001)',
  'RP402: Photo Motion supplier quote exceeds','over-ceiling quote refuses');
select pg_temp.pm_credit_refuses(
  'select public.credit_photo_motion_credits_for_cents(0)',
  'RP402: Photo Motion supplier quote exceeds','free or missing quote refuses');
select pg_temp.pm_credit_refuses(
  'select public.credit_photo_motion_credits_for_cents(1.12345)',
  'RP402: Photo Motion supplier quote exceeds','over-precision quote refuses');
select pg_temp.pm_credit_refuses(
  'update public.app_config set value=jsonb_set(value,''{enabled}'',''true''::jsonb)
    where key=''credit_photo_motion''',
  'terminal accounting is not installed','a config toggle cannot activate unfinished metering');
select jsonb_build_object('assertions',(select n from pm_credit_checks),'passed',true);
rollback;
