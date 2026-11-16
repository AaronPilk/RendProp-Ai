-- Explicit check-only calibration of an already-paid historical result.
-- The old image/provenance/pointer never changes; calibration cannot promote media.
begin;
alter table public.photo_edit_evidence add column if not exists purpose text not null default'prospective'check(purpose in('prospective','calibration'));
alter table public.photo_edit_evidence add column if not exists calibration_source jsonb;
create or replace function public.photo_quality_snapshot(p_actor uuid,p_evidence uuid)returns jsonb
language plpgsql security definer set search_path=''as $$declare e public.photo_edit_evidence;q public.photo_quality_checks;begin
 e:=public.photo_quality_scope(p_actor,p_evidence);select * into q from public.photo_quality_checks where evidence_id=e.id and automatic;
 return jsonb_build_object('evidence',to_jsonb(e),'check',to_jsonb(q),'can_continue',e.output_etag is not null and q.state in('pending','preparing','derivative_ready')and q.judge_started_at is null and(q.state='derivative_ready'or q.lease_until is null or q.lease_until<=now())and not exists(select 1 from public.serving_cost_reservations where org_id=e.org_id and actor_id=e.actor_id and request_key='photo-qc:'||q.id and state<>'rejected'));end$$;
create or replace function public.photo_quality_lookup(p_actor uuid,p_org uuid,p_key text)returns jsonb
language plpgsql security definer set search_path=''as $$declare id uuid;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select e.id into id from public.photo_edit_evidence e where e.actor_id=p_actor and e.org_id=p_org and e.request_key=p_key and e.purpose='prospective';
 if id is null then return null;end if;return public.photo_quality_snapshot(p_actor,id);end$$;
do $$begin if(select md5(prosrc)from pg_proc where oid='public.photo_quality_evidence_receipt(uuid,uuid,text,text)'::regprocedure)not in('9089a21c0c3c207131c56bb9ebd4ce62','2d4c9882f27ebc60e42b9fd7bc6c9393')then raise exception'Review changed photo quality function photo_quality_evidence_receipt';end if;end$$;
create or replace function public.photo_quality_evidence_receipt(p_actor uuid,p_evidence uuid,p_kind text,p_etag text)returns jsonb
language plpgsql security definer set search_path=''as $$declare e public.photo_edit_evidence;prior text;kind text;begin
 e:=public.photo_quality_scope(p_actor,p_evidence);select * into e from public.photo_edit_evidence where id=p_evidence for update;
 if p_kind not in('input','output')or p_etag is null or length(p_etag)not between 1 and 200 then raise exception'RP400: Exact retained evidence receipt is required';end if;
 prior:=case when p_kind='input'then e.input_etag else e.output_etag end;if prior is not null then if prior<>p_etag then raise exception'RP409: Evidence object receipt changed';end if;return public.photo_quality_snapshot(p_actor,e.id);end if;
 if p_kind='output'and(e.output is null or e.input_etag is null)then raise exception'RP409: Both source and candidate must be retained';end if;
 if p_kind='input'then update public.photo_edit_evidence set input_etag=p_etag,state='input_ready',updated_at=now()where id=e.id;
 else
  kind:=case e.edit when'stage'then'virtual_stage'when'declutter'then'declutter'else'photo_edit'end;
  insert into public.media_provenance(org_id,listing_id,kind,model_id,edit,style,original_key,disclosure,qc,qc_checked_at)
  values(e.org_id,e.listing_id,kind,e.generation_model,e.edit,e.style,coalesce(e.original_reference->>'storage_key',e.input->>'key'),public.provenance_disclosure(kind,e.edit),jsonb_build_object('task','judge.photo_fixed_features','medium','photo','policy',e.policy,'publishable',false,'action','hold','evidence_id',e.id),now())returning id into e.provenance_id;
  update public.photo_edit_evidence set output_etag=p_etag,state='evidence_ready',provenance_id=e.provenance_id,updated_at=now()where id=e.id;
 end if;return public.photo_quality_snapshot(p_actor,e.id);end$$;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.photo_quality_failure(uuid,uuid,text,jsonb)'::regprocedure)not in('d72652f9bdb22266f19edc53cadec015','9b9ddeea992e200e75e5db6648a1fcf0')then raise exception'Review changed photo quality function photo_quality_failure';end if;end$$;
create or replace function public.photo_quality_failure(p_actor uuid,p_evidence uuid,p_phase text,p_facts jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$declare e public.photo_edit_evidence;begin
 e:=public.photo_quality_scope(p_actor,p_evidence);select * into e from public.photo_edit_evidence where id=p_evidence for update;
 if p_phase is null or length(p_phase)not between 1 and 80 or jsonb_typeof(p_facts)is distinct from'object'or pg_column_size(p_facts)>4096 then raise exception'RP400: Bounded failure evidence is required';end if;
 if e.state in('accept','refuse')then return public.photo_quality_snapshot(p_actor,e.id);end if;
 update public.photo_edit_evidence set state='hold',failure=jsonb_build_object('phase',p_phase,'facts',p_facts),updated_at=now()where id=e.id;
 update public.photo_quality_checks set state='hold',finished_at=now()where evidence_id=e.id and automatic;
 return public.photo_quality_snapshot(p_actor,e.id);end$$;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.photo_quality_cpu_failure(uuid,uuid,text)'::regprocedure)not in('63bd815e0a8ab838a4f39f53f2b24488','7b14da68b6228587f17f62da124bd1ed')then raise exception'Review changed photo quality function photo_quality_cpu_failure';end if;end$$;
create or replace function public.photo_quality_cpu_failure(p_check uuid,p_lease uuid,p_code text)returns jsonb
language plpgsql security definer set search_path=''as $$declare x jsonb;q public.photo_quality_checks;e public.photo_edit_evidence;begin
 x:=public.photo_quality_worker_scope(p_check,p_lease);q:=jsonb_populate_record(null::public.photo_quality_checks,x->'check');e:=jsonb_populate_record(null::public.photo_edit_evidence,x->'evidence');
 if p_code is distinct from'cpu_photo_comparison_failed'then raise exception'RP400: Closed photo preparation failure is required';end if;
 update public.photo_quality_checks set state=case when cpu_attempts>=3 then'hold'else'pending'end,lease_until=null where id=q.id;
 update public.photo_edit_evidence set state=case when q.cpu_attempts>=3 then'hold'else'evidence_ready'end,failure=jsonb_build_object('phase','comparison_preparation','code',p_code),updated_at=now()where id=e.id;
 return public.photo_quality_snapshot(e.actor_id,e.id);end$$;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.photo_quality_derivatives_complete(uuid,uuid,jsonb)'::regprocedure)not in('ceae80c2ef17908768ee3dd81c64edea','e7404249906d7b78bd44df653f5262ff')then raise exception'Review changed photo quality function photo_quality_derivatives_complete';end if;end$$;
create or replace function public.photo_quality_derivatives_complete(p_check uuid,p_lease uuid,p_receipts jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$declare q public.photo_quality_checks;e public.photo_edit_evidence;v jsonb;d jsonb;done jsonb:='[]';begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into q from public.photo_quality_checks where id=p_check for update;if q.id is null then raise exception'RP404: Photo check is unavailable';end if;e:=public.photo_quality_scope((select actor_id from public.photo_edit_evidence where id=q.evidence_id),q.evidence_id);
 if q.state='derivative_ready'and q.derivatives=p_receipts then return public.photo_quality_snapshot(e.actor_id,e.id);end if;
 if q.state<>'preparing'or q.lease_token is distinct from p_lease or q.lease_until<=now()or q.derivatives is null or jsonb_typeof(p_receipts)is distinct from'array'or jsonb_array_length(p_receipts)<>10 then raise exception'RP409: Current paired comparison receipts are required';end if;
 for v in select value from jsonb_array_elements(p_receipts)loop
  select value into d from jsonb_array_elements(q.derivatives)where value->>'key'=v->>'key';
  if d is null or(v-'etag')is distinct from d or length(coalesce(v->>'etag',''))not between 1 and 200 or exists(select 1 from jsonb_array_elements(done)where value->>'key'=v->>'key')then raise exception'RP409: A comparison object receipt changed';end if;done:=done||jsonb_build_array(v);
 end loop;
 update public.photo_quality_checks set derivatives=done,state='derivative_ready'where id=q.id;return public.photo_quality_snapshot(e.actor_id,e.id);end$$;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.photo_quality_status(uuid,uuid)'::regprocedure)not in('226458b7bd8f422da2cb086e5a936de1','88d864dee7300279e5b0e5bbec677d41')then raise exception'Review changed photo quality function photo_quality_status';end if;end$$;
create or replace function public.photo_quality_status(p_actor uuid,p_check uuid)returns jsonb
language plpgsql security definer set search_path=''as $$declare e public.photo_edit_evidence;q public.photo_quality_checks;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into q from public.photo_quality_checks where id=p_check;if q.id is null then raise exception'RP404: Saved photo check is unavailable';end if;
 e:=public.photo_quality_scope(p_actor,q.evidence_id);return public.photo_quality_snapshot(p_actor,e.id);end$$;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.photo_quality_evidence_reserve(uuid,uuid,jsonb)'::regprocedure)not in('ac4c3e7a05b211cef2acf51e9efb7a35','01d75528461a5bd46d6e2aaf8d305bb6')then raise exception'Review changed photo quality function photo_quality_evidence_reserve';end if;end$$;
create or replace function public.photo_quality_evidence_reserve(p_actor uuid,p_evidence uuid,p_output jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$declare e public.photo_edit_evidence;o jsonb;ext text;begin
 e:=public.photo_quality_scope(p_actor,p_evidence);select * into e from public.photo_edit_evidence where id=p_evidence for update;
 if e.input_etag is null then raise exception'RP409: Save the exact source before generating its edit';end if;
 if jsonb_typeof(p_output)is distinct from'object'or exists(select 1 from jsonb_object_keys(p_output)k where k not in('sha256','bytes','mime','width','height','generation_stage','provider','model'))
  or coalesce(p_output->>'sha256','')!~'^[a-f0-9]{64}$'or coalesce(p_output->>'bytes','')!~'^[1-9][0-9]{0,7}$'or(p_output->>'bytes')::bigint>9000000
  or coalesce(p_output->>'mime','')not in('image/jpeg','image/png','image/webp')or coalesce(p_output->>'width','')!~'^[1-9][0-9]{0,4}$'or coalesce(p_output->>'height','')!~'^[1-9][0-9]{0,4}$'
  or(p_output->>'width')::int>16384 or(p_output->>'height')::int>16384 or(p_output->>'width')::bigint*(p_output->>'height')::bigint>24000000 or coalesce(p_output->>'generation_stage','')!~'^[a-z0-9:._-]{1,80}$'or length(coalesce(p_output->>'provider',''))not between 1 and 40 or length(coalesce(p_output->>'model',''))not between 1 and 240 then raise exception'RP400: Exact measured candidate receipt is required';end if;
 if e.purpose='calibration'and p_output is distinct from(e.calibration_source-'source_key')then raise exception'RP409: Calibration must retain the exact already-paid historical output';end if;
 ext:=case p_output->>'mime'when'image/jpeg'then'jpg'when'image/png'then'png'else'webp'end;
 o:=(p_output-'generation_stage'-'provider'-'model')||jsonb_build_object('bucket','renders','key','ai-router/'||e.org_id||'/photo-evidence/'||e.actor_id||'/'||e.id||'/candidate.'||ext);
 if e.output is not null then if row(e.output,e.generation_stage,e.generation_provider,e.generation_model)is distinct from row(o,p_output->>'generation_stage',p_output->>'provider',p_output->>'model')then raise exception'RP409: Generated photo evidence is immutable';end if;return to_jsonb(e);end if;
 if e.state not in('input_ready','pending')then raise exception'RP409: This photo operation no longer accepts generated bytes';end if;
 perform public.library_media_storage_reserve(p_actor,e.org_id,'renders',o->>'key',(o->>'bytes')::bigint);
 update public.photo_edit_evidence set output=o,generation_stage=p_output->>'generation_stage',generation_provider=p_output->>'provider',generation_model=p_output->>'model',updated_at=now(),write_until=now()+interval'20 minutes'where id=e.id returning * into e;return to_jsonb(e);end$$;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.photo_quality_check_bind(uuid,uuid,uuid,uuid)'::regprocedure)not in('3c9795ac58ac283386d3fa7bea549318','947f12ca92492be65da21ceaa3beb29a')then raise exception'Review changed photo quality function photo_quality_check_bind';end if;end$$;
create or replace function public.photo_quality_check_bind(p_actor uuid,p_check uuid,p_lease uuid,p_reservation uuid)returns jsonb
language plpgsql security definer set search_path=''as $$declare q public.photo_quality_checks;e public.photo_edit_evidence;r public.serving_cost_reservations;approved jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into q from public.photo_quality_checks where id=p_check for update;if q.id is null then raise exception'RP404: Photo check is unavailable';end if;e:=public.photo_quality_scope(p_actor,q.evidence_id);
 if q.state<>'derivative_ready'or q.lease_token is distinct from p_lease or q.lease_until<=now()or q.judge_started_at is not null then raise exception'RP409: This photo judge was already started or its lease expired';end if;
 select value->'approved_judge'into approved from public.app_config where key='photo_quality'and(value->'enabled'='true'::jsonb or e.purpose='calibration');
 select * into r from public.serving_cost_reservations where id=p_reservation and actor_id=p_actor and org_id=e.org_id and request_key='photo-qc:'||q.id and stage='photo.qc:0'and state='reserved';
 if r.id is null or approved is null or r.provider is distinct from approved->>'provider'or r.model is distinct from approved->>'model'then raise exception'RP409: The approved photo quality attempt was not funded';end if;
 if not exists(select 1 from public.serving_cost_reservations g join public.cost_ledger l on l.org_id=g.org_id and l.provider=g.provider and l.model=g.model and l.feature='photo_edit'and l.total_cents>0 and l.meta->>'request_key'=g.request_key and l.meta->>'stage'=g.stage where g.actor_id=e.actor_id and g.org_id=e.org_id and g.request_key=e.request_key and g.stage=e.generation_stage and g.provider=e.generation_provider and g.model=e.generation_model and g.state='succeeded')then raise exception'RP409: Generated photo cost receipt is not confirmed; the edit remains private';end if;
 update public.photo_quality_checks set state='checking',judge_started_at=now(),reservation_id=r.id,provider=r.provider,model=r.model,input_payload_sha256=r.input_sha256 where id=q.id returning * into q;
 update public.photo_edit_evidence set state='checking',updated_at=now()where id=e.id;return jsonb_build_object('evidence',to_jsonb(e),'check',to_jsonb(q));end$$;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.photo_quality_finish(uuid,uuid,uuid,jsonb)'::regprocedure)not in('164e5ddd95ce1c9187f2dd21919719e8','161b233d66b210e6dfffa4d5b8188adc')then raise exception'Review changed photo quality function photo_quality_finish';end if;end$$;
create or replace function public.photo_quality_finish(p_actor uuid,p_check uuid,p_lease uuid,p_result jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$declare q public.photo_quality_checks;e public.photo_edit_evidence;r public.serving_cost_reservations;l public.cost_ledger;accept boolean;axis text;qc jsonb;final text;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into q from public.photo_quality_checks where id=p_check for update;if q.id is null then raise exception'RP404: Photo check is unavailable';end if;e:=public.photo_quality_scope(p_actor,q.evidence_id);
 if q.state in('accept','refuse','hold')and q.result is not null then if q.result is distinct from p_result then raise exception'RP409: A saved quality verdict is immutable';end if;return public.photo_quality_snapshot(e.actor_id,e.id);end if;
 if q.state<>'checking'or q.lease_token is distinct from p_lease or q.judge_started_at is null or jsonb_typeof(p_result)is distinct from'object'or octet_length(p_result::text)>3000 or p_result->>'policy'is distinct from e.policy or coalesce(p_result->>'action','')not in('accept','refuse','hold')or coalesce(p_result->>'verdict','')not in('pass','fail','unknown')then raise exception'RP409: A current bounded photo quality verdict is required';end if;
 select * into r from public.serving_cost_reservations where id=q.reservation_id and state='succeeded'and actor_id=p_actor and org_id=e.org_id;
 select * into l from public.cost_ledger where org_id=e.org_id and feature='qc'and provider=q.provider and model=q.model and total_cents>0 and meta->>'request_key'='photo-qc:'||q.id and meta->>'stage'='photo.qc:0'and meta->>'photo_check_id'=q.id::text and meta->>'evidence_id'=e.id::text and meta->>'prepared_sha256'=e.input->>'sha256'and meta->>'output_sha256'=e.output->>'sha256'and meta->>'derivative_manifest_sha256'=q.derivative_manifest_sha256 and meta->>'policy'=e.policy order by created_at desc,id desc limit 1;
 accept:=p_result->>'action'='accept'and p_result->>'verdict'='pass'and r.id is not null and l.id is not null and jsonb_typeof(p_result->'confidence')='number'and(p_result->>'confidence')::numeric between .85 and 1
  and jsonb_typeof(p_result->'artifacts')='number'and(p_result->>'artifacts')::numeric between 90 and 100 and jsonb_typeof(p_result->'edit_quality')='number'and(p_result->>'edit_quality')::numeric between 80 and 100 and p_result->'findings'='[]'::jsonb and jsonb_typeof(p_result->'preservation')='object';
 foreach axis in array array['geometry','openings','fixtures','surfaces','viewpoint']loop if jsonb_typeof(p_result#>array['preservation',axis])is distinct from'number'then accept:=false;elsif(p_result#>>array['preservation',axis])::numeric not between 95 and 100 then accept:=false;end if;end loop;
 accept:=coalesce(accept,false);
 final:=case when accept then'accept'when p_result->>'action'='refuse'and p_result->>'verdict'='fail'and r.id is not null and l.id is not null then'refuse'else'hold'end;
 qc:=p_result||jsonb_build_object('task','judge.photo_fixed_features','medium','photo','policy',e.policy,'purpose',e.purpose,'publishable',accept and e.purpose='prospective','action',case when accept then'accept'when final='refuse'then'refuse'else'hold'end,'check_id',q.id,'evidence_id',e.id,'prepared_sha256',e.input->>'sha256','output_sha256',e.output->>'sha256','derivative_manifest_sha256',q.derivative_manifest_sha256);
 if e.provenance_id is null then raise exception'RP409: The retained photo disclosure record is missing';end if;
 perform public.record_media_qc(e.provenance_id,e.org_id,qc);
 update public.photo_quality_checks set state=final,result=p_result,qc_ledger_id=l.id,finished_at=now()where id=q.id;
 update public.photo_edit_evidence set state=final,updated_at=now()where id=e.id;
 if accept and e.purpose='prospective'then
  perform public.register_private_ai_output(e.actor_id,e.org_id,e.listing_id,'renders',e.output->>'key',(e.output->>'bytes')::bigint);
  if e.original_reference is null then perform public.register_private_ai_output(e.actor_id,e.org_id,e.listing_id,'renders',e.input->>'key',(e.input->>'bytes')::bigint);end if;
  update public.media_provenance set altered_key=e.output->>'key'where id=e.provenance_id;
 end if;return public.photo_quality_snapshot(e.actor_id,e.id);end$$;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.photo_quality_private_output_guard()'::regprocedure)not in('c8d3ca3bbbb7a41f36c7e0214fb266cc','8b52d5d1dd44f2aedd2dd568f607ea89')then raise exception'Review changed photo quality function photo_quality_private_output_guard';end if;end$$;
create or replace function public.photo_quality_private_output_guard()returns trigger language plpgsql security definer set search_path=''as $$begin
 if(new.storage_key like'ai-router/%/photo-evidence/%'or exists(select 1 from public.photo_edit_evidence e where e.legacy_keys?new.storage_key))and not exists(select 1 from public.photo_edit_evidence e where e.state='accept'and e.purpose='prospective'and e.org_id=new.org_id and e.actor_id=new.user_id and e.listing_id is not distinct from new.listing_id and((e.output->>'key'=new.storage_key and(e.output->>'bytes')::bigint=new.bytes)or(e.input->>'key'=new.storage_key and(e.input->>'bytes')::bigint=new.bytes)))then raise exception'RP409: This photo still awaits fixed-feature quality review';end if;return new;end$$;

do $$begin if(select md5(prosrc)from pg_proc where oid='public.photo_quality_provenance_media_guard()'::regprocedure)not in('77a9e6aa464a2d692404baff0cf3b351','40d1ad1ca66f1e46e84bd6fc6cb57fc0')then raise exception'Review changed photo quality function photo_quality_provenance_media_guard';end if;end$$;
create or replace function public.photo_quality_provenance_media_guard()returns trigger language plpgsql security definer set search_path=''as $$declare e public.photo_edit_evidence;begin
 select * into e from public.photo_edit_evidence where provenance_id=new.id;
 if e.id is not null and e.purpose='calibration'and new.altered_key is not null then raise exception'RP409: Calibration evidence cannot become listing media';end if;
 if e.id is not null and new.altered_key is not null and new.altered_key is distinct from old.altered_key and(new.altered_key is distinct from e.output->>'key')then
  if e.state<>'accept'or not exists(select 1 from public.capture_assets a where a.listing_id=e.listing_id and a.storage_key=new.altered_key and a.uploaded and not a.upload_aborted and a.sha256=e.output->>'sha256'and a.bytes=(e.output->>'bytes')::bigint)then raise exception'RP409: The selected version is not the exact checked photo';end if;end if;return new;end$$;

create or replace function public.photo_quality_calibration_begin(p_actor uuid,p_org uuid,p_key text,p_request_sha256 text,p_listing uuid,p_edit text,p_style text,p_original_asset uuid,p_input jsonb,p_output jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$declare e public.photo_edit_evidence;q public.photo_quality_checks;op public.serving_operations;saved public.serving_operation_results;owned public.private_ai_outputs;c jsonb;original jsonb;new_id uuid:=gen_random_uuid();ext text;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 perform pg_advisory_xact_lock(hashtextextended('photo-quality:'||p_org||':'||p_actor||':'||p_key,82));
 select * into op from public.serving_operations where org_id=p_org and actor_id=p_actor and request_key=p_key and state='completed'and input_sha256=p_request_sha256;
 select * into saved from public.serving_operation_results where org_id=p_org and actor_id=p_actor and request_key=p_key;
 if op.request_key is null or saved.request_key is null or saved.result->>'kind'is distinct from'photo_output'or saved.result->>'bucket'is distinct from'renders'or saved.result->>'key'is distinct from p_output->>'source_key'or saved.result->>'mime'is distinct from p_output->>'mime'
  or saved.result#>>'{metadata,edit}'is distinct from p_edit or saved.result#>>'{metadata,style}'is distinct from p_style then raise exception'RP409: A matching already-paid historical photo pointer and request body are required';end if;
 select * into owned from public.private_ai_outputs where org_id=p_org and user_id=p_actor and listing_id=p_listing and bucket='renders'and storage_key=p_output->>'source_key'and bytes=(p_output->>'bytes')::bigint;
 if owned.id is null or p_listing is null or p_original_asset is null then raise exception'RP404: Calibration requires the owned property original and saved output';end if;
 c:=public.listing_library_scope(p_actor,p_listing);if c->>'can_write'is distinct from'true'or(c->>'org_id')::uuid<>p_org then raise exception'RP404: Calibration property is unavailable';end if;
 original:=public.property_owned_upload(p_actor,p_listing,p_original_asset,'photo');
 if not exists(select 1 from public.serving_cost_reservations r join public.cost_ledger l on l.org_id=r.org_id and l.feature='photo_edit'and l.provider=r.provider and l.model=r.model and l.total_cents>0 and l.meta->>'request_key'=r.request_key and l.meta->>'stage'=r.stage
  where r.actor_id=p_actor and r.org_id=p_org and r.request_key=p_key and r.state='succeeded'and r.stage=p_output->>'generation_stage'and r.provider=p_output->>'provider'and r.model=p_output->>'model')then raise exception'RP409: Historical generation payment could not be confirmed';end if;
 select * into e from public.photo_edit_evidence where org_id=p_org and actor_id=p_actor and request_key=p_key;
 if e.id is not null then if row(e.purpose,e.request_sha256,e.listing_id,e.edit,e.style,e.original_asset_id,e.input-'key'-'bucket',e.calibration_source)is distinct from row('calibration'::text,p_request_sha256,p_listing,p_edit,p_style,p_original_asset,p_input,p_output)then raise exception'RP409: Saved calibration evidence is immutable';end if;
  return public.photo_quality_snapshot(p_actor,e.id)||jsonb_build_object('created',false);end if;
 if p_edit not in('twilight','sky','lawn','declutter','stage','custom')or p_style is not null and length(p_style)>80 or jsonb_typeof(p_input)is distinct from'object'or exists(select 1 from jsonb_object_keys(p_input)k where k not in('sha256','bytes','mime','width','height'))
  or coalesce(p_input->>'sha256','')!~'^[a-f0-9]{64}$'or coalesce(p_input->>'bytes','')!~'^[1-9][0-9]{0,7}$'or(p_input->>'bytes')::bigint>1000000 or coalesce(p_input->>'mime','')not in('image/jpeg','image/png','image/webp')then raise exception'RP400: Exact bounded historical prepared input is required';end if;
 if jsonb_typeof(p_output)is distinct from'object'or exists(select 1 from jsonb_object_keys(p_output)k where k not in('source_key','sha256','bytes','mime','width','height','generation_stage','provider','model'))
  or coalesce(p_output->>'sha256','')!~'^[a-f0-9]{64}$'or coalesce(p_output->>'bytes','')!~'^[1-9][0-9]{0,7}$'or(p_output->>'bytes')::bigint>9000000 or coalesce(p_output->>'mime','')not in('image/jpeg','image/png','image/webp')
  or coalesce(p_output->>'width','')!~'^[1-9][0-9]{0,4}$'or coalesce(p_output->>'height','')!~'^[1-9][0-9]{0,4}$'or(p_output->>'width')::int>16384 or(p_output->>'height')::int>16384 or(p_output->>'width')::bigint*(p_output->>'height')::bigint>24000000 then raise exception'RP400: Exact bounded historical candidate is required';end if;
 ext:=case p_input->>'mime'when'image/jpeg'then'jpg'when'image/png'then'png'else'webp'end;
 insert into public.photo_edit_evidence(id,org_id,actor_id,listing_id,library_org_id,request_key,request_sha256,policy,edit,style,original_asset_id,original_reference,input,purpose,calibration_source)
 values(new_id,p_org,p_actor,p_listing,(c->>'library_org_id')::uuid,p_key,p_request_sha256,'photo-fixed-features-v1',p_edit,p_style,p_original_asset,original,p_input||jsonb_build_object('bucket','renders','key','ai-router/'||p_org||'/photo-evidence/'||p_actor||'/'||new_id||'/input.'||ext),'calibration',p_output)returning * into e;
 perform public.photo_quality_scope(p_actor,e.id);perform public.library_media_storage_reserve(p_actor,p_org,'renders',e.input->>'key',(p_input->>'bytes')::bigint);
 insert into public.photo_quality_checks(evidence_id,policy)values(e.id,e.policy)returning * into q;
 return public.photo_quality_snapshot(p_actor,e.id)||jsonb_build_object('created',true);end$$;
revoke all on function public.photo_quality_snapshot(uuid,uuid),public.photo_quality_calibration_begin(uuid,uuid,text,text,uuid,text,text,uuid,jsonb,jsonb)from public,anon,authenticated;
grant execute on function public.photo_quality_snapshot(uuid,uuid),public.photo_quality_calibration_begin(uuid,uuid,text,text,uuid,text,text,uuid,jsonb,jsonb)to service_role;
commit;
