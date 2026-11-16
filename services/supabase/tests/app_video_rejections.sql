\set ON_ERROR_STOP on
begin;
create temporary table video_rejection_assertions(n int not null default 0);
insert into video_rejection_assertions default values;
create function pg_temp.check_rejection(ok boolean,label text) returns void language plpgsql as $$
begin
  if ok is distinct from true then raise exception 'FAIL: %',label; end if;
  update video_rejection_assertions set n=n+1;
end $$;
create function pg_temp.rejection_refuses(statement text,expected text) returns void language plpgsql as $$
begin
  begin execute statement; exception when others then
    if sqlerrm like '%'||expected||'%' then perform pg_temp.check_rejection(true,expected); return; end if;
    raise;
  end;
  raise exception 'FAIL: expected refusal %',expected;
end $$;
do $$
declare u uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); o uuid:=gen_random_uuid();
  r jsonb; receipt jsonb; before_cents numeric; rejected uuid; status integer; role_name text;
begin
  insert into auth.users(id,email) values(u,'reject-owner@example.invalid'),(outsider,'reject-outsider@example.invalid');
  insert into orgs(id,name,plan) values(o,'Synthetic reject test','pro');
  insert into memberships(user_id,org_id,role) values(u,o,'owner');
  update plan_entitlements set reels_per_month=50,aerials_per_month=50,topaz_per_month=50,cogs_ceiling_cents=6000 where plan='pro';
  foreach role_name in array array['anon','authenticated'] loop
    perform pg_temp.check_rejection(not has_function_privilege(role_name,'public.app_video_cost_release_rejected(uuid,uuid,text,integer,text)','execute'),'release is service only');
    perform pg_temp.check_rejection(not has_table_privilege(role_name,'public.app_video_cost_reservations','SELECT,INSERT,UPDATE,DELETE'),'journal remains private');
  end loop;
  perform pg_temp.check_rejection(has_function_privilege('service_role','public.app_video_cost_release_rejected(uuid,uuid,text,integer,text)','execute'),'service release grant');
  perform pg_temp.check_rejection(not has_table_privilege('service_role','public.app_video_cost_reservations','DELETE'),'released tombstones cannot be deleted');
  r:=public.app_video_cost_reserve(u,o,'reject-current-key','reel','fal','synthetic/reel',repeat('1',64),24,5,4.8,'{}');
  rejected:=(r->>'id')::uuid;
  perform pg_temp.check_rejection(public.org_month_spend_cents(o)=24,'priced hold is counted');
  foreach status in array array[200,202,408,409,425,500,503,504] loop
    perform pg_temp.rejection_refuses(format('select public.app_video_cost_release_rejected(%L,%L,''reject-current-key'',%s,''upstream'')',u,o,status),'RP400');
  end loop;
  perform pg_temp.rejection_refuses(format('select public.app_video_cost_release_rejected(%L,%L,''reject-current-key'',403,''timeout'')',u,o),'RP400');
  perform pg_temp.rejection_refuses(format('select public.app_video_cost_release_rejected(%L,%L,''reject-current-key'',403,''upstream'')',outsider,o),'RP409');
  perform pg_temp.rejection_refuses(format('select public.app_video_cost_release_rejected(%L,%L,''wrong-key'',403,''upstream'')',u,o),'RP409');
  r:=public.app_video_cost_release_rejected(u,o,'reject-current-key',403,'upstream');
  receipt:=public.app_video_cost_release_rejected(u,o,'reject-current-key',403,'upstream');
  perform pg_temp.check_rejection(r=receipt and (r->>'released')::boolean,'same refusal replay idempotent');
  perform pg_temp.check_rejection(public.app_video_held_cents(o)=0 and public.org_month_spend_cents(o)=0,'definitive rejection releases current month budget');
  perform pg_temp.check_rejection((select count(*)=1 from app_video_cost_reservations where org_id=o),'immutable refusal tombstone remains');
  perform pg_temp.rejection_refuses(format('select public.app_video_cost_reserve(%L,%L,''reject-current-key'',''reel'',''fal'',''synthetic/reel'',%L,24,5,4.8,''{}'')',u,o,repeat('1',64)),'RP409');
  perform pg_temp.rejection_refuses(format('select public.app_video_cost_settle(%L,%L,''reject-current-key'',''unexpected-paid-receipt'')',u,o),'RP409');
  perform pg_temp.rejection_refuses(format('select public.app_video_cost_release_rejected(%L,%L,''reject-current-key'',422,''validation'')',u,o),'RP409');
  perform pg_temp.rejection_refuses(format('update public.app_video_cost_reservations set released_at=null,rejection_status=null,rejection_error_class=null where id=%L',rejected),'RP409');
  perform pg_temp.rejection_refuses(format('update public.app_video_cost_reservations set rejection_status=401 where id=%L',rejected),'RP409');
  perform pg_temp.rejection_refuses(format('update public.app_video_cost_reservations set total_cents=25 where id=%L',rejected),'RP409');
  r:=public.app_video_cost_reserve(u,o,'prepare-failure-key','reel','fal','synthetic/reel',repeat('4',64),24,5,4.8,'{}');
  r:=public.app_video_cost_release_rejected(u,o,'prepare-failure-key',0,'upstream');
  perform pg_temp.check_rejection((r->>'released')::boolean and public.org_month_spend_cents(o)=0,'explicit server pre-dispatch failure releases without a fabricated HTTP status');
  r:=public.app_video_cost_reserve(u,o,'accepted-current-key','reel','fal','synthetic/reel',repeat('2',64),24,5,4.8,'{}');
  r:=public.app_video_cost_settle(u,o,'accepted-current-key','paid-receipt');
  receipt:=public.app_video_cost_settle(u,o,'accepted-current-key','paid-receipt');
  perform pg_temp.check_rejection(r=receipt and public.org_month_spend_cents(o)=24,'accepted settle replay books one cost');
  perform pg_temp.rejection_refuses(format('select public.app_video_cost_release_rejected(%L,%L,''accepted-current-key'',403,''upstream'')',u,o),'RP409');
  insert into public.app_video_cost_reservations(org_id,actor_id,idempotency_key,feature,provider,model,input_sha256,units,unit_cost_cents,total_cents,hold_cents,created_at)
    values(o,u,'old-unconfirmed-key','aerial','fal','synthetic/old',repeat('3',64),1,80,80,90,date_trunc('month',now())-interval '1 day');
  perform pg_temp.check_rejection(public.app_video_held_cents(o)=90 and public.org_month_spend_cents(o)=114,'unknown old-month attempt remains fenced');
  before_cents:=public.org_month_spend_cents(o);
  r:=public.app_video_cost_release_rejected(u,o,'old-unconfirmed-key',403,'upstream');
  perform pg_temp.check_rejection(public.org_month_spend_cents(o)=before_cents-90,'confirmed old-month rejection releases exact hold');
  perform pg_temp.check_rejection((select count(*)=1 from cost_ledger where org_id=o),'rejections never book ledger cost');
  perform pg_temp.check_rejection((select prosecdef and proconfig=array['search_path=""'] from pg_proc where oid='public.org_month_spend_cents(uuid)'::regprocedure) and not has_function_privilege('anon','public.org_month_spend_cents(uuid)','execute'),'pooled spend has pinned path and no anonymous access');
end $$;
select jsonb_build_object('assertions',n,'passed',true) from video_rejection_assertions;
rollback;
