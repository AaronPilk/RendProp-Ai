begin;
-- The logo extension replaced the deletion writer with a copy of 0039 and
-- omitted the later voice and private-project additions. Restore those exact
-- inventories, bounded-write grace periods and actor-owned metadata cleanup
-- without replacing the logo-aware writer or changing any of its ACLs.
do $$
declare
  definition text;
  inventory text:='object_targets:=object_targets||spatial_keys;';
  restored_inventory text:=E'object_targets:=object_targets||spatial_keys||public.studio_voice_deletion_targets(solo,p_upload_bucket);\n  object_targets:=object_targets||public.studio_project_deletion_targets(p_user,solo,p_upload_bucket);\n  select greatest(storage_after,max(write_deadline)+interval ''1 hour'') into storage_after from public.studio_project_media where actor_id=p_user or org_id=any(solo);\n  select greatest(storage_after,max(write_deadline)+interval ''1 hour'') into storage_after\n    from public.voice_storage_reservations where org_id=any(solo);';
  cleanup text:='delete from public.orgs where id=any(solo);';
  restored_cleanup text:=E'delete from public.studio_project_media where actor_id=p_user;\n  delete from public.orgs where id=any(solo);';
begin
  definition:=pg_get_functiondef('public.prepare_account_deletion(uuid,text,text)'::regprocedure);
  -- Exact-body replay is harmless; partial or unfamiliar definitions fail
  -- closed rather than silently installing an incomplete deletion snapshot.
  if (length(definition)-length(replace(definition,restored_inventory,'')))/length(restored_inventory)=1
     and (length(definition)-length(replace(definition,restored_cleanup,'')))/length(restored_cleanup)=1 then
    return;
  end if;
  if (length(definition)-length(replace(definition,inventory,'')))/length(inventory)<>1
     or (length(definition)-length(replace(definition,cleanup,'')))/length(cleanup)<>1
     or position('public.studio_voice_deletion_targets(' in definition)>0
     or position('public.studio_project_deletion_targets(' in definition)>0
     or position('delete from public.studio_project_media' in definition)>0 then
    raise exception 'Account deletion inventory changed; review before restoring Studio media cleanup';
  end if;
  definition:=replace(definition,inventory,restored_inventory);
  definition:=replace(definition,cleanup,restored_cleanup);
  execute definition;
end $$;
commit;
