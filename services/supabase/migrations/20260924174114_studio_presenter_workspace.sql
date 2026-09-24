-- Workspace-owned presenter consent. Only named subjects can grant their likeness;
-- organization administrators cannot grant it for them. No provider or job engine.
begin;
create table if not exists public.studio_presenter_profiles (
 id uuid primary key default gen_random_uuid(),
 org_id uuid not null references public.orgs(id) on delete cascade,
 subject_user_id uuid not null references auth.users(id) on delete cascade,
 source_listing_id uuid not null references public.listings(id) on delete cascade,
 display_name text not null check(length(btrim(display_name)) between 1 and 80),
 reference_asset_ids uuid[] not null check(cardinality(reference_asset_ids) between 1 and 8),
 reference_snapshot jsonb not null check(jsonb_typeof(reference_snapshot)='array'),
 revision integer not null check(revision>0),
 status text not null check(status in ('pending','approved','revoked')),
 approved_revision integer,
 consent_at timestamptz,
 updated_at timestamptz not null default clock_timestamp(),
 unique(org_id,subject_user_id),
 check((status='approved' and approved_revision=revision and consent_at is not null) or (status<>'approved' and approved_revision is null))
);
create table if not exists public.studio_presenter_drafts (
 id uuid primary key,
 org_id uuid not null references public.orgs(id) on delete cascade,
 listing_id uuid not null references public.listings(id) on delete cascade,
 author_user_id uuid not null references auth.users(id) on delete cascade,
 subject_user_id uuid not null references auth.users(id) on delete cascade,
 profile_id uuid not null references public.studio_presenter_profiles(id) on delete cascade,
 profile_revision integer not null check(profile_revision>0),
 title text not null check(length(btrim(title)) between 1 and 120),
 script text not null check(length(btrim(script)) between 1 and 2000),
 source_asset_id uuid not null,
 format text not null check(format in ('listing_intro','property_tour','market_update')),
 resolution text not null check(resolution in ('480p','720p')),
 revision integer not null check(revision>0),
 approved_revision integer,
 approved_profile_revision integer,
 approval_binding jsonb,
 consent_at timestamptz,
 generation_result_id uuid references public.studio_creative_results(id) on delete set null,
 updated_at timestamptz not null default clock_timestamp(),
 check((approved_revision is null and approved_profile_revision is null and approval_binding is null) or (approved_revision=revision and approved_profile_revision=profile_revision and approval_binding is not null and consent_at is not null))
);
create index if not exists studio_presenter_drafts_listing on public.studio_presenter_drafts(org_id,listing_id,updated_at desc,id);
create index if not exists studio_presenter_drafts_profile on public.studio_presenter_drafts(profile_id);
-- A job receipt may belong to the agency rather than the represented person.
-- Preserve subject deletion semantics for its private likeness snapshot too.
alter table public.studio_creative_results add column if not exists presenter_profile_id uuid references public.studio_presenter_profiles(id) on delete cascade;
create index if not exists studio_creative_results_presenter_profile on public.studio_creative_results(presenter_profile_id) where presenter_profile_id is not null;
alter table public.studio_presenter_profiles enable row level security;
alter table public.studio_presenter_drafts enable row level security;
revoke all on public.studio_presenter_profiles,public.studio_presenter_drafts from public,anon,authenticated;
grant select,insert,update,delete on public.studio_presenter_profiles,public.studio_presenter_drafts to service_role;

create or replace function public.studio_presenter_scope(p_actor uuid,p_org_id uuid,p_listing_id uuid)
returns text language plpgsql security invoker set search_path='' as $$
declare v_role text;
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required'; end if;
 -- Every presenter action in this workspace uses the same transaction lock. This
 -- bounds the consent/CAS critical section, including creation of absent rows.
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('studio-presenter:'||p_org_id::text,0));
 if not public.studio_review_named_account(p_actor) then raise exception 'RP403: Your named account is unavailable'; end if;
 select role into v_role from public.memberships where user_id=p_actor and org_id=p_org_id for share;
 if v_role is null then raise exception 'RP403: Workspace membership is required'; end if;
 perform 1 from public.orgs where id=p_org_id and deleted_at is null for share;
 if not found then raise exception 'RP404: Workspace is unavailable'; end if;
 perform 1 from public.listings where id=p_listing_id and org_id=p_org_id and deleted_at is null for share;
 if not found then raise exception 'RP404: Property is unavailable'; end if;
 return v_role;
end;
$$;
create or replace function public.studio_presenter_member(p_user uuid,p_org_id uuid)
returns boolean language sql stable security invoker set search_path='' as $$
 select public.studio_review_named_account(p_user) and exists(select 1 from public.memberships where user_id=p_user and org_id=p_org_id);
$$;
create or replace function public.studio_presenter_asset_eligible(a public.capture_assets,p_org_id uuid)
returns boolean language sql immutable security invoker set search_path='' as $$
 select coalesce(a.uploaded and a.bucket='uploads' and not a.upload_aborted and a.kind in ('photo','video')
  and a.sha256 ~ '^[0-9a-f]{64}$' and a.bytes>0
  and a.storage_key like 'uploads/'||p_org_id::text||'/'||a.listing_id::text||'/%'
  and a.storage_key not like '%..%' and a.storage_key !~ '[\\?#[:cntrl:]]'
  and (a.kind='photo' or a.duration_s between 4 and 30),false);
$$;
create or replace function public.studio_presenter_assets(p_org_id uuid,p_listing_id uuid,p_ids uuid[],p_kind text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare a public.capture_assets%rowtype; result jsonb:='[]'; v_id uuid;
begin
 if p_kind is null or p_kind not in ('photo','video') or coalesce(cardinality(p_ids),0) not between 1 and 8 or array_position(p_ids,null) is not null or cardinality(p_ids)<>(select count(distinct x) from unnest(p_ids) x) then raise exception 'RP400: Choose one to eight distinct uploaded assets'; end if;
 perform 1 from public.listings where id=p_listing_id and org_id=p_org_id and deleted_at is null for share;
 if not found then raise exception 'RP422: The source property is unavailable'; end if;
 foreach v_id in array p_ids loop
  select * into a from public.capture_assets where id=v_id and listing_id=p_listing_id for share;
  if not found or a.kind<>p_kind or not public.studio_presenter_asset_eligible(a,p_org_id) then raise exception 'RP422: Choose completed original uploads from the authorized source property'; end if;
  if p_kind='video' and (a.duration_s is null or a.duration_s<4 or a.duration_s>30) then raise exception 'RP422: Choose a source performance between 4 and 30 seconds'; end if;
  result:=result||jsonb_build_array(jsonb_build_object('id',a.id,'listing_id',a.listing_id,'bucket',a.bucket,'storage_key',a.storage_key,'sha256',a.sha256,'bytes',a.bytes,'duration_s',a.duration_s));
 end loop;
 return result;
end;
$$;
create or replace function public.studio_presenter_profile_valid(p public.studio_presenter_profiles)
returns boolean language plpgsql security invoker set search_path='' as $$
begin
 if p.status<>'approved' or p.approved_revision is distinct from p.revision or not public.studio_presenter_member(p.subject_user_id,p.org_id) then return false; end if;
 return public.studio_presenter_assets(p.org_id,p.source_listing_id,p.reference_asset_ids,'photo')=p.reference_snapshot;
exception when raise_exception then
 if SQLERRM like 'RP422:%' then return false; end if;
 raise;
end;
$$;
create or replace function public.studio_presenter_binding(d public.studio_presenter_drafts,p public.studio_presenter_profiles)
returns jsonb language plpgsql security invoker set search_path='' as $$
begin
 if d.org_id<>p.org_id or d.subject_user_id<>p.subject_user_id or d.profile_id<>p.id or d.profile_revision<>p.revision
   or not public.studio_presenter_profile_valid(p) or not public.studio_presenter_member(d.author_user_id,d.org_id) then raise exception 'RP422: The presenter profile or draft author is unavailable'; end if;
 return jsonb_build_object('draft_id',d.id,'listing_id',d.listing_id,'org_id',d.org_id,'subject_user_id',d.subject_user_id,
  'profile_id',p.id,'profile_revision',p.revision,'draft_revision',d.revision,'title',d.title,'script',d.script,'format',d.format,'resolution',d.resolution,
  'source_asset',public.studio_presenter_assets(d.org_id,d.listing_id,array[d.source_asset_id],'video')->0,'reference_assets',p.reference_snapshot,
  'source_performance_consent',true);
end;
$$;
create or replace function public.studio_presenter_draft_valid(d public.studio_presenter_drafts,p public.studio_presenter_profiles)
returns boolean language plpgsql security invoker set search_path='' as $$
begin
 if d.approved_revision is distinct from d.revision or d.approved_profile_revision is distinct from p.revision then return false; end if;
 return d.approval_binding=public.studio_presenter_binding(d,p);
exception when raise_exception then
 if SQLERRM like 'RP422:%' then return false; end if;
 raise;
end;
$$;
create or replace function public.studio_presenter_state(p_actor uuid,p_org_id uuid,p_listing_id uuid,p_role text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare p public.studio_presenter_profiles%rowtype; d public.studio_presenter_drafts%rowtype; pv boolean; dv boolean; editable boolean:=p_role in ('owner','admin','agent'); profiles jsonb:='[]'; drafts jsonb:='[]'; candidates jsonb; sources jsonb; reason text;
begin
 for p in select * from public.studio_presenter_profiles where org_id=p_org_id order by subject_user_id=p_actor desc,updated_at desc,id limit 200 loop
  pv:=public.studio_presenter_profile_valid(p);
  if p.subject_user_id=p_actor or pv then
   reason:=case when p.status='approved' and not pv then 'The reference photos, source property or represented account changed. Save and approve the profile again.' else null end;
   profiles:=profiles||jsonb_build_array(jsonb_build_object('id',p.id,'org_id',p.org_id,'subject_user_id',p.subject_user_id,'source_listing_id',p.source_listing_id,'display_name',p.display_name,
    'reference_asset_ids',p.reference_asset_ids,'revision',p.revision,'status',case when p.status='approved' and not pv then 'pending' else p.status end,
    'approved_revision',case when pv then p.approved_revision else null end,'updated_at',p.updated_at,'invalid_reason',reason,
    'permissions',jsonb_build_object('can_save',p_actor=p.subject_user_id and editable,'can_approve',p_actor=p.subject_user_id and editable and p.status='pending','can_revoke',p_actor=p.subject_user_id and p.status<>'revoked')));
  end if;
 end loop;
 for d in select * from public.studio_presenter_drafts where org_id=p_org_id and listing_id=p_listing_id order by updated_at desc,id limit 100 loop
  if not public.studio_presenter_member(d.author_user_id,p_org_id) or not public.studio_presenter_member(d.subject_user_id,p_org_id) then continue; end if;
  select * into p from public.studio_presenter_profiles where id=d.profile_id and org_id=p_org_id;
  if not found then continue; end if;
  pv:=public.studio_presenter_profile_valid(p) and p.revision=d.profile_revision;
  dv:=public.studio_presenter_draft_valid(d,p);
  drafts:=drafts||jsonb_build_array(jsonb_build_object('id',d.id,'org_id',d.org_id,'listing_id',d.listing_id,'author_user_id',d.author_user_id,'subject_user_id',d.subject_user_id,
   'profile_id',d.profile_id,'profile_revision',d.profile_revision,'title',d.title,'script',d.script,'source_asset_id',d.source_asset_id,'format',d.format,'resolution',d.resolution,
   'revision',d.revision,'status',case when dv then 'approved' else 'draft' end,'approved_revision',case when dv then d.approved_revision else null end,
   'approved_profile_revision',case when dv then d.approved_profile_revision else null end,'updated_at',d.updated_at,'generation_result_id',d.generation_result_id,
   'invalid_reason',case when not pv then 'The presenter profile changed or is unavailable. Select an approved profile and save again.' when d.approved_revision is not null and not dv then 'The source upload changed. Save and approve this draft again.' else null end,
   'permissions',jsonb_build_object('can_save',editable,'can_approve',editable and p_actor=d.subject_user_id and pv and not dv,'can_request_generation',editable and dv,'can_generate',false)));
 end loop;
 select coalesce(jsonb_agg(jsonb_build_object('asset_id',a.id,'listing_id',a.listing_id) order by a.created_at desc,a.id),'[]') into candidates from
  (select id,listing_id,created_at from public.capture_assets where listing_id=p_listing_id and kind='photo' and public.studio_presenter_asset_eligible(capture_assets,p_org_id) order by created_at desc,id limit 200) a;
 select coalesce(jsonb_agg(jsonb_build_object('asset_id',a.id,'listing_id',a.listing_id,'duration_s',a.duration_s) order by a.created_at desc,a.id),'[]') into sources from
  (select id,listing_id,created_at,duration_s from public.capture_assets where listing_id=p_listing_id and kind='video' and public.studio_presenter_asset_eligible(capture_assets,p_org_id) order by created_at desc,id limit 200) a;
 return jsonb_build_object('org_id',p_org_id,'listing_id',p_listing_id,'profiles',profiles,'drafts',drafts,'reference_candidates',candidates,'source_candidates',sources,
   'permissions',jsonb_build_object('can_save_profile',editable,'can_create_draft',editable),
   'truncated',jsonb_build_object('profiles',(select count(*)>200 from public.studio_presenter_profiles where org_id=p_org_id),'drafts',(select count(*)>100 from public.studio_presenter_drafts where org_id=p_org_id and listing_id=p_listing_id),
    'reference_candidates',(select count(*)>200 from public.capture_assets where listing_id=p_listing_id and kind='photo' and public.studio_presenter_asset_eligible(capture_assets,p_org_id)),
    'source_candidates',(select count(*)>200 from public.capture_assets where listing_id=p_listing_id and kind='video' and public.studio_presenter_asset_eligible(capture_assets,p_org_id))));
end;
$$;
create or replace function public.studio_presenter_workspace(p_actor uuid,p_org_id uuid,p_listing_id uuid,p_action text default 'get',p_payload jsonb default '{}')
returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_role text; p public.studio_presenter_profiles%rowtype; d public.studio_presenter_drafts%rowtype; expected integer; expected_profile integer; ids uuid[]; refs jsonb; draft_id uuid; profile_id uuid; now_at timestamptz:=clock_timestamp();
begin
 v_role:=public.studio_presenter_scope(p_actor,p_org_id,p_listing_id);
 if p_action is null or p_action not in ('get','save_profile','approve_profile','revoke_profile','save_draft','approve_draft') then raise exception 'RP400: Choose a presenter workspace action'; end if;
 if p_action='get' then return public.studio_presenter_state(p_actor,p_org_id,p_listing_id,v_role); end if;
 if jsonb_typeof(p_payload)<>'object' or octet_length(p_payload::text)>16384 or coalesce(p_payload->>'expected_revision','')!~ '^(0|[1-9][0-9]{0,9})$' then raise exception 'RP400: Refresh the saved revision before continuing'; end if;
 if (p_payload->>'expected_revision')::bigint>=2147483647 then raise exception 'RP400: Invalid revision'; end if;
 expected:=(p_payload->>'expected_revision')::integer;
 if v_role not in ('owner','admin','agent') and p_action<>'revoke_profile' then raise exception 'RP403: Your workspace role cannot change presenter work'; end if;
 if p_action in ('save_profile','approve_profile','revoke_profile') then
  select * into p from public.studio_presenter_profiles where org_id=p_org_id and subject_user_id=p_actor for update;
  if p_action<>'save_profile' and (p.id is null or p.id::text is distinct from p_payload->>'profile_id') then raise exception 'RP403: Only the represented person can approve or revoke their profile'; end if;
  if coalesce(p.revision,0)<>expected then raise exception 'RP409: This profile changed. Reload before continuing'; end if;
  if p_action='save_profile' then
   if coalesce(length(btrim(p_payload->>'display_name')),0) not between 1 and 80 or jsonb_typeof(p_payload->'reference_asset_ids') is distinct from 'array' or jsonb_array_length(p_payload->'reference_asset_ids') not between 1 and 8 then raise exception 'RP400: Add a name and one to eight reference photos'; end if;
   begin select array_agg(value::uuid order by ord) into ids from jsonb_array_elements_text(p_payload->'reference_asset_ids') with ordinality x(value,ord); exception when invalid_text_representation then raise exception 'RP400: Choose valid reference asset IDs'; end;
   refs:=public.studio_presenter_assets(p_org_id,p_listing_id,ids,'photo');
   insert into public.studio_presenter_profiles(org_id,subject_user_id,source_listing_id,display_name,reference_asset_ids,reference_snapshot,revision,status)
    values(p_org_id,p_actor,p_listing_id,btrim(p_payload->>'display_name'),ids,refs,expected+1,'pending')
    on conflict(org_id,subject_user_id) do update set source_listing_id=excluded.source_listing_id,display_name=excluded.display_name,reference_asset_ids=excluded.reference_asset_ids,
     reference_snapshot=excluded.reference_snapshot,revision=excluded.revision,status='pending',approved_revision=null,consent_at=null,updated_at=now_at returning * into p;
  elsif p_action='approve_profile' then
   if p_payload->'likeness_consent' is distinct from 'true'::jsonb then raise exception 'RP400: Confirm permission to use your likeness with these reference photos'; end if;
   if p.status<>'pending' then raise exception 'RP409: Save your current references before approving the profile'; end if;
   refs:=public.studio_presenter_assets(p_org_id,p.source_listing_id,p.reference_asset_ids,'photo');
   if refs<>p.reference_snapshot then raise exception 'RP409: Reference uploads changed. Save the profile again'; end if;
   update public.studio_presenter_profiles set revision=revision+1,status='approved',approved_revision=revision+1,consent_at=now_at,updated_at=now_at where id=p.id returning * into p;
  else
   update public.studio_presenter_profiles set revision=revision+1,status='revoked',approved_revision=null,consent_at=null,updated_at=now_at where id=p.id returning * into p;
  end if;
  -- Invalidate all draft approvals immediately across every property. Preserve
  -- the previous profile revision so a fresh save is required before reapproval.
  update public.studio_presenter_drafts pd set revision=pd.revision+1,approved_revision=null,approved_profile_revision=null,approval_binding=null,consent_at=null,updated_at=now_at where pd.profile_id=p.id;
 else
  begin draft_id:=(p_payload->>'draft_id')::uuid; expected_profile:=(p_payload->>'expected_profile_revision')::integer; exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'RP400: Choose a valid draft and profile revision'; end;
  if draft_id is null or expected_profile is null or expected_profile<1 then raise exception 'RP400: Choose a valid draft and profile revision'; end if;
  select * into d from public.studio_presenter_drafts where id=draft_id for update;
  if d.id is not null and (d.org_id<>p_org_id or d.listing_id<>p_listing_id) then raise exception 'RP404: Presenter draft is unavailable'; end if;
  if coalesce(d.revision,0)<>expected then raise exception 'RP409: This presenter draft changed. Reload before continuing'; end if;
  if p_action='save_draft' then
   begin profile_id:=(p_payload->>'profile_id')::uuid; exception when invalid_text_representation then raise exception 'RP400: Choose a valid presenter profile'; end;
  else
   if d.id is null then raise exception 'RP404: Save the draft before approval'; end if;
   profile_id:=d.profile_id;
  end if;
  select * into p from public.studio_presenter_profiles where id=profile_id and org_id=p_org_id for update;
  if not found or not public.studio_presenter_profile_valid(p) then raise exception 'RP422: Choose an approved and available presenter profile'; end if;
  if p.revision<>expected_profile then raise exception 'RP409: The presenter profile changed. Reload before continuing'; end if;
  if p_action='save_draft' then
   if coalesce(length(btrim(p_payload->>'title')),0) not between 1 and 120 or coalesce(length(btrim(p_payload->>'script')),0) not between 1 and 2000
    or coalesce(p_payload->>'format','') not in ('listing_intro','property_tour','market_update') or coalesce(p_payload->>'resolution','') not in ('480p','720p') then raise exception 'RP400: Add a title, recording script, supported format and resolution'; end if;
   if d.id is not null and not public.studio_presenter_member(d.author_user_id,p_org_id) then raise exception 'RP404: The draft author is unavailable'; end if;
   begin ids:=array[(p_payload->>'source_asset_id')::uuid]; exception when invalid_text_representation then raise exception 'RP400: Choose a valid source upload'; end;
   perform public.studio_presenter_assets(p_org_id,p_listing_id,ids,'video');
   insert into public.studio_presenter_drafts(id,org_id,listing_id,author_user_id,subject_user_id,profile_id,profile_revision,title,script,source_asset_id,format,resolution,revision)
    values(draft_id,p_org_id,p_listing_id,coalesce(d.author_user_id,p_actor),p.subject_user_id,p.id,p.revision,btrim(p_payload->>'title'),btrim(p_payload->>'script'),ids[1],p_payload->>'format',p_payload->>'resolution',expected+1)
    on conflict(id) do update set subject_user_id=excluded.subject_user_id,profile_id=excluded.profile_id,profile_revision=excluded.profile_revision,title=excluded.title,script=excluded.script,source_asset_id=excluded.source_asset_id,
     format=excluded.format,resolution=excluded.resolution,revision=excluded.revision,approved_revision=null,approved_profile_revision=null,approval_binding=null,consent_at=null,generation_result_id=null,updated_at=now_at;
  else
   if p_actor<>p.subject_user_id then raise exception 'RP403: Only the represented person can approve this video'; end if;
   if p_payload->'source_performance_consent' is distinct from 'true'::jsonb then raise exception 'RP400: Confirm permission to use this source performance'; end if;
   if d.profile_revision<>p.revision then raise exception 'RP409: Save the draft with the current approved profile first'; end if;
   if public.studio_presenter_draft_valid(d,p) then raise exception 'RP409: This exact draft is already approved'; end if;
   d.revision:=d.revision+1;
   refs:=public.studio_presenter_binding(d,p);
   update public.studio_presenter_drafts set revision=d.revision,approved_revision=d.revision,approved_profile_revision=p.revision,approval_binding=refs,consent_at=now_at,generation_result_id=null,updated_at=now_at where id=d.id;
  end if;
 end if;
 return public.studio_presenter_state(p_actor,p_org_id,p_listing_id,v_role);
end;
$$;

create or replace function public.studio_presenter_media(p_actor uuid,p_org_id uuid,p_listing_id uuid,p_payload jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare p public.studio_presenter_profiles%rowtype; ids uuid[]; assets jsonb;
begin
 perform public.studio_presenter_scope(p_actor,p_org_id,p_listing_id);
 if p_payload ? 'source_asset_id' then
  assets:=public.studio_presenter_assets(p_org_id,p_listing_id,array[(p_payload->>'source_asset_id')::uuid],'video');
 elsif p_payload ? 'profile_id' then
  select * into p from public.studio_presenter_profiles where id=(p_payload->>'profile_id')::uuid and org_id=p_org_id for share;
  if not found or (p.subject_user_id<>p_actor and not public.studio_presenter_profile_valid(p)) then raise exception 'RP404: Presenter profile is unavailable'; end if;
  if p.revision is distinct from (p_payload->>'expected_profile_revision')::integer then raise exception 'RP409: Presenter profile changed. Reload before continuing'; end if;
  assets:=public.studio_presenter_assets(p_org_id,p.source_listing_id,p.reference_asset_ids,'photo');
  if assets<>p.reference_snapshot then raise exception 'RP409: Reference uploads changed. Save the profile again'; end if;
 else
  if jsonb_typeof(p_payload->'asset_ids') is distinct from 'array' then raise exception 'RP400: Choose reference photos'; end if;
  select array_agg(value::uuid order by ord) into ids from jsonb_array_elements_text(p_payload->'asset_ids') with ordinality x(value,ord);
  assets:=public.studio_presenter_assets(p_org_id,p_listing_id,ids,'photo');
 end if;
 return jsonb_build_object('org_id',p_org_id,'listing_id',p_listing_id,'profile_id',p.id,'profile_revision',p.revision,'assets',assets);
exception when invalid_text_representation or numeric_value_out_of_range then raise exception 'RP400: Choose valid references and revision';
end;
$$;

-- Server-only orchestration hook. No public handler forwards this action. The
-- existing creative-result row is the execution receipt, not a parallel queue.
create or replace function public.studio_presenter_generation(p_actor uuid,p_org_id uuid,p_listing_id uuid,p_draft_id uuid,p_expected_revision integer,p_expected_profile_revision integer,p_action text default 'prepare',p_result_id uuid default null)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare role_name text; d public.studio_presenter_drafts%rowtype; p public.studio_presenter_profiles%rowtype; result_row public.studio_creative_results%rowtype; binding jsonb;
begin
 role_name:=public.studio_presenter_scope(p_actor,p_org_id,p_listing_id);
 if role_name not in ('owner','admin','agent') then raise exception 'RP403: Your role cannot request presenter generation'; end if;
 if p_action is null or p_action not in ('prepare','claim') then raise exception 'RP400: Unsupported generation operation'; end if;
 select * into d from public.studio_presenter_drafts where id=p_draft_id and org_id=p_org_id and listing_id=p_listing_id for update;
 if not found then raise exception 'RP404: Presenter draft is unavailable'; end if;
 select * into p from public.studio_presenter_profiles where id=d.profile_id and org_id=p_org_id for update;
 if d.revision is distinct from p_expected_revision or p.revision is distinct from p_expected_profile_revision then raise exception 'RP409: Presenter approval changed. Reload before continuing'; end if;
 if not public.studio_presenter_draft_valid(d,p) then raise exception 'RP422: This exact video needs current subject approval'; end if;
 binding:=public.studio_presenter_binding(d,p);
 if d.generation_result_id is not null then
  select * into result_row from public.studio_creative_results where id=d.generation_result_id and org_id=p_org_id and listing_id=p_listing_id and kind='video' for update;
  if not found or result_row.metadata->'presenter_snapshot' is distinct from binding then raise exception 'RP409: Saved generation no longer matches this exact approval'; end if;
 end if;
 if p_action='claim' and d.generation_result_id is null then
  select * into result_row from public.studio_creative_results where id=p_result_id and user_id=p_actor and org_id=p_org_id and listing_id=p_listing_id and kind='video' for update;
  if not found or result_row.metadata->>'state' is distinct from 'submitting' or result_row.metadata->>'video_kind' is distinct from 'presenter'
    or result_row.metadata->>'presenter_draft_id' is distinct from d.id::text or result_row.metadata->>'presenter_draft_revision' is distinct from d.revision::text
    or result_row.metadata->>'presenter_profile_id' is distinct from p.id::text or result_row.metadata->>'presenter_profile_revision' is distinct from p.revision::text
    or result_row.metadata ? 'presenter_snapshot' then raise exception 'RP409: Create a fresh scoped submitting video receipt before claiming'; end if;
  update public.studio_creative_results set metadata=metadata||jsonb_build_object('presenter_snapshot',binding),presenter_profile_id=p.id where id=result_row.id;
  update public.studio_presenter_drafts set generation_result_id=result_row.id where id=d.id returning * into d;
 end if;
 return jsonb_build_object('snapshot',binding,'source_asset',binding->'source_asset','reference_assets',binding->'reference_assets','existing_result_id',d.generation_result_id);
end;
$$;
-- Fail closed on PostgREST's inherited default EXECUTE privileges for every helper.
revoke all on function public.studio_presenter_asset_eligible(public.capture_assets,uuid) from public,anon,authenticated;
grant execute on function public.studio_presenter_asset_eligible(public.capture_assets,uuid) to service_role;
revoke all on function public.studio_presenter_scope(uuid,uuid,uuid),public.studio_presenter_member(uuid,uuid),public.studio_presenter_assets(uuid,uuid,uuid[],text),public.studio_presenter_profile_valid(public.studio_presenter_profiles),public.studio_presenter_binding(public.studio_presenter_drafts,public.studio_presenter_profiles),public.studio_presenter_draft_valid(public.studio_presenter_drafts,public.studio_presenter_profiles),public.studio_presenter_state(uuid,uuid,uuid,text),public.studio_presenter_workspace(uuid,uuid,uuid,text,jsonb),public.studio_presenter_media(uuid,uuid,uuid,jsonb),public.studio_presenter_generation(uuid,uuid,uuid,uuid,integer,integer,text,uuid) from public,anon,authenticated;
grant execute on function public.studio_presenter_scope(uuid,uuid,uuid),public.studio_presenter_member(uuid,uuid),public.studio_presenter_assets(uuid,uuid,uuid[],text),public.studio_presenter_profile_valid(public.studio_presenter_profiles),public.studio_presenter_binding(public.studio_presenter_drafts,public.studio_presenter_profiles),public.studio_presenter_draft_valid(public.studio_presenter_drafts,public.studio_presenter_profiles),public.studio_presenter_state(uuid,uuid,uuid,text),public.studio_presenter_workspace(uuid,uuid,uuid,text,jsonb),public.studio_presenter_media(uuid,uuid,uuid,jsonb),public.studio_presenter_generation(uuid,uuid,uuid,uuid,integer,integer,text,uuid) to service_role;
commit;
