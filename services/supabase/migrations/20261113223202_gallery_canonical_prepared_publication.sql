-- Recognize the retained accepted source A and its one prepared publication B
-- when the normal compliance PATCH previously pointed both at the saved key.
-- The rows and their evidence are immutable; every unrelated duplicate refuses.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

do $rewrite$
declare
 studio_sig constant text:='public.studio_gallery_photo_choice(uuid,uuid,uuid)';
 native_sig constant text:='public.native_gallery_selection_target(uuid,uuid,uuid,text,bigint,boolean)';
 studio_before constant text:='eb0931ac25a4f16e3902dfb01b2e3ac1';
 native_before constant text:='0eaf78cb5c019531ed1da8872e77f943';
 studio_after constant text:='437a690a9ce0736d7baa997a333e6686';
 native_after constant text:='447a025fd0a38da1bbc28661cce7703d';
 old_studio constant text:=$s$
 if(select count(*)from public.media_provenance where listing_id=p_listing and altered_key=key)>1 then return jsonb_build_object('photo_id',p_photo,'asset_id',a.id,'can_use',false,'review_required',true);end if;
 select *into m from public.media_provenance where listing_id=p_listing and altered_key=key;$s$;
 new_studio constant text:=$s$
 if(select count(*)from public.media_provenance where listing_id=p_listing and altered_key=key)>1 then
  select published.* into m from public.media_provenance published
   join public.media_provenance origin on origin.id::text=published.photo_publication#>>'{source,provenance_id}'
   where published.listing_id=p_listing and published.altered_key=key and published.org_id=p_org
    and origin.listing_id=p_listing and origin.altered_key=key and origin.org_id=p_org
    and origin.id<>published.id and origin.photo_publication is null
    and published.photo_publication->>'phase'='prepared'
    and published.photo_publication#>>'{target,output_asset_id}'=a.id::text
    and published.photo_publication#>>'{target,org_id}'=p_org::text
    and published.photo_publication#>>'{target,listing_id}'=p_listing::text
    and exists(select 1 from public.photo_edit_evidence evidence
      where evidence.id::text=published.photo_publication#>>'{source,evidence_id}'
       and evidence.provenance_id=origin.id and evidence.org_id=p_org and evidence.listing_id=p_listing
       and evidence.state='accept' and evidence.purpose='prospective')
    and public.photo_publication_metadata_valid(published.id)
    and(select count(*)from public.media_provenance where listing_id=p_listing and altered_key=key)=2;
  if m.id is null then return jsonb_build_object('photo_id',p_photo,'asset_id',a.id,'can_use',false,'review_required',true);end if;
 else
  select *into m from public.media_provenance where listing_id=p_listing and altered_key=key;
 end if;$s$;
 old_native constant text:=$n$
 if(select count(*)from public.media_provenance where listing_id=p_listing and altered_key=a.storage_key)>1 then raise exception'RP409: This photo has ambiguous edit evidence';end if;
 select *into m from public.media_provenance where listing_id=p_listing and altered_key=a.storage_key for share;$n$;
 new_native constant text:=$n$
 if(select count(*)from public.media_provenance where listing_id=p_listing and altered_key=a.storage_key)>1 then
  select published.* into m from public.media_provenance published
   join public.media_provenance origin on origin.id::text=published.photo_publication#>>'{source,provenance_id}'
   where published.listing_id=p_listing and published.altered_key=a.storage_key and published.org_id=p_org
    and origin.listing_id=p_listing and origin.altered_key=a.storage_key and origin.org_id=p_org
    and origin.id<>published.id and origin.photo_publication is null
    and published.photo_publication->>'phase'='prepared'
    and published.photo_publication#>>'{target,output_asset_id}'=a.id::text
    and published.photo_publication#>>'{target,org_id}'=p_org::text
    and published.photo_publication#>>'{target,listing_id}'=p_listing::text
    and exists(select 1 from public.photo_edit_evidence evidence
      where evidence.id::text=published.photo_publication#>>'{source,evidence_id}'
       and evidence.provenance_id=origin.id and evidence.org_id=p_org and evidence.listing_id=p_listing
       and evidence.state='accept' and evidence.purpose='prospective')
    and public.photo_publication_metadata_valid(published.id)
    and(select count(*)from public.media_provenance where listing_id=p_listing and altered_key=a.storage_key)=2
   for share of published,origin;
  if m.id is null then raise exception'RP409: This photo has ambiguous edit evidence';end if;
 else
  select *into m from public.media_provenance where listing_id=p_listing and altered_key=a.storage_key for share;
 end if;$n$;
 signature text; before_hash text; after_hash text; old_fragment text; new_fragment text;
 prior_md5 text; prior_metadata jsonb; definition text;
begin
 foreach signature in array array[studio_sig,native_sig] loop
  if signature=studio_sig then
   before_hash:=studio_before;after_hash:=studio_after;old_fragment:=old_studio;new_fragment:=new_studio;
  else
   before_hash:=native_before;after_hash:=native_after;old_fragment:=old_native;new_fragment:=new_native;
  end if;
  select md5(prosrc),(to_jsonb(p)-'prosrc'-'prosqlbody'),pg_get_functiondef(p.oid)
   into prior_md5,prior_metadata,definition from pg_proc p where p.oid=to_regprocedure(signature);
  if prior_md5 is null then raise exception'Review missing canonical gallery selection function: %',signature;end if;
  if (select p.prosecdef and p.proowner='postgres'::regrole
       and p.proconfig=array['search_path=""']::text[]
       and p.proacl=array['postgres=X/postgres']::aclitem[]
       and p.provolatile=case when signature=studio_sig then 's' else 'v' end
      from pg_proc p where p.oid=to_regprocedure(signature))is distinct from true then
   raise exception'Review changed canonical gallery selection authority: %',signature;
  end if;
  if prior_md5=after_hash then continue;end if;
  if prior_md5<>before_hash then raise exception'Review changed canonical gallery selection function: %',signature;end if;
  if length(definition)-length(replace(definition,old_fragment,''))<>length(old_fragment)then
   raise exception'Review changed duplicate provenance branch: %',signature;
  end if;
  execute replace(definition,old_fragment,new_fragment);
  if (select (to_jsonb(p)-'prosrc'-'prosqlbody')from pg_proc p where p.oid=to_regprocedure(signature))is distinct from prior_metadata then
   raise exception'Canonical gallery selection metadata changed: %',signature;
  end if;
  if (select md5(prosrc)from pg_proc where oid=to_regprocedure(signature))is distinct from after_hash then
   raise exception'Review resulting canonical gallery selection body: %',signature;
  end if;
 end loop;
end$rewrite$;
commit;
