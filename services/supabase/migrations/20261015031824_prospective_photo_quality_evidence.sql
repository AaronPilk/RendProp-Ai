-- Prospective fixed-feature photo review. Historical photo_output receipts are
-- unchanged. Evidence is private and non-deliverable until atomic acceptance.
create table if not exists public.photo_edit_evidence(
 id uuid primary key default gen_random_uuid(),org_id uuid not null references public.orgs(id)on delete cascade,actor_id uuid not null references auth.users(id)on delete cascade,
 listing_id uuid references public.listings(id)on delete cascade,library_org_id uuid not null,request_key text not null,request_sha256 text not null,legacy_keys jsonb not null default'[]'::jsonb,
 policy text not null check(policy='photo-fixed-features-v1'),edit text not null check(edit in('twilight','sky','lawn','declutter','stage','custom')),style text,
 original_asset_id uuid,original_reference jsonb,input jsonb not null,output jsonb,input_etag text,output_etag text,
 generation_stage text,generation_provider text,generation_model text,provenance_id uuid references public.media_provenance(id)on delete set null,
 state text not null default'pending'check(state in('pending','input_ready','evidence_ready','checking','accept','refuse','hold')),failure jsonb,
 write_until timestamptz not null default(now()+interval'20 minutes'),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 unique(org_id,actor_id,request_key),foreign key(org_id,actor_id,request_key)references public.serving_operations(org_id,actor_id,request_key));
create table if not exists public.photo_quality_checks(
 id uuid primary key default gen_random_uuid(),evidence_id uuid not null references public.photo_edit_evidence(id)on delete cascade,
 automatic boolean not null default true,policy text not null check(policy='photo-fixed-features-v1'),
 state text not null default'pending'check(state in('pending','preparing','derivative_ready','checking','accept','refuse','hold')),
 lease_token uuid,lease_until timestamptz,cpu_attempts integer not null default 0 check(cpu_attempts between 0 and 3),
 derivatives jsonb,derivative_manifest jsonb,derivative_manifest_sha256 text,judge_started_at timestamptz,reservation_id uuid references public.serving_cost_reservations(id),
 provider text,model text,input_payload_sha256 text,result jsonb,qc_ledger_id uuid references public.cost_ledger(id),created_at timestamptz not null default now(),finished_at timestamptz);
create unique index if not exists photo_quality_one_automatic on public.photo_quality_checks(evidence_id)where automatic;
do $$declare t text;begin foreach t in array array['photo_edit_evidence','photo_quality_checks']loop
 execute format('alter table public.%I enable row level security',t);execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);execute format('grant select on public.%I to service_role',t);end loop;end$$;
insert into public.app_config(key,value)values('photo_quality','{"enabled":false,"policy":"photo-fixed-features-v1","approved_judge":{"provider":"anthropic","model":"claude-sonnet-5"}}')on conflict do nothing;

create or replace function public.photo_quality_scope(p_actor uuid,p_evidence uuid)returns public.photo_edit_evidence
language plpgsql security definer set search_path=''as $$declare e public.photo_edit_evidence;c jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into e from public.photo_edit_evidence where id=p_evidence and actor_id=p_actor;
 if e.id is null or not exists(select 1 from auth.users where id=p_actor and is_anonymous=false)or not exists(select 1 from public.orgs where id=e.org_id and deleted_at is null)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception'RP404: Saved photo quality review is unavailable';end if;
 if e.listing_id is not null then c:=public.listing_library_scope(p_actor,e.listing_id);if c is null or c->>'can_write'<>'true'or(c->>'org_id')::uuid<>e.org_id then raise exception'RP404: Saved photo quality review is unavailable';end if;
 else if not exists(select 1 from public.memberships where user_id=p_actor and org_id=e.org_id and role in('owner','admin','agent'))then raise exception'RP404: Saved photo quality review is unavailable';end if;end if;
 if e.original_asset_id is not null and public.property_owned_upload(p_actor,e.listing_id,e.original_asset_id,'photo')is distinct from e.original_reference then raise exception'RP409: The selected original changed or was withdrawn';end if;return e;end$$;
create or replace function public.photo_quality_lookup(p_actor uuid,p_org uuid,p_key text)returns jsonb
language plpgsql security definer set search_path=''as $$declare e public.photo_edit_evidence;q public.photo_quality_checks;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into e from public.photo_edit_evidence where actor_id=p_actor and org_id=p_org and request_key=p_key;if e.id is null then return null;end if;
 e:=public.photo_quality_scope(p_actor,e.id);select * into q from public.photo_quality_checks where evidence_id=e.id and automatic;
 return jsonb_build_object('evidence',to_jsonb(e),'check',to_jsonb(q),'can_continue',e.output_etag is not null and q.state in('pending','preparing','derivative_ready')and q.judge_started_at is null and(q.state='derivative_ready'or q.lease_until is null or q.lease_until<=now())and not exists(select 1 from public.serving_cost_reservations where org_id=e.org_id and actor_id=e.actor_id and request_key='photo-qc:'||q.id and state<>'rejected'));end$$;
create or replace function public.photo_quality_begin(p_actor uuid,p_org uuid,p_key text,p_listing uuid,p_edit text,p_style text,p_original_asset uuid,p_input jsonb,p_legacy_keys jsonb default'[]'::jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$declare e public.photo_edit_evidence;q public.photo_quality_checks;op public.serving_operations;c jsonb;original jsonb;new_id uuid:=gen_random_uuid();ext text;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if not exists(select 1 from public.app_config where key='photo_quality'and value->'enabled'='true'::jsonb)then raise exception'RP503: Photo quality review is not active yet';end if;
 perform pg_advisory_xact_lock(hashtextextended('photo-quality:'||p_org||':'||p_actor||':'||p_key,82));
 select * into op from public.serving_operations where org_id=p_org and actor_id=p_actor and request_key=p_key;
 if op.request_key is null then raise exception'RP409: The original photo operation must be journaled first';end if;
 select * into e from public.photo_edit_evidence where org_id=p_org and actor_id=p_actor and request_key=p_key;
 if e.id is not null then if row(e.listing_id,e.edit,e.style,e.original_asset_id,e.input-'key'-'bucket',e.legacy_keys)is distinct from row(p_listing,p_edit,p_style,p_original_asset,p_input,p_legacy_keys)then raise exception'RP409: Saved photo quality inputs are immutable';end if;return public.photo_quality_lookup(p_actor,p_org,p_key)||jsonb_build_object('created',false);end if;
 if jsonb_typeof(p_legacy_keys)is distinct from'array'or jsonb_array_length(p_legacy_keys)not in(0,3)or exists(select 1 from jsonb_array_elements_text(p_legacy_keys)k where k!~('^ai-router/'||p_org||'/completed-photo/[a-f0-9]{64}\.(jpg|png|webp)$'))then raise exception'RP400: Owned historical result identities are invalid';end if;
 if p_edit not in('twilight','sky','lawn','declutter','stage','custom')or p_style is not null and length(p_style)>80 or jsonb_typeof(p_input)is distinct from'object'
  or exists(select 1 from jsonb_object_keys(p_input)k where k not in('sha256','bytes','mime','width','height'))or coalesce(p_input->>'sha256','')!~'^[a-f0-9]{64}$'
  or coalesce(p_input->>'bytes','')!~'^[1-9][0-9]{0,7}$'or(p_input->>'bytes')::bigint>1000000 or coalesce(p_input->>'mime','')not in('image/jpeg','image/png','image/webp')then raise exception'RP400: Exact bounded prepared photo bytes are required';end if;
 if(p_input?'width'or p_input?'height')and(coalesce(p_input->>'width','')!~'^[1-9][0-9]{0,3}$'or coalesce(p_input->>'height','')!~'^[1-9][0-9]{0,3}$'or(p_input->>'width')::int>8192 or(p_input->>'height')::int>8192)then raise exception'RP400: Bounded prepared photo geometry is required';end if;
 if not exists(select 1 from auth.users where id=p_actor and is_anonymous=false)or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then raise exception'RP403: A current named editor is required';end if;
 if p_listing is not null then c:=public.listing_library_scope(p_actor,p_listing);if c is null or c->>'can_write'<>'true'or(c->>'org_id')::uuid<>p_org then raise exception'RP404: The property library is unavailable';end if;
 else if not exists(select 1 from public.memberships where org_id=p_org and user_id=p_actor and role in('owner','admin','agent'))then raise exception'RP403: A current editor is required';end if;end if;
 if p_original_asset is not null then if p_listing is null then raise exception'RP400: An owned original needs its property identity';end if;original:=public.property_owned_upload(p_actor,p_listing,p_original_asset,'photo');end if;
 ext:=case p_input->>'mime'when'image/jpeg'then'jpg'when'image/png'then'png'else'webp'end;
 insert into public.photo_edit_evidence(id,org_id,actor_id,listing_id,library_org_id,request_key,request_sha256,legacy_keys,policy,edit,style,original_asset_id,original_reference,input)
 values(new_id,p_org,p_actor,p_listing,coalesce((c->>'library_org_id')::uuid,p_org),p_key,op.input_sha256,p_legacy_keys,'photo-fixed-features-v1',p_edit,p_style,p_original_asset,original,p_input||jsonb_build_object('bucket','renders','key','ai-router/'||p_org||'/photo-evidence/'||p_actor||'/'||new_id||'/input.'||ext))returning * into e;
 perform public.library_media_storage_reserve(p_actor,p_org,'renders',e.input->>'key',(p_input->>'bytes')::bigint);
 insert into public.photo_quality_checks(evidence_id,policy)values(e.id,e.policy)returning * into q;
 return jsonb_build_object('evidence',to_jsonb(e),'check',to_jsonb(q),'created',true,'can_continue',false);end$$;
create or replace function public.photo_quality_evidence_reserve(p_actor uuid,p_evidence uuid,p_output jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$declare e public.photo_edit_evidence;o jsonb;ext text;begin
 e:=public.photo_quality_scope(p_actor,p_evidence);select * into e from public.photo_edit_evidence where id=p_evidence for update;
 if e.input_etag is null then raise exception'RP409: Save the exact source before generating its edit';end if;
 if jsonb_typeof(p_output)is distinct from'object'or exists(select 1 from jsonb_object_keys(p_output)k where k not in('sha256','bytes','mime','width','height','generation_stage','provider','model'))
  or coalesce(p_output->>'sha256','')!~'^[a-f0-9]{64}$'or coalesce(p_output->>'bytes','')!~'^[1-9][0-9]{0,7}$'or(p_output->>'bytes')::bigint>9000000
  or coalesce(p_output->>'mime','')not in('image/jpeg','image/png','image/webp')or coalesce(p_output->>'width','')!~'^[1-9][0-9]{0,4}$'or coalesce(p_output->>'height','')!~'^[1-9][0-9]{0,4}$'
  or(p_output->>'width')::int>16384 or(p_output->>'height')::int>16384 or(p_output->>'width')::bigint*(p_output->>'height')::bigint>24000000 or coalesce(p_output->>'generation_stage','')!~'^[a-z0-9:._-]{1,80}$'or length(coalesce(p_output->>'provider',''))not between 1 and 40 or length(coalesce(p_output->>'model',''))not between 1 and 240 then raise exception'RP400: Exact measured candidate receipt is required';end if;
 ext:=case p_output->>'mime'when'image/jpeg'then'jpg'when'image/png'then'png'else'webp'end;
 o:=(p_output-'generation_stage'-'provider'-'model')||jsonb_build_object('bucket','renders','key','ai-router/'||e.org_id||'/photo-evidence/'||e.actor_id||'/'||e.id||'/candidate.'||ext);
 if e.output is not null then if row(e.output,e.generation_stage,e.generation_provider,e.generation_model)is distinct from row(o,p_output->>'generation_stage',p_output->>'provider',p_output->>'model')then raise exception'RP409: Generated photo evidence is immutable';end if;return to_jsonb(e);end if;
 if e.state not in('input_ready','pending')then raise exception'RP409: This photo operation no longer accepts generated bytes';end if;
 perform public.library_media_storage_reserve(p_actor,e.org_id,'renders',o->>'key',(o->>'bytes')::bigint);
 update public.photo_edit_evidence set output=o,generation_stage=p_output->>'generation_stage',generation_provider=p_output->>'provider',generation_model=p_output->>'model',updated_at=now(),write_until=now()+interval'20 minutes'where id=e.id returning * into e;return to_jsonb(e);end$$;
create or replace function public.photo_quality_evidence_receipt(p_actor uuid,p_evidence uuid,p_kind text,p_etag text)returns jsonb
language plpgsql security definer set search_path=''as $$declare e public.photo_edit_evidence;prior text;kind text;begin
 e:=public.photo_quality_scope(p_actor,p_evidence);select * into e from public.photo_edit_evidence where id=p_evidence for update;
 if p_kind not in('input','output')or p_etag is null or length(p_etag)not between 1 and 200 then raise exception'RP400: Exact retained evidence receipt is required';end if;
 prior:=case when p_kind='input'then e.input_etag else e.output_etag end;if prior is not null then if prior<>p_etag then raise exception'RP409: Evidence object receipt changed';end if;return public.photo_quality_lookup(p_actor,e.org_id,e.request_key);end if;
 if p_kind='output'and(e.output is null or e.input_etag is null)then raise exception'RP409: Both source and candidate must be retained';end if;
 if p_kind='input'then update public.photo_edit_evidence set input_etag=p_etag,state='input_ready',updated_at=now()where id=e.id;
 else
  kind:=case e.edit when'stage'then'virtual_stage'when'declutter'then'declutter'else'photo_edit'end;
  insert into public.media_provenance(org_id,listing_id,kind,model_id,edit,style,original_key,disclosure,qc,qc_checked_at)
  values(e.org_id,e.listing_id,kind,e.generation_model,e.edit,e.style,coalesce(e.original_reference->>'storage_key',e.input->>'key'),public.provenance_disclosure(kind,e.edit),jsonb_build_object('task','judge.photo_fixed_features','medium','photo','policy',e.policy,'publishable',false,'action','hold','evidence_id',e.id),now())returning id into e.provenance_id;
  update public.photo_edit_evidence set output_etag=p_etag,state='evidence_ready',provenance_id=e.provenance_id,updated_at=now()where id=e.id;
 end if;return public.photo_quality_lookup(p_actor,e.org_id,e.request_key);end$$;
create or replace function public.photo_quality_failure(p_actor uuid,p_evidence uuid,p_phase text,p_facts jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$declare e public.photo_edit_evidence;begin
 e:=public.photo_quality_scope(p_actor,p_evidence);select * into e from public.photo_edit_evidence where id=p_evidence for update;
 if p_phase is null or length(p_phase)not between 1 and 80 or jsonb_typeof(p_facts)is distinct from'object'or pg_column_size(p_facts)>4096 then raise exception'RP400: Bounded failure evidence is required';end if;
 if e.state in('accept','refuse')then return public.photo_quality_lookup(p_actor,e.org_id,e.request_key);end if;
 update public.photo_edit_evidence set state='hold',failure=jsonb_build_object('phase',p_phase,'facts',p_facts),updated_at=now()where id=e.id;
 update public.photo_quality_checks set state='hold',finished_at=now()where evidence_id=e.id and automatic;
 return public.photo_quality_lookup(p_actor,e.org_id,e.request_key);end$$;
create or replace function public.photo_quality_claim(p_check uuid)returns jsonb
language plpgsql security definer set search_path=''as $$declare q public.photo_quality_checks;e public.photo_edit_evidence;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into q from public.photo_quality_checks where id=p_check for update;if q.id is null then raise exception'RP404: Photo check is unavailable';end if;e:=public.photo_quality_scope((select actor_id from public.photo_edit_evidence where id=q.evidence_id),q.evidence_id);
 if q.state in('accept','refuse','hold','checking')or q.judge_started_at is not null or e.output_etag is null then return jsonb_build_object('action','wait','evidence',to_jsonb(e),'check',to_jsonb(q));end if;
 if q.state='derivative_ready'then
  if exists(select 1 from public.serving_cost_reservations where org_id=e.org_id and actor_id=e.actor_id and request_key='photo-qc:'||q.id and state<>'rejected')then return jsonb_build_object('action','wait','evidence',to_jsonb(e),'check',to_jsonb(q));end if;
  if q.lease_until is null or q.lease_until<=now()then update public.photo_quality_checks set lease_token=gen_random_uuid(),lease_until=now()+interval'10 minutes'where id=q.id returning * into q;end if;
  return jsonb_build_object('action','judge','evidence',to_jsonb(e),'check',to_jsonb(q));end if;
 if q.lease_until>now()then return jsonb_build_object('action','wait','evidence',to_jsonb(e),'check',to_jsonb(q));end if;
 if q.cpu_attempts>=3 or q.created_at+interval'1 hour'<=now()then update public.photo_quality_checks set state='hold',finished_at=now()where id=q.id;update public.photo_edit_evidence set state='hold',failure='{"phase":"comparison_preparation","message":"The saved edit could not be checked; no new generation was started."}'where id=e.id;return jsonb_build_object('action','wait');end if;
 update public.photo_quality_checks set state='preparing',lease_token=gen_random_uuid(),lease_until=now()+interval'10 minutes',cpu_attempts=cpu_attempts+1 where id=q.id returning * into q;
 return jsonb_build_object('action','prepare_photo_quality','policy',q.policy,'evidence',to_jsonb(e),'check',to_jsonb(q));end$$;
create or replace function public.photo_quality_worker_scope(p_check uuid,p_lease uuid)returns jsonb
language plpgsql security definer set search_path=''as $$declare q public.photo_quality_checks;e public.photo_edit_evidence;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into q from public.photo_quality_checks where id=p_check;if q.id is null then raise exception'RP404: Photo check is unavailable';end if;
 e:=public.photo_quality_scope((select actor_id from public.photo_edit_evidence where id=q.evidence_id),q.evidence_id);
 if q.state<>'preparing'or q.lease_token is distinct from p_lease or q.lease_until<=now()or q.judge_started_at is not null then raise exception'RP409: Photo comparison lease was superseded';end if;
 return jsonb_build_object('evidence',to_jsonb(e),'check',to_jsonb(q));end$$;
create or replace function public.photo_quality_heartbeat(p_check uuid,p_lease uuid)returns boolean
language plpgsql security definer set search_path=''as $$begin
 perform public.photo_quality_worker_scope(p_check,p_lease);
 update public.photo_quality_checks set lease_until=least(now()+interval'10 minutes',created_at+interval'1 hour')where id=p_check;
 if not found then return false;end if;return true;end$$;
create or replace function public.photo_quality_cpu_failure(p_check uuid,p_lease uuid,p_code text)returns jsonb
language plpgsql security definer set search_path=''as $$declare x jsonb;q public.photo_quality_checks;e public.photo_edit_evidence;begin
 x:=public.photo_quality_worker_scope(p_check,p_lease);q:=jsonb_populate_record(null::public.photo_quality_checks,x->'check');e:=jsonb_populate_record(null::public.photo_edit_evidence,x->'evidence');
 if p_code is distinct from'cpu_photo_comparison_failed'then raise exception'RP400: Closed photo preparation failure is required';end if;
 update public.photo_quality_checks set state=case when cpu_attempts>=3 then'hold'else'pending'end,lease_until=null where id=q.id;
 update public.photo_edit_evidence set state=case when q.cpu_attempts>=3 then'hold'else'evidence_ready'end,failure=jsonb_build_object('phase','comparison_preparation','code',p_code),updated_at=now()where id=e.id;
 return public.photo_quality_lookup(e.actor_id,e.org_id,e.request_key);end$$;

create or replace function public.photo_quality_derivatives_reserve(p_check uuid,p_lease uuid,p_manifest jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$declare q public.photo_quality_checks;e public.photo_edit_evidence;v jsonb;images jsonb:='[]';seen text[]:='{}';parents text[]:='{}';parent jsonb;crop jsonb;name text;key text;total bigint:=0;bound integer;pw integer;ph integer;left_x integer;top_y integer;cw integer;ch integer;sw bigint;sh bigint;vw bigint;vh bigint;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into q from public.photo_quality_checks where id=p_check for update;if q.id is null then raise exception'RP404: Photo check is unavailable';end if;e:=public.photo_quality_scope((select actor_id from public.photo_edit_evidence where id=q.evidence_id),q.evidence_id);
 if q.state<>'preparing'or q.lease_token is distinct from p_lease or q.lease_until<=now()or q.judge_started_at is not null then raise exception'RP409: Photo comparison lease was superseded';end if;
 if p_manifest->>'policy'is distinct from q.policy or p_manifest->>'prepared_sha256'is distinct from e.input->>'sha256'or p_manifest->>'candidate_sha256'is distinct from e.output->>'sha256'or jsonb_typeof(p_manifest->'images')is distinct from'array'or jsonb_array_length(p_manifest->'images')<>10 or pg_column_size(p_manifest)>32768 then raise exception'RP400: Exact paired photo derivative manifest is required';end if;
 if jsonb_typeof(p_manifest->'parents')is distinct from'array'or jsonb_array_length(p_manifest->'parents')<>2 or exists(select 1 from jsonb_object_keys(p_manifest)k where k not in('policy','prepared_sha256','candidate_sha256','parents','images'))then raise exception'RP400: Both normalized parent receipts are required';end if;
 for parent in select value from jsonb_array_elements(p_manifest->'parents')loop
  if exists(select 1 from jsonb_object_keys(parent)k where k not in('role','input_sha256','normalized_width','normalized_height','normalized_pixel_sha256','normalization','pixel_hash_policy'))or coalesce(parent->>'role','')not in('source','candidate')or(parent->>'role')=any(parents)
   or parent->>'input_sha256'is distinct from(case when parent->>'role'='source'then e.input->>'sha256'else e.output->>'sha256'end)or coalesce(parent->>'normalized_pixel_sha256','')!~'^[a-f0-9]{64}$'
   or parent->>'normalization'is distinct from'exif-icc-srgb-v1'or parent->>'pixel_hash_policy'is distinct from'rgb8-dimensions-row-major-v1'
   or coalesce(parent->>'normalized_width','')!~'^[1-9][0-9]{0,4}$'or coalesce(parent->>'normalized_height','')!~'^[1-9][0-9]{0,4}$'then raise exception'RP400: Exact normalized parent identity is required';end if;
  pw:=(parent->>'normalized_width')::int;ph:=(parent->>'normalized_height')::int;
  if pw not between 2 and 16384 or ph not between 2 and 16384 or pw::bigint*ph>24000000 then raise exception'RP400: Normalized parent geometry exceeds policy';end if;parents:=array_append(parents,parent->>'role');
  if parent->>'role'='source'then sw:=pw;sh:=ph;else vw:=pw;vh:=ph;end if;
 end loop;
 if abs(sw*vh-vw*sh)>greatest(sw,sh,vw,vh)then raise exception'RP409: The candidate changed the source aspect ratio';end if;
 for v in select value from jsonb_array_elements(p_manifest->'images')loop
  if exists(select 1 from jsonb_object_keys(v)k where k not in('role','region','sha256','bytes','width','height','crop'))or coalesce(v->>'role','')not in('source','candidate')or coalesce(v->>'region','')not in('whole','tl','tr','bl','br')or coalesce(v->>'sha256','')!~'^[a-f0-9]{64}$'or coalesce(v->>'bytes','')!~'^[1-9][0-9]{0,7}$'or(v->>'bytes')::bigint>6000000 or coalesce(v->>'width','')!~'^[1-9][0-9]{0,3}$'or coalesce(v->>'height','')!~'^[1-9][0-9]{0,3}$'then raise exception'RP400: Bounded closed comparison images are required';end if;
  name:=(v->>'role')||':'||(v->>'region');if name=any(seen)then raise exception'RP400: Every source and candidate region must appear once';end if;seen:=array_append(seen,name);bound:=case when v->>'region'='whole'then 2048 else 1024 end;
  if(v->>'width')::int>bound or(v->>'height')::int>bound then raise exception'RP400: Comparison dimensions exceed their policy';end if;
  select value into parent from jsonb_array_elements(p_manifest->'parents')where value->>'role'=v->>'role';pw:=(parent->>'normalized_width')::int;ph:=(parent->>'normalized_height')::int;
  left_x:=case when v->>'region'in('tr','br')then pw/2 else 0 end;top_y:=case when v->>'region'in('bl','br')then ph/2 else 0 end;
  cw:=case when v->>'region'='whole'then pw when v->>'region'in('tl','bl')then pw/2 else pw-pw/2 end;ch:=case when v->>'region'='whole'then ph when v->>'region'in('tl','tr')then ph/2 else ph-ph/2 end;
  crop:=jsonb_build_object('left',left_x,'top',top_y,'width',cw,'height',ch);
  if v->'crop'is distinct from crop or(v->>'width')::int>cw or(v->>'height')::int>ch or abs((v->>'width')::bigint*ch-(v->>'height')::bigint*cw)>greatest((v->>'width')::int,(v->>'height')::int,cw,ch)then raise exception'RP409: Comparison crops must cover the unchanged parent without stretch or upsample';end if;
  total:=total+(v->>'bytes')::bigint;key:='ai-router/'||e.org_id||'/photo-evidence/'||e.actor_id||'/'||e.id||'/checks/'||q.id||'/'||(v->>'role')||'-'||(v->>'region')||'.jpg';
  perform public.library_media_storage_reserve(e.actor_id,e.org_id,'renders',key,(v->>'bytes')::bigint);
  images:=images||jsonb_build_array(v||jsonb_build_object('bucket','renders','key',key,'mime','image/jpeg'));
 end loop;
 if total>6000000 then raise exception'RP413: The complete comparison package exceeds its measured memory envelope';end if;
 if q.derivative_manifest is not null and q.derivative_manifest is distinct from p_manifest then raise exception'RP409: Comparison derivative identities are immutable';end if;
 update public.photo_quality_checks set derivatives=images,derivative_manifest=p_manifest,derivative_manifest_sha256=encode(pg_catalog.sha256(pg_catalog.convert_to(p_manifest::text,'UTF8')),'hex')where id=q.id;
 return jsonb_build_object('check_id',q.id,'evidence_id',e.id,'parents',p_manifest->'parents','images',images);end$$;
create or replace function public.photo_quality_derivatives_complete(p_check uuid,p_lease uuid,p_receipts jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$declare q public.photo_quality_checks;e public.photo_edit_evidence;v jsonb;d jsonb;done jsonb:='[]';begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into q from public.photo_quality_checks where id=p_check for update;if q.id is null then raise exception'RP404: Photo check is unavailable';end if;e:=public.photo_quality_scope((select actor_id from public.photo_edit_evidence where id=q.evidence_id),q.evidence_id);
 if q.state='derivative_ready'and q.derivatives=p_receipts then return public.photo_quality_lookup(e.actor_id,e.org_id,e.request_key);end if;
 if q.state<>'preparing'or q.lease_token is distinct from p_lease or q.lease_until<=now()or q.derivatives is null or jsonb_typeof(p_receipts)is distinct from'array'or jsonb_array_length(p_receipts)<>10 then raise exception'RP409: Current paired comparison receipts are required';end if;
 for v in select value from jsonb_array_elements(p_receipts)loop
  select value into d from jsonb_array_elements(q.derivatives)where value->>'key'=v->>'key';
  if d is null or(v-'etag')is distinct from d or length(coalesce(v->>'etag',''))not between 1 and 200 or exists(select 1 from jsonb_array_elements(done)where value->>'key'=v->>'key')then raise exception'RP409: A comparison object receipt changed';end if;done:=done||jsonb_build_array(v);
 end loop;
 update public.photo_quality_checks set derivatives=done,state='derivative_ready'where id=q.id;return public.photo_quality_lookup(e.actor_id,e.org_id,e.request_key);end$$;
create or replace function public.photo_quality_check_bind(p_actor uuid,p_check uuid,p_lease uuid,p_reservation uuid)returns jsonb
language plpgsql security definer set search_path=''as $$declare q public.photo_quality_checks;e public.photo_edit_evidence;r public.serving_cost_reservations;approved jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into q from public.photo_quality_checks where id=p_check for update;if q.id is null then raise exception'RP404: Photo check is unavailable';end if;e:=public.photo_quality_scope(p_actor,q.evidence_id);
 if q.state<>'derivative_ready'or q.lease_token is distinct from p_lease or q.lease_until<=now()or q.judge_started_at is not null then raise exception'RP409: This photo judge was already started or its lease expired';end if;
 select value->'approved_judge'into approved from public.app_config where key='photo_quality'and value->'enabled'='true'::jsonb;
 select * into r from public.serving_cost_reservations where id=p_reservation and actor_id=p_actor and org_id=e.org_id and request_key='photo-qc:'||q.id and stage='photo.qc:0'and state='reserved';
 if r.id is null or approved is null or r.provider is distinct from approved->>'provider'or r.model is distinct from approved->>'model'then raise exception'RP409: The approved photo quality attempt was not funded';end if;
 if not exists(select 1 from public.serving_cost_reservations g join public.cost_ledger l on l.org_id=g.org_id and l.provider=g.provider and l.model=g.model and l.feature='photo_edit'and l.total_cents>0 and l.meta->>'request_key'=g.request_key and l.meta->>'stage'=g.stage where g.actor_id=e.actor_id and g.org_id=e.org_id and g.request_key=e.request_key and g.stage=e.generation_stage and g.provider=e.generation_provider and g.model=e.generation_model and g.state='succeeded')then raise exception'RP409: Generated photo cost receipt is not confirmed; the edit remains private';end if;
 update public.photo_quality_checks set state='checking',judge_started_at=now(),reservation_id=r.id,provider=r.provider,model=r.model,input_payload_sha256=r.input_sha256 where id=q.id returning * into q;
 update public.photo_edit_evidence set state='checking',updated_at=now()where id=e.id;return jsonb_build_object('evidence',to_jsonb(e),'check',to_jsonb(q));end$$;
create or replace function public.photo_quality_finish(p_actor uuid,p_check uuid,p_lease uuid,p_result jsonb)returns jsonb
language plpgsql security definer set search_path=''as $$declare q public.photo_quality_checks;e public.photo_edit_evidence;r public.serving_cost_reservations;l public.cost_ledger;accept boolean;axis text;qc jsonb;final text;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into q from public.photo_quality_checks where id=p_check for update;if q.id is null then raise exception'RP404: Photo check is unavailable';end if;e:=public.photo_quality_scope(p_actor,q.evidence_id);
 if q.state in('accept','refuse','hold')and q.result is not null then if q.result is distinct from p_result then raise exception'RP409: A saved quality verdict is immutable';end if;return public.photo_quality_lookup(e.actor_id,e.org_id,e.request_key);end if;
 if q.state<>'checking'or q.lease_token is distinct from p_lease or q.judge_started_at is null or jsonb_typeof(p_result)is distinct from'object'or octet_length(p_result::text)>3000 or p_result->>'policy'is distinct from e.policy or coalesce(p_result->>'action','')not in('accept','refuse','hold')or coalesce(p_result->>'verdict','')not in('pass','fail','unknown')then raise exception'RP409: A current bounded photo quality verdict is required';end if;
 select * into r from public.serving_cost_reservations where id=q.reservation_id and state='succeeded'and actor_id=p_actor and org_id=e.org_id;
 select * into l from public.cost_ledger where org_id=e.org_id and feature='qc'and provider=q.provider and model=q.model and total_cents>0 and meta->>'request_key'='photo-qc:'||q.id and meta->>'stage'='photo.qc:0'and meta->>'photo_check_id'=q.id::text and meta->>'evidence_id'=e.id::text and meta->>'prepared_sha256'=e.input->>'sha256'and meta->>'output_sha256'=e.output->>'sha256'and meta->>'derivative_manifest_sha256'=q.derivative_manifest_sha256 and meta->>'policy'=e.policy order by created_at desc,id desc limit 1;
 accept:=p_result->>'action'='accept'and p_result->>'verdict'='pass'and r.id is not null and l.id is not null and jsonb_typeof(p_result->'confidence')='number'and(p_result->>'confidence')::numeric between .85 and 1
  and jsonb_typeof(p_result->'artifacts')='number'and(p_result->>'artifacts')::numeric between 90 and 100 and jsonb_typeof(p_result->'edit_quality')='number'and(p_result->>'edit_quality')::numeric between 80 and 100 and p_result->'findings'='[]'::jsonb and jsonb_typeof(p_result->'preservation')='object';
 foreach axis in array array['geometry','openings','fixtures','surfaces','viewpoint']loop if jsonb_typeof(p_result#>array['preservation',axis])is distinct from'number'then accept:=false;elsif(p_result#>>array['preservation',axis])::numeric not between 95 and 100 then accept:=false;end if;end loop;
 accept:=coalesce(accept,false);
 final:=case when accept then'accept'when p_result->>'action'='refuse'and p_result->>'verdict'='fail'and r.id is not null and l.id is not null then'refuse'else'hold'end;
 qc:=p_result||jsonb_build_object('task','judge.photo_fixed_features','medium','photo','policy',e.policy,'publishable',accept,'action',case when accept then'accept'when final='refuse'then'refuse'else'hold'end,'check_id',q.id,'evidence_id',e.id,'prepared_sha256',e.input->>'sha256','output_sha256',e.output->>'sha256','derivative_manifest_sha256',q.derivative_manifest_sha256);
 if e.provenance_id is null then raise exception'RP409: The retained photo disclosure record is missing';end if;
 perform public.record_media_qc(e.provenance_id,e.org_id,qc);
 update public.photo_quality_checks set state=final,result=p_result,qc_ledger_id=l.id,finished_at=now()where id=q.id;
 update public.photo_edit_evidence set state=final,updated_at=now()where id=e.id;
 if accept then
  perform public.register_private_ai_output(e.actor_id,e.org_id,e.listing_id,'renders',e.output->>'key',(e.output->>'bytes')::bigint);
  if e.original_reference is null then perform public.register_private_ai_output(e.actor_id,e.org_id,e.listing_id,'renders',e.input->>'key',(e.input->>'bytes')::bigint);end if;
  update public.media_provenance set altered_key=e.output->>'key'where id=e.provenance_id;
 end if;return public.photo_quality_lookup(e.actor_id,e.org_id,e.request_key);end$$;
-- A mistaken legacy save path cannot register prospective quarantine as ready.
create or replace function public.photo_quality_private_output_guard()returns trigger language plpgsql security definer set search_path=''as $$begin
 if(new.storage_key like'ai-router/%/photo-evidence/%'or exists(select 1 from public.photo_edit_evidence e where e.legacy_keys?new.storage_key))and not exists(select 1 from public.photo_edit_evidence e where e.state='accept'and e.org_id=new.org_id and e.actor_id=new.user_id and e.listing_id is not distinct from new.listing_id and((e.output->>'key'=new.storage_key and(e.output->>'bytes')::bigint=new.bytes)or(e.input->>'key'=new.storage_key and(e.input->>'bytes')::bigint=new.bytes)))then raise exception'RP409: This photo still awaits fixed-feature quality review';end if;return new;end$$;
drop trigger if exists photo_quality_private_output_guard on public.private_ai_outputs;
create trigger photo_quality_private_output_guard before insert or update on public.private_ai_outputs for each row execute function public.photo_quality_private_output_guard();
do $$declare f regprocedure;begin for f in select oid::regprocedure from pg_proc where pronamespace='public'::regnamespace and(proname like'photo_quality_%')loop execute format('revoke all on function %s from public,anon,authenticated',f);execute format('grant execute on function %s to service_role',f);end loop;end$$;
create or replace function public.photo_quality_status(p_actor uuid,p_check uuid)returns jsonb
language plpgsql security definer set search_path=''as $$declare e public.photo_edit_evidence;q public.photo_quality_checks;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into q from public.photo_quality_checks where id=p_check;if q.id is null then raise exception'RP404: Saved photo check is unavailable';end if;
 e:=public.photo_quality_scope(p_actor,q.evidence_id);return public.photo_quality_lookup(p_actor,e.org_id,e.request_key);end$$;
-- Checked provenance may move to an exact uploaded copy, never unrelated bytes.
create or replace function public.photo_quality_provenance_media_guard()returns trigger language plpgsql security definer set search_path=''as $$declare e public.photo_edit_evidence;begin
 select * into e from public.photo_edit_evidence where provenance_id=new.id;
 if e.id is not null and new.altered_key is not null and new.altered_key is distinct from old.altered_key and(new.altered_key is distinct from e.output->>'key')then
  if e.state<>'accept'or not exists(select 1 from public.capture_assets a where a.listing_id=e.listing_id and a.storage_key=new.altered_key and a.uploaded and not a.upload_aborted and a.sha256=e.output->>'sha256'and a.bytes=(e.output->>'bytes')::bigint)then raise exception'RP409: The selected version is not the exact checked photo';end if;end if;return new;end$$;
drop trigger if exists photo_quality_provenance_media_guard on public.media_provenance;
create trigger photo_quality_provenance_media_guard before update of altered_key on public.media_provenance for each row execute function public.photo_quality_provenance_media_guard();
-- Evidence has no ordinary deliverable registry row while held, so include its
-- immutable object inventory explicitly in account and listing erasure.
create or replace function public.photo_quality_media_targets(p_orgs uuid[],p_listing uuid default null)returns jsonb
language sql stable security definer set search_path=''as $$
 select coalesce(jsonb_agg(distinct jsonb_build_object('bucket','renders','key',x.key,'valid',starts_with(x.key,'ai-router/'||e.org_id||'/photo-evidence/'||e.actor_id||'/'||e.id||'/')and x.key!~'(^|/)[.]{1,2}(/|$)')),'[]'::jsonb)
 from public.photo_edit_evidence e cross join lateral(
  select e.input->>'key'key union select e.output->>'key' union select v->>'key'from public.photo_quality_checks q cross join lateral jsonb_array_elements(coalesce(q.derivatives,'[]'::jsonb))v where q.evidence_id=e.id
 )x where e.org_id=any(p_orgs)and(p_listing is null or e.listing_id=p_listing)and x.key is not null;
$$;
do $$begin if to_regprocedure('public.photo_quality_previous_account_targets(uuid[],text,text)')is null then alter function public.account_private_output_targets(uuid[],text,text)rename to photo_quality_previous_account_targets;end if;end$$;
create or replace function public.account_private_output_targets(p_orgs uuid[],p_upload_bucket text,p_render_bucket text)returns jsonb
language plpgsql stable security definer set search_path=''as $$declare prior jsonb;extra jsonb;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 prior:=public.photo_quality_previous_account_targets(p_orgs,p_upload_bucket,p_render_bucket);
 select coalesce(jsonb_agg(v||jsonb_build_object('bucket',p_render_bucket)),'[]'::jsonb)into extra from jsonb_array_elements(public.photo_quality_media_targets(p_orgs,null))v;
 return(select coalesce(jsonb_agg(distinct v),'[]'::jsonb)from jsonb_array_elements(prior||extra)v);end$$;
do $$begin if to_regprocedure('public.photo_quality_previous_listing_cleanup(uuid)')is null then alter function public.queue_listing_media_cleanup(uuid)rename to photo_quality_previous_listing_cleanup;end if;end$$;
create or replace function public.queue_listing_media_cleanup(p_listing uuid)returns void
language plpgsql security definer set search_path=''as $$declare l public.listings;extra jsonb;all_keys jsonb;deadline timestamptz;begin
 perform public.photo_quality_previous_listing_cleanup(p_listing);select * into l from public.listings where id=p_listing;
 if l.id is null or l.deleted_at is null then return;end if;
 select coalesce(jsonb_agg(v-'valid'),'[]'::jsonb)into extra from jsonb_array_elements(public.photo_quality_media_targets(array[l.org_id],l.id))v;
 if jsonb_array_length(extra)=0 then return;end if;
 select coalesce(jsonb_agg(distinct v),'[]'::jsonb)into all_keys from jsonb_array_elements(coalesce((select payload->'r2'from public.privacy_cleanup_jobs where kind='listing'and source_id=l.id),'[]'::jsonb)||extra)v;
 select greatest(max(e.write_until)+interval'1 hour',max(q.lease_until)+interval'1 hour',now()+interval'1 hour')into deadline from public.photo_edit_evidence e left join public.photo_quality_checks q on q.evidence_id=e.id where e.listing_id=l.id;
 update public.privacy_cleanup_jobs set payload=jsonb_set(payload,'{r2}',all_keys),remaining=jsonb_set(remaining,'{r2}',all_keys),not_before=greatest(not_before,deadline)where kind='listing'and source_id=l.id;
end$$;
do $$declare f regprocedure;begin for f in select oid::regprocedure from pg_proc where pronamespace='public'::regnamespace and(proname like'photo_quality_%'or proname in('account_private_output_targets','queue_listing_media_cleanup'))loop execute format('revoke all on function %s from public,anon,authenticated',f);execute format('grant execute on function %s to service_role,postgres',f);end loop;end$$;
