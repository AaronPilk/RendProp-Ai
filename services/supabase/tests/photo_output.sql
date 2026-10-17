\set ON_ERROR_STOP on
begin;
-- Provider/bytes transport is closed synthetic evidence. Actual RPCs, locks,
-- quarantine, ACLs and immutable receipt relationships are exercised here.
create temporary table checks(n int);insert into checks values(0);grant all on checks to service_role,authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception'PHOTOQC FAIL: %',label;end if;update checks set n=n+1;end$$;
create function pg_temp.no(command text,needle text,label text)returns void language plpgsql as $$begin begin execute command;exception when others then if position(needle in sqlerrm)>0 then perform pg_temp.ok(true,label);return;end if;raise;end;raise exception'PHOTOQC FAIL allowed: %',label;end$$;
insert into auth.users(id,email,is_anonymous)values('f8200000-0000-4000-8000-000000000001','photo-quality-owner@fixture.invalid',false),('f8200000-0000-4000-8000-000000000002','photo-quality-other@fixture.invalid',false);
create temporary table f as select 'f8200000-0000-4000-8000-000000000001'::uuid actor,'f8200000-0000-4000-8000-000000000002'::uuid other,(select org_id from memberships where user_id='f8200000-0000-4000-8000-000000000001'and role='owner'limit 1)org,'f8200000-0000-4000-8000-000000000011'::uuid listing;
grant select on f to service_role,authenticated;
insert into listings(id,org_id,agent_id,address)select listing,org,actor,'Synthetic photo quality property'from f;
create function pg_temp.input()returns jsonb language sql as $$select jsonb_build_object('sha256',repeat('a',64),'bytes',60000,'mime','image/jpeg','width',1024,'height',768)$$;
create function pg_temp.seed(label text)returns jsonb language plpgsql as $$declare x jsonb;begin
 if not exists(select 1 from serving_operations where actor_id=(select actor from f)and org_id=(select org from f)and request_key='photo-quality:'||label)then perform serving_operation_begin((select actor from f),(select org from f),'photo-quality:'||label,'photo_edit',repeat('d',64));end if;
 x:=photo_quality_begin((select actor from f),(select org from f),'photo-quality:'||label,(select listing from f),'declutter',null,null,pg_temp.input(),jsonb_build_array('ai-router/'||(select org from f)||'/completed-photo/'||encode(sha256(convert_to(label||'j','UTF8')),'hex')||'.jpg','ai-router/'||(select org from f)||'/completed-photo/'||encode(sha256(convert_to(label||'p','UTF8')),'hex')||'.png','ai-router/'||(select org from f)||'/completed-photo/'||encode(sha256(convert_to(label||'w','UTF8')),'hex')||'.webp'));return x;end$$;
create function pg_temp.candidate(x jsonb,w int default 4096,h int default 3072)returns jsonb language plpgsql as $$declare id uuid:=(x#>>'{check,id}')::uuid;e uuid:=(x#>>'{evidence,id}')::uuid;begin
 perform photo_quality_evidence_receipt((select actor from f),e,'input','"prepared-etag"');
 perform photo_quality_evidence_reserve((select actor from f),e,jsonb_build_object('sha256',repeat('b',64),'bytes',8000000,'mime','image/png','width',w,'height',h,'generation_stage','photo.declutter:0','provider','gemini','model','gemini-3.1-flash-image'));
 return photo_quality_evidence_receipt((select actor from f),e,'output','"candidate-etag"');end$$;
create function pg_temp.manifest(x jsonb)returns jsonb language plpgsql as $$declare images jsonb:='[]';parents jsonb:='[]';role text;region text;pw int;ph int;cw int;ch int;l int;t int;scale numeric;begin
 foreach role in array array['source','candidate']loop
  pw:=case when role='source'then 1024 else 4096 end;ph:=case when role='source'then 768 else 3072 end;
  parents:=parents||jsonb_build_array(jsonb_build_object('role',role,'input_sha256',case when role='source'then repeat('a',64)else repeat('b',64)end,'normalized_width',pw,'normalized_height',ph,'normalized_pixel_sha256',repeat(case when role='source'then'c'else'd'end,64),'normalization','exif-icc-srgb-v1','pixel_hash_policy','rgb8-dimensions-row-major-v1'));
  foreach region in array array['whole','tl','tr','bl','br']loop
   l:=case when region in('tr','br')then pw/2 else 0 end;t:=case when region in('bl','br')then ph/2 else 0 end;
   cw:=case when region='whole'then pw when region in('tl','bl')then pw/2 else pw-pw/2 end;ch:=case when region='whole'then ph when region in('tl','tr')then ph/2 else ph-ph/2 end;
   scale:=least(1::numeric,(case when region='whole'then 2048 else 1024 end)::numeric/greatest(cw,ch));
   images:=images||jsonb_build_array(jsonb_build_object('role',role,'region',region,'sha256',encode(sha256(convert_to(role||region,'UTF8')),'hex'),'bytes',10000,'width',round(cw*scale),'height',round(ch*scale),'crop',jsonb_build_object('left',l,'top',t,'width',cw,'height',ch)));
  end loop;
 end loop;return jsonb_build_object('policy','photo-fixed-features-v1','prepared_sha256',repeat('a',64),'candidate_sha256',repeat('b',64),'parents',parents,'images',images);end$$;
create function pg_temp.prepared(x jsonb)returns jsonb language plpgsql as $$declare c jsonb;o jsonb;receipts jsonb;begin
 c:=photo_quality_claim((x#>>'{check,id}')::uuid);o:=photo_quality_derivatives_reserve((x#>>'{check,id}')::uuid,(c#>>'{check,lease_token}')::uuid,pg_temp.manifest(x));
 select jsonb_agg(v||jsonb_build_object('etag','"derivative-'||(v->>'role')||'-'||(v->>'region')||'"'))into receipts from jsonb_array_elements(o->'images')v;
 return photo_quality_derivatives_complete((x#>>'{check,id}')::uuid,(c#>>'{check,lease_token}')::uuid,receipts);end$$;
create function pg_temp.bind(x jsonb,paid_generation boolean default true)returns jsonb language plpgsql security definer as $$declare e jsonb:=x->'evidence';q jsonb:=x->'check';rid uuid:=gen_random_uuid();begin
 if paid_generation then
  insert into serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,sponsored_unlimited,state)values((e->>'org_id')::uuid,(e->>'actor_id')::uuid,e->>'request_key','photo.declutter:0','gemini','gemini-3.1-flash-image',repeat('a',64),'closed-fixture',.0001,true,'succeeded');
  insert into cost_ledger(org_id,feature,provider,model,total_cents,meta)values((e->>'org_id')::uuid,'photo_edit','gemini','gemini-3.1-flash-image',.0001,jsonb_build_object('request_key',e->>'request_key','stage','photo.declutter:0'));
 end if;
 insert into serving_cost_reservations(id,org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,sponsored_unlimited)values(rid,(e->>'org_id')::uuid,(e->>'actor_id')::uuid,'photo-qc:'||(q->>'id'),'photo.qc:0','anthropic','claude-sonnet-5',repeat('e',64),'closed-fixture',.0001,true);
 return photo_quality_check_bind((e->>'actor_id')::uuid,(q->>'id')::uuid,(q->>'lease_token')::uuid,rid);end$$;
create function pg_temp.verdict()returns jsonb language sql as $$select '{"policy":"photo-fixed-features-v1","verdict":"pass","action":"accept","confidence":0.99,"preservation":{"geometry":100,"openings":100,"fixtures":100,"surfaces":100,"viewpoint":100},"artifacts":100,"edit_quality":100,"findings":[],"reason":"Closed synthetic verdict; no real photo quality assertion."}'::jsonb$$;
create function pg_temp.finish(x jsonb,v jsonb,paid_qc boolean default true)returns jsonb language plpgsql security definer as $$declare e jsonb:=x->'evidence';q jsonb:=x->'check';begin
 if paid_qc then
  update serving_cost_reservations set state='succeeded',settled_at=now()where id=(q->>'reservation_id')::uuid;
  insert into cost_ledger(org_id,feature,provider,model,total_cents,meta)values((e->>'org_id')::uuid,'qc','anthropic','claude-sonnet-5',.0001,jsonb_build_object('request_key','photo-qc:'||(q->>'id'),'stage','photo.qc:0','photo_check_id',q->>'id','evidence_id',e->>'id','prepared_sha256',e#>>'{input,sha256}','output_sha256',e#>>'{output,sha256}','derivative_manifest_sha256',q->>'derivative_manifest_sha256','policy',e->>'policy'));
 end if;return photo_quality_finish((e->>'actor_id')::uuid,(q->>'id')::uuid,(q->>'lease_token')::uuid,v);end$$;
update app_config set value=jsonb_set(value,'{enabled}','true')where key='photo_quality';set local role service_role;
create temporary table at_bound as select pg_temp.seed('output25MiB')x;grant select on at_bound to service_role;
select photo_quality_evidence_receipt((select actor from f),(select(x#>>'{evidence,id}')::uuid from at_bound),'input','"prepared-etag"');
create temporary table candidate25 as select jsonb_build_object('sha256',repeat('b',64),'bytes',26214400,'mime','image/png','width',3584,'height',4780,'generation_stage','photo.declutter:0','provider','gemini','model','gemini-3.1-flash-image')o;grant select on candidate25 to service_role;
select pg_temp.no($q$select photo_quality_evidence_reserve((select actor from f),(select(x#>>'{evidence,id}')::uuid from at_bound),jsonb_set((select o from candidate25),'{bytes}','26214401'))$q$,'RP400','candidate next byte refuses');
select pg_temp.no($q$select photo_quality_evidence_reserve((select other from f),(select(x#>>'{evidence,id}')::uuid from at_bound),(select o from candidate25))$q$,'RP404','other actor cannot reserve candidate');
select pg_temp.ok(photo_quality_evidence_reserve((select actor from f),(select(x#>>'{evidence,id}')::uuid from at_bound),(select o from candidate25))#>>'{output,bytes}'='26214400','exact25MiB candidate retained');
select pg_temp.ok(photo_quality_evidence_reserve((select actor from f),(select(x#>>'{evidence,id}')::uuid from at_bound),(select o from candidate25))#>>'{output,bytes}'='26214400','same exact candidate replay immutable');
select pg_temp.no($q$select photo_quality_evidence_reserve((select actor from f),(select(x#>>'{evidence,id}')::uuid from at_bound),jsonb_set((select o from candidate25),'{sha256}',to_jsonb(repeat('c',64))))$q$,'RP409','candidate cannot replace retained SHA');
select pg_temp.no($q$select register_private_ai_output((select actor from f),(select org from f),(select listing from f),'renders','ai-router/'||(select org from f)||'/photo-evidence/'||(select actor from f)||'/'||(select x#>>'{evidence,id}'from at_bound)||'/candidate.png',26214400)$q$,'RP409','unreviewed large candidate cannot become deliverable');
select serving_operation_begin((select actor from f),(select org from f),'photo-quality:source9MB','photo_edit',repeat('d',64));
select pg_temp.no($q$select photo_quality_begin((select actor from f),(select org from f),'photo-quality:source9MB',(select listing from f),'declutter',null,null,jsonb_set(pg_temp.input(),'{bytes}','9000001'))$q$,'RP400','source next byte refuses');
select pg_temp.ok(photo_quality_begin((select actor from f),(select org from f),'photo-quality:source9MB',(select listing from f),'declutter',null,null,jsonb_set(pg_temp.input(),'{bytes}','9000000'))#>>'{evidence,input,bytes}'='9000000','exact9MB source remains admitted');
reset role;
select pg_temp.ok((select md5(prosrc)='7e208bcdf50821cd400cb33b5e00e8fc'from pg_proc where oid='public.photo_quality_calibration_begin(uuid,uuid,text,text,uuid,text,text,uuid,jsonb,jsonb)'::regprocedure),'historical calibration unchanged');
select pg_temp.ok(not has_function_privilege('authenticated','photo_quality_evidence_reserve(uuid,uuid,jsonb)','execute')and not has_function_privilege('anon','photo_quality_evidence_reserve(uuid,uuid,jsonb)','execute'),'actual output reservation service only');
update listings set deleted_at=now()where id=(select listing from f);set local role service_role;
select pg_temp.no($q$select photo_quality_evidence_reserve((select actor from f),(select(x#>>'{evidence,id}')::uuid from at_bound),(select o from candidate25))$q$,'RP404','deleted listing refuses exact candidate replay');
reset role;set local role authenticated;
select pg_temp.no('select *from photo_edit_evidence','permission denied','client cannot read quarantined candidate');reset role;
select jsonb_build_object('passed',true,'assertions',(select n from checks),'supplierCalls',0,'historicalCalibrationUnchanged',true);
rollback;
