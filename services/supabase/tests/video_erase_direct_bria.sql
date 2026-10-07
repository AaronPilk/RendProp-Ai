-- Synthetic direct Bria receipt tests. Local database only; rolled back.
\set ON_ERROR_STOP on
begin;
create temporary table direct_erase_assertions(n int);
insert into direct_erase_assertions values(0);
create or replace function pg_temp.direct_check(v boolean,msg text) returns void language plpgsql as $$
begin if v is distinct from true then raise exception 'FAIL: %',msg; end if; update direct_erase_assertions set n=n+1; end $$;
create or replace function pg_temp.direct_refuses(q text,code text) returns void language plpgsql as $$
begin execute q; raise exception 'FAIL: expected %',code;
exception when others then if sqlerrm not like code||'%' then raise; end if; update direct_erase_assertions set n=n+1; end $$;
do $$
declare
 u uuid:='bd000000-0000-4000-8000-000000000001'; o uuid:='bd000000-0000-4000-8000-000000000002';
 l uuid:='bd000000-0000-4000-8000-000000000003'; a uuid:='bd000000-0000-4000-8000-000000000004';
 cfg jsonb:='{"mask_unit_cost_cents":2,"erase_unit_cost_cents":3,"price_version":"synthetic-account-v1","output_hosts":["outputs.example.com"]}';
 mr jsonb:='{"request_id":"synthetic-mask","status_url":"https://engine.prod.bria-api.com/v2/status/synthetic-mask"}';
 er jsonb:='{"request_id":"synthetic-erase","status_url":"https://engine.prod.bria-api.com/v2/status/synthetic-erase"}';
 fal jsonb:='{"request_id":"synthetic-fal","status_url":"https://queue.fal.run/bria/requests/synthetic-fal/status","response_url":"https://queue.fal.run/bria/requests/synthetic-fal"}';
 b uuid:=gen_random_uuid(); idem uuid:=gen_random_uuid(); j uuid; jj uuid; r jsonb; rr jsonb; used int;
begin
 insert into auth.users(id,email) values(u,'direct-erase@example.invalid');
 insert into orgs(id,name,plan) values(o,'Synthetic direct Bria','pro');
 insert into memberships(user_id,org_id,role) values(u,o,'owner');
 insert into listings(id,org_id,agent_id,address) values(l,o,u,'Synthetic room');
 insert into capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,duration_s) values(a,l,'video','synthetic/direct.mp4','renders',true,2);
 update plan_entitlements set reels_per_month=200,cogs_ceiling_cents=2000 where plan='pro';
 perform pg_temp.direct_check(not has_function_privilege('authenticated','public.video_erase_reserve_direct(uuid,uuid,uuid,uuid,uuid,uuid,text,numeric,jsonb,text)','execute'),'direct reservation is service-only');
 perform pg_temp.direct_check(not has_function_privilege('anon','public.video_erase_finish_stage(uuid,text,text,jsonb,text,boolean)','execute'),'anonymous cannot fabricate paid stage receipts');
 perform pg_temp.direct_check(not has_function_privilege('authenticated','public.video_erase_admit_stage(uuid,uuid,uuid,text)','execute'),'tenant cannot admit a second paid stage');
 perform pg_temp.direct_check(not has_function_privilege('authenticated','public.video_erase_job_json(uuid)','execute') and not has_table_privilege('authenticated','public.video_erase_stages','select'),'private stage refs are not exposed');
 perform pg_temp.direct_refuses(format('select video_erase_reserve_direct(%L,%L,%L,%L,%L,%L,%L,2,%L,null)',o,u,l,b,a,idem,repeat('a',64),cfg),'RP403');
 perform pg_temp.direct_refuses(format('select video_erase_reserve_direct(%L,%L,%L,%L,%L,%L,%L,2,%L,%L)',o,u,l,b,a,idem,repeat('a',64),'{}','bria-video-v1'),'RP400');
 perform pg_temp.direct_check(not exists(select 1 from rate_limits where key in ('reelmo:'||o,'aivideo:'||o)),'pricing/consent refusals consume no quota');
 r:=video_erase_reserve_direct(o,u,l,b,a,idem,repeat('a',64),2,cfg,'bria-video-v1'); j:=(r->'job'->>'id')::uuid;
 perform pg_temp.direct_check((r->>'dispatch')::boolean and r->'job'->>'provider'='bria','one mask admission commits the selected provider');
 perform pg_temp.direct_check((select count(*) from video_erase_stages where job_id=j)=2 and video_erase_held_cents(o)=10,'both paid stages held together');
 rr:=video_erase_reserve_direct(o,u,l,b,a,idem,repeat('a',64),2,'{}','bria-video-v1');
 perform pg_temp.direct_check(not(rr->>'dispatch')::boolean and rr->'job'->>'id'=j::text,'lost submit response retrieves same job before current config');
 perform pg_temp.direct_check((select count from rate_limits where key='reelmo:'||o)=1,'two stages use one clip allowance');
 perform pg_temp.direct_refuses(format('update video_erase_jobs set provider=%L where id=%L','fal',j),'RP409');
 perform pg_temp.direct_refuses(format('update video_erase_jobs set provider_config=%L::jsonb where id=%L','{}',j),'RP409');
 perform pg_temp.direct_refuses(format('select video_erase_admit_stage(%L,%L,%L,%L)',o,u,j,'bria-video-v1'),'RP409');
 perform video_erase_finish_stage(j,'mask','processing',mr);
 perform video_erase_finish_stage(j,'mask','processing',mr);
 perform pg_temp.direct_check((select count(*) from cost_ledger where meta->>'erase_job_id'=j::text)=1,'mask receipt accounts exactly once');
 perform pg_temp.direct_check(org_month_spend_cents(o)=10 and video_erase_held_cents(o)=6,'mask ledger replaces only mask hold');
 perform video_erase_finish_stage(j,'mask','completed',null,'https://outputs.example.com/mask.mp4');
 perform pg_temp.direct_refuses(format('select video_erase_admit_stage(%L,%L,%L,%L)',o,u,j,'old-consent'),'RP403');
 r:=video_erase_admit_stage(o,u,j,'bria-video-v1'); rr:=video_erase_admit_stage(o,u,j,'bria-video-v1');
 perform pg_temp.direct_check((r->>'dispatch')::boolean and not(rr->>'dispatch')::boolean,'mask completion admits erase only once');
 perform pg_temp.direct_refuses(format('select video_erase_finish_stage(%L,%L,%L,%L::jsonb)',j,'mask','processing',er),'RP409');
 perform video_erase_finish_stage(j,'erase','processing',er);
 perform video_erase_finish_stage(j,'erase','completed',null,'https://outputs.example.com/edited.mp4');
 perform video_erase_finish_stage(j,'erase','completed',er,'https://outputs.example.com/edited.mp4');
 perform pg_temp.direct_check((select count(*) from cost_ledger where meta->>'erase_job_id'=j::text)=2 and org_month_spend_cents(o)=10,'erase receipt accounts once without doubling total COGS');
 perform pg_temp.direct_check((select sum(total_cents) from cost_ledger where meta->>'erase_job_id'=j::text)=10 and (select bool_and(provider='bria' and meta->>'price_version'='synthetic-account-v1') from cost_ledger where meta->>'erase_job_id'=j::text),'stage costs use pinned account pricing');
 perform pg_temp.direct_refuses(format('select video_erase_finish(%L,%L,null,%L,%L)',j,'completed','https://cdn.example.com/video.mp4','video-reflections/another-org/output.mp4'),'RP400');
 r:=video_erase_finish(j,'completed',null,'https://cdn.example.com/video.mp4','video-reflections/'||o||'/'||j||'.mp4');
 perform pg_temp.direct_check(r->>'state'='completed' and jsonb_array_length(r->'stages')=2,'completed result retains private stage receipts and scoped output');
 -- Existing fal jobs continue to use their original ref, published14c rate and ledger.
 r:=video_erase_reserve(o,u,l,gen_random_uuid(),a,gen_random_uuid(),repeat('f',64),2); jj:=(r->'job'->>'id')::uuid;
 perform video_erase_finish(jj,'completed',fal,'https://fal.media/synthetic.mp4','synthetic/fal.mp4');
 perform pg_temp.direct_check((select provider='fal' and cost_cents=28 from video_erase_jobs where id=jj) and not exists(select 1 from video_erase_stages where job_id=jj),'legacy fal receipts retain transport and price');
 -- Cancellation after masking releases the unpaid erase but preserves incurred mask COGS.
 r:=video_erase_reserve_direct(o,u,l,gen_random_uuid(),a,gen_random_uuid(),repeat('b',64),2,cfg,'bria-video-v1'); j:=(r->'job'->>'id')::uuid;
 perform video_erase_finish_stage(j,'mask','completed',mr,'https://outputs.example.com/mask.mp4');
 select count into used from rate_limits where key='reelmo:'||o;
 perform video_erase_cancel(o,u,j,null); perform video_erase_cancel(o,u,j,null);
 r:=video_erase_admit_stage(o,u,j,'bria-video-v1');
 perform pg_temp.direct_check(not(r->>'dispatch')::boolean and (select state='cancelled' and cost_hold_released_at is not null and admitted_at is null from video_erase_stages where job_id=j and stage='erase'),'cancelled mask cannot admit erase');
 perform pg_temp.direct_check((select count from rate_limits where key='reelmo:'||o)=used-1 and (select sum(total_cents) from cost_ledger where meta->>'erase_job_id'=j::text)=4,'cancel refunds allowance once and retains paid mask');
 perform pg_temp.direct_refuses(format('select video_erase_finish_stage(%L,%L,%L,%L::jsonb)',j,'erase','processing',er),'RP409');
 -- Ambiguity preserves exactly the unresolved paid hold and releases future work.
 r:=video_erase_reserve_direct(o,u,l,gen_random_uuid(),a,gen_random_uuid(),repeat('c',64),2,cfg,'bria-video-v1'); j:=(r->'job'->>'id')::uuid;
 perform video_erase_finish_stage(j,'mask','uncertain');
 perform pg_temp.direct_check((select state='uncertain' and allowance_refunded_at is not null from video_erase_jobs where id=j) and (select cost_hold_released_at is null from video_erase_stages where job_id=j and stage='mask') and (select cost_hold_released_at is not null from video_erase_stages where job_id=j and stage='erase'),'uncertain mask fences its paid attempt only');
 r:=video_erase_admit_stage(o,u,j,'bria-video-v1'); perform pg_temp.direct_check(not(r->>'dispatch')::boolean,'uncertain never admits future paid work');
 r:=video_erase_reserve_direct(o,u,l,gen_random_uuid(),a,gen_random_uuid(),repeat('d',64),2,cfg,'bria-video-v1'); j:=(r->'job'->>'id')::uuid;
 perform video_erase_finish_stage(j,'mask','failed',null,null,true);
 perform pg_temp.direct_check((select bool_and(cost_hold_released_at is not null) from video_erase_stages where job_id=j) and not exists(select 1 from cost_ledger where meta->>'erase_job_id'=j::text),'prequeue rejection releases both uncharged holds');
 -- A known mask plus ambiguous erase retains erase COGS hold, no duplicate admission.
 r:=video_erase_reserve_direct(o,u,l,gen_random_uuid(),a,gen_random_uuid(),repeat('e',64),2,cfg,'bria-video-v1'); j:=(r->'job'->>'id')::uuid;
 perform video_erase_finish_stage(j,'mask','completed',mr,'https://outputs.example.com/mask.mp4'); perform video_erase_admit_stage(o,u,j,'bria-video-v1');
 perform video_erase_finish_stage(j,'erase','uncertain'); r:=video_erase_admit_stage(o,u,j,'bria-video-v1');
 perform pg_temp.direct_check(not(r->>'dispatch')::boolean and (select cost_hold_released_at is null and cost_ledger_id is null from video_erase_stages where job_id=j and stage='erase'),'uncertain erase cannot be admitted again');
 -- Membership removal prevents the next stage, while a paid receipt remains accountable.
 r:=video_erase_reserve_direct(o,u,l,gen_random_uuid(),a,gen_random_uuid(),repeat('7',64),2,cfg,'bria-video-v1'); j:=(r->'job'->>'id')::uuid;
 perform video_erase_finish_stage(j,'mask','completed',mr,'https://outputs.example.com/mask.mp4');
 delete from memberships where org_id=o and user_id=u;
 perform pg_temp.direct_refuses(format('select video_erase_admit_stage(%L,%L,%L,%L)',o,u,j,'bria-video-v1'),'RP403');
 insert into memberships(user_id,org_id,role) values(u,o,'owner');
 -- Abandoned mask admission refunds on quote, retaining the ambiguous mask hold.
 r:=video_erase_reserve_direct(o,u,l,gen_random_uuid(),a,gen_random_uuid(),repeat('8',64),2,cfg,'bria-video-v1'); j:=(r->'job'->>'id')::uuid;
 update video_erase_stages set admitted_at=now()-interval '3 minutes' where job_id=j and stage='mask';
 perform video_erase_quote(o,u,l);
 perform pg_temp.direct_check((select state='uncertain' and allowance_refunded_at is not null from video_erase_jobs where id=j) and (select state='cancelled' and cost_hold_released_at is not null from video_erase_stages where job_id=j and stage='erase'),'stale stage admission expires without starting a new job');
 -- The total mask+erase hold still obeys the unchanged240c batch ceiling.
 b:=gen_random_uuid(); update capture_assets set duration_s=4.8 where id=a;
 cfg:=jsonb_set(cfg,'{mask_unit_cost_cents}','25'::jsonb); cfg:=jsonb_set(cfg,'{erase_unit_cost_cents}','25'::jsonb);
 r:=video_erase_reserve_direct(o,u,l,b,a,gen_random_uuid(),repeat('9',64),4.8,cfg,'bria-video-v1');
 perform pg_temp.direct_check((r->'job'->>'cost_cents')::numeric=240,'combined rate fits unchanged exact batch ceiling');
 jj:=gen_random_uuid();insert into capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,duration_s) values(jj,l,'video','synthetic/more.mp4','renders',true,.01);
 perform pg_temp.direct_refuses(format('select video_erase_reserve_direct(%L,%L,%L,%L,%L,%L,%L,.01,%L,%L)',o,u,l,b,jj,gen_random_uuid(),repeat('0',64),cfg,'bria-video-v1'),'RP402');
 perform pg_temp.direct_check((select count(*) from video_erase_jobs where batch_id=b)=1,'over-budget direct request never consumes a receipt');
 update plan_entitlements set cogs_ceiling_cents=org_month_spend_cents(o)::int where plan='pro';
 perform pg_temp.direct_refuses(format('select video_erase_reserve_direct(%L,%L,%L,%L,%L,%L,%L,.01,%L,%L)',o,u,l,gen_random_uuid(),jj,gen_random_uuid(),repeat('1',64),cfg,'bria-video-v1'),'RP402');
end $$;
select 'PASS direct Bria SQL: '||n||' assertions' from direct_erase_assertions;
rollback;
