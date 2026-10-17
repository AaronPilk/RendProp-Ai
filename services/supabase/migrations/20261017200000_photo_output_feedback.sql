-- AI photo feedback and improvement loop (owner scope 2026-10-17; contract
-- docs/handoff/PHOTO-FEEDBACK-DESIGN-20261017.md sections 2-5 + Amendments).
-- Observation metadata only. No funding, price, ledger, route, prompt,
-- generation, quality-gate or publication path changes, and nothing here can
-- start a provider call: feedback never triggers a regeneration. No historical
-- DML: evidence rows that predate this migration keep null (= unknown) recipe
-- and prompt columns, and feedback on a historical output is explicitly
-- 'provenance_only'. Ledger amounts summarised by the report are internal
-- modeled estimates, never reconciled supplier invoices.
begin;
-- Before ANY DDL, replay accepts only this migration's exact own objects: each
-- helper's exact body, security, config, signature and ACL, each relation's
-- exact shape, constraints, indexes, RLS and ACL, and the two evidence columns
-- with their exact checks. An unknown same-name object is refused here rather
-- than silently normalised by IF NOT EXISTS / OR REPLACE. Missing objects are
-- the first apply.
do $own_replay_guard$
declare e record;p pg_catalog.pg_proc;rel oid;owner_expected oid;service_oid oid;postgres_oid oid;shape text;
begin
 select proowner into owner_expected from pg_catalog.pg_proc where oid='public.photo_quality_begin(uuid,uuid,text,uuid,text,text,uuid,jsonb,jsonb)'::regprocedure;
 select oid into service_oid from pg_catalog.pg_roles where rolname='service_role';
 select oid into postgres_oid from pg_catalog.pg_roles where rolname='postgres';
 if owner_expected is null or service_oid is null or to_regclass('public.photo_edit_evidence')is null or to_regclass('public.media_provenance')is null then
  raise exception 'Photo quality journal, provenance and service_role must exist before photo feedback';end if;
 for e in select *from(values
  ('public.photo_quality_set_recipe(uuid,uuid,text,text)','a0da42a32dfd40ed164661174d4c26e1','plpgsql','v','jsonb',array['p_actor','p_evidence','p_revision','p_prompt_sha256']),
  ('public.photo_feedback_resolve(uuid,uuid,uuid)','1949e0d144fe8a538baf34a0d15f82d7','plpgsql','s','jsonb',array['p_actor','p_selected','p_provenance']),
  ('public.photo_feedback_attribution(uuid,uuid)','5e189f1e47ece7566c493aef4c5ec9d2','sql','s','jsonb',array['p_provenance','p_evidence']),
  ('public.photo_feedback_submit(uuid,uuid,uuid,text,text,integer,text,text[],text,text)','a4a4e1e536010c4690d35fa940fa4bc4','plpgsql','v','jsonb',
   array['p_actor','p_selected','p_provenance','p_output_sha256','p_client_key','p_revision','p_verdict','p_reasons','p_note','p_platform']),
  ('public.photo_feedback_signal(uuid,uuid,uuid,text,text,text,text)','3bb19af4fb47ebe00f0f6be690f339fb','plpgsql','v','jsonb',
   array['p_actor','p_selected','p_provenance','p_client_key','p_signal','p_detail','p_platform']),
  ('public.photo_feedback_state(uuid,uuid,uuid)','5d04e0ac05c04c506ed0a53b63042164','plpgsql','s','jsonb',array['p_actor','p_selected','p_provenance']),
  ('public.photo_regression_case_mark(uuid,uuid,uuid,text,text,boolean,boolean)','d6d2f35d63e5e1f3962d787928f0a514','plpgsql','v','jsonb',
   array['p_actor','p_selected','p_provenance','p_defect','p_expected','p_retain','p_withdraw']),
  ('public.photo_regression_cases_for_review(text)','6c69bce0613b63b1fb77b4913e789da3','sql','s','jsonb',array['p_recipe_revision']),
  ('public.photo_feedback_report(timestamptz,timestamptz)','8c5df8f177478c5d95df5040d2238835','plpgsql','s','jsonb',array['p_from','p_to'])
 )v(signature,body_md5,lang,volatility,result_type,arg_names)loop
  if to_regprocedure(e.signature)is not null then
   select *into p from pg_catalog.pg_proc where oid=to_regprocedure(e.signature);
   if md5(p.prosrc)<>e.body_md5 or p.proowner<>owner_expected or p.prokind<>'f'
    or p.prolang<>(select oid from pg_catalog.pg_language where lanname=e.lang)
    or not p.prosecdef or p.provolatile::text<>e.volatility or p.proisstrict or p.proleakproof or p.proparallel<>'u'
    or p.proconfig is distinct from array['search_path=""']::text[]
    or p.proargnames is distinct from e.arg_names or p.proargmodes is not null or p.proallargtypes is not null
    or p.provariadic<>0 or p.pronargdefaults<>0 or p.proargdefaults is not null
    or p.prorettype is distinct from to_regtype(e.result_type)::oid
    or exists(select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a
      where a.grantor<>owner_expected or a.privilege_type<>'EXECUTE'or a.is_grantable
       or a.grantee not in(owner_expected,service_oid,postgres_oid))
    or not exists(select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner)))a where a.grantee=service_oid)then
    raise exception 'Review changed photo feedback helper: %',e.signature;
   end if;
  end if;
 end loop;
 for e in select *from(values
  ('public.photo_output_feedback','id uuid not null default gen_random_uuid(), provenance_id uuid not null, evidence_id uuid, org_id uuid not null, listing_id uuid, actor_id uuid not null, client_key text not null, idempotency_key text not null, output_sha256 text, edit text not null, provider text, model text, generation_stage text, request_key text, recipe_revision text, prompt_sha256 text, attribution text not null, verdict text not null, reasons text[] not null default ''{}''::text[], note text, revision integer not null, revision_count integer not null default 1, platform text, created_at timestamp with time zone not null default now(), updated_at timestamp with time zone not null default now()','ae8b13263c7dd087ef9e558adf08e63a','CREATE UNIQUE INDEX photo_output_feedback_actor_id_client_key_key ON public.photo_output_feedback USING btree (actor_id, client_key); CREATE INDEX photo_output_feedback_evidence ON public.photo_output_feedback USING btree (evidence_id); CREATE UNIQUE INDEX photo_output_feedback_idempotency_key_key ON public.photo_output_feedback USING btree (idempotency_key); CREATE INDEX photo_output_feedback_listing ON public.photo_output_feedback USING btree (listing_id); CREATE UNIQUE INDEX photo_output_feedback_pkey ON public.photo_output_feedback USING btree (id); CREATE UNIQUE INDEX photo_output_feedback_provenance_id_actor_id_key ON public.photo_output_feedback USING btree (provenance_id, actor_id)'),
  ('public.photo_output_signals','id uuid not null default gen_random_uuid(), provenance_id uuid not null, evidence_id uuid, org_id uuid not null, listing_id uuid, actor_id uuid not null, signal text not null, detail text, client_key text not null, idempotency_key text not null, platform text, created_at timestamp with time zone not null default now()','dd9f727157469252a642d37b3954cde3','CREATE UNIQUE INDEX photo_output_signals_actor_id_client_key_key ON public.photo_output_signals USING btree (actor_id, client_key); CREATE INDEX photo_output_signals_evidence ON public.photo_output_signals USING btree (evidence_id); CREATE UNIQUE INDEX photo_output_signals_idempotency_key_key ON public.photo_output_signals USING btree (idempotency_key); CREATE INDEX photo_output_signals_listing ON public.photo_output_signals USING btree (listing_id); CREATE INDEX photo_output_signals_output ON public.photo_output_signals USING btree (provenance_id, actor_id); CREATE UNIQUE INDEX photo_output_signals_pkey ON public.photo_output_signals USING btree (id)'),
  ('public.photo_regression_cases','id uuid not null default gen_random_uuid(), provenance_id uuid not null, evidence_id uuid not null, feedback_id uuid, org_id uuid not null, listing_id uuid, defect text not null, expected_behavior text not null, edit text not null, style text, provider text, model text, recipe_revision text, prompt_sha256 text, input_ref jsonb not null, output_ref jsonb not null, protocol text not null default ''photo-fixed-features-v1''::text, authorized_by uuid, authorization_basis text not null default ''library_owner_consent''::text, authorized_at timestamp with time zone not null default now(), created_at timestamp with time zone not null default now(), updated_at timestamp with time zone not null default now(), withdrawn_at timestamp with time zone','117ae0dc43a88fb9aa4028b31f9508e0','CREATE UNIQUE INDEX photo_regression_cases_pkey ON public.photo_regression_cases USING btree (id); CREATE UNIQUE INDEX photo_regression_cases_provenance_id_key ON public.photo_regression_cases USING btree (provenance_id)')
 )v(name,shape,constraints,indexes)loop
  rel:=to_regclass(e.name);
  if rel is not null then
   select string_agg(a.attname||' '||format_type(a.atttypid,a.atttypmod)||case when a.attnotnull then ' not null'else ''end||coalesce(' default '||pg_get_expr(d.adbin,d.adrelid),''),', 'order by a.attnum)
    into shape from pg_catalog.pg_attribute a left join pg_catalog.pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
    where a.attrelid=rel and a.attnum>0 and not a.attisdropped;
   if shape is distinct from e.shape
    or md5((select string_agg(conname||': '||pg_get_constraintdef(oid),'; 'order by conname)from pg_catalog.pg_constraint where conrelid=rel))is distinct from e.constraints
    or(select string_agg(pg_get_indexdef(indexrelid),'; 'order by indexrelid::regclass::text)from pg_catalog.pg_index where indrelid=rel)is distinct from e.indexes
    or(select relkind<>'r'or not relrowsecurity or relforcerowsecurity or relowner<>owner_expected from pg_catalog.pg_class where oid=rel)
    or exists(select 1 from pg_catalog.pg_policy where polrelid=rel)
    or exists(select 1 from pg_catalog.pg_trigger where tgrelid=rel and not tgisinternal)
    or exists(select 1 from pg_catalog.pg_class c,aclexplode(coalesce(c.relacl,acldefault('r',c.relowner)))a where c.oid=rel
      and(a.grantor<>owner_expected or a.is_grantable or(a.grantee<>owner_expected and(a.grantee<>service_oid or a.privilege_type<>'SELECT'))))
    or not exists(select 1 from pg_catalog.pg_class c,aclexplode(coalesce(c.relacl,acldefault('r',c.relowner)))a where c.oid=rel and a.grantee=service_oid and a.privilege_type='SELECT')then
    raise exception 'Review changed photo feedback relation: %',e.name;
   end if;
  end if;
 end loop;
 -- The two evidence columns may only be this migration's own: nullable text,
 -- no default, and (when present) exactly its own named checks.
 if exists(select 1 from pg_catalog.pg_attribute where attrelid='public.photo_edit_evidence'::regclass and attname in('recipe_revision','prompt_sha256')and not attisdropped
    and(atttypid<>'text'::regtype or attnotnull or atthasdef))
  or exists(select 1 from pg_catalog.pg_constraint where conrelid='public.photo_edit_evidence'::regclass
    and conname in('photo_edit_evidence_recipe_revision_check','photo_edit_evidence_prompt_sha256_check','photo_edit_evidence_recipe_pair_check')
    and pg_get_constraintdef(oid)is distinct from case conname
     when'photo_edit_evidence_recipe_revision_check'then'CHECK (((recipe_revision IS NULL) OR (recipe_revision ~ ''^[a-z0-9][a-z0-9./_-]{1,79}$''::text)))'
     when'photo_edit_evidence_prompt_sha256_check'then'CHECK (((prompt_sha256 IS NULL) OR (prompt_sha256 ~ ''^[a-f0-9]{64}$''::text)))'
     else'CHECK (((recipe_revision IS NULL) = (prompt_sha256 IS NULL)))'end)then
  raise exception 'Review changed photo evidence recipe columns';
 end if;
end$own_replay_guard$;

-- 1. Immutable recipe identity on NEW generations. NULL = unknown: every row
-- that predates this migration stays null; nothing is back-filled.
alter table public.photo_edit_evidence add column if not exists recipe_revision text;
alter table public.photo_edit_evidence add column if not exists prompt_sha256 text;
do $add_checks$begin
 if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.photo_edit_evidence'::regclass and conname='photo_edit_evidence_recipe_revision_check')then
  alter table public.photo_edit_evidence add constraint photo_edit_evidence_recipe_revision_check check(recipe_revision is null or recipe_revision~'^[a-z0-9][a-z0-9./_-]{1,79}$');
 end if;
 if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.photo_edit_evidence'::regclass and conname='photo_edit_evidence_prompt_sha256_check')then
  alter table public.photo_edit_evidence add constraint photo_edit_evidence_prompt_sha256_check check(prompt_sha256 is null or prompt_sha256~'^[a-f0-9]{64}$');
 end if;
 if not exists(select 1 from pg_catalog.pg_constraint where conrelid='public.photo_edit_evidence'::regclass and conname='photo_edit_evidence_recipe_pair_check')then
  alter table public.photo_edit_evidence add constraint photo_edit_evidence_recipe_pair_check check((recipe_revision is null)=(prompt_sha256 is null));
 end if;
end$add_checks$;
comment on column public.photo_edit_evidence.recipe_revision is 'PHOTO_RECIPE_REVISION of the prompt/template/guardrail recipe that produced this generation, recorded once before provider dispatch. NULL means unknown: historical rows are never back-filled.';
comment on column public.photo_edit_evidence.prompt_sha256 is 'SHA-256 of the exact final prompt string handed to the provider adapter, recorded once before dispatch. NULL means unknown.';

create or replace function public.photo_quality_set_recipe(p_actor uuid,p_evidence uuid,p_revision text,p_prompt_sha256 text)returns jsonb
language plpgsql security definer set search_path=''as $$
declare e public.photo_edit_evidence;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_revision is null or p_revision!~'^[a-z0-9][a-z0-9./_-]{1,79}$'or p_prompt_sha256 is null or p_prompt_sha256!~'^[a-f0-9]{64}$'then
  raise exception'RP400: A bounded photo recipe revision and prompt hash are required';end if;
 e:=public.photo_quality_scope(p_actor,p_evidence);
 select*into e from public.photo_edit_evidence where id=e.id for update;
 if e.recipe_revision is not null or e.prompt_sha256 is not null then
  if e.recipe_revision is distinct from p_revision or e.prompt_sha256 is distinct from p_prompt_sha256 then
   raise exception'RP409: The photo recipe revision is immutable';end if;
  return jsonb_build_object('evidence_id',e.id,'recipe_revision',e.recipe_revision,'prompt_sha256',e.prompt_sha256,'replay',true);
 end if;
 if e.purpose<>'prospective'or e.output is not null or e.output_etag is not null or e.state not in('pending','input_ready')then
  raise exception'RP409: The photo recipe must be recorded before generation';end if;
 update public.photo_edit_evidence set recipe_revision=p_revision,prompt_sha256=p_prompt_sha256,updated_at=now()where id=e.id;
 return jsonb_build_object('evidence_id',e.id,'recipe_revision',p_revision,'prompt_sha256',p_prompt_sha256,'replay',false);
end$$;

-- 2. Explicit feedback, separate signals and regression cases. All three
-- cascade with the photo's provenance, its evidence, listing, org and the
-- author's account: feedback can never outlive the photo or its author.
create table if not exists public.photo_output_feedback(
 id uuid primary key default gen_random_uuid(),
 provenance_id uuid not null references public.media_provenance(id)on delete cascade,
 evidence_id uuid references public.photo_edit_evidence(id)on delete cascade,
 org_id uuid not null references public.orgs(id)on delete cascade,
 listing_id uuid references public.listings(id)on delete cascade,
 actor_id uuid not null references auth.users(id)on delete cascade,
 client_key text not null check(client_key~'^[A-Za-z0-9:_-]{8,128}$'),
 idempotency_key text not null unique,
 output_sha256 text check(output_sha256 is null or output_sha256~'^[a-f0-9]{64}$'),
 edit text not null check(length(edit)between 1 and 40),
 provider text,model text,generation_stage text,request_key text,recipe_revision text,prompt_sha256 text,
 attribution text not null check(attribution in('evidence','provenance_only')),
 verdict text not null check(verdict in('useful','needs_work')),
 reasons text[] not null default'{}',
 note text check(note is null or length(note)between 1 and 500),
 revision integer not null check(revision between 1 and 1000000),
 revision_count integer not null default 1 check(revision_count>=1),
 platform text check(platform is null or platform in('ios','studio','other')),
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 unique(provenance_id,actor_id),unique(actor_id,client_key),
 check(idempotency_key='photo-feedback:'||provenance_id::text||':'||client_key),
 check((attribution='evidence')=(evidence_id is not null)),
 check(attribution='evidence'or(provider is null and model is null and generation_stage is null and request_key is null and recipe_revision is null and prompt_sha256 is null)),
 check(revision_count<=revision),
 check(coalesce(array_ndims(reasons),1)=1 and reasons<@array['changed_permanent_features','moved_or_changed_appliance','blocked_doorway_or_opening','inconsistent_furniture_between_views','visible_visual_artifacts','requested_edit_incomplete','personal_style_preference','other']::text[]),
 check((verdict='useful'and cardinality(reasons)=0)or(verdict='needs_work'and cardinality(reasons)between 1 and 8))
);
comment on table public.photo_output_feedback is 'Explicit Useful / Needs work verdict: one live row per reviewer and exact output version (media_provenance.id), revised in place. An opinion, never a quality proof, and never a generation trigger. Service-only.';
create index if not exists photo_output_feedback_evidence on public.photo_output_feedback(evidence_id);
create index if not exists photo_output_feedback_listing on public.photo_output_feedback(listing_id);

create table if not exists public.photo_output_signals(
 id uuid primary key default gen_random_uuid(),
 provenance_id uuid not null references public.media_provenance(id)on delete cascade,
 evidence_id uuid references public.photo_edit_evidence(id)on delete cascade,
 org_id uuid not null references public.orgs(id)on delete cascade,
 listing_id uuid references public.listings(id)on delete cascade,
 actor_id uuid not null references auth.users(id)on delete cascade,
 signal text not null check(signal in('accuracy_ack','manual_selection','automatic_selection','export','publication')),
 detail text check(detail is null or detail in('staging_review','custom_review','gallery_save','listing_selection','kit_export','download','published_tour')),
 client_key text not null check(client_key~'^[A-Za-z0-9:_-]{8,128}$'),
 idempotency_key text not null unique,
 platform text check(platform is null or platform in('ios','studio','other')),
 created_at timestamptz not null default now(),
 unique(actor_id,client_key),
 check(idempotency_key='photo-signal:'||provenance_id::text||':'||signal||':'||client_key)
);
comment on table public.photo_output_signals is 'Client-reported acknowledgment, selection, export and publication events, kept apart from explicit feedback. Selection or publication never proves quality and is never counted as Useful. Append-only, service-only.';
create index if not exists photo_output_signals_output on public.photo_output_signals(provenance_id,actor_id);
create index if not exists photo_output_signals_evidence on public.photo_output_signals(evidence_id);
create index if not exists photo_output_signals_listing on public.photo_output_signals(listing_id);

create table if not exists public.photo_regression_cases(
 id uuid primary key default gen_random_uuid(),
 provenance_id uuid not null unique references public.media_provenance(id)on delete cascade,
 evidence_id uuid not null references public.photo_edit_evidence(id)on delete cascade,
 feedback_id uuid references public.photo_output_feedback(id)on delete set null,
 org_id uuid not null references public.orgs(id)on delete cascade,
 listing_id uuid references public.listings(id)on delete cascade,
 defect text not null check(defect in('changed_permanent_features','moved_or_changed_appliance','blocked_doorway_or_opening','inconsistent_furniture_between_views','visible_visual_artifacts','requested_edit_incomplete','other')),
 expected_behavior text not null check(length(expected_behavior)between 10 and 1000),
 edit text not null,style text,provider text,model text,recipe_revision text,prompt_sha256 text,
 input_ref jsonb not null check(jsonb_typeof(input_ref)='object'),output_ref jsonb not null check(jsonb_typeof(output_ref)='object'),
 protocol text not null default'photo-fixed-features-v1'check(protocol='photo-fixed-features-v1'),
 authorized_by uuid references auth.users(id)on delete set null,
 authorization_basis text not null default'library_owner_consent'check(authorization_basis='library_owner_consent'),
 authorized_at timestamptz not null default now(),
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),withdrawn_at timestamptz
);
comment on table public.photo_regression_cases is 'Private regression set with explicit library owner/admin consent. References the evidence objects the library already owns (no bytes copied, no retention extended): deleting the photo, listing, org or generating account deletes the case. Service-only.';
do $acl$declare t text;begin foreach t in array array['photo_output_feedback','photo_output_signals','photo_regression_cases']loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated,service_role',t);
 execute format('grant select on public.%I to service_role',t);
end loop;end$acl$;

-- 3. Authorization identical to the underlying media: a named, non-deleting
-- current editor of that photo's library. A valid id in another library is a
-- 404 (never a 403 that confirms existence); a reader without write access is
-- a 403. Only deliberate RP refusals are translated: a timeout or outage stays
-- an error, so a client never drops a queued verdict for a transient failure.
-- Only outputs the caller could have been shown are rateable: an accepted
-- prospective result, or a historical photo with no prospective evidence.
create or replace function public.photo_feedback_resolve(p_actor uuid,p_selected uuid,p_provenance uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare m public.media_provenance;e public.photo_edit_evidence;c jsonb;library uuid;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_actor is null or p_selected is null or p_provenance is null then
  raise exception'RP400: An exact output identity and its selected library are required';end if;
 if not exists(select 1 from auth.users where id=p_actor and is_anonymous=false)
  or exists(select 1 from public.deletion_requests where user_id=p_actor and status in('pending','processing'))then
  raise exception'RP403: A current named editor is required';end if;
 select*into m from public.media_provenance where id=p_provenance and kind in('photo_edit','virtual_stage','declutter');
 if m.id is null or not exists(select 1 from public.orgs where id=m.org_id and deleted_at is null)then
  raise exception'RP404: This photo is unavailable in the selected library';end if;
 begin
  if m.listing_id is not null then
   c:=public.listing_library_scope(p_actor,m.listing_id);
   if(c->>'org_id')::uuid is distinct from m.org_id then c:=null;end if;
   library:=(c->>'library_org_id')::uuid;
  else
   c:=public.library_access(p_actor,m.org_id);library:=m.org_id;
  end if;
 exception when raise_exception then c:=null;
 end;
 if c is null or c->>'can_read'is distinct from'true'or(p_selected<>m.org_id and p_selected is distinct from library)then
  raise exception'RP404: This photo is unavailable in the selected library';end if;
 if c->>'can_write'is distinct from'true'then raise exception'RP403: A current editor of this library is required';end if;
 select*into e from public.photo_edit_evidence where provenance_id=m.id;
 if e.id is not null and(e.purpose<>'prospective'or e.state<>'accept'or e.org_id<>m.org_id or e.listing_id is distinct from m.listing_id)then
  raise exception'RP404: This photo is unavailable in the selected library';end if;
 return jsonb_build_object('provenance_id',m.id,'org_id',m.org_id,'library_org_id',library,'listing_id',m.listing_id,'role',c->>'role',
  'edit',coalesce(e.edit,nullif(m.edit,''),case m.kind when'virtual_stage'then'stage'when'declutter'then'declutter'end,'unknown'),
  'evidence',case when e.id is null then null else to_jsonb(e)end);
end$$;

create or replace function public.photo_feedback_attribution(p_provenance uuid,p_evidence uuid)returns jsonb
language sql stable security definer set search_path=''as $$
 select jsonb_build_object('basis',case when e.id is null then'provenance_only'else'evidence'end,'evidence_id',e.id,
  'edit',coalesce(e.edit,nullif(m.edit,''),case m.kind when'virtual_stage'then'stage'when'declutter'then'declutter'end,'unknown'),
  'provider',e.generation_provider,'model',e.generation_model,'generation_stage',e.generation_stage,
  'recipe_revision',e.recipe_revision,'prompt_sha256',e.prompt_sha256,
  'provenance_model_id',case when e.id is null then m.model_id end,
  'attempts_known',e.id is not null and exists(select 1 from public.serving_cost_reservations r
    where r.org_id=e.org_id and r.actor_id=e.actor_id and r.request_key=e.request_key and r.stage like'photo.%'))
 from public.media_provenance m left join public.photo_edit_evidence e on e.id=p_evidence and e.provenance_id=m.id
 where m.id=p_provenance;
$$;

-- 4. Idempotent submit (contract 4.1): a client key is bound to one output and
-- actor forever; the same revision replays or conflicts; a higher revision is
-- revised in place; a late lower revision never regresses the stored opinion;
-- a second key for the same (output, actor) is answered with the existing key.
create or replace function public.photo_feedback_submit(p_actor uuid,p_selected uuid,p_provenance uuid,p_output_sha256 text,p_client_key text,p_revision integer,p_verdict text,p_reasons text[],p_note text,p_platform text)returns jsonb
language plpgsql security definer set search_path=''as $$
declare s jsonb;e jsonb;f public.photo_output_feedback;v_reasons text[];v_note text;v_state text;v_evidence uuid;
 known constant text[]:=array['changed_permanent_features','moved_or_changed_appliance','blocked_doorway_or_opening','inconsistent_furniture_between_views','visible_visual_artifacts','requested_edit_incomplete','personal_style_preference','other'];
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 v_note:=nullif(btrim(p_note),'');
 if p_client_key is null or p_client_key!~'^[A-Za-z0-9:_-]{8,128}$'or p_revision is null or p_revision not between 1 and 1000000
  or p_verdict is null or p_verdict not in('useful','needs_work')or p_reasons is null or coalesce(array_ndims(p_reasons),1)<>1
  or array_position(p_reasons,null)is not null or not(p_reasons<@known)
  or(select count(distinct x)from unnest(p_reasons)x)<>cardinality(p_reasons)
  or(p_verdict='useful'and cardinality(p_reasons)<>0)or(p_verdict='needs_work'and cardinality(p_reasons)=0)
  or(p_output_sha256 is not null and p_output_sha256!~'^[a-f0-9]{64}$')or(v_note is not null and length(v_note)>500)
  or(p_platform is not null and p_platform not in('ios','studio','other'))then
  raise exception'RP400: A bounded photo feedback verdict is required';end if;
 v_reasons:=array(select k.x from unnest(known)with ordinality k(x,i)where k.x=any(p_reasons)order by k.i);
 s:=public.photo_feedback_resolve(p_actor,p_selected,p_provenance);e:=nullif(s->'evidence','null'::jsonb);v_evidence:=(e->>'id')::uuid;
 if e is not null and p_output_sha256 is not null and p_output_sha256 is distinct from e#>>'{output,sha256}'then
  raise exception'RP409: OUTPUT_MISMATCH The pinned photo bytes differ from the retained result';end if;
 -- Key lock before output lock, always: no cycle, and two different outputs
 -- can never both claim one key.
 perform pg_advisory_xact_lock(hashtextextended('photo-feedback-key:'||p_actor::text||':'||p_client_key,91));
 perform pg_advisory_xact_lock(hashtextextended('photo-feedback:'||p_actor::text||':'||p_provenance::text,91));
 select*into f from public.photo_output_feedback where actor_id=p_actor and client_key=p_client_key for update;
 if f.id is not null and f.provenance_id<>p_provenance then
  raise exception'RP409: FEEDBACK_KEY_CONFLICT This feedback key already belongs to another photo';end if;
 if f.id is null then
  select*into f from public.photo_output_feedback where actor_id=p_actor and provenance_id=p_provenance for update;
  if f.id is not null then
   -- The caller's own stored opinion (one row per output and person), so a
   -- client adopting the key can skip an identical resend.
   return jsonb_build_object('state','conflict','code','feedback_exists','feedback_id',f.id,'provenance_id',f.provenance_id,
    'client_key',f.client_key,'revision',f.revision,'revision_count',f.revision_count,'verdict',f.verdict,'reasons',to_jsonb(f.reasons),'note',f.note);
  end if;
  insert into public.photo_output_feedback(provenance_id,evidence_id,org_id,listing_id,actor_id,client_key,idempotency_key,output_sha256,edit,
   provider,model,generation_stage,request_key,recipe_revision,prompt_sha256,attribution,verdict,reasons,note,revision,platform)
  values(p_provenance,v_evidence,(s->>'org_id')::uuid,(s->>'listing_id')::uuid,p_actor,p_client_key,'photo-feedback:'||p_provenance::text||':'||p_client_key,
   p_output_sha256,s->>'edit',e->>'generation_provider',e->>'generation_model',e->>'generation_stage',e->>'request_key',e->>'recipe_revision',e->>'prompt_sha256',
   case when v_evidence is null then'provenance_only'else'evidence'end,p_verdict,v_reasons,v_note,p_revision,p_platform)
  returning*into f;
  v_state:='recorded';
 else
  if f.output_sha256 is not null and p_output_sha256 is not null and f.output_sha256<>p_output_sha256 then
   raise exception'RP409: OUTPUT_MISMATCH The pinned photo bytes differ from this feedback''s photo';end if;
  if p_revision<f.revision then v_state:='replayed';
  elsif p_revision=f.revision then
   if f.verdict<>p_verdict or f.reasons<>v_reasons or f.note is distinct from v_note then
    raise exception'RP409: FEEDBACK_REVISION_CONFLICT Bump the feedback revision to change it';end if;
   v_state:='replayed';
  else
   update public.photo_output_feedback set verdict=p_verdict,reasons=v_reasons,note=v_note,revision=p_revision,revision_count=f.revision_count+1,
    platform=coalesce(p_platform,f.platform),output_sha256=coalesce(f.output_sha256,p_output_sha256),updated_at=now()
   where id=f.id returning*into f;
   v_state:='revised';
  end if;
 end if;
 return jsonb_build_object('state',v_state,'feedback_id',f.id,'provenance_id',f.provenance_id,'revision',f.revision,'revision_count',f.revision_count,
  'verdict',f.verdict,'reasons',to_jsonb(f.reasons),'note',f.note,'updated_at',f.updated_at,
  'attribution',public.photo_feedback_attribution(f.provenance_id,f.evidence_id));
end$$;

-- Signals are append-only and idempotent. A key belongs to exactly one
-- (output, signal, detail); reuse for anything else is a conflict, never a
-- silent replay that would drop the other event.
create or replace function public.photo_feedback_signal(p_actor uuid,p_selected uuid,p_provenance uuid,p_client_key text,p_signal text,p_detail text,p_platform text)returns jsonb
language plpgsql security definer set search_path=''as $$
declare s jsonb;g public.photo_output_signals;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_client_key is null or p_client_key!~'^[A-Za-z0-9:_-]{8,128}$'
  or p_signal is null or p_signal not in('accuracy_ack','manual_selection','automatic_selection','export','publication')
  or(p_detail is not null and p_detail not in('staging_review','custom_review','gallery_save','listing_selection','kit_export','download','published_tour'))
  or(p_platform is not null and p_platform not in('ios','studio','other'))then
  raise exception'RP400: A bounded photo signal is required';end if;
 s:=public.photo_feedback_resolve(p_actor,p_selected,p_provenance);
 perform pg_advisory_xact_lock(hashtextextended('photo-signal-key:'||p_actor::text||':'||p_client_key,91));
 select*into g from public.photo_output_signals where actor_id=p_actor and client_key=p_client_key;
 if g.id is not null then
  if g.provenance_id<>p_provenance or g.signal<>p_signal or g.detail is distinct from p_detail then
   raise exception'RP409: FEEDBACK_KEY_CONFLICT This signal key already belongs to another photo or signal';end if;
  return jsonb_build_object('state','replayed','signal_id',g.id,'provenance_id',g.provenance_id,'signal',g.signal,'detail',g.detail,'created_at',g.created_at);
 end if;
 insert into public.photo_output_signals(provenance_id,evidence_id,org_id,listing_id,actor_id,signal,detail,client_key,idempotency_key,platform)
 values(p_provenance,(s#>>'{evidence,id}')::uuid,(s->>'org_id')::uuid,(s->>'listing_id')::uuid,p_actor,p_signal,p_detail,p_client_key,
  'photo-signal:'||p_provenance::text||':'||p_signal||':'||p_client_key,p_platform)
 returning*into g;
 return jsonb_build_object('state','recorded','signal_id',g.id,'provenance_id',g.provenance_id,'signal',g.signal,'detail',g.detail,'created_at',g.created_at);
end$$;

-- Read-back for a client that lost its local queue (contract 4.3): only the
-- caller's own verdict and signals; the library's case summary; attribution.
create or replace function public.photo_feedback_state(p_actor uuid,p_selected uuid,p_provenance uuid)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare s jsonb;f public.photo_output_feedback;c public.photo_regression_cases;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 s:=public.photo_feedback_resolve(p_actor,p_selected,p_provenance);
 select*into f from public.photo_output_feedback where actor_id=p_actor and provenance_id=p_provenance;
 select*into c from public.photo_regression_cases where provenance_id=p_provenance;
 return jsonb_build_object('provenance_id',p_provenance,
  'feedback',case when f.id is null then null else jsonb_build_object('state','recorded','feedback_id',f.id,'provenance_id',f.provenance_id,
   'client_key',f.client_key,'revision',f.revision,'revision_count',f.revision_count,'verdict',f.verdict,'reasons',to_jsonb(f.reasons),'note',f.note,
   'updated_at',f.updated_at,'attribution',public.photo_feedback_attribution(f.provenance_id,f.evidence_id))end,
  'signals',coalesce((select jsonb_agg(jsonb_build_object('signal',g.signal,'detail',g.detail,'created_at',g.created_at)order by g.created_at,g.id)
   from public.photo_output_signals g where g.actor_id=p_actor and g.provenance_id=p_provenance),'[]'::jsonb),
  'regression_case',case when c.id is null then null else jsonb_build_object('id',c.id,'defect',c.defect,'withdrawn_at',c.withdrawn_at)end,
  'attribution',public.photo_feedback_attribution(p_provenance,(s#>>'{evidence,id}')::uuid));
end$$;

-- 5. Regression cases (contract 4.4): owner/admin of the library, explicit
-- retention consent, references to the existing evidence objects only.
-- Withdrawal needs no consent flag and is idempotent.
create or replace function public.photo_regression_case_mark(p_actor uuid,p_selected uuid,p_provenance uuid,p_defect text,p_expected text,p_retain boolean,p_withdraw boolean)returns jsonb
language plpgsql security definer set search_path=''as $$
declare s jsonb;e jsonb;c public.photo_regression_cases;v_feedback uuid;v_expected text;v_state text;
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 v_expected:=btrim(p_expected);
 if p_withdraw is null or p_retain is null or(not p_withdraw and(p_defect is null
   or p_defect not in('changed_permanent_features','moved_or_changed_appliance','blocked_doorway_or_opening','inconsistent_furniture_between_views','visible_visual_artifacts','requested_edit_incomplete','other')
   or v_expected is null or length(v_expected)not between 10 and 1000))then
  raise exception'RP400: A bounded defect and expected behavior are required';end if;
 s:=public.photo_feedback_resolve(p_actor,p_selected,p_provenance);e:=nullif(s->'evidence','null'::jsonb);
 if s->>'role'is null or s->>'role'not in('owner','admin')then
  raise exception'RP403: Only the library owner or an admin can keep an evaluation case';end if;
 perform pg_advisory_xact_lock(hashtextextended('photo-case:'||p_provenance::text,91));
 select*into c from public.photo_regression_cases where provenance_id=p_provenance for update;
 if p_withdraw then
  if c.id is null then return jsonb_build_object('state','withdrawn','case_id',null,'protocol','photo-fixed-features-v1','withdrawn_at',null);end if;
  update public.photo_regression_cases set withdrawn_at=coalesce(withdrawn_at,now()),updated_at=now()where id=c.id returning*into c;
  return jsonb_build_object('state','withdrawn','case_id',c.id,'protocol',c.protocol,'defect',c.defect,'recipe_revision',c.recipe_revision,'withdrawn_at',c.withdrawn_at);
 end if;
 if not p_retain then raise exception'RP403: CONSENT Explicit permission to keep this photo for evaluation is required';end if;
 if e is null or e->'output'is null or e->>'output_etag'is null then
  raise exception'RP409: EVIDENCE_UNAVAILABLE This photo has no retained evidence to evaluate against';end if;
 select f.id into v_feedback from public.photo_output_feedback f where f.provenance_id=p_provenance and f.actor_id=p_actor;
 if c.id is null then
  insert into public.photo_regression_cases(provenance_id,evidence_id,feedback_id,org_id,listing_id,defect,expected_behavior,edit,style,provider,model,
   recipe_revision,prompt_sha256,input_ref,output_ref,authorized_by)
  values(p_provenance,(e->>'id')::uuid,v_feedback,(s->>'org_id')::uuid,(s->>'listing_id')::uuid,p_defect,v_expected,e->>'edit',e->>'style',
   e->>'generation_provider',e->>'generation_model',e->>'recipe_revision',e->>'prompt_sha256',
   jsonb_build_object('bucket',e#>>'{input,bucket}','key',e#>>'{input,key}','sha256',e#>>'{input,sha256}','bytes',(e#>>'{input,bytes}')::bigint),
   jsonb_build_object('bucket',e#>>'{output,bucket}','key',e#>>'{output,key}','sha256',e#>>'{output,sha256}','bytes',(e#>>'{output,bytes}')::bigint),p_actor)
  returning*into c;
  v_state:='recorded';
 elsif c.withdrawn_at is null and c.defect=p_defect and c.expected_behavior=v_expected then v_state:='replayed';
 else
  update public.photo_regression_cases set defect=p_defect,expected_behavior=v_expected,feedback_id=coalesce(v_feedback,feedback_id),
   authorized_by=p_actor,authorized_at=now(),withdrawn_at=null,updated_at=now()where id=c.id returning*into c;
  v_state:='recorded';
 end if;
 return jsonb_build_object('state',v_state,'case_id',c.id,'protocol',c.protocol,'defect',c.defect,'recipe_revision',c.recipe_revision,'withdrawn_at',c.withdrawn_at);
end$$;

-- Operator-only listing of consented, active cases for reviewing a proposed
-- recipe/provider change. Object references only; nothing is copied and no
-- generation is scheduled. Soft-deleted libraries and listings are excluded.
create or replace function public.photo_regression_cases_for_review(p_recipe_revision text)returns jsonb
language sql stable security definer set search_path=''as $$
 select coalesce(jsonb_agg(jsonb_build_object('case_id',c.id,'evidence_id',c.evidence_id,'defect',c.defect,'expected_behavior',c.expected_behavior,
  'edit',c.edit,'style',c.style,'provider',c.provider,'model',c.model,'recipe_revision',c.recipe_revision,'prompt_sha256',c.prompt_sha256,
  'protocol',c.protocol,'input_ref',c.input_ref,'output_ref',c.output_ref,'authorized_at',c.authorized_at)order by c.authorized_at,c.id),'[]'::jsonb)
 from public.photo_regression_cases c join public.orgs o on o.id=c.org_id and o.deleted_at is null
 left join public.listings l on l.id=c.listing_id
 where c.withdrawn_at is null and(c.listing_id is null or l.deleted_at is null)
  and(p_recipe_revision is null or c.recipe_revision=p_recipe_revision);
$$;

-- 6. Honest aggregate report (contract 5 + Amendments). Cohort = prospective
-- generations created in the window; feedback given later on them counts.
-- Explicit verdicts, signals and silence stay separate. Cost: each ledger row
-- once by id however it is reached; rejected attempts carry no hold; uncertain
-- and unsettled holds stay outstanding; historical outputs are unknown
-- attribution. Org-level aggregates only: no ids, keys, notes or media.
create or replace function public.photo_feedback_report(p_from timestamptz,p_to timestamptz)returns jsonb
language plpgsql stable security definer set search_path=''as $$
declare v_out jsonb;
 fidelity constant text[]:=array['changed_permanent_features','moved_or_changed_appliance','blocked_doorway_or_opening','inconsistent_furniture_between_views','visible_visual_artifacts','requested_edit_incomplete'];
 known constant text[]:=array['changed_permanent_features','moved_or_changed_appliance','blocked_doorway_or_opening','inconsistent_furniture_between_views','visible_visual_artifacts','requested_edit_incomplete','personal_style_preference','other'];
begin
 if current_setting('role',true)is distinct from'service_role'then raise insufficient_privilege;end if;
 if p_from is null or p_to is null or p_to<=p_from or p_to-p_from>interval'400 days'then raise exception'RP400: A bounded report window is required';end if;
 with ev as(
  select e.id,e.org_id,e.actor_id,e.request_key,e.edit,e.state,e.provenance_id,e.output_etag is not null as retained,
   case when e.generation_provider is null then'no_retained_output'else e.generation_provider||'/'||e.generation_model end as provider_model,
   coalesce(e.recipe_revision,'unknown')as recipe,e.created_at,q.id as check_id,q.qc_ledger_id
  from public.photo_edit_evidence e left join public.photo_quality_checks q on q.evidence_id=e.id and q.automatic
  where e.purpose='prospective'and e.created_at>=p_from and e.created_at<p_to),
 fb as(select f.provenance_id,f.evidence_id,f.actor_id,f.verdict,f.reasons,f.revision_count,f.updated_at
  from public.photo_output_feedback f join ev on ev.id=f.evidence_id),
 hist as(select f.provenance_id,f.verdict from public.photo_output_feedback f
  where f.evidence_id is null and f.updated_at>=p_from and f.updated_at<p_to),
 rv as(select evidence_id,bool_or(verdict='useful')as any_useful,bool_or(verdict='needs_work')as any_needs_work from fb group by evidence_id),
 useful_out as(select evidence_id from rv where any_useful and not any_needs_work),
 att as(select distinct on(r.id)r.id,r.state,r.hold_cents,r.ledger_id,r.org_id,r.request_key,r.stage,r.created_at,ev.id as evidence_id,r.request_key like'photo-qc:%'as judge
  from ev join public.serving_cost_reservations r on r.org_id=ev.org_id and r.actor_id=ev.actor_id
   and((r.request_key=ev.request_key and r.stage like'photo.%')or(ev.check_id is not null and r.request_key='photo-qc:'||ev.check_id::text and r.stage='photo.qc:0'))
  order by r.id),
 lnk as(
  select a.id as attempt_id,a.evidence_id,a.ledger_id from att a where a.ledger_id is not null
  union select a.id,a.evidence_id,l.id from att a join public.cost_ledger l on l.org_id=a.org_id and l.created_at>=a.created_at-interval'1 day'
   and l.meta->>'request_key'=a.request_key and l.meta->>'stage'=a.stage
  union select a.id,a.evidence_id,ev.qc_ledger_id from att a join ev on ev.id=a.evidence_id where a.judge and ev.qc_ledger_id is not null),
 led as(select l.id,l.total_cents from public.cost_ledger l where l.id in(select ledger_id from lnk)),
 led_rv as(select l.id,l.total_cents from public.cost_ledger l where l.id in(select ledger_id from lnk where evidence_id in(select evidence_id from rv))),
 open_att as(select a.* from att a where a.state<>'rejected'and not exists(select 1 from lnk where lnk.attempt_id=a.id)),
 evc as(select a.evidence_id,count(*)as attempts from att a group by a.evidence_id),
 evl as(select x.evidence_id,sum(l.total_cents)as cents from(select distinct evidence_id,ledger_id from lnk)x join public.cost_ledger l on l.id=x.ledger_id group by x.evidence_id),
 fbc as(select evidence_id,count(*)filter(where verdict='useful')as useful,count(*)filter(where verdict='needs_work')as needs_work,
   count(*)filter(where verdict='needs_work'and reasons&&fidelity)as fidelity_rows,
   count(*)filter(where verdict='needs_work'and'personal_style_preference'=any(reasons))as taste_rows
  from fb group by evidence_id),
 cell as(select d.dim,d.key,count(*)as generated,count(*)filter(where ev.state='accept')as reviewable,count(rv.evidence_id)as reviewed,
   coalesce(sum(fbc.useful),0)as useful,coalesce(sum(fbc.needs_work),0)as needs_work,coalesce(sum(fbc.fidelity_rows),0)as fidelity_rows,
   coalesce(sum(fbc.taste_rows),0)as taste_rows,coalesce(sum(evc.attempts),0)as attempts,coalesce(sum(evl.cents),0)as recorded_cents
  from ev cross join lateral(values('edit',ev.edit),('provider_model',ev.provider_model),('recipe_revision',ev.recipe))d(dim,key)
  left join rv on rv.evidence_id=ev.id left join fbc on fbc.evidence_id=ev.id
  left join evc on evc.evidence_id=ev.id left join evl on evl.evidence_id=ev.id
  group by d.dim,d.key),
 cells as(select dim,jsonb_agg(jsonb_build_object('key',key,'generated',generated,'reviewable',reviewable,'reviewed',reviewed,
   'useful',useful,'needs_work',needs_work,'useful_rate',case when useful+needs_work=0 then null else round(useful::numeric/(useful+needs_work),4)end,
   'fidelity_rows',fidelity_rows,'taste_rows',taste_rows,'attempts',attempts,'recorded_cents',round(recorded_cents,4),
   'small_sample',reviewed<30)order by generated desc,key)as j from cell group by dim),
 sig as(select g.signal,count(*)as n,count(distinct g.evidence_id)as outputs from public.photo_output_signals g join ev on ev.id=g.evidence_id group by g.signal),
 rsn as(select k.x as reason,k.i,count(fb.evidence_id)as feedback_rows,count(distinct fb.evidence_id)as outputs
  from unnest(known)with ordinality k(x,i)left join fb on fb.verdict='needs_work'and k.x=any(fb.reasons)group by k.x,k.i)
 select jsonb_build_object(
  'from',p_from,'to',p_to,
  'basis','Generated = prospective photo generations started in this window (all states; calibration re-checks excluded). Reviewable = accepted results that were delivered to the requester. Explicitly reviewed = reviewable outputs with at least one Useful or Needs work verdict; each person''s verdict on an output counts once, at its latest revision. Useful rate = Useful verdicts / explicit verdicts, among explicitly reviewed outputs only. Coverage = explicitly reviewed / reviewable; unreviewed outputs are not rejections. Acknowledgments, selection, export and publication are separate signals and never count as Useful. Historical outputs without attribution are reported apart and excluded from every rate. Ledger amounts are internal modeled estimates, not supplier invoices. Breakdowns are observational: differences between edits, providers, models or recipe revisions are not evidence that one setting is better.',
  'data_range',jsonb_build_object('first_generated_at',(select min(created_at)from ev),'last_generated_at',(select max(created_at)from ev),
   'first_feedback_at',(select min(updated_at)from fb),'last_feedback_at',(select max(updated_at)from fb)),
  'generated',jsonb_build_object('outputs',(select count(*)from ev),'accepted',(select count(*)from ev where state='accept'),
   'refused',(select count(*)from ev where state='refuse'),'held',(select count(*)from ev where state='hold'),
   'pending',(select count(*)from ev where state not in('accept','refuse','hold')),'retained_candidates',(select count(*)from ev where retained),
   'excluded_calibration_checks',(select count(*)from public.photo_edit_evidence where purpose='calibration'and created_at>=p_from and created_at<p_to)),
  'explicit',jsonb_build_object('reviewable_outputs',(select count(*)from ev where state='accept'),'reviewed_outputs',(select count(*)from rv),
   'feedback_rows',(select count(*)from fb),'useful',(select count(*)from fb where verdict='useful'),'needs_work',(select count(*)from fb where verdict='needs_work'),
   'useful_rate',(select case when count(*)=0 then null else round(count(*)filter(where verdict='useful')::numeric/count(*),4)end from fb),
   'coverage',(select case when count(*)=0 then null else round((select count(*)from rv)::numeric/count(*),4)end from ev where state='accept'),
   'unreviewed_outputs',(select count(*)from ev where state='accept'and not exists(select 1 from rv where rv.evidence_id=ev.id)),
   'reviewers',(select count(distinct actor_id)from fb),'revised_rows',(select count(*)from fb where revision_count>1),
   'explicitly_useful_outputs',(select count(*)from useful_out),'contested_outputs',(select count(*)from rv where any_useful and any_needs_work)),
  'historical',jsonb_build_object('feedback_rows',(select count(*)from hist),'outputs',(select count(distinct provenance_id)from hist),
   'useful',(select count(*)from hist where verdict='useful'),'needs_work',(select count(*)from hist where verdict='needs_work'),
   'basis','Verdicts recorded in this window on outputs generated before attribution existed. Provider, model, recipe, attempts and cost are unknown for them, so they are excluded from every rate and cost above.'),
  'signals',jsonb_build_object('accuracy_ack',coalesce((select outputs from sig where signal='accuracy_ack'),0),
   'manual_selection',coalesce((select outputs from sig where signal='manual_selection'),0),
   'automatic_selection',coalesce((select outputs from sig where signal='automatic_selection'),0),
   'export',coalesce((select outputs from sig where signal='export'),0),'publication',coalesce((select outputs from sig where signal='publication'),0),
   'signal_rows',coalesce((select sum(n)from sig),0),
   'outputs_with_signal_and_no_feedback',(select count(*)from ev where exists(select 1 from public.photo_output_signals g where g.evidence_id=ev.id)
    and not exists(select 1 from rv where rv.evidence_id=ev.id)),
   'note','Counts are distinct outputs with each client-reported signal. Selection, export and publication are not quality judgments and are never added to the useful rate. Some outputs are selected automatically. Missing feedback is not rejection.'),
  'reasons',(select jsonb_agg(jsonb_build_object('reason',reason,'group',case when reason=any(fidelity)then'fidelity'when reason='personal_style_preference'then'taste'else'other'end,
   'feedback_rows',feedback_rows,'outputs',outputs)order by feedback_rows desc,i)from rsn),
  'fidelity_vs_taste',jsonb_build_object('needs_work_rows',(select count(*)from fb where verdict='needs_work'),
   'with_fidelity_reason',(select count(*)from fb where verdict='needs_work'and reasons&&fidelity),
   'taste_only',(select count(*)from fb where verdict='needs_work'and reasons<@array['personal_style_preference']),
   'other_only',(select count(*)from fb where verdict='needs_work'and reasons<@array['other']),
   'taste_and_fidelity',(select count(*)from fb where verdict='needs_work'and reasons&&fidelity and'personal_style_preference'=any(reasons))),
  'by_edit',coalesce((select j from cells where dim='edit'),'[]'::jsonb),
  'by_provider_model',coalesce((select j from cells where dim='provider_model'),'[]'::jsonb),
  'by_recipe_revision',coalesce((select j from cells where dim='recipe_revision'),'[]'::jsonb),
  'cost',jsonb_build_object('attributable_attempts',(select count(*)from att),'succeeded_attempts',(select count(*)from att where state='succeeded'),
   'failed_or_rejected_attempts',(select count(*)from att where state='rejected'),'uncertain_attempts',(select count(*)from att where state='uncertain'),
   'open_attempts',(select count(*)from att where state='reserved'),'judge_attempts',(select count(*)from att where judge),
   'retried_outputs',(select count(*)from(select evidence_id from att where not judge group by evidence_id having count(*)>1)x),
   'recorded_ledger_rows',(select count(*)from led),'recorded_cents',(select round(coalesce(sum(total_cents),0),4)from led),
   'outstanding_hold_cents',(select round(coalesce(sum(hold_cents),0),4)from open_att),'unsettled_attempts',(select count(*)from open_att),
   'attempts_with_multiple_ledger_rows',(select count(*)from(select attempt_id from lnk group by attempt_id having count(distinct ledger_id)>1)x),
   'unknown_attribution_outputs',(select count(distinct provenance_id)from hist),
   'generated_without_attempt_records',(select count(*)from ev where not exists(select 1 from att where att.evidence_id=ev.id)),
   'reviewed_attempts',(select count(*)from att where evidence_id in(select evidence_id from rv)),
   'reviewed_recorded_cents',(select round(coalesce(sum(total_cents),0),4)from led_rv),
   'reviewed_outstanding_hold_cents',(select round(coalesce(sum(hold_cents),0),4)from open_att where evidence_id in(select evidence_id from rv)),
   'explicitly_useful_outputs',(select count(*)from useful_out),
   'attempts_per_useful',(select case when(select count(*)from useful_out)=0 then null
     else round((select count(*)from att where evidence_id in(select evidence_id from rv))::numeric/(select count(*)from useful_out),4)end),
   'recorded_cents_per_useful',(select case when(select count(*)from useful_out)=0 then null
     else round((select coalesce(sum(total_cents),0)from led_rv)/(select count(*)from useful_out),4)end),
   'outstanding_hold_cents_per_useful',(select case when(select count(*)from useful_out)=0 then null
     else round((select coalesce(sum(hold_cents),0)from open_att where evidence_id in(select evidence_id from rv))/(select count(*)from useful_out),4)end),
   'window_recorded_cents_per_useful',(select case when(select count(*)from useful_out)=0 then null
     else round((select coalesce(sum(total_cents),0)from led)/(select count(*)from useful_out),4)end),
   'basis','Attempts are the paid generation steps (each retry is its own attempt) and the paid quality check behind this window''s generations, each reservation counted once. recorded_cents = distinct cost_ledger rows reached from those attempts by reservation binding, by request key and stage, or by the check''s judge receipt; a settlement reached several ways is counted once. outstanding_hold_cents = holds not definitively rejected that have no ledger row (in flight, uncertain after dispatch, or succeeded but not yet settled). Rejected attempts were refused before work and carry no cost. Per-useful figures divide the attempts and costs behind explicitly reviewed outputs by explicitly useful outputs (at least one Useful and no Needs work verdict); window_recorded_cents_per_useful divides all window spend and is an upper bound while coverage is below 1. Internal modeled estimates, never invoices.'),
  'regression_cases',jsonb_build_object('active',(select count(*)from public.photo_regression_cases where withdrawn_at is null),
   'withdrawn',(select count(*)from public.photo_regression_cases where withdrawn_at is not null),
   'by_defect',coalesce((select jsonb_agg(jsonb_build_object('key',defect,'n',n)order by n desc,defect)
     from(select defect,count(*)as n from public.photo_regression_cases where withdrawn_at is null group by defect)x),'[]'::jsonb),
   'by_recipe_revision',coalesce((select jsonb_agg(jsonb_build_object('key',k,'n',n)order by n desc,k)
     from(select coalesce(recipe_revision,'unknown')as k,count(*)as n from public.photo_regression_cases where withdrawn_at is null group by 1)x),'[]'::jsonb),
   'note','All consented, active cases regardless of window.'),
  'sample_note','Every cell carries its own n. A cell with fewer than 30 explicitly reviewed outputs (small_sample) is too small to read as a rate, and coverage below 1 means rates describe the people who chose to review, not every output.'
 )into v_out from(select 1)one;
 return v_out;
end$$;

revoke all on function public.photo_quality_set_recipe(uuid,uuid,text,text),public.photo_feedback_resolve(uuid,uuid,uuid),public.photo_feedback_attribution(uuid,uuid),
 public.photo_feedback_submit(uuid,uuid,uuid,text,text,integer,text,text[],text,text),public.photo_feedback_signal(uuid,uuid,uuid,text,text,text,text),
 public.photo_feedback_state(uuid,uuid,uuid),public.photo_regression_case_mark(uuid,uuid,uuid,text,text,boolean,boolean),
 public.photo_regression_cases_for_review(text),public.photo_feedback_report(timestamptz,timestamptz)from public,anon,authenticated;
grant execute on function public.photo_quality_set_recipe(uuid,uuid,text,text),public.photo_feedback_resolve(uuid,uuid,uuid),public.photo_feedback_attribution(uuid,uuid),
 public.photo_feedback_submit(uuid,uuid,uuid,text,text,integer,text,text[],text,text),public.photo_feedback_signal(uuid,uuid,uuid,text,text,text,text),
 public.photo_feedback_state(uuid,uuid,uuid),public.photo_regression_case_mark(uuid,uuid,uuid,text,text,boolean,boolean),
 public.photo_regression_cases_for_review(text),public.photo_feedback_report(timestamptz,timestamptz)to service_role;
commit;
