\set ON_ERROR_STOP on
begin;
create temporary table erase_assertions(n integer not null default 0);
insert into erase_assertions default values;
create function pg_temp.check_erase(ok boolean,label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL: %',label; end if; update erase_assertions set n=n+1; end $$;
create function pg_temp.erase_refuses(statement text,expected text) returns void language plpgsql as $$
begin
  begin execute statement; exception when others then
    if sqlerrm like '%'||expected||'%' then perform pg_temp.check_erase(true,expected); return; end if;
    raise;
  end;
  raise exception 'FAIL: expected refusal %',expected;
end $$;

do $$
declare u uuid:='ee000000-0000-4000-8000-000000000001'; o uuid:='ee000000-0000-4000-8000-000000000002';
  l uuid:='ee000000-0000-4000-8000-000000000003'; a uuid:='ee000000-0000-4000-8000-000000000004';
  b uuid:=gen_random_uuid(); tomb uuid:=gen_random_uuid(); idem uuid:=gen_random_uuid(); j uuid; second_job uuid;
  r jsonb; rr jsonb; q jsonb; ref jsonb:='{"request_id":"synthetic-job","status_url":"https://queue.fal.run/bria/requests/synthetic-job/status","response_url":"https://queue.fal.run/bria/requests/synthetic-job"}';
  orig uuid:=gen_random_uuid(); altered uuid:=gen_random_uuid(); photo uuid:=gen_random_uuid(); invalid uuid:=gen_random_uuid();
  batch_cap uuid:=gen_random_uuid(); success_batch uuid:=gen_random_uuid(); cap_asset uuid; cost numeric; n integer;
begin
  insert into auth.users(id,email) values(u,'erase-synthetic@example.invalid');
  insert into orgs(id,name,plan) values(o,'Synthetic erase audit','pro');
  insert into memberships(user_id,org_id,role) values(u,o,'owner');
  insert into listings(id,org_id,agent_id,address) values(l,o,u,'Synthetic room');
  update plan_entitlements set reels_per_month=50,cogs_ceiling_cents=2000 where plan='pro';
  insert into capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,duration_s)
    values(a,l,'video','synthetic/clip.mp4','renders',true,2),
      (orig,l,'video','synthetic/original.mp4','renders',true,10),
      (altered,l,'video','synthetic/altered.mp4','renders',true,10),
      (photo,l,'photo','synthetic/photo.jpg','renders',true,null),
      (invalid,l,'video','synthetic/invalid.mp4','renders',true,5);
  perform pg_temp.check_erase(not has_function_privilege('authenticated','public.video_erase_reserve(uuid,uuid,uuid,uuid,uuid,uuid,text,numeric)','execute'),'tenant cannot reserve directly');
  perform pg_temp.check_erase(not has_table_privilege('authenticated','public.video_erase_jobs','select'),'tenant cannot read service job table');
  q:=video_erase_quote(o,u,l);
  perform pg_temp.check_erase((q->>'available')::boolean and(q->>'remaining_clips')::int=50,'quote uses current entitlement');
  perform pg_temp.erase_refuses(format('select video_erase_reserve(%L,%L,%L,%L,%L,%L,%L)',o,u,l,b,invalid,idem,repeat('a',64)),'RP400');
  update capture_assets set duration_s=0 where id=invalid;
  perform pg_temp.erase_refuses(format('select video_erase_reserve(%L,%L,%L,%L,%L,%L,%L)',o,u,l,b,invalid,idem,repeat('a',64)),'RP400');
  update capture_assets set duration_s='NaN'::numeric where id=invalid;
  perform pg_temp.erase_refuses(format('select video_erase_reserve(%L,%L,%L,%L,%L,%L,%L)',o,u,l,b,invalid,idem,repeat('a',64)),'RP400');
  perform pg_temp.check_erase(not exists(select 1 from rate_limits where key in ('reelmo:'||o,'aivideo:'||o)),'preflight rejects without quota');
  r:=video_erase_reserve(o,u,l,b,a,idem,repeat('a',64));j:=(r->'job'->>'id')::uuid;
  perform pg_temp.check_erase((r->>'dispatch')::boolean,'one first dispatch claim');
  rr:=video_erase_reserve(o,u,l,b,a,idem,repeat('a',64));
  perform pg_temp.check_erase(not(rr->>'dispatch')::boolean and rr->'job'->>'id'=j::text,'repeat returns same job without dispatch');
  perform pg_temp.check_erase((select count from rate_limits where key='reelmo:'||o)=1,'idempotency consumes one monthly clip');
  perform pg_temp.erase_refuses(format('select video_erase_reserve(%L,%L,%L,%L,%L,%L,%L)',o,u,l,b,a,idem,repeat('b',64)),'RP409');
  update rate_limits set count=50 where key='reelmo:'||o;
  update capture_assets set duration_s=2 where id=invalid;
  perform pg_temp.erase_refuses(format('select video_erase_reserve(%L,%L,%L,%L,%L,%L,%L)',o,u,l,b,invalid,gen_random_uuid(),repeat('a',64)),'RP402');
  perform pg_temp.check_erase((select count from rate_limits where key='aivideo:'||o)=1,'monthly refusal rolls back burst charge');
  update rate_limits set count=1 where key='reelmo:'||o;
  perform video_erase_finish(j,'processing',ref);
  perform video_erase_finish(j,'processing',ref);
  perform pg_temp.check_erase((select count(*) from cost_ledger where org_id=o and feature='video_declutter')=1,'provider receipt records COGS once');
  perform pg_temp.check_erase((select total_cents=28 and units=2 and unit_cost_cents=14 from cost_ledger where org_id=o and feature='video_declutter'),'actual input seconds at14c');
  perform video_erase_cancel(o,u,null,b);
  perform video_erase_cancel(o,u,null,b);
  perform pg_temp.check_erase((select count from rate_limits where key='reelmo:'||o)=0,'repeat cancel refunds once');
  perform pg_temp.check_erase((select sum(total_cents) from cost_ledger where org_id=o)=28,'cancel preserves provider COGS');
  r:=video_erase_finish(j,'completed',ref,'https://media.invalid/edited.mp4','synthetic/edited.mp4');
  perform pg_temp.check_erase(r->>'state'='cancelled' and r->>'output_url' is null,'late completion cannot resurrect cancellation');
  r:=video_erase_cancel(o,u,null,tomb);
  perform pg_temp.check_erase(r->>'status'='cancelled' and(r->>'cancelled_clips')::int=0,'pre-submit cancellation creates tombstone');
  perform pg_temp.erase_refuses(format('select video_erase_reserve(%L,%L,%L,%L,%L,%L,%L)',o,u,l,tomb,a,gen_random_uuid(),repeat('a',64)),'RP409');
  r:=video_erase_reserve(o,u,l,gen_random_uuid(),invalid,gen_random_uuid(),repeat('a',64));second_job:=(r->'job'->>'id')::uuid;
  update rate_limits set window_start=now()+interval '1 second',count=7 where key in ('reelmo:'||o,'aivideo:'||o);
  perform video_erase_finish(second_job,'uncertain',null,null,null,'Synthetic timeout');
  perform pg_temp.check_erase((select count from rate_limits where key='reelmo:'||o)=7 and(select count from rate_limits where key='aivideo:'||o)=7,'late refund cannot alter a newer window');
  perform pg_temp.check_erase((select allowance_refunded_at is not null and cost_ledger_id is null from video_erase_jobs where id=second_job),'uncertain receipt releases allowance and retains unbilled cost hold');
  -- Decimal pricing: 3*4.8 +2.74 seconds is239.96c. Another0.01s breaches240c.
  for n in 1..4 loop
    cap_asset:=gen_random_uuid();insert into capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,duration_s) values(cap_asset,l,'video','synthetic/cap-'||n||'.mp4','renders',true,case when n<4 then 4.8 else 2.74 end);
    perform video_erase_reserve(o,u,l,batch_cap,cap_asset,gen_random_uuid(),repeat('a',64));
  end loop;
  select sum(cost_cents) into cost from video_erase_jobs where batch_id=batch_cap;
  perform pg_temp.check_erase(cost=239.96,'decimal batch hold matches duration atpublished price');
  update capture_assets set duration_s=.01 where id=invalid;
  perform pg_temp.erase_refuses(format('select video_erase_reserve(%L,%L,%L,%L,%L,%L,%L)',o,u,l,batch_cap,invalid,gen_random_uuid(),repeat('a',64)),'RP402');
  perform pg_temp.check_erase((select count(*) from video_erase_jobs where batch_id=batch_cap)=4,'budget refusal records no charged job');
  perform video_erase_cancel(o,u,null,batch_cap);
  update capture_assets set duration_s=2 where id=invalid;
  r:=video_erase_reserve(o,u,l,success_batch,invalid,gen_random_uuid(),repeat('a',64));j:=(r->'job'->>'id')::uuid;
  perform pg_temp.erase_refuses(format('select video_erase_apply(%L,%L,%L,%L,%L)',o,u,success_batch,orig,altered),'RP409');
  perform video_erase_finish(j,'completed',ref,'https://media.invalid/clip.mp4','synthetic/clip-result.mp4');
  perform pg_temp.erase_refuses(format('select video_erase_apply(%L,%L,%L,%L,%L)',o,u,success_batch,photo,altered),'RP400');
  perform pg_temp.erase_refuses(format('select video_erase_apply(%L,%L,%L,%L,%L)',o,u,success_batch,orig,orig),'RP400');
  update capture_assets set duration_s=-.01 where id=altered;
  perform pg_temp.erase_refuses(format('select video_erase_apply(%L,%L,%L,%L,%L)',o,u,success_batch,orig,altered),'RP400');
  update capture_assets set duration_s=10 where id=altered;
  r:=video_erase_apply(o,u,success_batch,orig,altered);
  rr:=video_erase_apply(o,u,success_batch,orig,altered);
  perform pg_temp.check_erase(r=rr and(r->'provenance'->>'recorded')::boolean,'lost apply response retrieves same immutable receipt');
  perform pg_temp.check_erase((select count(*) from media_provenance where listing_id=l)=1,'one public provenance after acceptance');
  perform pg_temp.check_erase((select kind='video_reflection_removal' and original_key='synthetic/original.mp4' and altered_key='synthetic/altered.mp4' and disclosure not like '%photo was%' from media_provenance where listing_id=l),'truthful full-video pair rather than photo disclosure');
  perform pg_temp.erase_refuses(format('select video_erase_cancel(%L,%L,null,%L)',o,u,success_batch),'RP409');
  perform pg_temp.erase_refuses(format('select video_erase_apply(%L,%L,%L,%L,%L)',o,u,success_batch,altered,orig),'RP409');
  perform pg_temp.erase_refuses(format('update media_provenance set original_key=%L where listing_id=%L','synthetic/photo.jpg',l),'RP409');
  perform pg_temp.erase_refuses(format('select video_erase_get(%L,%L,%L)',o,gen_random_uuid(),j),'RP403');
  -- App crash before saving its receipt: the next quote reclaims stale quota.
  r:=video_erase_reserve(o,u,l,gen_random_uuid(),a,gen_random_uuid(),repeat('a',64));j:=(r->'job'->>'id')::uuid;
  select count into n from rate_limits where key='reelmo:'||o;
  update video_erase_jobs set created_at=now()-interval '3 minutes' where id=j;
  perform video_erase_quote(o,u,l);
  perform pg_temp.check_erase((select state='uncertain' and allowance_refunded_at is not null from video_erase_jobs where id=j),'quote reclaims abandoned dispatch allowance');
  perform pg_temp.check_erase((select count from rate_limits where key='reelmo:'||o)=n-1,'stale allowance refunded exactly once');
  perform video_erase_quote(o,u,l);
  perform pg_temp.check_erase((select count from rate_limits where key='reelmo:'||o)=n-1,'repeat quote cannot mint allowance');
  b:=gen_random_uuid();
  r:=video_erase_reserve(o,u,l,b,a,gen_random_uuid(),repeat('a',64));j:=(r->'job'->>'id')::uuid;
  perform video_erase_reserve(o,u,l,b,invalid,gen_random_uuid(),repeat('b',64));
  r:=video_erase_cancel(o,u,j,null);
  perform pg_temp.check_erase((r->>'cancelled_clips')::int=2 and not exists(select 1 from video_erase_jobs where batch_id=b and allowance_refunded_at is null),'request cancellation refunds entire unusable batch');
  r:=video_erase_reserve(o,u,l,gen_random_uuid(),a,gen_random_uuid(),repeat('c',64),2.005);j:=(r->'job'->>'id')::uuid;
  perform pg_temp.check_erase((r->'job'->>'cost_cents')::numeric=28.07,'reserved COGS uses precise verified video timeline');
  perform video_erase_finish(j,'failed',null,null,null,'Synthetic provider403',true);
  perform pg_temp.check_erase((select state='failed' and allowance_refunded_at is not null and cost_hold_released_at is not null and cost_ledger_id is null from video_erase_jobs where id=j),'definitive rejection releases allowance and unbilled cost hold');
  perform video_erase_finish(j,'failed',null,null,null,'Repeat provider403',true);
  perform pg_temp.check_erase((select count(*) from cost_ledger where meta->>'erase_job_id'=j::text)=0,'rejected submit never becomes provider spend');
  -- Deleting a listing must still cascade through accepted receipts and clips.
  -- Deferred FK validation prevents cascade trigger ordering from blocking it.
  delete from listings where id=l;
  set constraints all immediate;
  perform pg_temp.check_erase(not exists(select 1 from video_erase_jobs where org_id=o) and not exists(select 1 from media_provenance where listing_id=l),'listing deletion clears jobs and provenance without FK ordering failure');
  perform pg_temp.check_erase(exists(select 1 from cost_ledger where org_id=o),'listing deletion retains incurred workspace COGS');
  -- A reflection hold must fence other existing monthly-spend consumers.
  o:=gen_random_uuid();l:=gen_random_uuid();a:=gen_random_uuid();b:=gen_random_uuid();orig:=gen_random_uuid();
  insert into orgs(id,name,plan) values(o,'Cross-feature synthetic budget','pro');
  insert into memberships(user_id,org_id,role) values(u,o,'owner');
  insert into listings(id,org_id,agent_id,address) values(l,o,u,'Synthetic budget room');
  update plan_entitlements set cogs_ceiling_cents=100 where plan='pro';
  insert into capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,duration_s) values(a,l,'video','synthetic/cross-feature.mp4','renders',true,4.8);
  r:=video_erase_reserve(o,u,l,b,a,gen_random_uuid(),repeat('d',64));j:=(r->'job'->>'id')::uuid;
  perform pg_temp.check_erase(org_month_spend_cents(o)=67.2,'global spend includes unresolved reflection holds');
  q:=video_erase_quote(o,u,l);
  perform pg_temp.check_erase((q->>'max_batch_cents')::numeric=32.8,'quote caps selection at remaining COGS headroom');
  insert into render_jobs(id,listing_id) values(orig,l);
  perform pg_temp.erase_refuses(format('select log_job_cost(%L,%L,%L,%L,%L,1,50,%L::jsonb,2500)',orig,o,'hero','fal','synthetic','{}'),'RP402');
  perform video_erase_finish(j,'processing',ref);
  perform pg_temp.check_erase(org_month_spend_cents(o)=67.2,'confirmed receipt replaces hold without double counting');
  invalid:=gen_random_uuid();insert into capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,duration_s) values(invalid,l,'video','synthetic/scoped-hold.mp4','renders',true,1);
  perform video_erase_reserve(o,u,l,gen_random_uuid(),invalid,gen_random_uuid(),repeat('e',64));
  perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',u)::text,true);
  set local role authenticated;
  cost:=video_erase_held_cents(o);
  reset role;
  perform pg_temp.check_erase(cost=14,'authenticated member sees only aggregate hold');
  perform set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',gen_random_uuid())::text,true);
  set local role authenticated;
  cost:=video_erase_held_cents(o);
  reset role;
  perform pg_temp.check_erase(cost=0,'unrelated authenticated identity cannot read held spend');
  perform set_config('request.jwt.claims','{}',true);



end $$;
select 'PASS video erase SQL: '||n||' assertions' from erase_assertions;
rollback;
