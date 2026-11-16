\set ON_ERROR_STOP on
begin;
do $$begin if inet_server_addr()is not null or current_database()<>'photo_feedback_proof'then raise exception'Use only the owned disposable photo_feedback_proof socket database';end if;end$$;
-- AI photo feedback loop (contract docs/handoff/PHOTO-FEEDBACK-DESIGN-20261017.md).
-- Closed synthetic evidence: no provider, no bytes, no network, everything
-- rolled back. Every output below is driven through the ACTUAL final-schema
-- photo journal (operation, evidence, retained source, recipe, candidate,
-- provenance, CPU lease, exact derivatives, saved judge context, funded bind,
-- settled paid verdict); verdict text and costs are synthetic fixtures.
-- Proves: wrong user/listing/library/role refusals, exact-version attribution,
-- idempotent offline resends and revisions, unknown historical provenance,
-- separate signals, consented regression cases, honest report denominators
-- with failed/retried/uncertain/unsettled attempts, untouched publication
-- authority, and deletion cascades.
-- BEGIN SETUP (reused verbatim by photo_feedback_pg.py for committed race fixtures)
create temp table checks(label text primary key);grant all on checks to service_role,authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception'PHOTOFB FAIL: %',label;end if;insert into checks values(label);end$$;
create function pg_temp.no(command text,needle text,label text)returns void language plpgsql as $$begin
 begin execute command;exception when others then
  if position(needle in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;
  raise exception'PHOTOFB FAIL wrong refusal for %: %',label,sqlerrm;
 end;raise exception'PHOTOFB FAIL allowed: %',label;end$$;
insert into auth.users(id,email,is_anonymous)values
 ('f8300000-0000-4000-8000-000000000001','photo-feedback-owner@fixture.invalid',false),
 ('f8300000-0000-4000-8000-000000000002','photo-feedback-other@fixture.invalid',false),
 ('f8300000-0000-4000-8000-000000000003','photo-feedback-editor@fixture.invalid',false),
 ('f8300000-0000-4000-8000-000000000004','photo-feedback-reader@fixture.invalid',false),
 ('f8300000-0000-4000-8000-000000000005','photo-feedback-guest@fixture.invalid',true),
 ('f8300000-0000-4000-8000-000000000006','photo-feedback-leaving@fixture.invalid',false),
 ('f8300000-0000-4000-8000-000000000007','photo-feedback-admin@fixture.invalid',false);
create temp table f as select
 'f8300000-0000-4000-8000-000000000001'::uuid a,'f8300000-0000-4000-8000-000000000002'::uuid b,'f8300000-0000-4000-8000-000000000003'::uuid e,
 'f8300000-0000-4000-8000-000000000004'::uuid r,'f8300000-0000-4000-8000-000000000005'::uuid g,'f8300000-0000-4000-8000-000000000006'::uuid d,
 'f8300000-0000-4000-8000-000000000007'::uuid m,
 (select org_id from memberships where user_id='f8300000-0000-4000-8000-000000000001'and role='owner'limit 1)o,
 (select org_id from memberships where user_id='f8300000-0000-4000-8000-000000000002'and role='owner'limit 1)o2,
 'f8300000-0000-4000-8000-000000000011'::uuid l1,'f8300000-0000-4000-8000-000000000012'::uuid l2,'f8300000-0000-4000-8000-000000000013'::uuid l3,
 'f8300000-0000-4000-8000-000000000041'::uuid h1,'f8300000-0000-4000-8000-000000000042'::uuid h2,
 'f8300000-0000-4000-8000-000000000043'::uuid calib,'f8300000-0000-4000-8000-000000000044'::uuid reel;
grant select on f to service_role,authenticated;
-- The feedback contract exercises retained paid outputs across three listings.
-- Give both synthetic libraries manual paid authority before the final-schema
-- listing admission trigger sees their first draft.
update orgs set plan='starter',plan_source='manual'
where id in(select o from f union select o2 from f);
insert into listings(id,org_id,agent_id,address)select l1,o,a,'Synthetic feedback property'from f;
insert into listings(id,org_id,agent_id,address)select l2,o2,b,'Synthetic other-library property'from f;
insert into listings(id,org_id,agent_id,address)select l3,o,a,'Synthetic second property'from f;
-- Editor (agent), reader (marketing), anonymous member, member with a pending
-- account deletion, and an admin, all in the owner's library.
insert into memberships(org_id,user_id,role)select o,e,'agent'from f union all select o,r,'marketing'from f union all select o,g,'agent'from f
 union all select o,d,'agent'from f union all select o,m,'admin'from f;
insert into deletion_requests(user_id,status)select d,'pending'from f;
update app_config set value=jsonb_set(value,'{enabled}','true')where key='photo_quality';
select pg_temp.ok((select count(*)=3 from pg_class where relname in('photo_output_feedback','photo_output_signals','photo_regression_cases')and relrowsecurity and not relforcerowsecurity),'feedback tables have RLS');
select pg_temp.ok(not exists(select 1 from pg_policy where polrelid in('photo_output_feedback'::regclass,'photo_output_signals'::regclass,'photo_regression_cases'::regclass)),'no RLS policy opens a client path');
select pg_temp.ok(not has_table_privilege('authenticated','photo_output_feedback','SELECT')and not has_table_privilege('anon','photo_output_signals','SELECT')and not has_table_privilege('authenticated','photo_regression_cases','SELECT'),'clients cannot read feedback, signals or cases');
select pg_temp.ok(not has_table_privilege('service_role','photo_output_feedback','INSERT')and not has_table_privilege('service_role','photo_output_feedback','UPDATE')and not has_table_privilege('service_role','photo_output_signals','INSERT')and not has_table_privilege('service_role','photo_regression_cases','DELETE'),'service table writes revoked outside the RPCs');
select pg_temp.ok(not has_function_privilege('authenticated','photo_feedback_submit(uuid,uuid,uuid,text,text,integer,text,text[],text,text)','EXECUTE')and not has_function_privilege('anon','photo_feedback_report(timestamptz,timestamptz)','EXECUTE')and not has_function_privilege('authenticated','photo_quality_set_recipe(uuid,uuid,text,text)','EXECUTE')and not has_function_privilege('authenticated','photo_regression_cases_for_review(text)','EXECUTE'),'clients cannot call feedback RPCs directly');

create function pg_temp.input()returns jsonb language sql as $$select jsonb_build_object('sha256',repeat('a',64),'bytes',60000,'mime','image/jpeg','width',1024,'height',768)$$;
-- One prospective generation through the actual journal. All share ONE
-- source photo (same prepared bytes), so outputs are told apart only by their
-- exact version identity.
create function pg_temp.generate(label text,p_edit text,p_style text,p_recipe text,p_provider text,p_model text,p_stage int,p_actor uuid default null,p_listing uuid default null)returns jsonb language plpgsql as $$
declare v_actor uuid:=coalesce(p_actor,(select a from f));v_listing uuid:=coalesce(p_listing,(select l1 from f));v_org uuid;x jsonb;ev uuid;begin
 select org_id into v_org from listings where id=v_listing;
 perform serving_operation_begin(v_actor,v_org,'photo-fb:'||label,'photo_edit',repeat('d',64));
 x:=photo_quality_begin(v_actor,v_org,'photo-fb:'||label,v_listing,p_edit,p_style,null,pg_temp.input(),'[]'::jsonb);ev:=(x#>>'{evidence,id}')::uuid;
 perform photo_quality_evidence_receipt(v_actor,ev,'input','"prepared-'||label||'"');
 if p_recipe is not null then perform photo_quality_set_recipe(v_actor,ev,p_recipe,encode(sha256(convert_to('final prompt '||label,'UTF8')),'hex'));end if;
 if p_provider is not null then
  perform photo_quality_evidence_reserve(v_actor,ev,jsonb_build_object('sha256',encode(sha256(convert_to('candidate '||label,'UTF8')),'hex'),'bytes',800000,'mime','image/png',
   'width',4096,'height',3072,'generation_stage','photo.'||p_edit||':'||p_stage,'provider',p_provider,'model',p_model));
  perform photo_quality_evidence_receipt(v_actor,ev,'output','"candidate-'||label||'"');
 end if;
 return(select to_jsonb(v)from photo_edit_evidence v where v.id=ev);end$$;
-- Paid-attempt and modeled-ledger fixtures (metadata only).
create function pg_temp.attempt(ev jsonb,p_stage text,p_state text,p_hold numeric,p_provider text default null,p_model text default null,p_budget text default'funding')returns uuid language plpgsql security definer as $$
declare rid uuid:=gen_random_uuid();begin
 insert into serving_cost_reservations(id,org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,sponsored_unlimited,state,settled_at,budget_source)
 values(rid,(ev->>'org_id')::uuid,(ev->>'actor_id')::uuid,ev->>'request_key',p_stage,coalesce(p_provider,ev->>'generation_provider','gemini'),coalesce(p_model,ev->>'generation_model','gemini-3.1-flash-image'),
  repeat('a',64),'closed-fixture',p_hold,p_budget='funding',p_state,case when p_state='reserved'then null else now()end,p_budget);
 return rid;end$$;
create function pg_temp.ledger(ev jsonb,p_stage text,p_cents numeric,p_provider text default null,p_model text default null)returns uuid language plpgsql security definer as $$
declare lid uuid;begin
 insert into cost_ledger(org_id,feature,provider,model,total_cents,meta)values((ev->>'org_id')::uuid,'photo_edit',coalesce(p_provider,ev->>'generation_provider'),coalesce(p_model,ev->>'generation_model'),p_cents,
  jsonb_build_object('request_key',ev->>'request_key','stage',p_stage,'cost_basis','closed_fixture_modeled_estimate'))returning id into lid;
 return lid;end$$;
create function pg_temp.manifest(ev jsonb)returns jsonb language plpgsql as $$declare images jsonb:='[]';parents jsonb:='[]';v_role text;region text;pw int;ph int;cw int;ch int;l int;t int;scale numeric;begin
 foreach v_role in array array['source','candidate']loop
  pw:=case when v_role='source'then(ev#>>'{input,width}')::int else(ev#>>'{output,width}')::int end;ph:=case when v_role='source'then(ev#>>'{input,height}')::int else(ev#>>'{output,height}')::int end;
  parents:=parents||jsonb_build_array(jsonb_build_object('role',v_role,'input_sha256',case when v_role='source'then ev#>>'{input,sha256}'else ev#>>'{output,sha256}'end,'normalized_width',pw,'normalized_height',ph,
   'normalized_pixel_sha256',encode(sha256(convert_to(v_role||(ev->>'id'),'UTF8')),'hex'),'normalization','exif-icc-srgb-v1','pixel_hash_policy','rgb8-dimensions-row-major-v1'));
  foreach region in array array['whole','tl','tr','bl','br']loop
   l:=case when region in('tr','br')then pw/2 else 0 end;t:=case when region in('bl','br')then ph/2 else 0 end;
   cw:=case when region='whole'then pw when region in('tl','bl')then pw/2 else pw-pw/2 end;ch:=case when region='whole'then ph when region in('tl','tr')then ph/2 else ph-ph/2 end;
   scale:=least(1::numeric,(case when region='whole'then 2048 else 1024 end)::numeric/greatest(cw,ch));
   images:=images||jsonb_build_array(jsonb_build_object('role',v_role,'region',region,'sha256',encode(sha256(convert_to(v_role||region||(ev->>'id'),'UTF8')),'hex'),'bytes',10000,
    'width',round(cw*scale),'height',round(ch*scale),'crop',jsonb_build_object('left',l,'top',t,'width',cw,'height',ch)));
  end loop;
 end loop;
 return jsonb_build_object('policy','photo-fixed-features-v1','prepared_sha256',ev#>>'{input,sha256}','candidate_sha256',ev#>>'{output,sha256}','parents',parents,'images',images);end$$;
create function pg_temp.verdict(accept boolean default true)returns jsonb language sql as $$select case when accept then
 '{"policy":"photo-fixed-features-v1","verdict":"pass","action":"accept","confidence":0.99,"preservation":{"geometry":100,"openings":100,"fixtures":100,"surfaces":100,"viewpoint":100},"artifacts":100,"edit_quality":100,"findings":[],"reason":"Closed synthetic verdict; no real photo quality assertion."}'::jsonb
 else'{"policy":"photo-fixed-features-v1","verdict":"fail","action":"refuse","confidence":0.99,"preservation":{"geometry":40,"openings":40,"fixtures":100,"surfaces":100,"viewpoint":100},"artifacts":100,"edit_quality":100,"findings":[],"reason":"Closed synthetic refusal."}'::jsonb end$$;
-- The actual final-schema judge path for one retained candidate: CPU lease,
-- exact derivatives, saved judge context, funded judge bind, settled paid QC.
create function pg_temp.judge(ev jsonb,v jsonb)returns jsonb language plpgsql security definer as $$
declare v_actor uuid:=(ev->>'actor_id')::uuid;q uuid;c jsonb;o jsonb;receipts jsonb;rid uuid:=gen_random_uuid();x jsonb;begin
 select id into q from photo_quality_checks where evidence_id=(ev->>'id')::uuid and automatic;
 c:=photo_quality_claim(q);
 o:=photo_quality_derivatives_reserve(q,(c#>>'{check,lease_token}')::uuid,pg_temp.manifest(ev));
 select jsonb_agg(i||jsonb_build_object('etag','"derivative-'||(i->>'role')||'-'||(i->>'region')||'"'))into receipts from jsonb_array_elements(o->'images')i;
 perform photo_quality_derivatives_complete(q,(c#>>'{check,lease_token}')::uuid,receipts);
 perform photo_quality_set_context(v_actor,(ev->>'id')::uuid,ev->>'request_sha256',jsonb_build_object('edit',ev->>'edit','style',ev->'style','instruction',''));
 insert into serving_cost_reservations(id,org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,sponsored_unlimited)
  values(rid,(ev->>'org_id')::uuid,v_actor,'photo-qc:'||q,'photo.qc:0','anthropic','claude-sonnet-5',repeat('e',64),'closed-fixture',.0002,true);
 x:=photo_quality_check_bind(v_actor,q,(c#>>'{check,lease_token}')::uuid,rid);
 update serving_cost_reservations set state='succeeded',settled_at=now()where id=rid;
 insert into cost_ledger(org_id,feature,provider,model,total_cents,meta)values((ev->>'org_id')::uuid,'qc','anthropic','claude-sonnet-5',.0002,jsonb_build_object('request_key','photo-qc:'||q,'stage','photo.qc:0',
  'photo_check_id',q,'evidence_id',ev->>'id','prepared_sha256',ev#>>'{input,sha256}','output_sha256',ev#>>'{output,sha256}','derivative_manifest_sha256',x#>>'{check,derivative_manifest_sha256}','policy',ev->>'policy'));
 return photo_quality_finish(v_actor,q,(c#>>'{check,lease_token}')::uuid,v);end$$;
create function pg_temp.prov(x jsonb)returns uuid language sql as $$select(x->>'provenance_id')::uuid$$;
create function pg_temp.sha(x jsonb)returns text language sql as $$select x#>>'{output,sha256}'$$;
-- END SETUP

set local role service_role;
-- Recipe identity is recorded once, before generation, and never invented later.
create temp table ev as select pg_temp.generate('a','declutter',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0)a;
alter table ev add column a2 jsonb,add column b jsonb,add column c jsonb,add column d jsonb,add column e jsonb,add column h jsonb,add column r jsonb,add column x jsonb,add column g jsonb;
grant select,update on ev to service_role;
select pg_temp.ok((select a->>'recipe_revision'='photo-recipe/2026-10-17.1'and a->>'prompt_sha256'=encode(sha256(convert_to('final prompt a','UTF8')),'hex')from ev),'recipe revision and exact prompt hash recorded before the candidate');
select pg_temp.ok((photo_quality_set_recipe((select a from f),(select(a->>'id')::uuid from ev),'photo-recipe/2026-10-17.1',(select a->>'prompt_sha256'from ev))->>'replay')='true','identical recipe replays');
select pg_temp.no($q$select photo_quality_set_recipe((select a from f),(select(a->>'id')::uuid from ev),'photo-recipe/2026-10-17.2',(select a->>'prompt_sha256'from ev))$q$,'RP409','recipe revision cannot be rewritten');
select pg_temp.no($q$select photo_quality_set_recipe((select a from f),(select(a->>'id')::uuid from ev),'Bad Revision!',repeat('0',64))$q$,'RP400','unbounded recipe label refused');
select pg_temp.no($q$select photo_quality_set_recipe((select b from f),(select(a->>'id')::uuid from ev),'photo-recipe/2026-10-17.1',repeat('0',64))$q$,'RP404','another account cannot write a recipe');
-- a2: a second output of the SAME source photo (exact-version attribution).
update ev set a2=pg_temp.generate('a2','declutter',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0);
-- b: staging retry within one operation: step 0 definitively rejected, step 1 succeeded.
update ev set b=pg_temp.generate('b','stage','modern','photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',1);
-- c: older recipe; step 0 failed after dispatch (uncertain), fallback step 1 on another provider succeeded.
update ev set c=pg_temp.generate('c','stage','modern','photo-recipe/2026-10-16.9','fal','flux-kontext-pro',1);
-- d: succeeded but never settled or judged (pending, not reviewable).
update ev set d=pg_temp.generate('d','twilight',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0);
-- e: generated before recipes were recorded: recipe stays unknown.
update ev set e=pg_temp.generate('e','sky',null,null,'gemini','gemini-3.1-flash-image',0);
-- h: generation failed after dispatch; no candidate.
update ev set h=pg_temp.generate('h','lawn',null,'photo-recipe/2026-10-17.1',null,null,0);
-- r: refused by the fixed-feature judge (private, never delivered).
update ev set r=pg_temp.generate('r','declutter',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0);
-- x: accepted, signalled, never explicitly reviewed.
update ev set x=pg_temp.generate('x','declutter',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0);
select pg_temp.no($q$select photo_quality_set_recipe((select a from f),(select(e->>'id')::uuid from ev),'photo-recipe/2026-10-17.1',repeat('0',64))$q$,'RP409','a recipe cannot be invented after the candidate exists');
select pg_temp.ok((select e->>'recipe_revision'is null and e->>'prompt_sha256'is null from ev),'pre-recipe generation keeps unknown recipe');
-- Attempts and modeled ledger rows. a's settlement is bound BOTH by
-- reservation.ledger_id (ceiling trigger) and by request key + stage.
select pg_temp.attempt(a,'photo.declutter:0','succeeded',.0001,null,null,'ceiling')from ev;select pg_temp.ledger(a,'photo.declutter:0',.0004)from ev;
select pg_temp.attempt(a2,'photo.declutter:0','succeeded',.0001)from ev;select pg_temp.ledger(a2,'photo.declutter:0',.0004)from ev;
select pg_temp.attempt(b,'photo.stage:0','rejected',.0003)from ev;select pg_temp.attempt(b,'photo.stage:1','succeeded',.0003)from ev;select pg_temp.ledger(b,'photo.stage:1',.0006)from ev;
select pg_temp.attempt(c,'photo.stage:0','uncertain',.0008,'gemini','gemini-3.1-flash-image')from ev;select pg_temp.attempt(c,'photo.stage:1','succeeded',.0005)from ev;select pg_temp.ledger(c,'photo.stage:1',.0005)from ev;
select pg_temp.attempt(d,'photo.twilight:0','succeeded',.0005)from ev;
select pg_temp.attempt(e,'photo.sky:0','succeeded',.0003)from ev;select pg_temp.ledger(e,'photo.sky:0',.0003)from ev;
select pg_temp.attempt(h,'photo.lawn:0','uncertain',.0007,'gemini','gemini-3.1-flash-image')from ev;
select pg_temp.attempt(r,'photo.declutter:0','succeeded',.0001)from ev;select pg_temp.ledger(r,'photo.declutter:0',.0004)from ev;
select pg_temp.attempt(x,'photo.declutter:0','succeeded',.0001)from ev;select pg_temp.ledger(x,'photo.declutter:0',.0004)from ev;
select pg_temp.ok((select ledger_id is not null from serving_cost_reservations where request_key=(select a->>'request_key'from ev)and stage='photo.declutter:0'),'fixture settlement bound by ledger id as well as by metadata');
update ev set h=(select to_jsonb(v)from photo_edit_evidence v where v.id=(select(h->>'id')::uuid from ev));
select photo_quality_failure((select a from f),(select(h->>'id')::uuid from ev),'generation',jsonb_build_object('provider_cost_incurred','possible','retained_output',false));
-- The actual judge path: five accepted outputs, one refused, d left pending.
update ev set a=(pg_temp.judge(a,pg_temp.verdict()))->'evidence',a2=(pg_temp.judge(a2,pg_temp.verdict()))->'evidence',b=(pg_temp.judge(b,pg_temp.verdict()))->'evidence',
 c=(pg_temp.judge(c,pg_temp.verdict()))->'evidence',e=(pg_temp.judge(e,pg_temp.verdict()))->'evidence',x=(pg_temp.judge(x,pg_temp.verdict()))->'evidence',
 r=(pg_temp.judge(r,pg_temp.verdict(false)))->'evidence';
select pg_temp.ok((select a->>'state'='accept'and a2->>'state'='accept'and b->>'state'='accept'and c->>'state'='accept'and e->>'state'='accept'and x->>'state'='accept'and r->>'state'='refuse'
 and(select state from photo_edit_evidence where id=(d->>'id')::uuid)='evidence_ready'and(select state from photo_edit_evidence where id=(h->>'id')::uuid)='hold'from ev),'actual journal reached the intended states');
select pg_temp.ok((select pg_temp.prov(a)<>pg_temp.prov(a2)and pg_temp.sha(a)<>pg_temp.sha(a2)and a#>>'{input,sha256}'=a2#>>'{input,sha256}'from ev),'two output versions of one source photo');
-- Historical, other-library, calibration and video provenance (synthetic rows).
reset role;
insert into media_provenance(id,org_id,listing_id,kind,model_id,edit,disclosure)select h1,o,l1,'photo_edit','legacy-model','twilight','Synthetic historical disclosure'from f;
insert into media_provenance(id,org_id,listing_id,kind,model_id,edit,disclosure)select h2,o2,l2,'declutter','legacy-model','declutter','Synthetic other-library disclosure'from f;
insert into media_provenance(id,org_id,listing_id,kind,model_id,edit,disclosure)select calib,o,l1,'declutter','gemini-3.1-flash-image','declutter','Synthetic calibration copy'from f;
insert into media_provenance(id,org_id,listing_id,kind,model_id,edit,disclosure)select reel,o,l1,'reel','fixture-video','reel','Synthetic video disclosure'from f;
set local role service_role;
select serving_operation_begin((select a from f),(select o from f),'photo-fb:calibration','photo_edit',repeat('d',64));
reset role;
-- A calibration journal (re-check of an already-paid output) is not a deliverable output version.
insert into photo_edit_evidence(org_id,actor_id,listing_id,library_org_id,request_key,request_sha256,policy,edit,input,purpose,provenance_id,state)
 select o,a,l1,o,'photo-fb:calibration',repeat('d',64),'photo-fixed-features-v1','declutter',pg_temp.input()||'{"bucket":"renders","key":"synthetic-calibration-input.jpg"}','calibration',calib,'accept'from f;
create temp table authority_before as select
 (select md5(coalesce(string_agg(p::text,''order by p.id),''))from media_provenance p)provenance,
 (select md5(coalesce(string_agg(v::text,''order by v.id),''))from photo_edit_evidence v)evidence,
 (select md5(coalesce(string_agg(q::text,''order by q.id),''))from photo_quality_checks q)checks,
 (select md5(coalesce(string_agg(o::text,''order by o::text),''))from private_ai_outputs o)outputs,
 (select md5(coalesce(string_agg(s::text,''order by s::text),''))from serving_operations s)operations,
 (select md5(coalesce(string_agg(h::text,''order by h.id),''))from serving_cost_reservations h)holds,
 (select md5(coalesce(string_agg(l::text,''order by l.id),''))from cost_ledger l)ledger,
 (select count(*)from capture_assets)assets;
set local role service_role;

-- Authorization identical to the media: wrong user, listing, library and role.
select pg_temp.no($q$select photo_feedback_submit((select b from f),(select o2 from f),pg_temp.prov((select a from ev)),null,'k-other-001',1,'useful','{}',null,'studio')$q$,'RP404','another account cannot rate this library''s photo');
select pg_temp.no($q$select photo_feedback_submit((select b from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-other-002',1,'useful','{}',null,'studio')$q$,'RP404','naming the owner library grants nothing');
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),(select h2 from f),null,'k-wrong-listing',1,'useful','{}',null,'studio')$q$,'RP404','a photo on another library''s listing is unavailable');
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o2 from f),pg_temp.prov((select a from ev)),null,'k-wrong-selected',1,'useful','{}',null,'studio')$q$,'RP404','wrong selected library is a 404');
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),gen_random_uuid(),null,'k-missing-1',1,'useful','{}',null,'studio')$q$,'RP404','unknown output is a 404');
select pg_temp.no($q$select photo_feedback_submit((select r from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-reader-01',1,'useful','{}',null,'studio')$q$,'RP403','a read-only member cannot record feedback');
select pg_temp.no($q$select photo_feedback_submit((select g from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-guest-001',1,'useful','{}',null,'ios')$q$,'RP403','an anonymous member cannot record feedback');
select pg_temp.no($q$select photo_feedback_submit((select d from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-leaving-1',1,'useful','{}',null,'ios')$q$,'RP403','a member with a pending deletion cannot record feedback');
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select d from ev)),null,'k-pending-1',1,'useful','{}',null,'studio')$q$,'RP404','an output awaiting its quality check is not rateable');
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select r from ev)),null,'k-refused-1',1,'useful','{}',null,'studio')$q$,'RP404','a refused private output is not rateable');
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),(select calib from f),null,'k-calib-001',1,'useful','{}',null,'studio')$q$,'RP404','a calibration copy is not an output version');
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),(select reel from f),null,'k-video-001',1,'useful','{}',null,'studio')$q$,'RP404','video provenance is not a photo output');
select pg_temp.no($q$select photo_feedback_submit((select a from f),null,pg_temp.prov((select a from ev)),null,'k-noselect1',1,'useful','{}',null,'studio')$q$,'RP400','the selected library is required');
-- Bounded verdicts.
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-bad-00001',1,'needs_work','{}',null,'studio')$q$,'RP400','needs work requires a reason');
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-bad-00001',1,'useful','{other}',null,'studio')$q$,'RP400','useful carries no reason');
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-bad-00001',1,'needs_work','{not_a_reason}',null,'studio')$q$,'RP400','unknown reason refused');
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-bad-00001',1,'needs_work','{other,other}',null,'studio')$q$,'RP400','duplicate reason refused');
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-bad-00001',1,'needs_work','{other}',repeat('n',501),'studio')$q$,'RP400','note longer than 500 refused');
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),null,'short',1,'useful','{}',null,'studio')$q$,'RP400','unbounded client key refused');
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-bad-00001',0,'useful','{}',null,'studio')$q$,'RP400','revision starts at 1');
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),pg_temp.sha((select a2 from ev)),'k-bad-00001',1,'useful','{}',null,'studio')$q$,'OUTPUT_MISMATCH','bytes of the sibling version are refused');
select pg_temp.ok((select count(*)=0 from photo_output_feedback),'no refused submission wrote a row');

-- Exact-version attribution: two outputs of one source; feedback lands on the chosen one.
create temp table fb as select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),pg_temp.sha((select a from ev)),'k-a-00000001',1,'useful','{}',null,'studio')x;grant select,update on fb to service_role;
select pg_temp.ok((select x->>'state'='recorded'and x#>>'{attribution,basis}'='evidence'and x#>>'{attribution,evidence_id}'=(select a->>'id'from ev)
 and x#>>'{attribution,provider}'='gemini'and x#>>'{attribution,model}'='gemini-3.1-flash-image'and x#>>'{attribution,generation_stage}'='photo.declutter:0'
 and x#>>'{attribution,recipe_revision}'='photo-recipe/2026-10-17.1'and x#>>'{attribution,prompt_sha256}'=(select a->>'prompt_sha256'from ev)
 and(x#>>'{attribution,attempts_known}')::boolean and x#>'{attribution,provenance_model_id}'='null'::jsonb from fb),'feedback bound to the exact evidence, provider, model, stage and recipe');
select pg_temp.ok((select request_key=(select a->>'request_key'from ev)and output_sha256=(select pg_temp.sha(a)from ev)and edit='declutter'and listing_id=(select l1 from f)and org_id=(select o from f)
 from photo_output_feedback where client_key='k-a-00000001'),'stored row carries the exact request, bytes, listing and library');
select pg_temp.ok((select count(*)=1 from photo_output_feedback where provenance_id=(select pg_temp.prov(a)from ev))and(select count(*)=0 from photo_output_feedback where provenance_id=(select pg_temp.prov(a2)from ev)),'feedback attaches only to the rated output version');
-- Offline resend: identical body replays; nothing is written.
select pg_temp.ok((photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),pg_temp.sha((select a from ev)),'k-a-00000001',1,'useful','{}',null,'studio')->>'state')='replayed','duplicate offline submission replays');
select pg_temp.ok((photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-a-00000001',1,'useful','{}','  ','studio')->>'state')='replayed','blank note and omitted bytes are the same content');
select pg_temp.ok((select count(*)=1 and max(revision_count)=1 from photo_output_feedback where actor_id=(select a from f)),'duplicates never add a row or a revision');
-- Same revision with other content conflicts; a higher revision revises in place; a late lower revision never regresses.
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-a-00000001',1,'needs_work','{other}',null,'studio')$q$,'FEEDBACK_REVISION_CONFLICT','changed content needs a new revision');
update fb set x=photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-a-00000001',2,'needs_work','{visible_visual_artifacts,blocked_doorway_or_opening}','Doorway on the right is covered',null);
select pg_temp.ok((select x->>'state'='revised'and x->>'revision'='2'and x->>'revision_count'='2'and x->>'verdict'='needs_work'and x->'reasons'='["blocked_doorway_or_opening","visible_visual_artifacts"]'::jsonb from fb),'revision updates in place with canonical reason order');
select pg_temp.ok((select count(*)=1 and min(platform)='studio'from photo_output_feedback where provenance_id=(select pg_temp.prov(a)from ev)),'revision never duplicates a row and keeps the platform');
select pg_temp.ok((photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-a-00000001',2,'needs_work','{blocked_doorway_or_opening,visible_visual_artifacts}','Doorway on the right is covered','studio')->>'state')='replayed','reordered reasons replay the same revision');
select pg_temp.ok((select x->>'state'='replayed'and x->>'revision'='2'and x->>'verdict'='needs_work'from photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-a-00000001',1,'useful','{}',null,'studio')x),'a late retry of an old revision returns the newer opinion');
select pg_temp.ok((select verdict='needs_work'and revision=2 and revision_count=2 from photo_output_feedback where client_key='k-a-00000001'),'the stored opinion did not regress');
-- A key is bound to one output forever; a second key for the same output is answered with the existing one.
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select b from ev)),null,'k-a-00000001',3,'useful','{}',null,'studio')$q$,'FEEDBACK_KEY_CONFLICT','a feedback key is bound to one photo');
select pg_temp.ok((select x->>'state'='conflict'and x->>'code'='feedback_exists'and x->>'client_key'='k-a-00000001'and x->>'revision'='2'from photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-a-00000002',1,'useful','{}',null,'ios')x),'a second key for the same output returns the existing key');
select pg_temp.ok((select x->>'verdict'='needs_work'and x->'reasons'='["blocked_doorway_or_opening","visible_visual_artifacts"]'::jsonb and x->>'note'='Doorway on the right is covered'
 and x->>'revision_count'='2'and x->>'provenance_id'=pg_temp.prov((select a from ev))::text
 from photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-a-00000003',1,'needs_work','{other}',null,'studio')x),
 'feedback_exists carries the stored verdict, reasons and note so a client can skip an identical resend');
select pg_temp.ok((select count(*)=1 from photo_output_feedback where actor_id=(select a from f)),'the conflicting key wrote nothing');
-- Each reviewer has their own row; the owner's opinion is untouched.
select photo_feedback_submit((select e from f),(select o from f),pg_temp.prov((select a from ev)),null,'k-editor-0001',1,'useful','{}',null,'ios');
select pg_temp.ok((select count(*)=2 from photo_output_feedback where provenance_id=(select pg_temp.prov(a)from ev))and(select verdict='needs_work'from photo_output_feedback where client_key='k-a-00000001'),'each reviewer has one row per output');
-- Remaining verdicts for the report.
select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select a2 from ev)),pg_temp.sha((select a2 from ev)),'k-a2-0000001',1,'useful','{}',null,'studio');
select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select b from ev)),null,'k-b-00000001',1,'useful','{}',null,'studio');
select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select c from ev)),null,'k-c-00000001',1,'needs_work','{personal_style_preference}',null,'ios');
select photo_feedback_submit((select e from f),(select o from f),pg_temp.prov((select c from ev)),null,'k-editor-0002',1,'needs_work','{personal_style_preference,changed_permanent_features}','Window trim was repainted','ios');
create temp table fe as select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select e from ev)),null,'k-e-00000001',1,'needs_work','{other}',null,'studio')x;grant select on fe to service_role;
select pg_temp.ok((select x#>>'{attribution,basis}'='evidence'and x#>'{attribution,recipe_revision}'='null'::jsonb and x#>'{attribution,prompt_sha256}'='null'::jsonb and x#>>'{attribution,provider}'='gemini'from fe),'pre-recipe generation is attributed with its recipe explicitly unknown');
-- Historical output: provenance only, every binding explicitly unknown.
create temp table hist as select photo_feedback_submit((select a from f),(select o from f),(select h1 from f),repeat('9',64),'k-hist-0001',1,'needs_work','{changed_permanent_features}',null,'ios')x;grant select on hist to service_role;
select pg_temp.ok((select x#>>'{attribution,basis}'='provenance_only'and x#>'{attribution,evidence_id}'='null'::jsonb and x#>'{attribution,provider}'='null'::jsonb and x#>'{attribution,model}'='null'::jsonb
 and x#>'{attribution,generation_stage}'='null'::jsonb and x#>'{attribution,recipe_revision}'='null'::jsonb and not(x#>>'{attribution,attempts_known}')::boolean
 and x#>>'{attribution,provenance_model_id}'='legacy-model'and x#>>'{attribution,edit}'='twilight'from hist),'historical output stays provenance-only with unknown provider, recipe and attempts');
select pg_temp.ok((select attribution='provenance_only'and evidence_id is null and provider is null and model is null and generation_stage is null and request_key is null and recipe_revision is null and prompt_sha256 is null
 and output_sha256=repeat('9',64)from photo_output_feedback where client_key='k-hist-0001'),'nothing is invented for a historical row');
select pg_temp.no($q$select photo_feedback_submit((select a from f),(select o from f),(select h1 from f),repeat('8',64),'k-hist-0001',2,'useful','{}',null,'ios')$q$,'OUTPUT_MISMATCH','a historical row cannot move to other bytes');
reset role;
select pg_temp.no($q$update photo_output_feedback set provider='invented'where client_key='k-hist-0001'$q$,'photo_output_feedback_check','table refuses invented historical attribution');
select pg_temp.no($q$update photo_edit_evidence set recipe_revision='photo-recipe/2026-10-17.1'where id=(select(e->>'id')::uuid from ev)$q$,'photo_edit_evidence_recipe_pair_check','a recipe without its prompt hash is refused');
set local role service_role;

-- Separate signals: idempotent, append-only, never folded into feedback.
select pg_temp.ok((photo_feedback_signal((select a from f),(select o from f),pg_temp.prov((select a from ev)),'s-a-00000001','manual_selection','gallery_save','studio')->>'state')='recorded','manual selection recorded as a signal');
select pg_temp.ok((photo_feedback_signal((select a from f),(select o from f),pg_temp.prov((select a from ev)),'s-a-00000001','manual_selection','gallery_save','studio')->>'state')='replayed','signal replay is a no-op');
select pg_temp.no($q$select photo_feedback_signal((select a from f),(select o from f),pg_temp.prov((select b from ev)),'s-a-00000001','manual_selection','gallery_save','studio')$q$,'FEEDBACK_KEY_CONFLICT','signal key cannot move to another photo');
select pg_temp.no($q$select photo_feedback_signal((select a from f),(select o from f),pg_temp.prov((select a from ev)),'s-a-00000001','export','download','studio')$q$,'FEEDBACK_KEY_CONFLICT','signal key cannot become another signal');
select pg_temp.no($q$select photo_feedback_signal((select a from f),(select o from f),pg_temp.prov((select a from ev)),'s-a-00000009','liked',null,'studio')$q$,'RP400','unknown signal refused');
select pg_temp.no($q$select photo_feedback_signal((select b from f),(select o2 from f),pg_temp.prov((select a from ev)),'s-other-001','export',null,'studio')$q$,'RP404','another account cannot signal on this photo');
select photo_feedback_signal((select e from f),(select o from f),pg_temp.prov((select a from ev)),'s-e-00000001','manual_selection','gallery_save','ios');
select photo_feedback_signal((select a from f),(select o from f),pg_temp.prov((select x from ev)),'s-x-00000001','automatic_selection','listing_selection','ios');
select photo_feedback_signal((select a from f),(select o from f),pg_temp.prov((select b from ev)),'s-b-00000001','accuracy_ack','staging_review','ios');
select photo_feedback_signal((select a from f),(select o from f),pg_temp.prov((select b from ev)),'s-b-00000002','publication','published_tour','studio');
select photo_feedback_signal((select a from f),(select o from f),pg_temp.prov((select a2 from ev)),'s-a2-0000001','export','download','studio');
select photo_feedback_signal((select a from f),(select o from f),(select h1 from f),'s-h1-0000001','export','kit_export','ios');
select pg_temp.ok((select count(*)=2 from photo_output_signals where provenance_id=(select pg_temp.prov(a)from ev))and(select count(*)=7 from photo_output_signals),'one signal row per key');
select pg_temp.ok((select verdict='needs_work'from photo_output_feedback where client_key='k-a-00000001')and not exists(select 1 from photo_output_feedback where provenance_id=(select pg_temp.prov(x)from ev)),'selection never creates or changes a verdict');
-- State read-back for a client that lost its local queue.
select pg_temp.ok((select x#>>'{feedback,client_key}'='k-a-00000001'and x#>>'{feedback,revision}'='2'and x#>>'{feedback,verdict}'='needs_work'and jsonb_array_length(x->'signals')=1
 and x->'regression_case'='null'::jsonb and x#>>'{attribution,basis}'='evidence'from photo_feedback_state((select a from f),(select o from f),pg_temp.prov((select a from ev)))x),'state returns only the caller''s own verdict and signals');
select pg_temp.ok((select x#>>'{feedback,client_key}'='k-editor-0001'and jsonb_array_length(x->'signals')=1 from photo_feedback_state((select e from f),(select o from f),pg_temp.prov((select a from ev)))x),'another reviewer reads only their own state');
select pg_temp.ok((select x->'feedback'='null'::jsonb and x->'signals'='[]'::jsonb from photo_feedback_state((select m from f),(select o from f),pg_temp.prov((select a from ev)))x),'an editor with no verdict gets an empty state');
select pg_temp.no($q$select photo_feedback_state((select b from f),(select o2 from f),pg_temp.prov((select a from ev)))$q$,'RP404','state is library-scoped');

-- Regression cases: owner/admin, explicit consent, existing evidence references only.
select pg_temp.no($q$select photo_regression_case_mark((select e from f),(select o from f),pg_temp.prov((select a from ev)),'blocked_doorway_or_opening','Keep the right-hand doorway open and unobstructed.',true,false)$q$,'RP403','an agent cannot keep an evaluation case');
select pg_temp.no($q$select photo_regression_case_mark((select a from f),(select o from f),pg_temp.prov((select a from ev)),'blocked_doorway_or_opening','Keep the right-hand doorway open and unobstructed.',false,false)$q$,'CONSENT','retention needs explicit consent');
select pg_temp.no($q$select photo_regression_case_mark((select a from f),(select o from f),(select h1 from f),'changed_permanent_features','Keep the garage door and trim as photographed.',true,false)$q$,'EVIDENCE_UNAVAILABLE','a historical output has no retained evidence to evaluate');
select pg_temp.no($q$select photo_regression_case_mark((select b from f),(select o2 from f),pg_temp.prov((select a from ev)),'other','Expected behavior text here.',true,false)$q$,'RP404','another library owner cannot keep this photo');
select pg_temp.no($q$select photo_regression_case_mark((select a from f),(select o from f),pg_temp.prov((select a from ev)),'personal_style_preference','Taste is not a regression to keep.',true,false)$q$,'RP400','taste is not a regression defect');
create temp table rc as select photo_regression_case_mark((select a from f),(select o from f),pg_temp.prov((select a from ev)),'blocked_doorway_or_opening','Keep the right-hand doorway open and unobstructed.',true,false)x;grant select,update on rc to service_role;
select pg_temp.ok((select x->>'state'='recorded'and x->>'protocol'='photo-fixed-features-v1'and x->>'recipe_revision'='photo-recipe/2026-10-17.1'from rc),'case recorded under the existing photo evaluation protocol with its recipe');
select pg_temp.ok((select input_ref->>'key'=(select a#>>'{input,key}'from ev)and output_ref->>'sha256'=(select pg_temp.sha(a)from ev)and output_ref->>'key'=(select a#>>'{output,key}'from ev)
 and feedback_id=(select id from photo_output_feedback where client_key='k-a-00000001')and authorized_by=(select a from f)and authorization_basis='library_owner_consent'
 and prompt_sha256=(select a->>'prompt_sha256'from ev)from photo_regression_cases where provenance_id=(select pg_temp.prov(a)from ev)),'case references the existing evidence objects, recipe and the owner''s feedback');
select pg_temp.ok((photo_regression_case_mark((select a from f),(select o from f),pg_temp.prov((select a from ev)),'blocked_doorway_or_opening','Keep the right-hand doorway open and unobstructed.',true,false)->>'state')='replayed','same case replays');
select pg_temp.ok((photo_regression_case_mark((select m from f),(select o from f),pg_temp.prov((select c from ev)),'changed_permanent_features','Window trim colour must stay exactly as photographed.',true,false)->>'state')='recorded','a library admin can keep a case');
select pg_temp.ok(jsonb_array_length(photo_regression_cases_for_review('photo-recipe/2026-10-17.1'))=1 and jsonb_array_length(photo_regression_cases_for_review('photo-recipe/2026-10-16.9'))=1
 and jsonb_array_length(photo_regression_cases_for_review(null))=2 and(photo_regression_cases_for_review('photo-recipe/2026-10-16.9')->0->>'style')='modern','cases are reusable by recipe revision');
select pg_temp.ok((select x#>>'{regression_case,defect}'='blocked_doorway_or_opening'from photo_feedback_state((select e from f),(select o from f),pg_temp.prov((select a from ev)))x),'the library case is visible to its editors');
update rc set x=photo_regression_case_mark((select a from f),(select o from f),pg_temp.prov((select a from ev)),null,null,false,true);
select pg_temp.ok((select x->>'state'='withdrawn'and x->>'withdrawn_at'is not null from rc)and jsonb_array_length(photo_regression_cases_for_review('photo-recipe/2026-10-17.1'))=0,'withdrawal needs no consent flag and leaves the review set');
select pg_temp.ok((photo_regression_case_mark((select a from f),(select o from f),pg_temp.prov((select a2 from ev)),null,null,false,true)->>'state')='withdrawn','withdrawing a case that never existed is a no-op');
select pg_temp.no($q$select photo_regression_case_mark((select e from f),(select o from f),pg_temp.prov((select c from ev)),null,null,false,true)$q$,'RP403','an agent cannot withdraw a library case');

-- Feedback, signals and cases never touched generation, quality, funding or publication authority.
reset role;
select pg_temp.ok((select(select md5(coalesce(string_agg(p::text,''order by p.id),''))from media_provenance p)=provenance
 and(select md5(coalesce(string_agg(v::text,''order by v.id),''))from photo_edit_evidence v)=evidence
 and(select md5(coalesce(string_agg(q::text,''order by q.id),''))from photo_quality_checks q)=checks
 and(select md5(coalesce(string_agg(o::text,''order by o::text),''))from private_ai_outputs o)=outputs
 and(select md5(coalesce(string_agg(s::text,''order by s::text),''))from serving_operations s)=operations
 and(select md5(coalesce(string_agg(h::text,''order by h.id),''))from serving_cost_reservations h)=holds
 and(select md5(coalesce(string_agg(l::text,''order by l.id),''))from cost_ledger l)=ledger
 and(select count(*)from capture_assets)=assets from authority_before),'feedback never changed provenance, evidence, checks, delivery, operations, holds, ledger or listing media');
select pg_temp.ok((select bool_and(qc->>'publishable'='false'and altered_key is null)from media_provenance where id in(select pg_temp.prov(r)from ev union all select pg_temp.prov(d)from ev)),'refused and pending outputs stay unpublished');
set local role service_role;

-- Honest report. Every row this fixture writes carries this transaction's
-- timestamp, so [now(), now()+1h) is exactly this fixture's cohort even on a
-- cluster that already holds committed rows.
create temp table rep as select photo_feedback_report(now(),now()+interval'1 hour')x;grant select on rep to service_role;
select pg_temp.ok((select x#>>'{generated,outputs}'='9'and x#>>'{generated,accepted}'='6'and x#>>'{generated,refused}'='1'and x#>>'{generated,held}'='1'and x#>>'{generated,pending}'='1'
 and x#>>'{generated,retained_candidates}'='8'and x#>>'{generated,excluded_calibration_checks}'='1'from rep),'generated counts every prospective generation by state and excludes calibration');
select pg_temp.ok((select x#>>'{explicit,reviewable_outputs}'='6'and x#>>'{explicit,reviewed_outputs}'='5'and x#>>'{explicit,feedback_rows}'='7'and x#>>'{explicit,useful}'='3'
 and x#>>'{explicit,needs_work}'='4'and(x#>>'{explicit,useful_rate}')::numeric=.4286 and(x#>>'{explicit,coverage}')::numeric=.8333 and x#>>'{explicit,unreviewed_outputs}'='1'
 and x#>>'{explicit,reviewers}'='2'and x#>>'{explicit,revised_rows}'='1'and x#>>'{explicit,explicitly_useful_outputs}'='2'and x#>>'{explicit,contested_outputs}'='1'from rep),'explicit denominators: reviewable, reviewed, verdict rows and coverage are separate');
select pg_temp.ok((select x#>>'{historical,feedback_rows}'='1'and x#>>'{historical,outputs}'='1'and x#>>'{historical,needs_work}'='1'and x#>>'{historical,useful}'='0'from rep),'historical feedback is reported apart from every rate');
select pg_temp.ok((select x#>>'{signals,manual_selection}'='1'and x#>>'{signals,automatic_selection}'='1'and x#>>'{signals,accuracy_ack}'='1'and x#>>'{signals,publication}'='1'
 and x#>>'{signals,export}'='1'and x#>>'{signals,signal_rows}'='6'and x#>>'{signals,outputs_with_signal_and_no_feedback}'='1'from rep),'signals are distinct outputs per signal and never count as useful');
select pg_temp.ok((select x#>>'{fidelity_vs_taste,needs_work_rows}'='4'and x#>>'{fidelity_vs_taste,with_fidelity_reason}'='2'and x#>>'{fidelity_vs_taste,taste_only}'='1'
 and x#>>'{fidelity_vs_taste,other_only}'='1'and x#>>'{fidelity_vs_taste,taste_and_fidelity}'='1'from rep),'property-fidelity defects are separated from personal taste');
select pg_temp.ok((select jsonb_array_length(x->'reasons')=8 and x#>>'{reasons,0,reason}'='personal_style_preference'and x#>>'{reasons,0,group}'='taste'and x#>>'{reasons,0,feedback_rows}'='2'
 and x#>>'{reasons,0,outputs}'='1'and x#>>'{reasons,1,reason}'='changed_permanent_features'and x#>>'{reasons,1,group}'='fidelity'and x#>>'{reasons,4,reason}'='other'
 and x#>>'{reasons,4,group}'='other'and x#>>'{reasons,7,feedback_rows}'='0'from rep),'every reason listed with its group, most common first');
select pg_temp.ok((select i->>'generated'='4'and i->>'reviewable'='3'and i->>'reviewed'='2'and i->>'useful'='2'and i->>'needs_work'='1'and(i->>'useful_rate')::numeric=.6667
 and i->>'attempts'='8'and(i->>'recorded_cents')::numeric=.0024 and(i->>'small_sample')::boolean from rep,jsonb_array_elements(x->'by_edit')i where i->>'key'='declutter'),'breakdown by edit carries n, attempts and recorded cost');
select pg_temp.ok((select x#>>'{by_edit,0,key}'='declutter'and x#>>'{by_edit,1,key}'='stage'and jsonb_array_length(x->'by_edit')=5 from rep)
 and(select i->>'reviewed'='0'and i->'useful_rate'='null'::jsonb from rep,jsonb_array_elements(x->'by_edit')i where i->>'key'='twilight'),'unreviewed cells report a null rate, never zero');
select pg_temp.ok((select i->>'generated'='1'and i->>'reviewed'='1'and i->>'needs_work'='2'and(i->>'useful_rate')::numeric=0 and i->>'attempts'='3' from rep,jsonb_array_elements(x->'by_provider_model')i where i->>'key'='fal/flux-kontext-pro')
 and(select i->>'generated'='1'and i->>'reviewable'='0'from rep,jsonb_array_elements(x->'by_provider_model')i where i->>'key'='no_retained_output'),'breakdown by provider and model, failed generation kept apart');
select pg_temp.ok((select i->>'generated'='7'from rep,jsonb_array_elements(x->'by_recipe_revision')i where i->>'key'='photo-recipe/2026-10-17.1')
 and(select i->>'generated'='1'and i->>'needs_work'='2'from rep,jsonb_array_elements(x->'by_recipe_revision')i where i->>'key'='photo-recipe/2026-10-16.9')
 and(select i->>'generated'='1'and i->>'needs_work'='1'from rep,jsonb_array_elements(x->'by_recipe_revision')i where i->>'key'='unknown'),'breakdown by recipe revision keeps unknown apart');
-- Cost: 18 attempts (each reservation once). b retried after a definitive rejection;
-- c failed after dispatch then fell back; d succeeded unsettled; h failed; seven paid checks.
select pg_temp.ok((select x#>>'{cost,attributable_attempts}'='18'and x#>>'{cost,succeeded_attempts}'='15'and x#>>'{cost,failed_or_rejected_attempts}'='1'and x#>>'{cost,uncertain_attempts}'='2'
 and x#>>'{cost,open_attempts}'='0'and x#>>'{cost,judge_attempts}'='7'and x#>>'{cost,retried_outputs}'='2'from rep),'failed, rejected and retried attempts each counted once');
select pg_temp.ok((select x#>>'{cost,recorded_ledger_rows}'='14'and(x#>>'{cost,recorded_cents}')::numeric=.0044 and x#>>'{cost,attempts_with_multiple_ledger_rows}'='0'from rep),'a settlement reached by binding, metadata and judge receipt is counted once');
select pg_temp.ok((select(x#>>'{cost,outstanding_hold_cents}')::numeric=.0020 and x#>>'{cost,unsettled_attempts}'='3'and x#>>'{cost,unknown_attribution_outputs}'='1'and x#>>'{cost,generated_without_attempt_records}'='0'from rep),'uncertain and unsettled holds stay outstanding; historical output is unknown attribution');
select pg_temp.ok((select x#>>'{cost,reviewed_attempts}'='12'and(x#>>'{cost,reviewed_recorded_cents}')::numeric=.0032 and(x#>>'{cost,reviewed_outstanding_hold_cents}')::numeric=.0008
 and x#>>'{cost,explicitly_useful_outputs}'='2'and(x#>>'{cost,attempts_per_useful}')::numeric=6 and(x#>>'{cost,recorded_cents_per_useful}')::numeric=.0016
 and(x#>>'{cost,outstanding_hold_cents_per_useful}')::numeric=.0004 and(x#>>'{cost,window_recorded_cents_per_useful}')::numeric=.0022 from rep),'attempts and recorded cents per explicitly useful output over reviewed outputs only');
select pg_temp.ok((select x->>'basis'like'%not supplier invoices%'and x->>'basis'like'%not evidence that one setting is better%'and x#>>'{cost,basis}'like'%never invoices%'
 and x#>>'{signals,note}'like'%Missing feedback is not rejection%'and x->>'sample_note'like'%small_sample%'from rep),'report carries the honesty wording');
select pg_temp.ok((select x#>>'{data_range,first_generated_at}'is not null and x#>>'{data_range,last_feedback_at}'is not null and x->>'from'is not null and x->>'to'is not null from rep),'report shows its date range');
select pg_temp.ok((select x#>>'{regression_cases,active}'='1'and x#>>'{regression_cases,withdrawn}'='1'and x#>>'{regression_cases,by_defect,0,key}'='changed_permanent_features'
 and x#>>'{regression_cases,by_recipe_revision,0,key}'='photo-recipe/2026-10-16.9'from rep),'regression case counts');
select pg_temp.ok((select not(x::text~'f8300000-0000-4000-8000')and position('photo-fb:'in x::text)=0 and position('Doorway'in x::text)=0 and position('ai-router/'in x::text)=0 from rep),'report carries no ids, request keys, notes or media keys');
select pg_temp.ok((select x#>>'{generated,outputs}'='0'and x#>'{explicit,useful_rate}'='null'::jsonb and x#>'{explicit,coverage}'='null'::jsonb and x#>'{cost,attempts_per_useful}'='null'::jsonb
 and x->'by_edit'='[]'::jsonb from photo_feedback_report(now()-interval'3 days',now()-interval'2 days')x),'an empty window reports null rates, never zero');
select pg_temp.no($q$select photo_feedback_report(now(),now()-interval'1 day')$q$,'RP400','inverted window refused');
select pg_temp.no($q$select photo_feedback_report(now()-interval'401 days',now())$q$,'RP400','unbounded window refused');
select pg_temp.ok((select count(*)=0 from serving_operations where request_key like'photo-fb:%'and request_key not in(select request_key from photo_edit_evidence))
 and(select count(*)=18 from serving_cost_reservations where(request_key like'photo-fb:%'or request_key like'photo-qc:%')and created_at=now()),'no feedback call created an operation or a paid attempt');

-- Retention follows the photo and its author.
reset role;
-- g: an output generated by the editor and rated by the owner.
set local role service_role;
update ev set g=pg_temp.generate('g','declutter',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0,(select e from f),(select l3 from f));
select pg_temp.attempt(g,'photo.declutter:0','succeeded',.0001)from ev;select pg_temp.ledger(g,'photo.declutter:0',.0004)from ev;
update ev set g=(pg_temp.judge(g,pg_temp.verdict()))->'evidence';
select photo_feedback_submit((select a from f),(select o from f),pg_temp.prov((select g from ev)),null,'k-g-00000001',1,'useful','{}',null,'studio');
select photo_feedback_signal((select a from f),(select o from f),pg_temp.prov((select g from ev)),'s-g-00000001','export','download','studio');
select pg_temp.ok((select count(*)=1 from photo_output_feedback where provenance_id=(select pg_temp.prov(g)from ev)),'owner feedback on the editor''s generation exists');
reset role;
-- Listing soft-delete hides consented cases from review before the purge.
update listings set deleted_at=now()where id=(select l1 from f);
select pg_temp.ok(jsonb_array_length(photo_regression_cases_for_review(null))=0,'a trashed listing''s cases leave the review set');
set local role service_role;
select pg_temp.no($q$select photo_feedback_state((select a from f),(select o from f),pg_temp.prov((select c from ev)))$q$,'RP404','a trashed listing''s photo is unavailable');
reset role;
delete from listings where id=(select l1 from f);
select pg_temp.ok((select count(*)=0 from photo_output_feedback where listing_id=(select l1 from f))and(select count(*)=0 from photo_output_signals where listing_id=(select l1 from f))
 and(select count(*)=0 from photo_regression_cases),'listing deletion cascades every feedback row, signal and case');
select pg_temp.ok((select count(*)=1 from photo_output_feedback)and(select count(*)=1 from photo_output_signals),'the other listing''s feedback is untouched');
-- Deleting the generating account removes its evidence and every opinion bound to it.
delete from auth.users where id=(select e from f);
select pg_temp.ok((select count(*)=0 from photo_output_feedback)and(select count(*)=0 from photo_output_signals),'feedback never outlives the generation evidence or its author');
set local role authenticated;
select pg_temp.no('select *from photo_output_feedback','permission denied','actual client cannot read feedback');
select pg_temp.no('select photo_feedback_report(now()-interval''1 day'',now())','permission denied','actual client cannot read the report');
select pg_temp.no($q$select photo_feedback_submit(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),null,'k-client-01',1,'useful','{}',null,'ios')$q$,'permission denied','actual client cannot call submit');
reset role;
select jsonb_build_object('passed',true,'suite','photo_feedback','assertions',(select count(*)from checks),'realProviderCalls',0,'paidRegenerations',0);
rollback;
