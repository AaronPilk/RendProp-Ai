\set ON_ERROR_STOP on
begin;
-- Disposable local metadata only. No network probe, customer object or cash.
create temp table video_checks(n integer default 0);insert into video_checks default values;
grant all on video_checks to service_role,authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin
 if v is distinct from true then raise exception 'TRIAL VIDEO FAIL: %',label;end if;update video_checks set n=n+1;end$$;
create function pg_temp.denied(command text,prefix text,label text)returns void language plpgsql as $$begin
 begin execute command;exception when others then if position(prefix in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;raise;end;
 raise exception 'TRIAL VIDEO FAIL expected %: %',prefix,label;end$$;
-- Test-only privileged observation; authenticated application roles retain
-- their real denial of the private financial/action tables.
create function pg_temp.actions(p_grant uuid,p_kind text default null)returns bigint
language sql security definer set search_path='' as $$select count(*)from public.subscription_trial_actions where grant_id=p_grant and(p_kind is null or kind=p_kind)$$;
create temp table vf(u uuid,o uuid,l uuid,a uuid,b uuid,g uuid,f uuid,j uuid,c uuid);
insert into vf values('e1000000-0000-4000-8000-000000000001','e2000000-0000-4000-8000-000000000001',gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),null,gen_random_uuid());
grant all on vf to service_role,authenticated;
insert into auth.users(id,email,is_anonymous,email_confirmed_at)select u,'trial-video@example.invalid',false,now()from vf;
insert into orgs(id,name,plan,plan_source,plan_expires_at)select o,'Synthetic duration test','starter','manual',now()+interval '6 days'from vf;
insert into memberships(org_id,user_id,role)select o,u,'owner'from vf;
insert into listings(id,org_id,agent_id,address)select l,o,u,'Synthetic duration property'from vf;
insert into serving_funding(id,org_id,source,collection_ref,actor_id,net_receipts_cents,sponsored_cents,starts_at,ends_at,retention_ends_at,service_months,recurring_reserve_cents,reserve_components,evidence_sha256,apple_original_transaction_id)
 select f,o,'trial','synthetic-video-trial-funding',u,0,100,now()-interval '1 minute',now()+interval '6 days',now()+interval '96 days',1,0,
 '{"storage":0,"delivery":0,"compute":0,"email":0,"support":0,"retention":0,"uncertainty":0}',repeat('a',64),'synthetic-video-original'from vf;
insert into serving_funding_slices(funding_id,slice_index,org_id,starts_at,ends_at,total_budget_cents,recurring_reserve_cents)
 select f,0,o,now()-interval '1 minute',now()+interval '6 days',100,0 from vf;
insert into subscription_trial_grants(id,actor_id,identity_sha256,org_id,original_transaction_id,funding_id,starts_at,ends_at,walkthrough_cap,photo_cap,listing_cap,upload_budget_bytes,max_video_seconds,evidence_sha256)
 select g,u,repeat('b',64),o,'synthetic-video-original',f,now()-interval '1 minute',now()+interval '6 days',1,5,1,1073741824,90,repeat('a',64)from vf;
insert into capture_assets(id,listing_id,kind,bucket,storage_key,bytes,uploaded,transport_version,content_type)
 select x,l,'video','renders','renders/'||o||'/'||l||'/'||x||'.mp4',100,true,2,'video/mp4'from vf cross join lateral unnest(array[a,b,c])x;
insert into upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes,state,settled_at)
 select x,o,l,u,current_date,'{}',0,'completed',clock_timestamp()from vf cross join lateral unnest(array[a,b,c])x;
insert into upload_operations(asset_id,kind,bucket,object_key,bytes,expected_bytes,content_type,content_type_declared,asset_kind,state,etag)
 select ca.id,'copy','renders',ca.storage_key,100,ca.bytes,'video/mp4',true,'video','retained','synthetic-etag-'||ca.id from vf join capture_assets ca on ca.id in(vf.a,vf.b,vf.c);
-- Synthetic pre-trial finalized uploads; all tested admission below uses the
-- restored Apple source and current immutable registered trial.
update orgs set plan_source='apple'where id=(select o from vf);
select pg_temp.ok(not has_table_privilege(r,'subscription_trial_video_attestations','INSERT,UPDATE,DELETE'),'attestation table is not writable by '||r)from unnest(array['anon','authenticated','service_role'])r;
select pg_temp.ok(not has_function_privilege(r,'record_subscription_trial_video(uuid,uuid,uuid,uuid,text,text,text,bigint,numeric,numeric,text)','EXECUTE'),'no public attestation authority for '||r)from unnest(array['anon','authenticated'])r;
set local role service_role;
do $$declare x record;ctx jsonb;begin select * into x from vf;
 ctx:=subscription_trial_video_context(x.u,x.o,x.l,x.a);
 perform pg_temp.ok(ctx->>'required'='true'and ctx->>'etag'='synthetic-etag-'||x.a,'exact retained object authority');
 perform pg_temp.denied(format('select record_subscription_trial_video(%L,%L,%L,%L,''renders'',%L,%L,100,91,91,''mp4-timing-v1'')',x.u,x.o,x.l,x.a,ctx->>'storage_key',ctx->>'etag'),'RP402','actual duration above90 is rejected');
 perform pg_temp.denied(format('select record_subscription_trial_video(%L,%L,%L,%L,''renders'',%L,%L,100,89.95,90.05,''mp4-timing-v1'')',x.u,x.o,x.l,x.a,ctx->>'storage_key',ctx->>'etag'),'RP402','billable samples above90 are rejected');
 perform pg_temp.denied(format('select record_subscription_trial_video(%L,%L,%L,%L,''renders'',%L,%L,100,''NaN'',60,''mp4-timing-v1'')',x.u,x.o,x.l,x.a,ctx->>'storage_key',ctx->>'etag'),'RP402','nonfinite duration is rejected');
 perform pg_temp.denied(format('select record_subscription_trial_video(%L,%L,%L,%L,''renders'',%L,''wrong-etag'',100,60,60,''mp4-timing-v1'')',x.u,x.o,x.l,x.a,ctx->>'storage_key'),'RP409','changed observation cannot attest');
 perform pg_temp.denied(format('select subscription_trial_video_context(%L,%L,%L,%L)',x.u,gen_random_uuid(),x.l,x.a),'RP403','foreign workspace rejected');
 perform pg_temp.denied(format('select subscription_trial_video_context(%L,%L,%L,%L)',x.u,x.o,gen_random_uuid(),x.a),'RP403','foreign property rejected');
 perform pg_temp.denied(format('select subscription_trial_video_context(%L,%L,%L,%L)',gen_random_uuid(),x.o,x.l,x.a),'RP403','foreign actor rejected');
 perform pg_temp.ok((select count(*)=0 from subscription_trial_video_attestations),'all invalid videos failed before attestation');
end$$;
reset role;
insert into deletion_requests(user_id,status)select u,'pending'from vf;
set local role service_role;
do $$declare x record;begin select * into x from vf;
 perform pg_temp.denied(format('select subscription_trial_video_context(%L,%L,%L,%L)',x.u,x.o,x.l,x.a),'RP403','pending account deletion refuses video authority');end$$;
reset role;
delete from deletion_requests where user_id=(select u from vf);
do $$begin perform set_config('request.jwt.claim.sub',(select u::text from vf),true);end$$;
set local role authenticated;
do $$declare x record;begin select * into x from vf;
 perform pg_temp.denied(format('select create_render_job(%L,%L,''smooth'',''{}'',''trial-video-no-attestation'',''app'')',x.l,x.a),'RP402','direct RPC cannot bypass missing attestation');
 perform pg_temp.ok(pg_temp.actions(x.g)=0,'unattested video consumes no walkthrough credit');
end$$;
reset role;
set local role service_role;
select record_subscription_trial_video(v.u,v.o,v.l,a.id,'renders',a.storage_key,'synthetic-etag-'||a.id,a.bytes,90,90,'mp4-timing-v1')from vf v join capture_assets a on a.id=v.a;
select record_subscription_trial_video(v.u,v.o,v.l,a.id,'renders',a.storage_key,'synthetic-etag-'||a.id,a.bytes,90,90,'mp4-timing-v1')from vf v join capture_assets a on a.id=v.a;
select pg_temp.ok((select count(*)=1 from subscription_trial_video_attestations),'same exact attestation replays once');
do $$declare x record;k text;begin select * into x from vf;select storage_key into k from capture_assets where id=x.a;
 perform pg_temp.denied(format('select record_subscription_trial_video(%L,%L,%L,%L,''renders'',%L,%L,100,60,60,''mp4-timing-v1'')',x.u,x.o,x.l,x.a,k,'synthetic-etag-'||x.a),'RP409','recorded timing is immutable');
end$$;
reset role;
-- Stored object changes never inherit an earlier duration capability.
update upload_operations set etag='changed-retained-etag'where asset_id=(select a from vf)and kind='copy';
set local role authenticated;
do $$declare x record;begin select * into x from vf;
 perform pg_temp.denied(format('select create_render_job(%L,%L,''smooth'',''{}'',''trial-video-changed-etag'',''app'')',x.l,x.a),'RP402','changed retained ETag fails direct RPC');
 perform pg_temp.ok(pg_temp.actions(x.g)=0,'changed ETag consumes no credit');end$$;
reset role;
update upload_operations set etag='synthetic-etag-'||asset_id where asset_id=(select a from vf)and kind='copy';
do $$begin perform pg_temp.denied('update capture_assets set bytes=101 where id=(select a from vf)','RP409','finalized asset metadata is already immutable');end$$;
update upload_operations set expected_bytes=101 where asset_id=(select a from vf)and kind='copy';
set local role authenticated;
do $$declare x record;begin select * into x from vf;
 perform pg_temp.denied(format('select create_render_job(%L,%L,''smooth'',''{}'',''trial-video-changed-bytes'',''app'')',x.l,x.a),'RP402','changed size fails direct RPC');end$$;
reset role;
update upload_operations set expected_bytes=100 where asset_id=(select a from vf)and kind='copy';
set local role authenticated;
do $$declare x record;j public.render_jobs;r public.renders;begin select * into x from vf;
 j:=create_render_job(x.l,x.a,'smooth','{}','trial-video-verified-key','app');update vf set j=j.id;
 perform pg_temp.ok(pg_temp.actions(x.g,'walkthrough')=1,'verified90s consumes one walkthrough');
 r:=publish_render(j.id,7199,2,'[]',null);
 perform pg_temp.ok(r.duration_s=90,'direct publish uses verified timing rather than claimed7199');
 perform pg_temp.ok(pg_temp.actions(x.g,'publication')=1,'verified90s publishes first listing');
 perform pg_temp.denied(format('select create_render_job(%L,%L,''smooth'',''{}'',''trial-video-second-asset'',''app'')',x.l,x.b),'RP402','second unattested source cannot borrow first attestation');
end$$;
reset role;
-- Replays retain their recorded result even after the original attestation is
-- unavailable. This is not permission for a new job or a new listing.
delete from subscription_trial_video_attestations where asset_id=(select a from vf);
set local role authenticated;
do $$declare x record;j public.render_jobs;r public.renders;begin select * into x from vf;
 j:=create_render_job(x.l,x.a,'smooth','{}','trial-video-verified-key','app');r:=publish_render(j.id,1,2,'[]',null);
 perform pg_temp.ok(j.id=x.j and r.duration_s=90,'recorded job and publication replay remain intact');
end$$;
reset role;
set local role service_role;
select record_subscription_trial_video(v.u,v.o,v.l,ca.id,'renders',ca.storage_key,'synthetic-etag-'||ca.id,ca.bytes,60,60,'mp4-timing-v1')from vf v join capture_assets ca on ca.id=v.c;
reset role;
delete from capture_assets where id=(select c from vf);
select pg_temp.ok(not exists(select 1 from subscription_trial_video_attestations where asset_id=(select c from vf)),'asset deletion cascades only its technical attestation');
select pg_temp.ok((select count(*)=1 from subscription_trial_grants where id=(select g from vf)),'technical cleanup never erases lifetime financial grant');
-- Executed negative control: remove ONLY the actual duration guard call from
-- the current trigger body. The real direct RPC now admits an unattested asset.
do $$declare d text;needle text;begin
 select pg_get_functiondef('public.subscription_trial_render_guard()'::regprocedure)into d;
 needle:=E' if tg_table_name=''renders''then new.duration_s:=public.assert_subscription_trial_video(auth.uid(),org,listing,asset,g.max_video_seconds);\n else perform public.assert_subscription_trial_video(auth.uid(),org,listing,asset,g.max_video_seconds);end if;\n';
 if position(needle in d)=0 then raise exception 'Unknown duration mutation control';end if;execute replace(d,needle,'');
end$$;
delete from subscription_trial_actions where grant_id=(select g from vf)and kind='walkthrough';
set local role authenticated;
select create_render_job(l,b,'smooth','{}','trial-video-missing-guard-control','app')from vf;
select pg_temp.ok(pg_temp.actions((select g from vf),'walkthrough')=1,'removing actual guard makes unattested direct RPC succeed');
reset role;
select 'TRIAL_VIDEO_CHECKS '||n from video_checks;
rollback;
