-- Disposable test. Staging remains dormant until a matching client/catalog
-- launch, but an activated quote must bind one photo and its saved QC only.
begin;
create temporary table stage_credit_checks(n integer not null default 0);
insert into stage_credit_checks default values;
grant all on stage_credit_checks to service_role;
create function pg_temp.stage_ok(v boolean,label text) returns void language plpgsql as $$
begin
 if v is distinct from true then raise exception 'STAGE CREDIT FAIL: %',label;end if;
 update stage_credit_checks set n=n+1;
end$$;
create function pg_temp.stage_refuses(statement text,needle text,label text)
returns void language plpgsql as $$
begin
 begin execute statement;exception when others then
  if position(needle in sqlerrm)>0 then perform pg_temp.stage_ok(true,label);return;end if;
  raise;
 end;
 raise exception 'STAGE CREDIT FAIL: admitted %',label;
end$$;

insert into auth.users(id,email,is_anonymous)values
 ('52111111-1111-4111-8111-111111111111','stage-credit@example.invalid',false);
insert into public.orgs(id,name,plan,plan_source)values
 ('52aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Stage credit fixture','free',null);
insert into public.memberships(user_id,org_id,role)values
 ('52111111-1111-4111-8111-111111111111','52aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','owner');
insert into public.credit_grants(org_id,environment,source,reference,product_id,
 granted_credits,remaining_credits,expires_at)values
 ('52aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Production','topup','stage-credit-fixture',
 'com.rendprop.app.credits.100',100,100,null);

set local role service_role;
do $$
declare actor uuid:='52111111-1111-4111-8111-111111111111';
 org uuid:='52aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 key text:='stage-credit-0001'; result jsonb;
begin
 perform pg_temp.stage_ok((select credits=15 and not active from public.credit_tariffs
   where operation='photo.stage' and version='photo-stage-v1'),
   'fifteen-credit Stage quote starts dormant');
 result:=public.serving_operation_begin(actor,org,key,'/ai-photo',repeat('a',64));
 perform pg_temp.stage_refuses(format(
   'select public.credit_wallet_reserve(%L,%L,%L,%L,%L,%L)',
   actor,org,'Production',key,'photo.stage','photo-stage-v1'),
   'RP400:','dormant Stage quote cannot charge customers');
end$$;
reset role;
update public.credit_tariffs set active=true where operation='photo.stage' and version='photo-stage-v1';
with evidence as (
 insert into public.photo_edit_evidence(org_id,actor_id,library_org_id,
   request_key,request_sha256,policy,edit,input)
 values('52aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   '52111111-1111-4111-8111-111111111111',
   '52aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','stage-credit-0001',repeat('a',64),
   'photo-fixed-features-v1','stage','{}'::jsonb) returning id
)
insert into public.photo_quality_checks(evidence_id,policy)
select id,'photo-fixed-features-v1' from evidence;
set local role service_role;
do $$
declare actor uuid:='52111111-1111-4111-8111-111111111111';
 org uuid:='52aaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
 key text:='stage-credit-0001'; result jsonb; check_id uuid; qc_key text;
begin
 result:=public.credit_wallet_reserve(actor,org,'Production',key,'photo.stage','photo-stage-v1');
 perform pg_temp.stage_ok(result->>'reserved'='true' and result->>'credits'='15' and
   (public.credit_wallet_state(org,'Production')->>'total_available')::integer=85,
   'activated Stage uses fifteen purchased credits once');
 perform pg_temp.stage_refuses(format(
   'select public.credit_serving_cost_reserve(%L,%L,%L,%L,%L,%L,%L,1,%L,%L,%L,%L)',
   actor,org,key,'photo.declutter:0','gemini','gemini-3-pro-image',repeat('b',64),
   'quoted-pro4k',org,key,'Production'),
   'RP403:','Stage credit cannot fund Declutter supplier work');
 result:=public.credit_serving_cost_reserve(actor,org,key,'photo.stage:0',
   'gemini','gemini-3-pro-image',repeat('b',64),30.5536,'quoted-pro4k',org,key,'Production');
 perform pg_temp.stage_ok(result->>'budget'='credits','Stage supplier is bound to wallet hold');
 result:=public.serving_cost_finish(actor,org,key,'photo.stage:0','succeeded',null);
 result:=public.credit_wallet_finish(actor,org,'Production',key,'settled');
 select q.id into check_id from public.photo_quality_checks q
   join public.photo_edit_evidence e on e.id=q.evidence_id
   where e.org_id=org and e.request_key=key and e.edit='stage';
 qc_key:='photo-qc:'||check_id::text;
 result:=public.serving_operation_begin(actor,org,qc_key,'/ai-photo/judge',repeat('c',64));
 result:=public.credit_serving_cost_reserve(actor,org,qc_key,'photo.qc:0',
   'anthropic','claude-sonnet-5',repeat('d',64),10.8624,'quoted-qc',org,key,'Production');
 perform pg_temp.stage_ok(result->>'budget'='credits' and
   (public.credit_wallet_state(org,'Production')->>'total_available')::integer=85,
   'saved Stage judge shares the original quote without a second debit');
 perform pg_temp.stage_refuses(format(
   'select public.credit_serving_cost_reserve(%L,%L,%L,%L,%L,%L,%L,40,%L,%L,%L,%L)',
   actor,org,key,'photo.stage:1','gemini','gemini-3-pro-image',repeat('e',64),
   'quoted-pro4k',org,key,'Production'),
   'RP402:','supplier attempts and judge together cannot exceed 75 cents');
end$$;
reset role;
select jsonb_build_object('passed',true,'assertions',(select n from stage_credit_checks));
rollback;
