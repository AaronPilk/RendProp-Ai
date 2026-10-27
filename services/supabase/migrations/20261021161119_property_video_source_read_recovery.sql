-- Explicit recovery of one failed read which never entered the paid helper.
-- Existing Resume/QC/funding/lease authorities remain byte-exact. No job is
-- resumed by this migration: the normal authenticated Resume route must read
-- and verify the exact frozen media before submitting its proof fingerprint.
begin;
do $$begin
 if (select md5(prosrc) from pg_catalog.pg_proc where oid=to_regprocedure('public.property_video_job_resume(uuid,uuid,numeric)')) is distinct from '121a22da639a891d762964ae72efb00b'
 or (select md5(prosrc) from pg_catalog.pg_proc where oid=to_regprocedure('public.property_video_job_scope(uuid,uuid,boolean)')) is distinct from 'b930e3e83254b806bc6a7de33d204100'
 or (select md5(prosrc) from pg_catalog.pg_proc where oid=to_regprocedure('public.property_video_job_worker_scope(uuid,uuid,uuid)')) is distinct from '825b4af8b68e94646b3ad856af0e60ee'
 then raise exception 'Review changed saved-video recovery predecessors';end if;
end$$;

-- Only the opaque retired admission key survives normal job/account-history
-- erasure. No actor, workspace, listing, media reference or credential is
-- retained here. A primary-key lookup also keeps every admission probe bounded.
create table public.property_video_source_read_retired_keys(
 request_key text primary key check(request_key~'^bgvideo:[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'),
 retired_at timestamptz not null default now());
alter table public.property_video_source_read_retired_keys enable row level security;
revoke all on public.property_video_source_read_retired_keys from public,anon,authenticated,service_role;
create function public.property_video_source_read_retirement_immutable() returns trigger
language plpgsql set search_path='' as $$begin raise exception 'RP409: A never-dispatched admission retirement is immutable';end$$;
create trigger property_video_source_read_retirement_immutable before update or delete on public.property_video_source_read_retired_keys
 for each row execute function public.property_video_source_read_retirement_immutable();

create or replace function public.property_video_source_read_resume_proof(p_job uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare j public.property_video_jobs;s public.property_video_job_sources;rows jsonb;failed integer;payload jsonb;c jsonb;m jsonb;permission_at timestamptz;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
 j:=public.property_video_job_scope(p_job,null,false);
 if j.state<>'failed' or j.cancelled_at is not null or j.deadline<=now() then return null;end if;
 -- This recovery is the exact activated Kie recipe only. Owner-test grants and
 -- other profiles retain their existing, separate authorities and limits.
 if j.quality_profile is distinct from 'kie-kling3-4k-steady-v1'
  or j.quality_identity is distinct from public.property_video_quality_identity('kie-kling3-4k-steady-v1')
  or j.kie_test_grant_id is not null or j.consent_revision is distinct from 'property-video-jobs-v2'
  or jsonb_typeof(j.processor_consent) is distinct from 'object' then return null;end if;
 if (j.processor_consent-array['token','disclosure_revision','processors','recorded_at'])<>'{}'::jsonb
  or jsonb_typeof(j.processor_consent->'recorded_at') is distinct from 'string' then return null;end if;
 begin permission_at:=(j.processor_consent->>'recorded_at')::timestamptz;
 exception when invalid_datetime_format or datetime_field_overflow then return null;end;
 if not isfinite(permission_at) or permission_at>now() or permission_at<j.created_at-interval '5 minutes' or permission_at>j.created_at+interval '5 minutes' then return null;end if;
 c:=public.property_video_processor_consent_current();
 if c is null or j.processor_consent->'token' is distinct from c->'token'
  or j.processor_consent->'disclosure_revision' is distinct from c->'disclosure_revision'
  or j.processor_consent->'processors' is distinct from c->'processors' then return null;end if;
 if jsonb_typeof(j.manifest->'sources') is distinct from 'array' or jsonb_array_length(j.manifest->'sources')<>j.source_count
  or j.source_count not between 1 and 100 or j.manifest->>'operation_id' is distinct from j.operation_id::text
  or j.manifest->>'listing_id' is distinct from j.listing_id::text
  or j.manifest_sha256 is distinct from encode(pg_catalog.sha256(pg_catalog.convert_to(j.manifest::text,'UTF8')),'hex') then return null;end if;
 if j.result is not null or j.compose_attempts<>0 or j.output_asset_id is not null or j.poster_asset_id is not null then return null;end if;
 select count(*) into failed from public.property_video_job_sources where job_id=p_job and state='failed';
 -- One closed failure; an ambiguous or unrelated failure must be reconciled.
 if failed<>1 or exists(select 1 from public.property_video_job_sources where job_id=p_job and state not in('pending','processing','quality_review','ready','original_photo','failed')) then return null;end if;
 for s in select * from public.property_video_job_sources where job_id=p_job order by position loop
  m:=j.manifest->'sources'->s.position;
  if m is null or m->>'photo_id' is distinct from s.photo_id or m->>'photo_asset_id' is distinct from s.asset_id::text
   or m->>'photo_version_id' is distinct from s.version_id or m->>'photo_provenance_id' is distinct from s.photo_provenance_id::text
   or m->>'motion' is distinct from s.motion then return null;end if;
  begin
   if public.property_photo_reference(j.actor_id,j.listing_id,s.asset_id,s.photo_provenance_id) is distinct from s.source then return null;end if;
  exception when sqlstate 'P0001' then
   if sqlerrm like 'RP403:%' or sqlerrm like 'RP404:%' or sqlerrm like 'RP409:%' then return null;end if;raise;
  end;
  if s.state<>'failed' then continue;end if;
  if s.last_error is distinct from 'source_unavailable' or s.attempt_id is null or s.request_key is distinct from 'bgvideo:'||s.attempt_id::text
   or s.receipt is not null or s.clip is not null or s.generation_provenance_id is not null or s.provider_terminal_at is not null
   or s.lease_until>now() or s.admission_retries>=3
   or exists(select 1 from jsonb_array_elements(s.non_dispatch_history) h where h->>'reason'='source_unavailable')
   or exists(select 1 from public.property_video_source_read_retired_keys r where r.request_key=s.request_key) then return null;end if;
  -- No held, rejected, settled, accepted or otherwise uncertain supplier row
  -- may be treated as a failed local read. Even a released hold is ineligible.
  if exists(select 1 from public.app_video_cost_reservations r where r.actor_id=j.actor_id and r.org_id=j.org_id and r.idempotency_key=s.request_key)
   or exists(select 1 from public.serving_cost_reservations r where r.actor_id=j.actor_id and r.org_id=j.org_id and r.request_key=s.request_key)
   or exists(select 1 from public.serving_operations r where r.actor_id=j.actor_id and r.org_id=j.org_id and r.request_key=s.request_key)
   or exists(select 1 from public.serving_operation_results r where r.actor_id=j.actor_id and r.org_id=j.org_id and r.request_key=s.request_key)
   or exists(select 1 from public.app_video_submission_receipts r where r.actor_id=j.actor_id and r.org_id=j.org_id and r.operation_id=s.request_key)
   or exists(select 1 from public.cost_ledger r where r.org_id=j.org_id and (r.meta->>'request_key'=s.request_key or r.idempotency_key=s.request_key))
   or exists(select 1 from public.property_video_kie_test_grant_uses r where r.job_id=p_job and (r.attempt_id=s.attempt_id or r.request_key=s.request_key)) then return null;end if;
 end loop;
 select jsonb_agg(to_jsonb(x) order by position) into rows from public.property_video_job_sources x where job_id=p_job;
 if jsonb_array_length(rows) is distinct from j.source_count then return null;end if;
 payload:=jsonb_build_object('schema',1,'job',to_jsonb(j),'sources',rows,'failed_positions',(select jsonb_agg(position order by position) from public.property_video_job_sources where job_id=p_job and state='failed'));
 return payload||jsonb_build_object('proof_sha256',encode(pg_catalog.sha256(pg_catalog.convert_to(payload::text,'UTF8')),'hex'));
end$$;

-- A retired never-dispatched key must not acquire a late financial row after
-- the recovery commits. INSERT only: existing accepted siblings and their
-- settlement/terminal updates are untouched. VOLATILE gives each trigger SQL
-- read a fresh READ COMMITTED snapshot after a table-lock wait. A historical
-- snapshot cannot establish absence and is refused for background keys.
create or replace function public.property_video_retired_source_read_key_guard() returns trigger
language plpgsql volatile security definer set search_path='' as $$
declare doc jsonb:=to_jsonb(new);k text;keys text[];
begin
 keys:=case TG_TABLE_NAME when 'app_video_cost_reservations' then array[doc->>'idempotency_key']
  when 'app_video_submission_receipts' then array[doc->>'operation_id']
  when 'cost_ledger' then array[doc#>>'{meta,request_key}',doc->>'idempotency_key']
  when 'property_video_kie_test_grant_uses' then array[doc->>'request_key','bgvideo:'||(doc->>'attempt_id')]
  else array[doc->>'request_key'] end;
 foreach k in array keys loop
  if k is null or k !~ '^bgvideo:[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$' then continue;end if;
  if current_setting('transaction_isolation')<>'read committed' then raise exception 'RP409: Background admission requires a current transaction snapshot';end if;
  if exists(select 1 from public.property_video_source_read_retired_keys r where r.request_key=k) then
   raise exception 'RP409: This never-dispatched source-read attempt was retired; no supplier admission was created';end if;
 end loop;
 return new;
end$$;
do $$declare t text;begin
 foreach t in array array['app_video_cost_reservations','serving_cost_reservations','serving_operations','serving_operation_results','app_video_submission_receipts','cost_ledger','property_video_kie_test_grant_uses'] loop
  execute format('create trigger property_video_retired_source_read_key before insert on public.%I for each row execute function public.property_video_retired_source_read_key_guard()',t);
 end loop;
end$$;

create or replace function public.property_video_source_read_history_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare i integer;e jsonb;p jsonb;fields text[]:=array['state','admission_retries','non_dispatch_history','attempt_id','request_key','lease_token','lease_until','last_error'];
begin
 if not exists(select 1 from jsonb_array_elements(old.non_dispatch_history) h where h->>'reason'='source_unavailable')
  and not exists(select 1 from jsonb_array_elements(new.non_dispatch_history) h where h->>'reason'='source_unavailable') then return new;end if;
 if jsonb_array_length(new.non_dispatch_history)<jsonb_array_length(old.non_dispatch_history) then raise exception 'RP409: Source-read recovery history is immutable';end if;
 for i in 0..jsonb_array_length(old.non_dispatch_history)-1 loop
  if new.non_dispatch_history->i is distinct from old.non_dispatch_history->i then raise exception 'RP409: Source-read recovery history is immutable';end if;
 end loop;
 if jsonb_array_length(new.non_dispatch_history)>jsonb_array_length(old.non_dispatch_history) then
  e:=new.non_dispatch_history->-1;
  if e->>'reason'='source_unavailable' then
   p:=public.property_video_source_read_resume_proof(old.job_id);
   if p is null or jsonb_array_length(new.non_dispatch_history)<>jsonb_array_length(old.non_dispatch_history)+1
    or e->'prior_source' is distinct from to_jsonb(old)-'non_dispatch_history' or e->>'proof_sha256' is distinct from p->>'proof_sha256'
    or new.admission_retries<>old.admission_retries+1 or new.state<>'pending'
    or new.attempt_id is not null or new.request_key is not null or new.lease_token is not null or new.lease_until is not null or new.last_error is not null
    or to_jsonb(new)-fields is distinct from to_jsonb(old)-fields then raise exception 'RP409: An exact never-dispatched source-read recovery proof is required';end if;
  end if;
 end if;
 return new;
end$$;
create trigger property_video_source_read_history before update of non_dispatch_history on public.property_video_job_sources
 for each row execute function public.property_video_source_read_history_guard();

create or replace function public.property_video_job_resume_source_read(p_actor uuid,p_job uuid,p_quote numeric,p_proof_sha text) returns public.property_video_jobs
language plpgsql security definer set search_path='' as $$
declare j public.property_video_jobs;s public.property_video_job_sources;p jsonb;n integer;billing uuid;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege;end if;
 if p_proof_sha is null or p_proof_sha !~ '^[a-f0-9]{64}$' then raise exception 'RP400: Use the exact inspected source-read proof';end if;
 if p_actor is null then raise exception 'RP400: Use the saved video actor';end if;
 j:=public.property_video_job_scope(p_job,p_actor,false);
 -- Lost-response replay never reopens a stopped job or changes a worker lease.
 if j.state in('queued','generating','quality_review','composing','ready') and exists(select 1 from public.property_video_job_sources x where x.job_id=p_job and x.non_dispatch_history @> jsonb_build_array(jsonb_build_object('reason','source_unavailable','proof_sha256',p_proof_sha))) then return j;end if;
 -- Canonical parent/deletion lock order precedes billing and job/source locks.
 -- FOR SHARE (not KEY SHARE) also waits for a soft-deletion UPDATE; reading
 -- its old MVCC row is not current listing authority.
 perform 1 from auth.users where id=p_actor for share;
 perform 1 from public.profiles where id=p_actor for share;
 billing:=public.library_actor_billing_org(p_actor,j.org_id);
 perform 1 from public.orgs where id in(j.org_id,j.library_org_id,billing) order by id for share;
 perform 1 from public.listings where id=j.listing_id for share;
 j:=public.property_video_job_scope(p_job,p_actor,false);
 if p_quote is null or p_quote<=0 or p_quote::text in('NaN','Infinity','-Infinity') then raise exception 'RP409: Price the remaining unpaid shots before resuming this read';end if;
 select count(*) into n from public.property_video_job_sources where job_id=p_job and state in('pending','failed');
 -- Take existing billing admission locks before financial-table locks. A busy
 -- settlement is a refusal before mutation, never a lock-order retry loop.
 perform public.property_video_recipe_capacity(p_actor,j.listing_id,n,p_quote);
 begin
  lock table public.deletion_requests,public.app_video_cost_reservations,public.serving_cost_reservations,public.serving_operations,public.serving_operation_results,public.app_video_submission_receipts,public.cost_ledger,public.property_video_sources,public.property_video_kie_test_grant_uses in share mode nowait;
 exception when lock_not_available then raise exception 'RP409: Processing settlement is busy; no saved work was resumed';end;
 select * into j from public.property_video_jobs where id=p_job for update;
 j:=public.property_video_job_scope(p_job,p_actor,false);
 perform 1 from public.property_video_job_sources where job_id=p_job order by position for update;
 -- Recheck after waiting: another Resume, cancellation, deletion, a natural
 -- accepted callback or a source edit may have committed while locks waited.
 if j.state in('queued','generating','quality_review','composing','ready') and exists(select 1 from public.property_video_job_sources x where x.job_id=p_job and x.non_dispatch_history @> jsonb_build_array(jsonb_build_object('reason','source_unavailable','proof_sha256',p_proof_sha))) then return j;end if;
 perform 1 from public.capture_assets where id in(select asset_id from public.property_video_job_sources where job_id=p_job) order by id for share;
 p:=public.property_video_source_read_resume_proof(p_job);
 if p is null or p->>'proof_sha256' is distinct from p_proof_sha then raise exception 'RP409: The inspected source-read recovery changed or is unavailable';end if;
 for s in select * from public.property_video_job_sources where job_id=p_job and state='failed' order by position for update loop
  update public.property_video_job_sources set state='pending',admission_retries=admission_retries+1,
   non_dispatch_history=non_dispatch_history||jsonb_build_array(jsonb_build_object('reason','source_unavailable','prior_source',to_jsonb(s)-'non_dispatch_history','proof_sha256',p_proof_sha,'recovered_at',now())),
   attempt_id=null,request_key=null,lease_token=null,lease_until=null,last_error=null where job_id=p_job and position=s.position;
  insert into public.property_video_source_read_retired_keys(request_key) values(s.request_key);
 end loop;
 update public.property_video_jobs set state='generating',message='Resuming the selected photo after its saved file was verified. The accepted clip and remaining photo order are preserved.',updated_at=now() where id=p_job returning * into j;
 return j;
end$$;
revoke all on function public.property_video_source_read_resume_proof(uuid),public.property_video_job_resume_source_read(uuid,uuid,numeric,text),public.property_video_source_read_history_guard(),public.property_video_retired_source_read_key_guard(),public.property_video_source_read_retirement_immutable() from public,anon,authenticated;
revoke all on function public.property_video_source_read_history_guard(),public.property_video_retired_source_read_key_guard(),public.property_video_source_read_retirement_immutable() from service_role;
grant execute on function public.property_video_source_read_resume_proof(uuid),public.property_video_job_resume_source_read(uuid,uuid,numeric,text) to service_role;
commit;
