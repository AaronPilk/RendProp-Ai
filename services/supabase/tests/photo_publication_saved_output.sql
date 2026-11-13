\set ON_ERROR_STOP on
begin;
do $$begin if inet_server_addr()is not null or current_database()not in('photo_publication_saved_output','rendprop_audit','rendprop_replay')then raise exception'Owned socket fixture only';end if;end$$;
create temp table checks(label text primary key);
grant all on checks to service_role,authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception'PUBLICATION FAIL: %',label;end if;insert into checks values(label);end$$;
create function pg_temp.no(command text,label text,needle text default'RP404:')returns void language plpgsql as $$declare msg text;begin begin execute command;exception when others then msg:=sqlerrm;end;perform pg_temp.ok(position(needle in coalesce(msg,''))>0,label);end$$;
insert into auth.users(id,email,is_anonymous)values('f8300000-0000-4000-8000-000000000001','publication-owner@fixture.invalid',false),('f8300000-0000-4000-8000-000000000002','publication-other@fixture.invalid',false);
create temp table f as select 'f8300000-0000-4000-8000-000000000001'::uuid actor,'f8300000-0000-4000-8000-000000000002'::uuid other,(select org_id from memberships where user_id='f8300000-0000-4000-8000-000000000001'and role='owner'limit 1)org,'f8300000-0000-4000-8000-000000000011'::uuid listing;
grant select on f to service_role,authenticated;
update orgs set plan='starter',plan_source='manual'where id=(select org from f);
insert into listings(id,org_id,agent_id,address)select listing,org,actor,'Synthetic accepted publication'from f;
update app_config set value=jsonb_set(value,'{enabled}','true')where key='photo_quality';
create function pg_temp.upload(original boolean,sha text,n bigint)returns uuid language plpgsql as $$declare a uuid:=gen_random_uuid();op jsonb;claim uuid;begin
 perform reserve_upload_assets((select actor from f),jsonb_build_array(jsonb_build_object('id',a,'listing_id',(select listing from f),'kind','photo','bucket','renders','storage_key','renders/'||(select org from f)||'/'||(select listing from f)||'/'||case when original then'original-'else'gallery-'end||a||'.jpg','bytes',n,'content_type','image/jpeg','content_type_declared',true,'sha256',sha,'idem_key','studio-upload:'||a)));
 op:=plan_upload_operation(a,'single');claim:=gen_random_uuid();perform claim_upload_operation((op->>'id')::uuid,claim);perform finish_upload_operation((op->>'id')::uuid,claim,'stored','synthetic-single',null,'image/jpeg');
 op:=plan_upload_operation(a,'copy');claim:=gen_random_uuid();perform claim_upload_operation((op->>'id')::uuid,claim);perform finish_upload_operation((op->>'id')::uuid,claim,'stored','synthetic-copy',null,'image/jpeg');
 perform settle_upload_reservation(a,true,(op->>'id')::uuid,jsonb_build_object('sha256',sha));return a;end$$;
set local role service_role;
create temp table ids as select pg_temp.upload(true,repeat('a',64),60000)original,pg_temp.upload(false,repeat('b',64),80000)output;
grant select on ids to service_role,authenticated;
select serving_operation_begin(actor,org,'publication-saved-output','photo_edit',repeat('d',64))from f;
create temp table evidence as select photo_quality_begin(actor,org,'publication-saved-output',listing,'stage',null,(select original from ids),jsonb_build_object('sha256',repeat('a',64),'bytes',60000,'mime','image/jpeg','width',1024,'height',768))x from f;
grant select,update on evidence to service_role,authenticated;
select photo_quality_evidence_receipt((select actor from f),(x#>>'{evidence,id}')::uuid,'input','prepared-etag')from evidence;
select photo_quality_evidence_reserve((select actor from f),(x#>>'{evidence,id}')::uuid,jsonb_build_object('sha256',repeat('b',64),'bytes',80000,'mime','image/jpeg','width',2048,'height',1536,'generation_stage','photo.stage:0','provider','gemini','model','gemini-3.1-flash-image'))from evidence;
update evidence set x=photo_quality_evidence_receipt((select actor from f),(x#>>'{evidence,id}')::uuid,'output','candidate-etag');
update evidence set x=photo_quality_release((select actor from f),(x#>>'{evidence,id}')::uuid,'{"synthetic":true}');
select pg_temp.ok((select x#>>'{evidence,state}'='accept'and x#>>'{check,state}'='pending'from evidence),'accepted output publishes while advisory check remains pending');
select pg_temp.ok(not studio_presenter_media_access((select output from ids)),'accepted uploaded output is hidden before publication');
create temp table before_save as select (select to_jsonb(e)from photo_edit_evidence e where e.id=(x#>>'{evidence,id}')::uuid)evidence,(select to_jsonb(q)from photo_quality_checks q where q.id=(x#>>'{check,id}')::uuid)check_row from evidence;
reset role;
select set_config('request.jwt.claim.sub',(select actor::text from f),true);
set local role authenticated;
select set_provenance_media((select(x#>>'{evidence,provenance_id}')::uuid from evidence),null,(select output from ids),null);
reset role;
select pg_temp.ok((select m.altered_key=a.storage_key from media_provenance m join capture_assets a on a.id=(select output from ids)where m.id=(select(x#>>'{evidence,provenance_id}')::uuid from evidence)),'normal compliance RPC retains exact completed output alias');
create function pg_temp.source()returns jsonb language sql as $$select photo_publication_source(actor,org,org,(select(x#>>'{evidence,id}')::uuid from evidence))from f$$;
set local role service_role;
select pg_temp.ok(pg_temp.source()#>>'{evidence,id}'=(select x#>>'{evidence,id}'from evidence),'saved alias accepted by source authority');
create temp table target as select photo_publication_target(actor,org,org,listing,(select output from ids))x from f;
select pg_temp.no('select photo_publication_target(actor,org,org,gen_random_uuid(),(select output from ids))from f','foreign listing target refuses','RP404:');
create temp table proof as select jsonb_build_object('sha256',repeat('b',64),'bytes',80000,'mime','image/jpeg','etag',x#>>'{target,etag}')t from target;
grant select on target,proof to service_role;
select pg_temp.ok((select photo_publication_resolve(actor,org,org,listing,(select output from ids),(select(x#>>'{evidence,provenance_id}')::uuid from evidence),(select t from proof))#>>'{evidence,id}'=(select x#>>'{evidence,id}'from evidence)from f),'real target and resolve preserve exact evidence');
reset role;
-- Each mutation is rolled back even after a source refusal; errors in the
-- mutation itself do not count as the source guard rejecting missing proof.
create function pg_temp.missing(command text,label text)returns void language plpgsql as $$declare passed boolean:=false;begin
 begin execute command;begin perform pg_temp.source();exception when others then if sqlerrm like'RP404:%'then passed:=true;else raise;end if;end;raise exception using errcode='PZ001',message='rollback synthetic mutation';exception when sqlstate'PZ001'then null;end;
 perform pg_temp.ok(passed,label);end$$;
select pg_temp.missing('update capture_assets set sha256=null where id=(select output from ids)','NULL output hash refuses');
select pg_temp.missing('update capture_assets set sha256=repeat(''f'',64)where id=(select output from ids)','wrong output hash refuses');
select pg_temp.no('update capture_assets set bytes=80001 where id=(select output from ids)','completed output length is immutable','RP409: completed upload publication is immutable');
select pg_temp.no('update capture_assets set content_type=''image/png''where id=(select output from ids)','completed output MIME is immutable','RP409: completed upload publication is immutable');
select pg_temp.missing('update upload_reservations set actor_id=(select other from f)where asset_id=(select output from ids)','foreign reservation actor refuses');
select pg_temp.missing('update upload_reservations set spec=jsonb_set(spec,''{key_role}'',''"original"'')where asset_id=(select output from ids)','non-gallery upload role refuses');
select pg_temp.missing('update upload_operations set claim=null where asset_id=(select output from ids)and kind=''copy''','missing retained claim refuses');
select pg_temp.missing('update upload_operations set etag=null where asset_id=(select output from ids)and kind=''copy''','missing retained ETag refuses');
select pg_temp.no('update capture_assets set upload_aborted=true where id=(select output from ids)','completed output cannot be marked aborted','RP409: completed upload publication is immutable');
select pg_temp.no('select photo_publication_source((select other from f),(select org from f),(select org from f),(select(x#>>''{evidence,id}'')::uuid from evidence))','foreign source actor refuses');
select pg_temp.no('select photo_publication_source((select actor from f),(select org from f),gen_random_uuid(),(select(x#>>''{evidence,id}'')::uuid from evidence))','foreign source library refuses');
set local role service_role;
select pg_temp.no('select photo_publication_reserve(actor,org,org,listing,(select output from ids),(select(x#>>''{evidence,id}'')::uuid from evidence),''{}'',''{}'',(select t from proof),gen_random_uuid())from f','missing physical body proofs refuse','RP409:');
create temp table reserved as select photo_publication_reserve(actor,org,org,listing,(select output from ids),(select(x#>>'{evidence,id}')::uuid from evidence),jsonb_build_object('sha256',repeat('a',64),'bytes',60000,'mime','image/jpeg','etag','prepared-etag'),jsonb_build_object('sha256',repeat('b',64),'bytes',80000,'mime','image/jpeg','etag','candidate-etag'),(select t from proof),gen_random_uuid())x from f;
grant select on reserved to service_role;
select pg_temp.ok((select x->>'dispatch'='true'and x#>>'{publication,photo_publication,phase}'='preparing'from reserved),'real reserve owns one source-copy dispatch');
select pg_temp.ok(not photo_publication_metadata_valid((select(x#>>'{publication,id}')::uuid from reserved)),'unsettled publication remains unreadable');
select pg_temp.no('select studio_attach_photo_from_upload(actor,org,listing,(select output from ids),''Before finish'',(select(x#>>''{publication,id}'')::uuid from reserved))from f','unprepared accepted result cannot attach','RP409:');
select pg_temp.no('select photo_publication_finish(actor,org,org,listing,(select(x#>>''{publication,id}'')::uuid from reserved),jsonb_build_object(''sha256'',repeat(''f'',64),''bytes'',60000,''mime'',''image/jpeg'',''etag'',''copied-source''),(select t from proof))from f','wrong actual source-copy hash refuses','RP409:');
create temp table finished as select photo_publication_finish(actor,org,org,listing,(select(x#>>'{publication,id}')::uuid from reserved),jsonb_build_object('sha256',repeat('a',64),'bytes',60000,'mime','image/jpeg','etag','copied-source'),(select t from proof))x from f;
grant select on finished to service_role;
select pg_temp.ok((select x#>>'{publication,photo_publication,phase}'='prepared'from finished)and photo_publication_metadata_valid((select(x#>>'{publication,id}')::uuid from finished)),'real finish verifies complete retained source copy');
select pg_temp.ok(studio_presenter_media_access((select output from ids))and photo_publication_asset_valid((select output from ids)),'prepared output passes Presenter and publication readability');
-- The real Studio client reads capture_assets under the authenticated JWT,
-- rather than using the service-role validation used by publication RPCs.
set local role authenticated;
select set_config('request.jwt.claim.sub',(select actor::text from f),true);
select pg_temp.ok(auth.uid()=(select actor from f),'prepared read uses exact authenticated owner');
select pg_temp.ok(studio_presenter_media_access((select output from ids)),'authenticated prepared output passes Presenter access');
select pg_temp.ok((select count(*)=1 from capture_assets where id=(select output from ids)),'authenticated prepared output is visible to Studio');
select set_config('request.jwt.claim.sub',(select other::text from f),true);
select pg_temp.ok(not studio_presenter_media_access((select output from ids)),'foreign actor cannot read prepared Presenter output');
select pg_temp.ok((select count(*)=0 from capture_assets where id=(select output from ids)),'foreign actor cannot see prepared output asset');
select set_config('request.jwt.claim.sub',(select actor::text from f),true);
select pg_temp.ok((select count(*)=1 from capture_assets where id=(select output from ids)),'owner read remains available after foreign actor check');
set local role service_role;
create temp table attached as select studio_attach_photo_from_upload(actor,org,listing,(select output from ids),'Accepted saved photo',(select(x#>>'{publication,id}')::uuid from finished))x from f;
select pg_temp.ok((select x->>'created'='true'and x#>>'{photo,id}'=(select output::text from ids)from attached),'actual final attach uses returned publication identity');
select pg_temp.ok((select studio_attach_photo_from_upload(actor,org,listing,(select output from ids),'Replay',(select(x#>>'{publication,id}')::uuid from finished))->>'created'='false'from f),'attachment replay does not duplicate photo');
select pg_temp.ok((select photo_publication_finish(actor,org,org,listing,(select(x#>>'{publication,id}')::uuid from reserved),jsonb_build_object('sha256',repeat('a',64),'bytes',60000,'mime','image/jpeg','etag','copied-source'),(select t from proof))#>>'{publication,id}'=(select x#>>'{publication,id}'from finished)from f),'finish replay preserves canonical publication');
select pg_temp.ok((select photo_publication_reserve(actor,org,org,listing,(select output from ids),(select(x#>>'{evidence,id}')::uuid from evidence),jsonb_build_object('sha256',repeat('a',64),'bytes',60000,'mime','image/jpeg','etag','prepared-etag'),jsonb_build_object('sha256',repeat('b',64),'bytes',80000,'mime','image/jpeg','etag','candidate-etag'),(select t from proof),gen_random_uuid())->>'dispatch'='false'from f),'reserve replay never dispatches another source copy');
reset role;
select pg_temp.ok((select count(*)=1 from media_provenance where photo_publication is not null and listing_id=(select listing from f))and(select count(*)=1 from photos where id=(select output from ids)),'one publication and one attached photo after all replays');
select pg_temp.ok((select to_jsonb(e)=b.evidence from photo_edit_evidence e cross join before_save b where e.id=(select(x#>>'{evidence,id}')::uuid from evidence))and(select to_jsonb(q)=b.check_row from photo_quality_checks q cross join before_save b where q.id=(select(x#>>'{check,id}')::uuid from evidence)),'paid evidence and pending advisory check remain byte-identical');
select pg_temp.ok((select gallery_asset_ids='{}'::uuid[]and main_photo_key is null from listings where id=(select listing from f)),'attachment does not silently select or publish photo');
set local role service_role;
select pg_temp.ok((select count(*)=2 from media_provenance where listing_id=(select listing from f)and altered_key=(select storage_key from capture_assets where id=(select output from ids))),'saved compliance source and prepared publication retain exactly two historical rows');
select pg_temp.ok((select published.photo_publication#>>'{source,provenance_id}'=(select x#>>'{evidence,provenance_id}'from evidence)
 and photo_publication_metadata_valid(published.id) from media_provenance published where published.id=(select(x#>>'{publication,id}')::uuid from finished)),'prepared publication links the accepted source and complete retained proof');
select pg_temp.ok((select item->>'can_use'='true'and item->>'review_required'='true'and item->>'asset_id'=(select output::text from ids)
 from f cross join lateral jsonb_array_elements(studio_gallery_selection_snapshot(f.actor,f.org,f.listing)->'photos')item
 where item->>'photo_id'=(select output::text from ids)),'Studio selection admits the exact canonical saved A-to-B pair');
create temp table selection_request as select jsonb_build_object('family_asset_ids',jsonb_build_array((select output from ids)),
 'target',jsonb_build_object('asset_id',(select output from ids),'sha256',repeat('b',64),'bytes',80000),
 'expected_selection',jsonb_build_object('gallery_asset_ids','[]'::jsonb,'main_photo_key',null),
 'follow_family_cover',false,'reviewed',false)body;
grant select on selection_request to service_role;
create temp table selected as select native_gallery_selection_change(actor,org,org,listing,gen_random_uuid(),(select body from selection_request))x from f;
select pg_temp.ok((select x->'gallery_asset_ids'=to_jsonb(array[(select output from ids)])and x->'replayed'='false'::jsonb from selected),'native selection accepts only the exact prepared saved A-to-B pair');
create temp table studio_selected as select studio_gallery_selection_change(actor,org,listing,'use_cover',(select output from ids),
 jsonb_build_object('gallery_asset_ids',array[(select output from ids)],'main_photo_key',null),null,null,true)x from f;
select pg_temp.ok((select x->>'main_photo_key'=(select storage_key from capture_assets where id=(select output from ids))from studio_selected)
 and(select main_photo_key=(select storage_key from capture_assets where id=(select output from ids))from listings where id=(select listing from f)),'Studio cover action retains the same exact selected saved photo');
-- Roll back each malformed A-to-B pair after checking both changed consumers.
-- A rejected UPDATE is not a successful selection refusal.
reset role;
create function pg_temp.bad_pair(command text,label text)returns void language plpgsql as $$
declare studio_refused boolean:=false;native_refused boolean:=false;native_error text;
begin
 begin
  execute command;
  select (public.studio_gallery_photo_choice(f.org,f.listing,(select output from ids))->>'can_use')='false'
   into studio_refused from f;
  begin
   perform public.native_gallery_selection_target(f.org,f.listing,(select output from ids),repeat('b',64),80000,false)from f;
  exception when others then native_error:=sqlerrm;
  end;
  native_refused:=position('RP409: This photo has ambiguous edit evidence' in coalesce(native_error,''))>0;
  raise exception using errcode='PZ001',message='rollback synthetic pair mutation';
 exception when sqlstate 'PZ001' then null;
 end;
 perform pg_temp.ok(studio_refused and native_refused,label);
end$$;
select pg_temp.bad_pair('update media_provenance set qc=jsonb_set(qc,''{evidence_id}'',to_jsonb(gen_random_uuid()::text))where id=(select(x#>>''{evidence,provenance_id}'')::uuid from evidence)',
 'wrong retained source evidence refuses in Studio and native');
select pg_temp.bad_pair('update media_provenance set qc=jsonb_set(qc,''{check_id}'',to_jsonb(gen_random_uuid()::text))where id=(select(x#>>''{evidence,provenance_id}'')::uuid from evidence)',
 'wrong retained advisory check refuses in Studio and native');
select pg_temp.bad_pair('update media_provenance set original_key=''renders/wrong-original.jpg''where id=(select(x#>>''{evidence,provenance_id}'')::uuid from evidence)',
 'wrong retained original refuses in Studio and native');
select pg_temp.bad_pair('update media_provenance set qc=jsonb_set(qc,''{output_sha256}'',to_jsonb(repeat(''f'',64)))where id=(select(x#>>''{evidence,provenance_id}'')::uuid from evidence)',
 'wrong retained output hash refuses in Studio and native');
-- An unrelated third row must remain ambiguous to both actual selection APIs.
create temp table third_row as select gen_random_uuid()id;
insert into media_provenance(id,org_id,listing_id,kind,label,edit,original_key,altered_key,disclosure)
 select (select id from third_row),org,listing,'photo_edit','Unrelated duplicate','synthetic',
  (select original_key from media_provenance where id=(select(x#>>'{publication,id}')::uuid from finished)),
  (select storage_key from capture_assets where id=(select output from ids)),'Unrelated disclosure'from f;
grant select on third_row to service_role;
set local role service_role;
select pg_temp.ok((select item->>'can_use'='false'from f cross join lateral jsonb_array_elements(studio_gallery_selection_snapshot(f.actor,f.org,f.listing)->'photos')item
 where item->>'photo_id'=(select output::text from ids)),'third unrelated provenance row remains unavailable in Studio');
select pg_temp.no('select native_gallery_selection_change(actor,org,org,listing,gen_random_uuid(),
 jsonb_set((select body from selection_request),''{expected_selection}'',jsonb_build_object(''gallery_asset_ids'',array[(select output from ids)],''main_photo_key'',
 (select storage_key from capture_assets where id=(select output from ids)))))from f',
 'third unrelated provenance row remains unavailable to native selection','RP409: This photo has ambiguous edit evidence');
reset role;
delete from media_provenance where id=(select id from third_row);
set local role service_role;
select pg_temp.ok((select item->>'can_use'='true'from f cross join lateral jsonb_array_elements(studio_gallery_selection_snapshot(f.actor,f.org,f.listing)->'photos')item
 where item->>'photo_id'=(select output::text from ids)),'canonical selection recovers when unrelated duplicate is removed');
reset role;
select pg_temp.ok(not has_function_privilege('authenticated','photo_publication_reserve(uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb,jsonb,uuid)','execute')and not has_function_privilege('anon','photo_publication_finish(uuid,uuid,uuid,uuid,uuid,jsonb,jsonb)','execute'),'publication orchestration remains service-only');
select jsonb_build_object('passed',true,'suite','photo-publication-saved-output','assertions',(select count(*)from checks),'chain','upload/early-release/compliance/source/target/resolve/reserve/finish/attach/gallery-choice/native-choice/readability/replay');
do $$begin if(select count(*)from checks)<>50 then raise exception'Incomplete publication fixture inventory';end if;end$$;
select 'PASS saved-output publication: 50 assertions';
rollback;
