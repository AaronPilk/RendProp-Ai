\set ON_ERROR_STOP on
begin;
do $$begin if current_database()<>'rendprop_audit'or inet_server_addr()is not null then raise exception 'Owned socket-only fixture required';end if;end$$;
create temp table checks(name text primary key,ok boolean not null);
create function pg_temp.ok(v boolean,n text)returns void language plpgsql as $$begin if v is distinct from true then raise exception 'TEAM PRIVATE FAIL: %',n;end if;insert into checks values(n,true);end$$;
create function pg_temp.denied(q text,p text,n text)returns void language plpgsql as $$declare e text;begin begin execute q;exception when others then e:=sqlerrm;end;perform pg_temp.ok(e like p||'%',n);end$$;
create temp table f(owner_id uuid,sally uuid,tom uuid,outsider uuid,team uuid,sally_org uuid,tom_org uuid,out_org uuid,owner_listing uuid,sally_listing uuid,tom_listing uuid,legacy_sally uuid,legacy_tom uuid,sally_invite uuid,tom_invite uuid);
-- The fixture expands seats to three only to prove sibling isolation and a
-- shared financial boundary; no production allowance or price is changed.
select pg_temp.ok(not has_table_privilege('authenticated','public.team_private_libraries','SELECT,INSERT,UPDATE,DELETE')and not has_table_privilege('anon','public.team_private_libraries','SELECT,INSERT,UPDATE,DELETE')and(select relrowsecurity from pg_class where oid='public.team_private_libraries'::regclass)and not exists(select 1 from pg_policy where polrelid='public.team_private_libraries'::regclass),'Team relation is service-only deny-all RLS');
select pg_temp.ok(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'and p.proname in('library_access','listing_library_scope','list_library_listings','library_listing_ids','lead_library_scope','list_library_leads','list_library_provenance','library_usage_summary','library_media_delivery_admit','library_media_storage_reserve','bind_team_private_library','library_financial_actor','library_actor_billing_org','library_serving_envelope_admit')and(has_function_privilege('authenticated',p.oid,'EXECUTE')or has_function_privilege('anon',p.oid,'EXECUTE')or not p.prosecdef or p.proconfig is distinct from array['search_path=""'])),'Actor-taking library/financial RPCs have pinned service-only authority');
update public.plan_entitlements set seats=3 where plan='team';
insert into auth.users(id,email,is_anonymous,raw_user_meta_data)values
 ('e9010001-0000-4000-8000-000000000001','owner-team@fixture.invalid',false,'{"name":"Team Owner"}'),
 ('e9010001-0000-4000-8000-000000000002','sally-team@fixture.invalid',false,'{"name":"Sally"}'),
 ('e9010001-0000-4000-8000-000000000003','tom-team@fixture.invalid',false,'{"name":"Tom"}'),
 ('e9010001-0000-4000-8000-000000000004','outsider-team@fixture.invalid',false,'{"name":"Other"}');
insert into f select 'e9010001-0000-4000-8000-000000000001','e9010001-0000-4000-8000-000000000002','e9010001-0000-4000-8000-000000000003','e9010001-0000-4000-8000-000000000004',
 (select org_id from public.memberships where user_id='e9010001-0000-4000-8000-000000000001'),
 (select org_id from public.memberships where user_id='e9010001-0000-4000-8000-000000000002'),
 (select org_id from public.memberships where user_id='e9010001-0000-4000-8000-000000000003'),
 (select org_id from public.memberships where user_id='e9010001-0000-4000-8000-000000000004'),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),null,null;
update public.orgs set plan='team',plan_source='manual',name='Owner Team'where id=(select team from f);
insert into public.listings(id,org_id,agent_id,address)select owner_listing,team,owner_id,'Owner original'from f;
insert into public.listings(id,org_id,agent_id,address)select sally_listing,sally_org,sally,'Sally original'from f;
insert into public.listings(id,org_id,agent_id,address)select tom_listing,tom_org,tom,'Tom original'from f;
insert into public.leads(id,org_id,listing_id,name)select 'e9010002-0000-4000-8000-000000000001',sally_org,sally_listing,'Own inquiry'from f;
grant all on checks,f to service_role,authenticated;
set local role service_role;
do $$declare x record;r jsonb;begin select *into x from f;
 r:=public.create_org_invite(x.owner_id,x.team,null,'agent',repeat('a',64));update f set sally_invite=(r->>'id')::uuid;
 r:=public.accept_org_invite(x.sally,repeat('a',64));
 perform pg_temp.ok((r->>'org_id')::uuid=x.sally_org and r->>'role'='owner','accept keeps original private library');
 r:=public.create_org_invite(x.owner_id,x.team,null,'agent',repeat('b',64));update f set tom_invite=(r->>'id')::uuid;
 r:=public.accept_org_invite(x.tom,repeat('b',64));
 perform pg_temp.ok((r->>'org_id')::uuid=x.tom_org,'second acceptance private library');
 perform pg_temp.ok(public.library_billing_org(x.sally_org)=x.team and public.library_billing_org(x.tom_org)=x.team,'both finite libraries share parent billing');
 perform pg_temp.ok(public.team_library_owner(x.sally_org)is null and public.team_library_owner(x.tom_org)is null,'beneficiary projected Team cannot host another Team');
 perform pg_temp.ok((public.workspace_directory(x.sally,null)->'workspaces')=jsonb_build_array((public.workspace_directory(x.sally,null)->'workspaces')->0)
 and jsonb_array_length(public.workspace_directory(x.sally,null)->'workspaces')=1,'Sally directory has one private library');
 perform pg_temp.ok(not(public.workspace_directory(x.sally,null)->>'can_switch_agent_libraries')::boolean,'Sally cannot switch sibling libraries');
 perform pg_temp.ok(jsonb_array_length(public.workspace_directory(x.owner_id,null)->'workspaces')=3,'actual owner directory includes both linked agent libraries');
 perform pg_temp.ok((public.workspace_directory(x.owner_id,null)->>'can_switch_agent_libraries')::boolean,'actual owner switching capability explicit');
 r:=public.library_access(x.owner_id,x.sally_org);
 perform pg_temp.ok(r->>'actor_id'=x.owner_id::text and r->>'role'='team_owner'and r->>'access_mode'='team_owner'and(r->>'can_write')::boolean,'delegated content actor and write capability');
 perform pg_temp.ok(not(r->>'can_manage_subscription')::boolean,'delegated library cannot manage agent subscription');
 perform pg_temp.ok(not(public.library_access(x.sally,x.sally_org)->>'can_manage_subscription')::boolean,'beneficiary cannot manage parent subscription');
 perform pg_temp.ok((public.library_access(x.owner_id,x.team)->>'can_manage_subscription')::boolean,'parent owner retains genuine billing control');
 r:=public.select_workspace(x.owner_id,x.sally_org);
 perform pg_temp.ok(r->>'org_name'='Sally'and(public.workspace_directory(x.owner_id,null)->>'billing_org_id')::uuid=x.team,'purchase root stable while viewing agent');
 perform pg_temp.denied(format('select public.select_workspace(%L,%L)',x.sally,x.tom_org),'RP403:','Sally cannot select Tom');
 perform pg_temp.denied(format('select public.select_workspace(%L,%L)',x.sally,x.team),'RP403:','Sally cannot select owner shared Team');
 perform pg_temp.denied(format('select public.library_access(%L,%L)',x.outsider,x.sally_org),'RP403:','unrelated private owner cannot delegate');
 perform pg_temp.ok((select plan='free'and plan_source is null from public.orgs where id=x.sally_org),'stored private plan unchanged');
 perform pg_temp.ok((select org_id=x.sally_org and agent_id=x.sally from public.listings where id=x.sally_listing),'original listing identity unchanged');
end$$;
reset role;
-- Historical Team-org rows are retained; their logical library follows agent.
insert into public.listings(id,org_id,agent_id,address)select legacy_sally,team,sally,'Legacy Sally'from f;
insert into public.listings(id,org_id,agent_id,address)select legacy_tom,team,tom,'Legacy Tom'from f;
insert into public.leads(id,org_id,listing_id,name)select 'e9010002-0000-4000-8000-000000000002',team,legacy_sally,'Legacy inquiry'from f;
insert into public.leads(id,org_id,listing_id,name)select 'e9010002-0000-4000-8000-000000000003',team,legacy_tom,'Other inquiry'from f;
insert into public.capture_assets(listing_id,kind,storage_key,uploaded)select l.id,'photo','uploads/'||l.org_id||'/'||l.id||'/fixture.jpg',true from public.listings l where l.id in(select owner_listing from f union select sally_listing from f union select tom_listing from f union select legacy_sally from f union select legacy_tom from f);
insert into public.photos(listing_id,original_key)select l.id,'uploads/'||l.org_id||'/'||l.id||'/fixture.jpg'from public.listings l where l.id in(select owner_listing from f union select sally_listing from f union select tom_listing from f union select legacy_sally from f union select legacy_tom from f);
set local role service_role;
do $$declare x record;r jsonb;begin select *into x from f;
 r:=public.listing_library_scope(x.sally,x.legacy_sally);
 perform pg_temp.ok((r->>'org_id')::uuid=x.team and(r->>'library_org_id')::uuid=x.sally_org and(r->>'billing_org_id')::uuid=x.team,'legacy scope retains source org with private grouping');
 r:=public.list_library_listings(x.sally,x.sally_org,500,0);
 perform pg_temp.ok(r->>'actor_id'=x.sally::text and(r->>'total')::integer=2 and jsonb_array_length(r->'listings')=2,'private library aggregates own original and legacy rows');
 perform pg_temp.ok(not exists(select 1 from jsonb_array_elements(r->'listings')l where l->>'agent_id'<>x.sally::text),'aggregated list excludes sibling and owner rows');
 r:=public.list_library_listings(x.owner_id,x.sally_org,1,0);
 perform pg_temp.ok((r->>'total')::integer=2 and(r->>'next_offset')::integer=1,'owner delegated pagination complete');
 perform pg_temp.denied(format('select public.listing_library_scope(%L,%L)',x.sally,x.legacy_tom),'RP403:','legacy source org cannot expose Tom');
 perform pg_temp.denied(format('select public.list_library_listings(%L,%L,501,0)',x.owner_id,x.sally_org),'RP400:','pagination bounded at 500');
 perform pg_temp.ok(jsonb_array_length(public.list_library_leads(x.sally,x.sally_org))=2,'inbox aggregates own private and legacy inquiries');
 r:=public.lead_library_scope(x.owner_id,'e9010002-0000-4000-8000-000000000002');
 perform pg_temp.ok((r->>'org_id')::uuid=x.team and(r->>'library_org_id')::uuid=x.sally_org and(r->>'can_write')::boolean,'owner delegated lead preserves physical source');
 perform pg_temp.ok(cardinality(public.library_listing_ids(x.sally,x.sally_org))=2,'compliance ID scope includes own legacy listing');
 perform pg_temp.denied(format('select public.lead_library_scope(%L,%L)',x.sally,'e9010002-0000-4000-8000-000000000003'),'RP403:','inbox scope denies sibling inquiry');
end$$;
reset role;
-- Raw authenticated REST/RLS is an independent privacy boundary.
select set_config('request.jwt.claim.sub',(select sally::text from f),true);
set local role authenticated;
select pg_temp.ok((select count(*)=2 from public.listings),'raw REST lists only own original and own legacy');
select pg_temp.ok((select count(*)=0 from public.listings where id=(select tom_listing from f)),'raw REST denies Tom private listing');
select pg_temp.ok((select count(*)=0 from public.listings where id=(select owner_listing from f)),'raw REST denies owner listing');
select pg_temp.ok((select count(*)=0 from public.listings where id=(select legacy_tom from f)),'raw REST denies legacy Tom listing');
select pg_temp.ok((select count(*)=2 from public.leads),'raw REST inquiry scope excludes sibling');
select pg_temp.ok((select count(*)=2 from public.capture_assets),'cached parent raw REST assets expose only own media');
select pg_temp.ok((select count(*)=2 from public.photos),'cached parent raw REST photos exclude owner and sibling');
select pg_temp.ok((public.set_lead_status('e9010002-0000-4000-8000-000000000002','contacted')).status='contacted','raw RPC can update own legacy inquiry');
select pg_temp.denied('select public.set_lead_status(''e9010002-0000-4000-8000-000000000003'',''won'')','RP404:','raw RPC denies sibling inquiry update');
select pg_temp.denied(format('select public.library_access(%L,%L)',(select sally from f),(select sally_org from f)),'permission denied','actor-taking RPC denied authenticated');
reset role;
select set_config('request.jwt.claim.sub',(select owner_id::text from f),true);
set local role authenticated;
select pg_temp.ok((select count(*)=5 from public.listings),'actual Team owner raw RLS can see exactly authorized content');
insert into public.listings(org_id,agent_id,address)select sally_org,sally,'Owner creates for Sally'from f;
select pg_temp.ok((select count(*)=1 from public.listings where address='Owner creates for Sally'and agent_id=(select sally from f)),'delegated creation preserves listing agent');
update public.orgs set name='Hijack'where id=(select sally_org from f);
select pg_temp.ok((select count(*)=0 from public.orgs where id=(select sally_org from f)),'delegated content cannot read private account billing metadata');
reset role;
select pg_temp.ok((select name='Sally'from public.orgs where id=(select sally_org from f)),'delegated content does not grant private org branding update');
-- Real FAL/direct reflection reservation uses one parent clip allowance. The
-- provider calls are synthetic SQL claims, not network dispatches. A definite
-- no-charge stage failure/cancel refunds only its exact admitted parent window.
set local role service_role;
do $$declare x record;r jsonb;j uuid;a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();old_cap integer;cfg jsonb:= '{"mask_unit_cost_cents":2,"erase_unit_cost_cents":4.5,"price_version":"fixture-v1","output_hosts":["outputs.example.com"]}';begin select *into x from f;
 select reels_per_month into old_cap from public.plan_entitlements where plan='team';
 update public.plan_entitlements set reels_per_month=1 where plan='team';
 insert into public.capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,duration_s)values(a,x.sally_listing,'video','fixture/sally.mp4','renders',true,4),(b,x.tom_listing,'video','fixture/tom.mp4','renders',true,4);
 r:=public.video_erase_reserve(x.sally_org,x.sally,x.sally_listing,gen_random_uuid(),a,gen_random_uuid(),repeat('f',64),4);j:=(r->'job'->>'id')::uuid;
 perform pg_temp.ok((r->>'dispatch')::boolean and(select billing_org_id=x.team and org_id=x.sally_org from public.video_erase_jobs where id=j),'reflection FAL preserves content org and parent financial stamp');
 perform pg_temp.ok((select count=1 from public.rate_limits where key='reelmo:'||x.team)and not exists(select 1 from public.rate_limits where key in('reelmo:'||x.sally_org,'reelmo:'||x.tom_org)),'reflection clip allowance is one parent meter');
 r:=public.video_erase_quote(x.tom_org,x.tom,x.tom_listing);
 perform pg_temp.ok(not(r->>'available')::boolean and(r->>'remaining_clips')::integer=0,'reflection quote exposes actual shared remaining allowance');
 perform pg_temp.denied(format('select public.video_erase_reserve_direct(%L,%L,%L,%L,%L,%L,%L,4,%L,%L)',x.tom_org,x.tom,x.tom_listing,gen_random_uuid(),b,gen_random_uuid(),repeat('e',64),cfg,'bria-video-v1'),'RP402:','second agent direct reflection cannot clone last parent clip');
 perform public.video_erase_finish(j,'failed',null,null,null,'Synthetic definite no-charge rejection',true);
 perform pg_temp.ok((select count=0 from public.rate_limits where key='reelmo:'||x.team)and public.serving_ceiling_spent_cents(x.team,null,null)=0,'FAL failure refunds parent clip and releases only no-charge hold');
 r:=public.video_erase_reserve_direct(x.tom_org,x.tom,x.tom_listing,gen_random_uuid(),b,gen_random_uuid(),repeat('d',64),4,cfg,'bria-video-v1');j:=(r->'job'->>'id')::uuid;
 perform pg_temp.ok((r->>'dispatch')::boolean and(select billing_org_id=x.team and org_id=x.tom_org from public.video_erase_jobs where id=j)and(select count=1 from public.rate_limits where key='reelmo:'||x.team),'direct reflection reuses legitimately refunded parent clip');
 perform public.video_erase_finish_stage(j,'mask','failed',null,null,true);
 perform pg_temp.ok((select count=0 from public.rate_limits where key='reelmo:'||x.team)and public.serving_ceiling_spent_cents(x.team,null,null)=0 and(select bool_and(cost_hold_released_at is not null)from public.video_erase_stages where job_id=j),'direct definite rejection refunds exact parent clip and unpaid stages');
 r:=public.video_erase_reserve(x.sally_org,x.sally,x.sally_listing,gen_random_uuid(),a,gen_random_uuid(),repeat('c',64),4);j:=(r->'job'->>'id')::uuid;
 perform public.video_erase_cancel(x.sally_org,x.sally,j,null);
 perform pg_temp.ok((select count=0 from public.rate_limits where key='reelmo:'||x.team),'reflection cancellation refunds immutable parent meter');
 perform public.video_erase_cancel(x.sally_org,x.sally,j,null);
 perform pg_temp.ok((select count=0 from public.rate_limits where key='reelmo:'||x.team),'replayed reflection cancellation cannot mint parent quota');
 perform public.video_erase_finish(j,'failed',null,null,null,'Synthetic definite no-charge rejection',true);
 update public.plan_entitlements set reels_per_month=old_cap where plan='team';
 update public.memberships set role='admin'where org_id=x.team and user_id=x.tom;
 perform pg_temp.denied(format('select public.remove_org_member(%L,%L,%L)',x.team,x.tom,x.sally),'RP403:','historical Team admin cannot remove an owner-linked agent');
 perform pg_temp.ok(public.library_team_owner(x.sally_org)=x.owner_id,'denied admin removal preserves explicit owner relationship');
 update public.memberships set role='agent'where org_id=x.team and user_id=x.tom;
end$$;
reset role;
-- Owner transfer/co-owner ambiguity and seat revocation are freshly denied.
set local role service_role;
do $$declare x record;old_role text;begin select *into x from f;
 update public.memberships set role='admin'where org_id=x.team and user_id=x.owner_id;
 perform pg_temp.ok(public.library_team_owner(x.sally_org)is null and public.library_billing_org(x.sally_org)=x.sally_org,'ownership removal disables content grant and future finite projection');
 perform pg_temp.denied(format('select public.library_access(%L,%L)',x.owner_id,x.sally_org),'RP403:','former owner cannot use stale delegated library');
 update public.memberships set role='owner'where org_id=x.team and user_id=x.owner_id;
 update public.memberships set role='owner'where org_id=x.team and user_id=x.tom;
 perform pg_temp.ok(public.team_library_owner(x.team)is null,'co-owner ambiguity has no Team owner authority');
 perform pg_temp.denied(format('select public.library_access(%L,%L)',x.owner_id,x.sally_org),'RP403:','co-owner ambiguity denies delegation');
 update public.memberships set role='agent'where org_id=x.team and user_id=x.tom;
 -- Normal finite dollars are not cloned into child accounts.
 perform public.serving_cost_reserve(x.sally,x.sally_org,'team-fixture-001','copy.caption:0','gemini','fixture',repeat('c',64),3001,'fixture-v1');
 perform pg_temp.ok(public.serving_ceiling_spent_cents(x.team,null,null)=3001 and public.serving_ceiling_spent_cents(x.tom_org,null,null)=3001,'parent and second child observe same admitted liability');
 perform pg_temp.denied(format('select public.serving_cost_reserve(%L,%L,%L,%L,%L,%L,%L,3001,%L)',x.tom,x.tom_org,'team-fixture-002','copy.caption:0','gemini','fixture',repeat('d',64),'fixture-v1'),'RP402:','second child cannot clone parent financial allowance');
 perform pg_temp.ok((select billing_org_id=x.team and org_id=x.sally_org from public.serving_cost_reservations where request_key='team-fixture-001'),'liability retains original content org and immutable parent billing');
 perform public.remove_org_member(x.team,x.owner_id,x.sally);
 perform pg_temp.ok(public.library_billing_org(x.sally_org)=x.sally_org,'removed seat loses future parent allowance');
 perform pg_temp.ok(public.serving_ceiling_spent_cents(x.team,null,null)=3001,'seat removal cannot erase prior parent liability');
 perform pg_temp.denied(format('select public.library_access(%L,%L)',x.owner_id,x.sally_org),'RP403:','removed seat loses owner cross-library access');
 perform pg_temp.ok(public.library_content_access(x.sally,x.sally_org,true),'removed agent retains own original private library');
 insert into public.render_jobs(id,listing_id,capture_asset_id)select 'e9010003-0000-4000-8000-000000000001',x.legacy_sally,a.id from public.capture_assets a where a.listing_id=x.legacy_sally limit 1;
 insert into public.render_jobs(id,listing_id,capture_asset_id,status)select 'e9010003-0000-4000-8000-000000000002',x.legacy_sally,a.id,'ready'from public.capture_assets a where a.listing_id=x.legacy_sally limit 1;
 insert into public.renders(id,job_id,listing_id,slug,duration_s)values('e9010003-0000-4000-8000-000000000003','e9010003-0000-4000-8000-000000000002',x.legacy_sally,'fixture-private-legacy-render',10);
 insert into public.media_provenance(id,org_id,listing_id,kind,label,disclosure)values('e9010003-0000-4000-8000-000000000004',x.team,x.legacy_sally,'other','Original retained disclosure','AI-assisted edit');
 perform set_config('request.jwt.claim.sub',x.owner_id::text,true);
 perform pg_temp.denied('select public.fail_render_job(''e9010003-0000-4000-8000-000000000001'',''No access'')','RP403:','former owner cannot mutate removed agent legacy job');
 perform pg_temp.denied('select public.set_render_chapters(''e9010003-0000-4000-8000-000000000003'',''[]'')','RP404:','former owner cannot mutate removed agent legacy chapters');
 perform pg_temp.denied(format('select public.record_provenance(%L,%L,%L)',x.legacy_sally,'declutter','Unauthorized label'),'RP403:','former owner cannot mint removed agent legacy provenance');
 perform pg_temp.denied('select public.set_provenance_media(''e9010003-0000-4000-8000-000000000004'',null,null,''Unauthorized label'')','RP404:','former owner cannot change removed agent legacy disclosure');
 perform set_config('request.jwt.claim.sub',x.sally::text,true);
 perform pg_temp.ok((public.fail_render_job('e9010003-0000-4000-8000-000000000001','Own request')).status='failed','removed agent can manage own retained legacy job');
 perform pg_temp.ok(public.set_render_chapters('e9010003-0000-4000-8000-000000000003','[{"label":"Living","t_ms":0,"sort":0}]')=1,'removed agent can edit own retained legacy chapters');
 perform pg_temp.ok((public.record_provenance(x.legacy_sally,'declutter','Own cleaned room')).listing_id=x.legacy_sally,'removed agent may record own retained legacy provenance');
 perform pg_temp.ok((public.set_provenance_media('e9010003-0000-4000-8000-000000000004',null,null,'Own reviewed label')).label='Own reviewed label','removed agent may update own retained legacy disclosure');
 perform set_config('request.jwt.claim.sub',x.owner_id::text,true);

 perform pg_temp.ok((select count(*)=1 from public.listings where id=x.sally_listing and org_id=x.sally_org),'seat removal preserves original content');
 perform pg_temp.ok((public.list_library_listings(x.sally,x.sally_org)->>'total')::integer=3,'removed agent keeps original and historical assigned listings');
 perform pg_temp.ok(public.listing_content_access(x.sally,x.legacy_sally,true),'removed agent retains own legacy write access');
 perform pg_temp.denied(format('select public.listing_library_scope(%L,%L)',x.owner_id,x.legacy_sally),'RP403:','former Team owner cannot read removed agent legacy content');
 perform pg_temp.ok(jsonb_array_length(public.list_library_leads(x.sally,x.sally_org))=2,'removed agent retains legacy inquiry inbox');
 perform pg_temp.denied(format('select public.lead_library_scope(%L,%L)',x.owner_id,'e9010002-0000-4000-8000-000000000002'),'RP403:','former owner cannot read removed agent inquiry');
 perform public.serving_cost_reserve(x.sally,x.team,'retained-legacy-001','copy.caption:0','gemini','fixture',repeat('e',64),10,'fixture-v1');
 perform pg_temp.ok((select billing_org_id=x.sally_org and org_id=x.team from public.serving_cost_reservations where request_key='retained-legacy-001'),'new legacy processing uses own allowance after removal');
 perform pg_temp.ok(public.serving_ceiling_spent_cents(x.team,null,null)=3001,'retained legacy processing does not debit former Team');
 perform public.serving_cost_finish(x.sally,x.sally_org,'team-fixture-001','copy.caption:0','succeeded');
 insert into public.cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,idempotency_key,meta)
 values(x.sally_org,'caption','gemini','fixture',1,7.1,7.1,'different-receipt-key',jsonb_build_object('request_key','team-fixture-001','stage','copy.caption:0','actor_id',x.sally));
 perform pg_temp.ok((select billing_org_id=x.team from public.cost_ledger where idempotency_key='different-receipt-key'),'late exact meta-key receipt retains original parent liability after removal');
 perform pg_temp.ok((select ledger_id is not null from public.serving_cost_reservations where request_key='team-fixture-001'),'late receipt exact identity binds succeeded hold');
 perform pg_temp.ok(public.serving_ceiling_spent_cents(x.team,null,null)=7.1 and public.serving_ceiling_spent_cents(x.sally_org,null,null)=10,'receipt replaces only original parent hold with ledger cost');
 perform pg_temp.ok(public.library_storage_billing_org(x.team,'renders','renders/'||x.team||'/'||x.legacy_sally||'/declutter.jpg')=x.sally_org,'retained original namespace storage resolves own current liability');
 perform pg_temp.ok(not exists(select 1 from pg_constraint c where c.contype='f'and c.conrelid in('public.cost_ledger'::regclass,'public.serving_cost_reservations'::regclass,'public.media_storage_receipts'::regclass)and pg_get_constraintdef(c.oid)like '%billing_org_id%'),'liability identity does not block physical account cleanup');

end$$;
reset role;
select count(*)from checks;
select name||'|'||ok from checks order by name;
rollback;
