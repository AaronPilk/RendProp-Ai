-- Early private release of a generated photo edit (12 Nov 2026).
--
-- Problem: the judge has been advisory since 20261106231733, yet the realtor
-- still waited ~55 s (container cold start + derivative prep + judge) after a
-- ~20 s generation, because the only step that wrote the delivery receipts was
-- photo_quality_finish, at the very end of the check.
--
-- This migration splits "the requester may privately review the exact retained
-- bytes" (RELEASE) from "the edit may enter listing media" (state = 'accept').
--
--   * photo_quality_release      new. Callable once the candidate is retained
--     (output receipt etag recorded, which is also the statement that created
--     the disclosure row) and the edge geometry check has run. It writes the
--     same private_ai_outputs delivery receipts photo_quality_finish writes and
--     one photo_edit_releases row. It does NOT touch evidence.state,
--     check.state, media_provenance.altered_key or media_provenance.qc, so
--     every publication gate keyed on state = 'accept' / qc.publishable keeps
--     refusing until the advisory check has recorded its verdict.
--   * photo_quality_private_output_guard   also admits a released evidence row
--     (same org / actor / listing / key / bytes identity as before).
--   * photo_quality_defer_altered  new. Shipped iOS (build 147) uploads the
--     saved edit and PATCHes it onto the disclosure record right after the
--     image arrives. While the check is still running that PATCH used to be a
--     404/409. The exact uploaded asset (same listing, same sha256, same byte
--     count as the checked output) is now remembered and applied by
--     photo_quality_finish in the SAME statement path and under the SAME
--     photo_quality_provenance_media_guard trigger, only when the check
--     accepts.
--   * photo_quality_finish        unchanged acceptance predicate and receipts;
--     additionally applies a deferred altered asset on accept.
--   * photo_quality_snapshot      adds a "release" key (null when not
--     released). Deployed edge code ignores unknown keys.
--   * photo_quality_cpu_failure   a third failed comparison preparation ends
--     the check; it now stamps finished_at like every other terminal path, so
--     the client sees a closed operation (422) instead of an unresolvable 409.
--
-- Backward compatible with the edge functions deployed today: nothing calls
-- the new functions until the new ai-photo / me functions ship, and the new
-- edge code falls back to the old synchronous path when these are absent.
-- Safe to apply once: every rewritten function is pinned to its predecessor
-- md5 and the migration aborts untouched if any of them changed.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $pin$
declare pinned record;
begin
 for pinned in select * from (values
   ('public.photo_quality_finish(uuid,uuid,uuid,jsonb)','18a80bc6401a14eabb43729610de9499'),
   ('public.photo_quality_snapshot(uuid,uuid)','e12f34d725a4466b453ccfd859cf456b'),
   ('public.photo_quality_private_output_guard()','8b52d5d1dd44f2aedd2dd568f607ea89'),
   ('public.photo_quality_cpu_failure(uuid,uuid,text)','7b14da68b6228587f17f62da124bd1ed')
  ) as v(signature,expected)
 loop
  if (select md5(prosrc) from pg_proc where oid = pinned.signature::regprocedure) is distinct from pinned.expected then
   raise exception '% changed since 2026-11-12; review the early-release rewrite before applying', pinned.signature;
  end if;
 end loop;
 if to_regclass('public.photo_edit_releases') is not null then
  raise exception 'photo_edit_releases already exists; this migration applies once';
 end if;
end
$pin$;

-- One row per privately released edit. IDs and bounded facts only: no storage
-- key lives here, so storage accounting and erasure are unchanged (the row
-- disappears with its evidence row).
create table public.photo_edit_releases(
 evidence_id uuid primary key references public.photo_edit_evidence(id) on delete cascade,
 actor_id uuid not null,
 org_id uuid not null,
 provenance_id uuid not null,
 output_sha256 text not null check(output_sha256 ~ '^[a-f0-9]{64}$'),
 facts jsonb not null default '{}'::jsonb check(jsonb_typeof(facts) = 'object' and pg_column_size(facts) <= 2048),
 released_at timestamptz not null default now(),
 pending_altered_asset uuid,
 pending_altered_at timestamptz,
 altered_outcome text check(altered_outcome in('applied','refused'))
);
alter table public.photo_edit_releases enable row level security;
revoke all on public.photo_edit_releases from public,anon,authenticated,service_role;
grant select on public.photo_edit_releases to service_role;

-- The delivery receipt may exist for an accepted edit (as before) or for a
-- released one. Identity conditions are byte-for-byte the previous ones.
create or replace function public.photo_quality_private_output_guard()
returns trigger language plpgsql security definer set search_path to '' as $function$begin
 if(new.storage_key like'ai-router/%/photo-evidence/%'or exists(select 1 from public.photo_edit_evidence e where e.legacy_keys?new.storage_key))and not exists(select 1 from public.photo_edit_evidence e where(e.state='accept'or exists(select 1 from public.photo_edit_releases r where r.evidence_id=e.id and r.actor_id=e.actor_id and r.org_id=e.org_id and r.output_sha256=e.output->>'sha256'))and e.purpose='prospective'and e.org_id=new.org_id and e.actor_id=new.user_id and e.listing_id is not distinct from new.listing_id and((e.output->>'key'=new.storage_key and(e.output->>'bytes')::bigint=new.bytes)or(e.input->>'key'=new.storage_key and(e.input->>'bytes')::bigint=new.bytes)))then raise exception'RP409: This photo still awaits fixed-feature quality review';end if;return new;end$function$;

create or replace function public.photo_quality_snapshot(p_actor uuid,p_evidence uuid)
returns jsonb language plpgsql security definer set search_path to '' as $function$declare e public.photo_edit_evidence;q public.photo_quality_checks;begin
 e:=public.photo_quality_scope(p_actor,p_evidence);select * into q from public.photo_quality_checks where evidence_id=e.id and automatic;
 return jsonb_build_object('evidence',to_jsonb(e),'check',to_jsonb(q),'can_continue',e.output_etag is not null and q.state in('pending','preparing','derivative_ready')and q.judge_started_at is null and(q.state='derivative_ready'or q.lease_until is null or q.lease_until<=now())and not exists(select 1 from public.serving_cost_reservations where org_id=e.org_id and actor_id=e.actor_id and request_key='photo-qc:'||q.id and state<>'rejected'),
  'release',(select jsonb_build_object('released_at',r.released_at,'output_sha256',r.output_sha256,'facts',r.facts,'pending_altered_asset',r.pending_altered_asset,'altered_outcome',r.altered_outcome)from public.photo_edit_releases r where r.evidence_id=e.id));end$function$;

-- RELEASE. The caller is the generation request, after: the cost ledger row
-- and credit settlement (unchanged, earlier in that request), the exact
-- candidate bytes retained and re-read from private storage, the disclosure
-- row created by photo_quality_evidence_receipt, and the edge geometry check.
create function public.photo_quality_release(p_actor uuid,p_evidence uuid,p_facts jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$declare e public.photo_edit_evidence;q public.photo_quality_checks;begin
 e:=public.photo_quality_scope(p_actor,p_evidence);select * into e from public.photo_edit_evidence where id=p_evidence for update;
 if jsonb_typeof(p_facts)is distinct from'object'or pg_column_size(p_facts)>2048 then raise exception'RP400: Bounded release facts are required';end if;
 if exists(select 1 from public.photo_edit_releases where evidence_id=e.id)then return public.photo_quality_snapshot(p_actor,e.id);end if;
 select * into q from public.photo_quality_checks where evidence_id=e.id and automatic;
 if e.purpose is distinct from'prospective'or e.output is null or e.output_etag is null or e.input_etag is null or e.provenance_id is null
  or e.state not in('evidence_ready','checking','accept')or q.id is null or q.state in('refuse','hold')
  or coalesce(e.output->>'sha256','')!~'^[a-f0-9]{64}$'
  or not exists(select 1 from public.media_provenance m where m.id=e.provenance_id and m.org_id=e.org_id and m.listing_id is not distinct from e.listing_id)
 then raise exception'RP409: This photo operation cannot be released for private review';end if;
 insert into public.photo_edit_releases(evidence_id,actor_id,org_id,provenance_id,output_sha256,facts)values(e.id,e.actor_id,e.org_id,e.provenance_id,e.output->>'sha256',p_facts);
 perform public.register_private_ai_output(e.actor_id,e.org_id,e.listing_id,'renders',e.output->>'key',(e.output->>'bytes')::bigint);
 if e.original_reference is null then perform public.register_private_ai_output(e.actor_id,e.org_id,e.listing_id,'renders',e.input->>'key',(e.input->>'bytes')::bigint);end if;
 return public.photo_quality_snapshot(p_actor,e.id);end$function$;

-- Remember the exact uploaded copy of a released, still-unchecked edit. The
-- asset conditions are the ones photo_quality_provenance_media_guard enforces
-- (same listing, uploaded, not aborted, same sha256 and byte count) plus the
-- ones provenance_asset_key enforces (a photo in the renders bucket). Nothing
-- is published here; photo_quality_finish applies it only on accept.
create function public.photo_quality_defer_altered(p_actor uuid,p_evidence uuid,p_asset uuid)
returns jsonb language plpgsql security definer set search_path to '' as $function$declare e public.photo_edit_evidence;rel public.photo_edit_releases;begin
 e:=public.photo_quality_scope(p_actor,p_evidence);select * into e from public.photo_edit_evidence where id=p_evidence for update;
 select * into rel from public.photo_edit_releases where evidence_id=e.id for update;
 if rel.evidence_id is null or e.purpose is distinct from'prospective'or e.listing_id is null or e.provenance_id is null or e.state not in('evidence_ready','checking')then
  return jsonb_build_object('deferred',false,'state',e.state);end if;
 if p_asset is null or not exists(select 1 from public.capture_assets a where a.id=p_asset and a.listing_id=e.listing_id and a.kind='photo'and coalesce(a.bucket,'uploads')='renders'and a.uploaded and not a.upload_aborted and a.sha256=e.output->>'sha256'and a.bytes=(e.output->>'bytes')::bigint)then
  raise exception'RP409: The selected version is not the exact checked photo';end if;
 update public.photo_edit_releases set pending_altered_asset=p_asset,pending_altered_at=now(),altered_outcome=null where evidence_id=e.id;
 return jsonb_build_object('deferred',true,'state',e.state,'provenance_id',e.provenance_id,'listing_id',e.listing_id);end$function$;

-- Identical to the 20261106231733 body through the accept block; the only
-- addition is the deferred altered-asset application at the end of that block.
create or replace function public.photo_quality_finish(p_actor uuid,p_check uuid,p_lease uuid,p_result jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $function$declare q public.photo_quality_checks;e public.photo_edit_evidence;r public.serving_cost_reservations;l public.cost_ledger;accept boolean;axis text;qc jsonb;final text;rel public.photo_edit_releases;altered text;begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 select * into q from public.photo_quality_checks where id=p_check for update;if q.id is null then raise exception'RP404: Photo check is unavailable';end if;e:=public.photo_quality_scope(p_actor,q.evidence_id);
 if q.state in('accept','refuse','hold')and q.result is not null then if q.result is distinct from p_result then raise exception'RP409: A saved quality verdict is immutable';end if;return public.photo_quality_snapshot(e.actor_id,e.id);end if;
 if q.state<>'checking'or q.lease_token is distinct from p_lease or q.judge_started_at is null or jsonb_typeof(p_result)is distinct from'object'or octet_length(p_result::text)>3000 or p_result->>'policy'is distinct from e.policy or coalesce(p_result->>'action','')not in('accept','refuse','hold')or coalesce(p_result->>'verdict','')not in('pass','fail','unknown')then raise exception'RP409: A current bounded photo quality verdict is required';end if;
 select * into r from public.serving_cost_reservations where id=q.reservation_id and state='succeeded'and actor_id=p_actor and org_id=e.org_id;
 select * into l from public.cost_ledger where org_id=e.org_id and feature='qc'and provider=q.provider and model=q.model and total_cents>0 and meta->>'request_key'='photo-qc:'||q.id and meta->>'stage'='photo.qc:0'and meta->>'photo_check_id'=q.id::text and meta->>'evidence_id'=e.id::text and meta->>'prepared_sha256'=e.input->>'sha256'and meta->>'output_sha256'=e.output->>'sha256'and meta->>'derivative_manifest_sha256'=q.derivative_manifest_sha256 and meta->>'policy'=e.policy order by created_at desc,id desc limit 1;
 accept:=coalesce(p_result->>'action','')='accept'and r.id is not null and l.id is not null and jsonb_typeof(p_result->'preservation')='object'and jsonb_typeof(p_result->'findings')='array';
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
  select * into rel from public.photo_edit_releases where evidence_id=e.id for update;
  if rel.pending_altered_asset is not null and rel.altered_outcome is null and e.listing_id is not null then
   -- A refused attachment must never undo the verdict that was just saved.
   begin
    select a.storage_key into altered from public.capture_assets a where a.id=rel.pending_altered_asset and a.listing_id=e.listing_id and a.kind='photo'and coalesce(a.bucket,'uploads')='renders'and a.uploaded is true;
    if altered is null then raise exception'RP409: The deferred saved copy is unavailable';end if;
    update public.media_provenance set altered_key=altered where id=e.provenance_id;
    update public.photo_edit_releases set altered_outcome='applied'where evidence_id=e.id;
   exception when others then
    update public.photo_edit_releases set altered_outcome='refused'where evidence_id=e.id;
   end;
  end if;
 end if;return public.photo_quality_snapshot(e.actor_id,e.id);end$function$;

create or replace function public.photo_quality_cpu_failure(p_check uuid,p_lease uuid,p_code text)
returns jsonb language plpgsql security definer set search_path to '' as $function$declare x jsonb;q public.photo_quality_checks;e public.photo_edit_evidence;begin
 x:=public.photo_quality_worker_scope(p_check,p_lease);q:=jsonb_populate_record(null::public.photo_quality_checks,x->'check');e:=jsonb_populate_record(null::public.photo_edit_evidence,x->'evidence');
 if p_code is distinct from'cpu_photo_comparison_failed'then raise exception'RP400: Closed photo preparation failure is required';end if;
 update public.photo_quality_checks set state=case when cpu_attempts>=3 then'hold'else'pending'end,lease_until=null,finished_at=case when cpu_attempts>=3 then now()else finished_at end where id=q.id;
 update public.photo_edit_evidence set state=case when q.cpu_attempts>=3 then'hold'else'evidence_ready'end,failure=jsonb_build_object('phase','comparison_preparation','code',p_code),updated_at=now()where id=e.id;
 return public.photo_quality_snapshot(e.actor_id,e.id);end$function$;

-- Checks that already ended this way (one row, 15 Oct) get the same terminal
-- stamp, so their requester's saved operation can close.
update public.photo_quality_checks q set finished_at=now()
 where q.state='hold'and q.finished_at is null and q.judge_started_at is null and q.cpu_attempts>=3
  and exists(select 1 from public.photo_edit_evidence e where e.id=q.evidence_id and e.state='hold');

revoke all on function public.photo_quality_release(uuid,uuid,jsonb)from public,anon,authenticated;
revoke all on function public.photo_quality_defer_altered(uuid,uuid,uuid)from public,anon,authenticated;
grant execute on function public.photo_quality_release(uuid,uuid,jsonb)to service_role;
grant execute on function public.photo_quality_defer_altered(uuid,uuid,uuid)to service_role;

do $verify$
declare signature text;
begin
 foreach signature in array array[
  'public.photo_quality_finish(uuid,uuid,uuid,jsonb)','public.photo_quality_snapshot(uuid,uuid)','public.photo_quality_private_output_guard()',
  'public.photo_quality_cpu_failure(uuid,uuid,text)','public.photo_quality_release(uuid,uuid,jsonb)','public.photo_quality_defer_altered(uuid,uuid,uuid)']
 loop
  if not exists(select 1 from pg_proc p where p.oid=signature::regprocedure and p.prosecdef and p.proconfig=array['search_path=""']
    and not has_function_privilege('anon',p.oid,'execute')and not has_function_privilege('authenticated',p.oid,'execute')
    and has_function_privilege('service_role',p.oid,'execute'))then
   raise exception '% lost its definer/search_path/grant contract',signature;
  end if;
 end loop;
 if (select prosrc from pg_proc where oid='public.photo_quality_finish(uuid,uuid,uuid,jsonb)'::regprocedure)
   not like '%accept:=coalesce(p_result->>''action'','''')=''accept''and r.id is not null and l.id is not null and jsonb_typeof(p_result->''preservation'')=''object''and jsonb_typeof(p_result->''findings'')=''array'';%' then
  raise exception 'photo_quality_finish lost its 20261106231733 acceptance predicate';
 end if;
end
$verify$;
commit;
