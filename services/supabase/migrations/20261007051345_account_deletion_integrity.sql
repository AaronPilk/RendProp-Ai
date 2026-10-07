begin;

-- Tenant listing removal is the existing soft-delete path, which records the
-- exact media cleanup inventory. A raw Data API DELETE bypassed that boundary.
revoke delete on public.listings from anon, authenticated;
drop policy if exists "org listings delete" on public.listings;

-- Refuse before recording a destructive deletion intent. A former workspace
-- retains its listings; this operation cannot silently transfer their custody.
-- Shared Studio records can also cascade through Auth/presenter/document FKs.
-- They need an explicit workspace/likeness cleanup decision, not accidental
-- destruction while the person's unrelated solo workspace is being purged.
create or replace function public.account_deletion_integrity_preflight(p_user uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
  if current_setting('role',true) is distinct from 'service_role' then
    raise insufficient_privilege using message='service role required';
  end if;
  if exists(select 1 from public.listings l where l.agent_id=p_user and
    not exists(select 1 from public.memberships m where m.org_id=l.org_id and m.user_id=p_user)) then
    raise exception 'RP409: A former workspace still has listings assigned to this account. Ask its owner to reassign them before retrying account deletion.';
  end if;
  if exists(select 1 from public.memberships owner where owner.user_id=p_user and owner.role='owner'
    and exists(select 1 from public.memberships peer where peer.org_id=owner.org_id and peer.user_id<>p_user)
    and not exists(select 1 from public.memberships heir where heir.org_id=owner.org_id and heir.user_id<>p_user and heir.role='owner'))then
    raise exception 'RP409: Transfer ownership of the shared workspace before deleting this account. Contact support if an ownership transfer needs assistance.';
  end if;
  if exists(
    select 1 from (
      select org_id from public.studio_documents where user_id=p_user
      union select org_id from public.studio_creative_results where user_id=p_user
      union select org_id from public.studio_presenter_profiles where subject_user_id=p_user
      union select org_id from public.studio_presenter_drafts where author_user_id=p_user or subject_user_id=p_user
      union select org_id from public.studio_property_music_copies where actor_id=p_user
      union select org_id from public.video_erase_jobs where user_id=p_user
    ) retained
    where not exists(select 1 from public.memberships m where m.org_id=retained.org_id and m.user_id=p_user
      and (select count(*) from public.memberships peers where peers.org_id=m.org_id)=1)
  ) then
    raise exception 'RP409: This account has retained work or likeness records in a shared or former workspace. Contact support for workspace-preserving cleanup before retrying account deletion.';
  end if;
end$$;
revoke all on function public.account_deletion_integrity_preflight(uuid) from public,anon,authenticated;
grant execute on function public.account_deletion_integrity_preflight(uuid) to service_role;

-- Lock Auth before inspecting pending intent, matching prepare's Auth/profile
-- order. An insertion that waited for deletion must see the committed intent;
-- it cannot recreate a profile FK or a shared Auth-cascade child in Edge's
-- subsequent cleanup phase. Existing unchanged references remain readable and
-- ordinary soft-delete/custody cleanup does not recreate an admission.
create or replace function public.account_deletion_reference_guard()
returns trigger language plpgsql security definer set search_path='' as $$
declare field text;actor uuid;
begin
  foreach field in array TG_ARGV loop
    if TG_OP='UPDATE' and to_jsonb(new)->field is not distinct from to_jsonb(old)->field then continue;end if;
    actor:=(to_jsonb(new)->>field)::uuid;
    if actor is null then continue;end if;
    perform 1 from auth.users where id=actor for key share;
    if not found then raise exception 'RP409: The referenced account is unavailable';end if;
    if exists(select 1 from public.deletion_requests d where d.user_id=actor and d.status in('pending','processing'))then
      raise exception 'RP409: Account deletion is in progress; a new ownership reference cannot be added';
    end if;
  end loop;
  return new;
end$$;
revoke all on function public.account_deletion_reference_guard() from public,anon,authenticated,service_role;

drop trigger if exists account_deletion_listing_reference on public.listings;
create trigger account_deletion_listing_reference before insert or update of agent_id on public.listings
for each row execute function public.account_deletion_reference_guard('agent_id');
drop trigger if exists account_deletion_document_reference on public.studio_documents;
create trigger account_deletion_document_reference before insert or update of user_id on public.studio_documents
for each row execute function public.account_deletion_reference_guard('user_id');
drop trigger if exists account_deletion_creative_reference on public.studio_creative_results;
create trigger account_deletion_creative_reference before insert or update of user_id on public.studio_creative_results
for each row execute function public.account_deletion_reference_guard('user_id');
drop trigger if exists account_deletion_presenter_profile_reference on public.studio_presenter_profiles;
create trigger account_deletion_presenter_profile_reference before insert or update of subject_user_id on public.studio_presenter_profiles
for each row execute function public.account_deletion_reference_guard('subject_user_id');
drop trigger if exists account_deletion_presenter_draft_reference on public.studio_presenter_drafts;
create trigger account_deletion_presenter_draft_reference before insert or update of author_user_id,subject_user_id on public.studio_presenter_drafts
for each row execute function public.account_deletion_reference_guard('author_user_id','subject_user_id');
drop trigger if exists account_deletion_music_reference on public.studio_property_music_copies;
create trigger account_deletion_music_reference before insert or update of actor_id on public.studio_property_music_copies
for each row execute function public.account_deletion_reference_guard('actor_id');
drop trigger if exists account_deletion_reflection_reference on public.video_erase_jobs;
create trigger account_deletion_reflection_reference before insert or update of user_id on public.video_erase_jobs
for each row execute function public.account_deletion_reference_guard('user_id');

-- Preserve the currently delivered writer, its ownership, ACL and every media
-- inventory extension. The observed canonical body is guarded before patching.
do $patch$
declare body text;definition text;
  anchor text:='  perform 1 from public.profiles where id=p_user for update;';
  addition text:=E'  perform 1 from public.profiles where id=p_user for update;\n  perform public.account_deletion_integrity_preflight(p_user);';
begin
  select prosrc into body from pg_proc where oid='public.prepare_account_deletion(uuid,text,text)'::regprocedure;
  if position(addition in body)>0 then return;end if;
  if md5(body)<>'41066c58be3437e64d5f1ec4316d597e' or
    (length(body)-length(replace(body,anchor,'')))/length(anchor)<>1 then
    raise exception 'Account deletion writer differs from the reviewed canonical body; no integrity patch was applied';
  end if;
  definition:=pg_get_functiondef('public.prepare_account_deletion(uuid,text,text)'::regprocedure);
  execute replace(definition,anchor,addition);
end$patch$;

-- A join can hold an org lock while the early Auth/profile preflight still
-- observes a solo workspace. Recheck after every sorted org lock and the
-- membership reread: otherwise the original custody loop could remove the
-- sole owner after that join commits. No intent or purge is permitted first.
do $patch$
declare body text;definition text;
  anchor text:=$anchor$  select coalesce(array_agg(o),'{}'::uuid[]) into solo from unnest(all_orgs) o$anchor$;
  addition text;
  org_lock text:='  perform 1 from public.orgs where id=any(all_orgs) order by id for update;';
  reread text:='  if exists(select 1 from unnest(all_orgs) x where not exists(select 1 from public.memberships where org_id=x and user_id=p_user)) then';
begin
  addition:=E'  perform public.account_deletion_integrity_preflight(p_user);\n'||anchor;
  select prosrc into body from pg_proc where oid='public.prepare_account_deletion(uuid,text,text)'::regprocedure;
  if position(addition in body)>0 then return;end if;
  if (length(body)-length(replace(body,anchor,'')))/length(anchor)<>1 or
    position(org_lock in body)=0 or position(reread in body)<=position(org_lock in body) or
    position(anchor in body)<=position(reread in body) then
    raise exception 'Reviewed account lock order differs; no post-lock integrity patch was applied';
  end if;
  definition:=pg_get_functiondef('public.prepare_account_deletion(uuid,text,text)'::regprocedure);
  execute replace(definition,anchor,addition);
end$patch$;

-- Reflection output is private R2 storage owned by the exact persisted job,
-- never a provider URL. Freeze both acknowledged output_key and the one exact
-- destination used by both current adapters, so a lost completion/cancelled
-- receipt does not lose the cleanup identity. No prefix scan or guessed key.
create or replace function public.account_deletion_reflection_targets(p_orgs uuid[],p_render_bucket text)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
  if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege;end if;
  perform 1 from public.video_erase_jobs where org_id=any(p_orgs)order by id for update;
  if exists(select 1 from public.video_erase_jobs j where j.org_id=any(p_orgs)and
    (j.output_key is not null and j.output_key<>'video-reflections/'||j.org_id||'/'||j.id||'.mp4'
    or not exists(select 1 from public.video_erase_batches b join public.listings l on l.id=b.listing_id
      join public.capture_assets a on a.listing_id=l.id and a.id=j.asset_id
      where b.id=j.batch_id and b.org_id=j.org_id and l.org_id=j.org_id)))then
    raise exception 'RP409: Reflection output ownership requires assisted account deletion; nothing was deleted';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('bucket',p_render_bucket,
    'key','video-reflections/'||j.org_id||'/'||j.id||'.mp4','valid',true))
    from public.video_erase_jobs j where j.org_id=any(p_orgs)),'[]'::jsonb);
end$$;
revoke all on function public.account_deletion_reflection_targets(uuid[],text)from public,anon,authenticated;
grant execute on function public.account_deletion_reflection_targets(uuid[],text)to service_role;
do $patch$
declare definition text;
  anchor text:='  object_targets:=object_targets||public.account_private_output_targets(solo,p_upload_bucket,p_render_bucket);';
  addition text:=E'  object_targets:=object_targets||public.account_private_output_targets(solo,p_upload_bucket,p_render_bucket);\n  object_targets:=object_targets||public.account_deletion_reflection_targets(solo,p_render_bucket);';
begin
  definition:=pg_get_functiondef('public.prepare_account_deletion(uuid,text,text)'::regprocedure);
  if position(addition in definition)>0 then return;end if;
  if (length(definition)-length(replace(definition,anchor,'')))/length(anchor)<>1 or
    position('public.account_deletion_integrity_preflight(p_user);'in definition)=0 then
    raise exception 'Reviewed account inventory differs; no reflection cleanup extension was applied';
  end if;
  execute replace(definition,anchor,addition);
end$patch$;
commit;
