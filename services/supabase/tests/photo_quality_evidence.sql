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
create function pg_temp.bind(x jsonb,paid_generation boolean default true,retain_context boolean default true)returns jsonb language plpgsql security definer as $$declare e jsonb:=x->'evidence';q jsonb:=x->'check';rid uuid:=gen_random_uuid();begin
 if retain_context then perform public.photo_quality_set_context((e->>'actor_id')::uuid,(e->>'id')::uuid,e->>'request_sha256',jsonb_build_object('edit',e->>'edit','style',e->'style','instruction',''));end if;
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
select pg_temp.ok((select value->>'enabled'='false'from app_config where key='photo_quality'),'policy ships disabled');
select pg_temp.ok((select bool_and(relrowsecurity)from pg_class where relname in('photo_edit_evidence','photo_quality_checks')),'evidence and checks have RLS');
select pg_temp.ok(not has_table_privilege('authenticated','photo_edit_evidence','SELECT')and not has_table_privilege('service_role','photo_edit_evidence','UPDATE'),'no direct client reads or service mutations');
select pg_temp.ok(not has_function_privilege('authenticated','photo_quality_finish(uuid,uuid,uuid,jsonb)','EXECUTE')and not has_function_privilege('anon','photo_quality_begin(uuid,uuid,text,uuid,text,text,uuid,jsonb,jsonb)','EXECUTE'),'clients cannot claim machine verdicts');
set local role service_role;
select pg_temp.no($q$select pg_temp.seed('inactive')$q$,'RP503','inactive policy refuses before generator');
reset role;update app_config set value=jsonb_set(value,'{enabled}','true')where key='photo_quality';set local role service_role;
create temporary table b as select pg_temp.seed('happy')x;grant select,update on b to service_role;
select pg_temp.ok((select x->>'created'='true'and x#>>'{check,state}'='pending'from b),'one prospective operation creates one pending check');
select pg_temp.ok((pg_temp.seed('happy')->>'created')='false','same operation replays check without regeneration');
select pg_temp.no($q$select photo_quality_status((select other from f),(select(x#>>'{check,id}')::uuid from b))$q$,'RP404','other account cannot read evidence');
select pg_temp.no($q$select photo_quality_evidence_reserve((select actor from f),(select(x#>>'{evidence,id}')::uuid from b),'{}')$q$,'RP409','source must be retained before paid candidate');
update b set x=pg_temp.candidate(x);
select pg_temp.ok((select x#>>'{evidence,state}'='evidence_ready'and x#>>'{check,state}'='pending'from b),'paid candidate saved privately before checking');
select pg_temp.ok((select count(*)=0 from private_ai_outputs where storage_key=(select x#>>'{evidence,output,key}'from b)),'candidate is not ordinary ready media');
select pg_temp.no($q$select register_private_ai_output((select actor from f),(select org from f),(select listing from f),'renders',(select x#>>'{evidence,output,key}'from b),8000000)$q$,'RP409','pending evidence cannot bypass ordinary registry');
select pg_temp.no($q$select register_private_ai_output((select actor from f),(select org from f),(select listing from f),'renders',(select x#>>'{evidence,legacy_keys,0}'from b),8000000)$q$,'RP409','pending evidence cannot bypass legacy pointerless fallback');
select pg_temp.ok((select qc->>'publishable'='false'and altered_key is null from media_provenance where id=(select(x#>>'{evidence,provenance_id}')::uuid from b)),'pending provenance stays unpublished');
create temporary table c as select photo_quality_claim((select(x#>>'{check,id}')::uuid from b))x;grant select on c to service_role;
select pg_temp.ok((select x->>'action'='prepare_photo_quality'and x#>>'{check,cpu_attempts}'='1'from c),'private CPU comparison gets leased');
select pg_temp.ok(photo_quality_claim((select(x#>>'{check,id}')::uuid from b))->>'action'='wait','active CPU lease cannot duplicate');
select pg_temp.no($q$select photo_quality_worker_scope((select(x#>>'{check,id}')::uuid from b),gen_random_uuid())$q$,'RP409','stale worker cannot read exact private capability');
select pg_temp.ok(photo_quality_heartbeat((select(x#>>'{check,id}')::uuid from b),(select(x#>>'{check,lease_token}')::uuid from c)),'current CPU heartbeat keeps exact lease');
select pg_temp.no($q$select photo_quality_derivatives_reserve((select(x#>>'{check,id}')::uuid from b),(select(x#>>'{check,lease_token}')::uuid from c),jsonb_set(pg_temp.manifest((select x from b)),'{candidate_sha256}',to_jsonb(repeat('f',64))))$q$,'RP400','wrong candidate SHA cannot receive derivative PUTs');
select pg_temp.no($q$select photo_quality_derivatives_reserve((select(x#>>'{check,id}')::uuid from b),(select(x#>>'{check,lease_token}')::uuid from c),jsonb_set(pg_temp.manifest((select x from b)),'{images,1,crop,left}','1'))$q$,'RP409','quadrant crop gap is refused');
select pg_temp.no($q$select photo_quality_derivatives_reserve((select(x#>>'{check,id}')::uuid from b),(select(x#>>'{check,lease_token}')::uuid from c),jsonb_set(pg_temp.manifest((select x from b)),'{images,0,width}','2048'))$q$,'RP409','comparison cannot upsample source');
select pg_temp.no($q$select photo_quality_derivatives_reserve((select(x#>>'{check,id}')::uuid from b),(select(x#>>'{check,lease_token}')::uuid from c),jsonb_set(pg_temp.manifest((select x from b)),'{parents,1,normalized_width}','4000'))$q$,'RP409','true candidate aspect drift cannot be stretched away');
select pg_temp.no($q$select photo_quality_derivatives_reserve((select(x#>>'{check,id}')::uuid from b),(select(x#>>'{check,lease_token}')::uuid from c),(select jsonb_set(pg_temp.manifest((select x from b)),'{images}',jsonb_agg(v||'{"bytes":600001}'::jsonb))from jsonb_array_elements(pg_temp.manifest((select x from b))->'images')v))$q$,'RP413','aggregate comparison memory bound refuses whole package');
-- Current lease reused: prepared helper starts with claim wait but returns same check.
update b set x=pg_temp.prepared(x);
select pg_temp.ok((select x#>>'{check,state}'='derivative_ready'and jsonb_array_length(x#>'{check,derivatives}')=10 from b),'all ten exact comparison receipts retained before judge');
select pg_temp.ok((select (x->>'can_continue')::boolean from b),'definitively unstarted judge can continue same check');
update b set x=pg_temp.bind(x);
select pg_temp.ok((select x#>>'{check,state}'='checking'and x#>>'{check,judge_started_at}'is not null from b),'funded exact judge bound once before supplier');
select pg_temp.no($q$select photo_quality_check_bind((select actor from f),(select(x#>>'{check,id}')::uuid from b),(select(x#>>'{check,lease_token}')::uuid from b),(select(x#>>'{check,reservation_id}')::uuid from b))$q$,'RP409','second paid judge dispatch refused');
select pg_temp.ok(photo_quality_claim((select(x#>>'{check,id}')::uuid from b))->>'action'='wait','ambiguous judge never receives automatic retry');
update b set x=pg_temp.finish(x,pg_temp.verdict());
select pg_temp.ok((select x#>>'{evidence,state}'='accept'and x#>>'{check,state}'='accept'from b),'paid passing verdict atomically accepts');
select pg_temp.ok((select count(*)=2 from private_ai_outputs where storage_key in((select x#>>'{evidence,output,key}'from b),(select x#>>'{evidence,input,key}'from b))),'accepted output and prepared original registered exactly');
select pg_temp.ok((select altered_key=(select x#>>'{evidence,output,key}'from b)and(qc->>'publishable')::boolean from media_provenance where id=(select(x#>>'{evidence,provenance_id}')::uuid from b)),'exact accepted source/output provenance promoted');
select pg_temp.ok((photo_quality_finish((select actor from f),(select(x#>>'{check,id}')::uuid from b),(select(x#>>'{check,lease_token}')::uuid from b),pg_temp.verdict())#>>'{check,state}')='accept','same final receipt replays without paid work');
select pg_temp.no($q$select photo_quality_finish((select actor from f),(select(x#>>'{check,id}')::uuid from b),(select(x#>>'{check,lease_token}')::uuid from b),jsonb_set(pg_temp.verdict(),'{confidence}','0.9'))$q$,'RP409','accepted verdict cannot be rewritten');
select pg_temp.no($q$update media_provenance set altered_key='unrelated-object'where id=(select(x#>>'{evidence,provenance_id}')::uuid from b)$q$,'RP409','accepted provenance cannot attach unrelated bytes');
create temporary table bad as select pg_temp.bind(pg_temp.prepared(pg_temp.candidate(pg_temp.seed('door-drift'))))x;grant select,update on bad to service_role;
update bad set x=pg_temp.finish(x,jsonb_set(jsonb_set(pg_temp.verdict(),'{preservation,openings}','70'),'{findings}','[{"category":"openings","region":"br","source":"Covered opening","output":"Clear glazing and a new view","certainty":"confirmed"}]'));
select pg_temp.ok((select x#>>'{check,state}'='hold'from bad),'contradictory pass plus changed door stays held');
select pg_temp.ok((select count(*)=0 from private_ai_outputs where storage_key=(select x#>>'{evidence,output,key}'from bad)),'door drift cannot become ready media');
create temporary table unpaid as select pg_temp.bind(pg_temp.prepared(pg_temp.candidate(pg_temp.seed('no-qc-ledger'))))x;grant select,update on unpaid to service_role;
update unpaid set x=pg_temp.finish(x,pg_temp.verdict(),false);
select pg_temp.ok((select x#>>'{check,state}'='hold'from unpaid),'passing text without settled paid QC receipt is held');
create temporary table reject as select pg_temp.bind(pg_temp.prepared(pg_temp.candidate(pg_temp.seed('refused'))))x;grant select,update on reject to service_role;
update reject set x=pg_temp.finish(x,jsonb_set(jsonb_set(pg_temp.verdict(),'{verdict}','"fail"'),'{action}','"refuse"'));
select pg_temp.ok((select x#>>'{check,state}'='refuse'from reject),'paid terminal refusal retained without promotion');
select pg_temp.no($q$select register_private_ai_output((select actor from f),(select org from f),(select listing from f),'renders',(select x#>>'{evidence,legacy_keys,1}'from reject),8000000)$q$,'RP409','refused legacy output remains quarantined');
create temporary table missing_gen as select pg_temp.prepared(pg_temp.candidate(pg_temp.seed('no-generation-ledger')))x;grant select on missing_gen to service_role;
select pg_temp.no($q$select pg_temp.bind((select x from missing_gen),false)$q$,'RP409','missing generation settlement cannot start QC');
create temporary table missing_context as select pg_temp.prepared(pg_temp.candidate(pg_temp.seed('no-judge-context')))x;grant select on missing_context to service_role;
select pg_temp.no($q$select pg_temp.bind((select x from missing_context),true,false)$q$,'Exact saved photo judge context is missing','funded judge without retained context cannot dispatch');
create temporary table pano as select pg_temp.candidate(pg_temp.seed('four-k-panorama'),12288,1536)x;grant select on pano to service_role;
select pg_temp.ok((select x#>>'{evidence,output,width}'='12288'from pano),'official4Kpanorama geometry retained without resize');
create temporary table cpu as select pg_temp.candidate(pg_temp.seed('cpu-infra'))x;grant select,update on cpu to service_role;
do $$declare c jsonb;begin for i in 1..3 loop c:=photo_quality_claim((select(x#>>'{check,id}')::uuid from cpu));perform photo_quality_cpu_failure((select(x#>>'{check,id}')::uuid from cpu),(c#>>'{check,lease_token}')::uuid,'cpu_photo_comparison_failed');end loop;end$$;
select pg_temp.ok((photo_quality_status((select actor from f),(select(x#>>'{check,id}')::uuid from cpu))#>>'{check,state}')='hold','three CPU infrastructure failures hold exact candidate');
select pg_temp.ok(photo_quality_claim((select(x#>>'{check,id}')::uuid from cpu))->>'action'='wait','exhausted CPU cannot restart generation/judge');
select pg_temp.ok((select count(*)=0 from serving_cost_reservations where request_key='photo-qc:'||(select x#>>'{check,id}'from cpu)),'CPU failures never create paid judge');
select pg_temp.ok(jsonb_array_length(photo_quality_media_targets(array[(select org from f)],(select listing from f)))>=10,'held evidence and derivative keys in erasure inventory');
select pg_temp.ok(exists(select 1 from jsonb_array_elements(account_private_output_targets(array[(select org from f)],'fixture-uploads','fixture-renders'))v where v->>'key'=(select x#>>'{evidence,output,key}'from bad)and v->>'bucket'='fixture-renders'),'account erasure includes non-ready candidate');
-- Historical saved output with no prospective journal remains byte-for-byte replayable.
select register_private_ai_output((select actor from f),(select org from f),(select listing from f),'renders','ai-router/'||(select org from f)||'/completed-photo/'||repeat('9',64)||'.jpg',222222);
select pg_temp.ok((select bytes=222222 from private_ai_outputs where storage_key='ai-router/'||(select org from f)||'/completed-photo/'||repeat('9',64)||'.jpg'),'historical2Kpointerless replay unchanged');
-- Check-only calibration of a genuine historical paid pointer. No original
-- operation/output/provenance promotion, replacement, image quota or generator.
reset role;
set local session_replication_role=replica;
insert into capture_assets(id,listing_id,kind,bucket,storage_key,bytes,sha256,uploaded,transport_version,content_type)select 'f8200000-0000-4000-8000-000000000031',listing,'photo','uploads','uploads/'||org||'/'||listing||'/original-owned.jpg',60000,repeat('a',64),true,2,'image/jpeg'from f;
insert into upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes,spent_bytes,state,settled_at)select id,(select org from f),listing_id,(select actor from f),current_date,'{}',0,bytes,'completed',now()from capture_assets where id='f8200000-0000-4000-8000-000000000031';
insert into upload_operations(asset_id,kind,bucket,object_key,bytes,expected_bytes,content_type,content_type_declared,asset_kind,state,etag)select id,'copy',bucket,storage_key,bytes,bytes,content_type,true,kind,'retained','"historical-original-etag"'from capture_assets where id='f8200000-0000-4000-8000-000000000031';
set local session_replication_role=origin;
insert into media_provenance(id,org_id,listing_id,kind,edit,model_id,disclosure,original_key,altered_key)select 'f8200000-0000-4000-8000-000000000032',org,listing,'declutter','declutter','gemini-3.1-flash-image','AI-altered photo','uploads/'||org||'/'||listing||'/original-owned.jpg','ai-router/'||org||'/completed-photo/'||repeat('9',64)||'.jpg'from f;
insert into serving_operations(org_id,actor_id,request_key,operation,input_sha256,state)select org,actor,'photo-quality:historical-2k','/ai-photo',repeat('7',64),'completed'from f;
insert into serving_operation_results(org_id,actor_id,request_key,result)select org,actor,'photo-quality:historical-2k',jsonb_build_object('kind','photo_output','bucket','renders','key','ai-router/'||org||'/completed-photo/'||repeat('9',64)||'.jpg','mime','image/jpeg','metadata',jsonb_build_object('edit','declutter','provenance',jsonb_build_object('id','f8200000-0000-4000-8000-000000000032','recorded',true)))from f;
insert into serving_cost_reservations(org_id,actor_id,request_key,stage,provider,model,input_sha256,tariff_version,hold_cents,sponsored_unlimited,state)select org,actor,'photo-quality:historical-2k','photo.declutter:0','gemini','gemini-3.1-flash-image',repeat('a',64),'closed-historical-fixture',.0001,true,'succeeded'from f;
insert into cost_ledger(org_id,feature,provider,model,total_cents,meta)select org,'photo_edit','gemini','gemini-3.1-flash-image',.0001,'{"request_key":"photo-quality:historical-2k","stage":"photo.declutter:0"}'from f;
create temporary table old_historical as select(select to_jsonb(p)from media_provenance p where p.id='f8200000-0000-4000-8000-000000000032')provenance,(select to_jsonb(o)from serving_operations o where request_key='photo-quality:historical-2k')operation,(select result from serving_operation_results where request_key='photo-quality:historical-2k')pointer;
create temporary table calibration_output as select jsonb_build_object('source_key','ai-router/'||org||'/completed-photo/'||repeat('9',64)||'.jpg','sha256',repeat('b',64),'bytes',222222,'mime','image/jpeg','width',4096,'height',3072,'generation_stage','photo.declutter:0','provider','gemini','model','gemini-3.1-flash-image')o from f;
grant select on old_historical,calibration_output to service_role;
update app_config set value=jsonb_set(value,'{enabled}','false')where key='photo_quality';set local role service_role;
select pg_temp.no($q$select photo_quality_calibration_begin((select actor from f),(select org from f),'photo-quality:historical-2k',repeat('8',64),(select listing from f),'declutter',null,'f8200000-0000-4000-8000-000000000031',pg_temp.input(),(select o from calibration_output))$q$,'RP409','calibration refuses different originalgenerationbodyhash');
select pg_temp.no($q$select photo_quality_calibration_begin((select actor from f),(select org from f),'photo-quality:historical-2k',repeat('7',64),(select listing from f),'declutter',null,'f8200000-0000-4000-8000-000000000031',pg_temp.input(),jsonb_set((select o from calibration_output),'{source_key}','"other-key"'))$q$,'RP409','calibration cannot substitute unrelated outputpointer');
create temporary table calibrated as select photo_quality_calibration_begin((select actor from f),(select org from f),'photo-quality:historical-2k',repeat('7',64),(select listing from f),'declutter',null,'f8200000-0000-4000-8000-000000000031',pg_temp.input(),(select o from calibration_output))x;grant select,update on calibrated to service_role;
select pg_temp.ok((select x->>'created'='true'and x#>>'{evidence,purpose}'='calibration'from calibrated),'ownedpaidpointer creates one nonpromotingcalibration whileordinarypolicyinactive');
select pg_temp.ok(photo_quality_lookup((select actor from f),(select org from f),'photo-quality:historical-2k')is null,'ordinarysaved2Klookup ignorescalibrationjournal');
select pg_temp.ok((photo_quality_calibration_begin((select actor from f),(select org from f),'photo-quality:historical-2k',repeat('7',64),(select listing from f),'declutter',null,'f8200000-0000-4000-8000-000000000031',pg_temp.input(),(select o from calibration_output))->>'created')='false','calibrationreplay retainsonecheck no generator');
select photo_quality_evidence_receipt((select actor from f),(select(x#>>'{evidence,id}')::uuid from calibrated),'input','"calibration-prepared-etag"');
select pg_temp.no($q$select photo_quality_evidence_reserve((select actor from f),(select(x#>>'{evidence,id}')::uuid from calibrated),jsonb_set((select o-'source_key'from calibration_output),'{sha256}',to_jsonb(repeat('c',64))))$q$,'RP409','calibrationcannotreplace already-paidcandidatebytes');
select photo_quality_evidence_reserve((select actor from f),(select(x#>>'{evidence,id}')::uuid from calibrated),(select o-'source_key'from calibration_output));
update calibrated set x=photo_quality_evidence_receipt((select actor from f),(x#>>'{evidence,id}')::uuid,'output','"calibration-candidate-etag"');
update calibrated set x=pg_temp.bind(pg_temp.prepared(x),false);
select pg_temp.ok((select x#>>'{check,state}'='checking'from calibrated),'QC-onlycalibration admitsrealhistoricalgenerationlineage withoutfakegenerationreceipt');
update calibrated set x=pg_temp.finish(x,pg_temp.verdict());
select pg_temp.ok((select x#>>'{check,state}'='accept'and x#>>'{evidence,purpose}'='calibration'from calibrated),'calibrationrecordsclassifierpass withoutclaimingpublishedmedia');
select pg_temp.ok((select count(*)=0 from private_ai_outputs where storage_key in((select x#>>'{evidence,input,key}'from calibrated),(select x#>>'{evidence,output,key}'from calibrated))),'calibrationneverpromotescandidateorpreparedoriginal');
select pg_temp.ok((select qc->>'publishable'='false'and qc->>'purpose'='calibration'and altered_key is null from media_provenance where id=(select(x#>>'{evidence,provenance_id}')::uuid from calibrated)),'passingcalibrationprovenanceremainsnonpublishable');
select pg_temp.no($q$select register_private_ai_output((select actor from f),(select org from f),(select listing from f),'renders',(select x#>>'{evidence,output,key}'from calibrated),222222)$q$,'RP409','passingcalibrationcannotbypassdeliverableregistry');
select pg_temp.no($q$update media_provenance set altered_key=(select x#>>'{evidence,output,key}'from calibrated)where id=(select(x#>>'{evidence,provenance_id}')::uuid from calibrated)$q$,'RP409','calibrationcannotattachlistingmedia');
select pg_temp.ok((photo_quality_status((select actor from f),(select(x#>>'{check,id}')::uuid from calibrated))#>>'{check,state}')='accept','calibrationstatusaddressesexactcheck despiteexcludednormallookup');
select pg_temp.ok((select (select to_jsonb(p)from media_provenance p where p.id='f8200000-0000-4000-8000-000000000032')=provenance and(select to_jsonb(o)from serving_operations o where request_key='photo-quality:historical-2k')=operation and(select result from serving_operation_results where request_key='photo-quality:historical-2k')=pointer from old_historical),'historicalpointeroperationandprovenanceremainbyteidentical');
select pg_temp.ok((select count(*)=1 from serving_cost_reservations where request_key='photo-quality:historical-2k'),'checkexistingcreatesnoadditionalgenerationattempt');
select pg_temp.ok((select count(*)=1 from private_ai_outputs where storage_key=(select o->>'source_key'from calibration_output)and bytes=222222),'originalhistoricaloutputreceiptunchanged');
reset role;
update listings set deleted_at=now()where id=(select listing from f);
select pg_temp.ok(exists(select 1 from privacy_cleanup_jobs j cross join lateral jsonb_array_elements(j.payload->'r2')v where j.source_id=(select listing from f)and v->>'key'=(select x#>>'{evidence,output,key}'from bad)),'listing erasure freezes held candidate before row deletion');
select pg_temp.ok((select not_before>=now()+interval'1 hour'from privacy_cleanup_jobs where source_id=(select listing from f)),'erasure waits finite evidence/CPUwrite lease');
set local role service_role;
select pg_temp.no($q$select photo_quality_status((select actor from f),(select(x#>>'{check,id}')::uuid from b))$q$,'RP404','withdrawn listing revokes even accepted evidence read');
reset role;set local role authenticated;
select pg_temp.no('select *from photo_edit_evidence','permission denied','actual client cannot read privatecheck inventory');
select pg_temp.no('select photo_quality_claim(gen_random_uuid())','permission denied','actual client cannot lease CPU');
reset role;
select jsonb_build_object('passed',true,'assertions',(select n from checks),'realProviderCalls',0,'actualPhotoQualityClaim',false);
rollback;
