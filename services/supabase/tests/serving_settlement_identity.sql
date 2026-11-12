\set ON_ERROR_STOP on
-- Exact attempt receipt regressions; synthetic fixtures, no providers, rollback.
begin;
create temporary table settlement_assertions(n integer not null default 0);insert into settlement_assertions default values;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin
 if v is distinct from true then raise exception 'SETTLEMENT-IDENTITY FAIL: %',label;end if;
 update settlement_assertions set n=n+1;
end$$;
insert into auth.users(id,email,is_anonymous,email_confirmed_at)values
('f5100000-0000-4000-8000-000000000001','settlement@example.invalid',false,now()),
('f5100000-0000-4000-8000-000000000002','settlement-other@example.invalid',false,now());
insert into orgs(id,name,plan)values
('f5200000-0000-4000-8000-000000000001','Synthetic winning copy fallback','free'),
('f5200000-0000-4000-8000-000000000002','Synthetic incomplete identity','free'),
('f5200000-0000-4000-8000-000000000003','Synthetic duplicate receipt','free'),
('f5200000-0000-4000-8000-000000000004','Synthetic unconfirmed attempt','free'),
('f5200000-0000-4000-8000-000000000005','Synthetic ambiguous actor identity','free');
insert into memberships(user_id,org_id,role)select 'f5100000-0000-4000-8000-000000000001',id,'owner'from orgs where id::text like 'f5200000-%';
update app_config set value=jsonb_build_object('mode','ceiling','free_published_listings',1)where key='serving_mode';
-- The original55→7.1 failure, now with exact winning identity recorded by ai-copy.
insert into serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,budget_source,state,created_at)values
('f5200000-0000-4000-8000-000000000001','f5100000-0000-4000-8000-000000000001','copy-fallback','copy.reel_script:initial:0','openai','gpt-6-astra',repeat('a',64),'synthetic',50,'ceiling','uncertain',now()-interval '1 second'),
('f5200000-0000-4000-8000-000000000001','f5100000-0000-4000-8000-000000000001','copy-fallback','copy.reel_script:initial:1','anthropic','claude-sonnet-5',repeat('b',64),'synthetic',5,'ceiling','succeeded',now());
insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)values
('f5200000-0000-4000-8000-000000000001','copy_assist','anthropic','claude-sonnet-5',1,2.1,2.1,'{"request_key":"copy-fallback","stage":"copy.reel_script:initial:1"}');
select pg_temp.ok((select ledger_id is null from serving_cost_reservations where org_id='f5200000-0000-4000-8000-000000000001'and provider='openai'),'uncertain primary50c remains unbound');
select pg_temp.ok((select ledger_id is not null from serving_cost_reservations where org_id='f5200000-0000-4000-8000-000000000001'and provider='anthropic'),'only the successful winning fallback binds');
select pg_temp.ok(serving_ceiling_spent_cents('f5200000-0000-4000-8000-000000000001',null,null)=52.1,'unknown primary50c plus winning2.1c are both accounted');
-- Missing stage on the old ai-copy shape must retain BOTH holds; no key-only or FIFO substitution.
insert into serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,budget_source,state,created_at)values
('f5200000-0000-4000-8000-000000000002','f5100000-0000-4000-8000-000000000001','legacy-copy','copy.reel_script:initial:0','openai','gpt-6-astra',repeat('c',64),'synthetic',50,'ceiling','uncertain',now()-interval '1 second'),
('f5200000-0000-4000-8000-000000000002','f5100000-0000-4000-8000-000000000001','legacy-copy','copy.reel_script:initial:1','anthropic','claude-sonnet-5',repeat('d',64),'synthetic',5,'ceiling','succeeded',now());
insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)values
('f5200000-0000-4000-8000-000000000002','copy_assist','anthropic','claude-sonnet-5',1,2.1,2.1,'{"request_key":"legacy-copy"}');
select pg_temp.ok((select bool_and(ledger_id is null)from serving_cost_reservations where org_id='f5200000-0000-4000-8000-000000000002'),'incomplete receipt cannot bind any predecessor');
select pg_temp.ok(serving_ceiling_spent_cents('f5200000-0000-4000-8000-000000000002',null,null)=57.1,'old key-only shape retains55c liability plus2.1c ledger');
-- A wrong request, stage, provider, model or keyless historical row cannot consume a matching successful hold.
insert into serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,budget_source,state)values
('f5200000-0000-4000-8000-000000000003','f5100000-0000-4000-8000-000000000001','photo-key','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('e',64),'synthetic',10,'ceiling','succeeded'),
('f5200000-0000-4000-8000-000000000003','f5100000-0000-4000-8000-000000000001','photo-key','photo.stage:1','fal','flux-pro/kontext',repeat('f',64),'synthetic',20,'ceiling','uncertain');
do $$declare shape jsonb;begin
 for shape in select * from jsonb_array_elements('[
  {"request_key":"wrong-key","stage":"photo.stage:0","provider":"gemini","model":"gemini-3.1-flash-image"},
  {"request_key":"photo-key","stage":"wrong-stage","provider":"gemini","model":"gemini-3.1-flash-image"},
  {"request_key":"photo-key","stage":"photo.stage:0","provider":"fal","model":"gemini-3.1-flash-image"},
  {"request_key":"photo-key","stage":"photo.stage:0","provider":"gemini","model":"wrong-model"},
  {"provider":"gemini","model":"gemini-3.1-flash-image"}]'::jsonb)loop
  insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)values
   ('f5200000-0000-4000-8000-000000000003','photo_edit',shape->>'provider',shape->>'model',1,1,1,shape-'provider'-'model');
  perform pg_temp.ok((select bool_and(ledger_id is null)from serving_cost_reservations where org_id='f5200000-0000-4000-8000-000000000003'),'mismatched or keyless receipt preserves holds: '||shape::text);
 end loop;
end$$;
insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)values
('f5200000-0000-4000-8000-000000000003','photo_edit','gemini','gemini-3.1-flash-image',1,6.7,6.7,'{"request_key":"photo-key","stage":"photo.stage:0"}');
select pg_temp.ok((select ledger_id is not null from serving_cost_reservations where org_id='f5200000-0000-4000-8000-000000000003'and stage='photo.stage:0'),'exact successful receipt binds its own stage');
insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)values
('f5200000-0000-4000-8000-000000000003','photo_edit','gemini','gemini-3.1-flash-image',1,6.7,6.7,'{"request_key":"photo-key","stage":"photo.stage:0"}');
select pg_temp.ok((select count(*)=1 from serving_cost_reservations where org_id='f5200000-0000-4000-8000-000000000003'and ledger_id is not null),'duplicate primary receipt cannot consume fallback');
select pg_temp.ok((select ledger_id is null from serving_cost_reservations where org_id='f5200000-0000-4000-8000-000000000003'and stage='photo.stage:1'),'uncertain fallback stays held after duplicate');
select pg_temp.ok(serving_ceiling_spent_cents('f5200000-0000-4000-8000-000000000003',null,null)=38.4,'only primary10c released; fallback20c plus all ledger rows counted');
-- Even exact identity cannot silently resolve an unconfirmed or rejected state.
insert into serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,budget_source,state)values
('f5200000-0000-4000-8000-000000000004','f5100000-0000-4000-8000-000000000001','unconfirmed','photo.stage:0','gemini','gemini-3.1-flash-image',repeat('a',64),'synthetic',20,'ceiling','uncertain');
insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)values
('f5200000-0000-4000-8000-000000000004','photo_edit','gemini','gemini-3.1-flash-image',1,6.7,6.7,'{"request_key":"unconfirmed","stage":"photo.stage:0"}');
select pg_temp.ok((select ledger_id is null from serving_cost_reservations where org_id='f5200000-0000-4000-8000-000000000004'),'uncertain exact receipt awaits explicit reconciliation');
-- The database key includes actor_id, but the receipt does not. Never choose
-- between two otherwise identical holds, even after a duplicate receipt.
insert into memberships(user_id,org_id,role)values
('f5100000-0000-4000-8000-000000000002','f5200000-0000-4000-8000-000000000005','agent');
insert into serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,budget_source,state)values
('f5200000-0000-4000-8000-000000000005','f5100000-0000-4000-8000-000000000001','same-actor-key','copy.reel_script:initial:0','anthropic','claude-sonnet-5',repeat('b',64),'synthetic',20,'ceiling','succeeded'),
('f5200000-0000-4000-8000-000000000005','f5100000-0000-4000-8000-000000000002','same-actor-key','copy.reel_script:initial:0','anthropic','claude-sonnet-5',repeat('c',64),'synthetic',5,'ceiling','succeeded');
insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)values
('f5200000-0000-4000-8000-000000000005','copy_assist','anthropic','claude-sonnet-5',1,2.1,2.1,'{"request_key":"same-actor-key","stage":"copy.reel_script:initial:0"}');
select pg_temp.ok((select bool_and(ledger_id is null)from serving_cost_reservations where org_id='f5200000-0000-4000-8000-000000000005'),'ambiguous actor identity cannot choose one hold');
select pg_temp.ok(serving_ceiling_spent_cents('f5200000-0000-4000-8000-000000000005',null,null)=27.1,'ambiguous identity retains25c holds plus2.1c ledger');
insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)values
('f5200000-0000-4000-8000-000000000005','copy_assist','anthropic','claude-sonnet-5',1,2.1,2.1,'{"request_key":"same-actor-key","stage":"copy.reel_script:initial:0"}');
select pg_temp.ok((select bool_and(ledger_id is null)from serving_cost_reservations where org_id='f5200000-0000-4000-8000-000000000005'),'duplicate ambiguous receipt still cannot consume either hold');
-- A legacy binding on actorA must not let its duplicate receipt release
-- actorB's same-key hold. Include already-bound records in ambiguity detection.
update serving_cost_reservations set ledger_id=(
 select id from cost_ledger where org_id='f5200000-0000-4000-8000-000000000005'limit 1
)where org_id='f5200000-0000-4000-8000-000000000005'and actor_id='f5100000-0000-4000-8000-000000000001';
insert into cost_ledger(org_id,feature,provider,model,units,unit_cost_cents,total_cents,meta)values
('f5200000-0000-4000-8000-000000000005','copy_assist','anthropic','claude-sonnet-5',1,2.1,2.1,'{"request_key":"same-actor-key","stage":"copy.reel_script:initial:0"}');
select pg_temp.ok((select ledger_id is null from serving_cost_reservations where org_id='f5200000-0000-4000-8000-000000000005'and actor_id='f5100000-0000-4000-8000-000000000002'),'duplicate already-bound actorA receipt cannot bind actorB');
select pg_temp.ok(not has_function_privilege('anon','public.cost_ledger_settle_serving_hold()','execute')and not has_function_privilege('authenticated','public.cost_ledger_settle_serving_hold()','execute'),'trigger helper is not tenant executable');
select jsonb_build_object('suite','serving_settlement_identity','assertions',n,'fallback_committed_cents',52.1,'incomplete_receipt_committed_cents',57.1)from settlement_assertions;
rollback;
