\set ON_ERROR_STOP on
begin;
do $$begin if inet_server_addr()is not null or current_database()<>'gallery_copy_proof'then raise exception'Use only owned socket fixture';end if;end$$;
create temp table checks(label text primary key);
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception'GALLERY COPY FAIL: %',label;end if;insert into checks values(label);end$$;
create function pg_temp.denied(command text,label text,expected text default'RP409:')returns void language plpgsql as $$declare message text;begin begin execute command;exception when others then message:=sqlerrm;end;perform pg_temp.ok(message like expected||'%',label);end$$;
-- BEGIN FIXTURE
create temp table cf(actor uuid,other_actor uuid,org uuid,other_org uuid,listing uuid,other_listing uuid,original uuid,edited uuid,held uuid,unknown_source uuid,provenance uuid,held_provenance uuid);
do $$declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();o uuid;oo uuid;l uuid:=gen_random_uuid();ol uuid:=gen_random_uuid();src uuid:=gen_random_uuid();ed uuid:=gen_random_uuid();held uuid:=gen_random_uuid();unknown_src uuid:=gen_random_uuid();mp uuid:=gen_random_uuid();badmp uuid:=gen_random_uuid();begin
 insert into auth.users(id,email,is_anonymous)values(a,'gallery-copy-owner@fixture.invalid',false),(b,'gallery-copy-other@fixture.invalid',false);
 select org_id into o from memberships where user_id=a;select org_id into oo from memberships where user_id=b;
 -- Both synthetic homes need listing authority before copy provenance checks.
 update orgs set plan='starter',plan_source='manual' where id in(o,oo);
 insert into listings(id,org_id,agent_id,address)values(l,o,a,'Synthetic copy home'),(ol,oo,b,'Other synthetic copy home');
 insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,bytes,sha256,content_type,transport_version)values
 (src,l,'photo','renders','renders/'||o||'/'||l||'/original-'||src||'.jpg',true,100,repeat('a',64),'image/jpeg',2),
 (ed,l,'photo','renders','renders/'||o||'/'||l||'/'||ed||'.jpg',true,101,repeat('b',64),'image/jpeg',2),
 (held,l,'photo','renders','renders/'||o||'/'||l||'/'||held||'.jpg',true,102,repeat('c',64),'image/jpeg',2),
 (unknown_src,l,'photo','renders','renders/'||o||'/'||l||'/'||unknown_src||'.jpg',true,103,repeat('d',64),'image/jpeg',2);
 insert into upload_reservations(asset_id,actor_id,org_id,listing_id,day,spec,held_bytes,state,settled_at)values(src,a,o,l,current_date,'{"key_role":"original"}',0,'completed',clock_timestamp());
 insert into media_provenance(id,org_id,listing_id,kind,original_key,altered_key,disclosure,qc)values
 (mp,o,l,'virtual_stage','renders/'||o||'/'||l||'/original-'||src||'.jpg','renders/'||o||'/'||l||'/'||ed||'.jpg','AI altered; compare with retained Original',null),
 (badmp,o,l,'declutter','renders/'||o||'/'||l||'/original-'||src||'.jpg','renders/'||o||'/'||l||'/'||held||'.jpg','AI altered; held for accuracy review','{"publishable":false,"action":"hold"}');
 insert into cf values(a,b,o,oo,l,ol,src,ed,held,unknown_src,mp,badmp);
end$$;
grant select on cf to service_role;
-- END FIXTURE
create function pg_temp.copy_ticket(f cf,n bigint,idem text)returns uuid language plpgsql as $$declare id uuid:=gen_random_uuid();r jsonb;begin
 r:=public.reserve_upload_assets(f.actor,jsonb_build_array(jsonb_build_object('id',id,'listing_id',f.listing,'kind','photo','bucket','renders','storage_key','renders/'||f.org||'/'||f.listing||'/gallery-'||id||'.jpg','bytes',n,'content_type','image/jpeg','content_type_declared',true,'idem_key',idem)));
 return(r#>>'{0,id}')::uuid;end$$;
create function pg_temp.complete(a uuid)returns void language plpgsql as $$declare op jsonb;c uuid;begin
 op:=public.plan_upload_operation(a,'single');c:=gen_random_uuid();perform public.claim_upload_operation((op->>'id')::uuid,c);perform public.finish_upload_operation((op->>'id')::uuid,c,'stored','synthetic-only-single-etag',null,'image/jpeg');
 op:=public.plan_upload_operation(a,'copy');c:=gen_random_uuid();perform public.claim_upload_operation((op->>'id')::uuid,c);perform public.finish_upload_operation((op->>'id')::uuid,c,'stored','synthetic-only-copy-etag',null,'image/jpeg');
 perform public.settle_upload_reservation(a,true,(op->>'id')::uuid,'{}');end$$;
grant all on checks to service_role;
select pg_temp.ok(not has_table_privilege('service_role','studio_gallery_copies','insert')and not has_table_privilege('authenticated','studio_gallery_copies','select'),'receipt table has no direct client or service writes');
select pg_temp.ok(has_function_privilege('service_role','studio_gallery_copy_finish(uuid,uuid,uuid,uuid,text,bigint)','execute')and not has_function_privilege('authenticated','studio_gallery_copy_prepare(uuid,uuid,uuid,uuid,uuid,text)','execute')and not has_function_privilege('anon','studio_gallery_copy_status(uuid,uuid,uuid,uuid)','execute'),'copy API is service-only and internal proof stays private');
set local role service_role;
do $$declare f cf;op uuid:=gen_random_uuid();edop uuid:=gen_random_uuid();r jsonb;again jsonb;copy uuid;edcopy uuid;second uuid;source_before jsonb;old_history jsonb;selection_before jsonb;qc_before jsonb;complete_time text;begin
 select *into f from cf;
 select to_jsonb(a)into source_before from capture_assets a where id=f.original;
 -- Reproduce the existing dead-end row, then recover it without rewriting it.
 perform studio_attach_photo(f.actor,f.org,f.listing,f.original,'Existing private source',null);
 select to_jsonb(p)into old_history from photos p where id=f.original;
 r:=studio_gallery_selection_snapshot(f.actor,f.org,f.listing);
 perform pg_temp.ok(r#>'{photos,0,can_use}'='false'::jsonb,'existing non-gallery history row reproduces disabled Use');
 r:=studio_gallery_copy_prepare(f.actor,f.org,f.listing,f.original,op,'Original');
 perform pg_temp.ok(r#>>'{source,kind}'='original'and r#>'{source,provenance}'='null'::jsonb,'immutable original role is classified without false AI claim');
 perform pg_temp.ok((select gallery_asset_ids is null and main_photo_key is null from listings where id=f.listing),'preparation metadata alone never changes NULL selection or cover');
 again:=studio_gallery_copy_prepare(f.actor,f.org,f.listing,f.original,gen_random_uuid(),'Ignored retry caption');
 perform pg_temp.ok(again=r,'lost prepare reply or cleared browser journal resolves the same server operation');
 perform pg_temp.denied(format('select studio_gallery_copy_prepare(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,f.edited,op,'wrong'),'same operation cannot be reused for different source');
 copy:=pg_temp.copy_ticket(f,100,'prepared-original');
 perform pg_temp.ok((select gallery_asset_ids='{}'::uuid[]and main_photo_key is null from listings where id=f.listing),'existing reservation freeze makes exactly prior empty membership explicit');
 r:=studio_gallery_copy_bind(f.actor,f.org,f.listing,op,copy);
 perform pg_temp.ok(r->>'destination_asset_id'=copy::text and r->>'complete'='false','copy binds one destination before its PUT');
 perform pg_temp.ok(studio_gallery_copy_bind(f.actor,f.org,f.listing,op,copy)=r,'lost bind reply returns exact same destination');
 second:=pg_temp.copy_ticket(f,100,'different-copy');
 perform pg_temp.denied(format('select studio_gallery_copy_bind(%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,op,second),'different upload cannot replace bound destination');
 perform pg_temp.denied(format('select studio_gallery_copy_finish(%L,%L,%L,%L,%L,100)',f.actor,f.org,f.listing,op,repeat('a',64)),'unuploaded copy cannot finalize');
 perform pg_temp.complete(copy);
 perform pg_temp.denied(format('select studio_gallery_copy_finish(%L,%L,%L,%L,%L,100)',f.actor,f.org,f.listing,op,repeat('f',64)),'wrong actual stored hash cannot attach a copy');
 perform pg_temp.ok(not exists(select 1 from photos where id=copy),'wrong hash has no private history side effect');
 r:=studio_gallery_copy_finish(f.actor,f.org,f.listing,op,repeat('a',64),100);
 perform pg_temp.ok(r->>'complete'='true'and r#>>'{photo,id}'=copy::text,'exact copy of attached original becomes a separate ready history row');
 perform pg_temp.ok((select sha256=repeat('a',64)from capture_assets where id=copy),'server verified hash is retained on copied capture');
 perform pg_temp.ok((select to_jsonb(a)=source_before from capture_assets a where id=f.original)and(select to_jsonb(p)=old_history from photos p where id=f.original),'original bytes metadata and first private history row stay unchanged');
 perform pg_temp.ok((select gallery_asset_ids='{}'::uuid[]and main_photo_key is null from listings where id=f.listing),'finalize never selects a photo or cover');
 again:=studio_gallery_copy_finish(f.actor,f.org,f.listing,op,repeat('a',64),100);
 perform pg_temp.ok(again=r and(select count(*)=1 from photos where id=copy),'lost finish reply acknowledges without duplicate copy or attach');
 perform pg_temp.ok(studio_gallery_copy_prepare(f.actor,f.org,f.listing,f.original,gen_random_uuid(),'Later')=r,'accepted operation survives a new browser request without another upload');
 again:=studio_gallery_selection_snapshot(f.actor,f.org,f.listing);
 perform pg_temp.ok(exists(select 1 from jsonb_array_elements(again->'photos')p where p->>'photo_id'=copy::text and p->'can_use'='true'::jsonb and p->'selected'='false'::jsonb and p->'review_required'='false'::jsonb),'prepared Original exposes a real unselected Use action');
 perform pg_temp.denied(format('select studio_gallery_copy_prepare(%L,%L,%L,%L,%L,%L)',f.other_actor,f.org,f.listing,f.original,gen_random_uuid(),''),'outsider cannot prepare another library source','RP403:');
 perform pg_temp.denied(format('select studio_gallery_copy_prepare(%L,%L,%L,%L,%L,%L)',f.actor,f.other_org,f.listing,f.original,gen_random_uuid(),''),'wrong org cannot prepare source','RP404:');
 perform pg_temp.denied(format('select studio_gallery_copy_prepare(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.other_listing,f.original,gen_random_uuid(),''),'cross listing cannot prepare source','RP404:');
 perform pg_temp.denied(format('select studio_gallery_copy_prepare(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,f.unknown_source,gen_random_uuid(),''),'unknown renders source is not relabelled Original');
 perform pg_temp.denied(format('select studio_gallery_copy_prepare(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,f.held,gen_random_uuid(),''),'held edit refuses before copy reservation');
 for qc_before in select v from(values('{"publishable":true,"action":"unknown"}'::jsonb),('{"publishable":"true","action":"accept"}'::jsonb),('{"verdict":"unknown"}'::jsonb))q(v)loop
  update media_provenance set qc=qc_before where id=f.held_provenance;
  perform pg_temp.denied(format('select studio_gallery_copy_prepare(%L,%L,%L,%L,%L,%L)',f.actor,f.org,f.listing,f.held,gen_random_uuid(),''),'malformed or unknown QC refuses '||qc_before::text);
 end loop;
 r:=studio_gallery_copy_prepare(f.actor,f.org,f.listing,f.edited,edop,'Edited room');
 perform pg_temp.ok(r#>>'{source,kind}'='altered'and r#>>'{source,provenance,id}'=f.provenance::text and r#>>'{source,provenance,original_asset_id}'=f.original::text,'legacy edit carries exact retained original and disclosure without fake QC');
 edcopy:=pg_temp.copy_ticket(f,101,'prepared-edit');perform studio_gallery_copy_bind(f.actor,f.org,f.listing,edop,edcopy);perform pg_temp.complete(edcopy);
 update media_provenance set qc='{"publishable":false,"action":"hold"}'where id=f.provenance;
 perform pg_temp.denied(format('select studio_gallery_copy_finish(%L,%L,%L,%L,%L,101)',f.actor,f.org,f.listing,edop,repeat('b',64)),'HOLD appearing during upload refuses finalization');
 perform pg_temp.ok(not exists(select 1 from photos where id=edcopy),'late HOLD does not attach or mutate provenance');
 update media_provenance set qc=null where id=f.provenance;
 update capture_assets set sha256=repeat('e',64)where id=f.edited;
 perform pg_temp.denied(format('select studio_gallery_copy_status(%L,%L,%L,%L)',f.actor,f.org,f.listing,edop),'changed source snapshot refuses recovery');
 update capture_assets set sha256=repeat('b',64)where id=f.edited;
 r:=studio_gallery_copy_finish(f.actor,f.org,f.listing,edop,repeat('b',64),101);
 perform pg_temp.ok(r->>'complete'='true'and r#>'{photo,is_staged}'='true'::jsonb and r#>>'{photo,original_key}'=source_before->>'storage_key','edited copy retains its actual original lineage');
 perform pg_temp.ok((select m.altered_key=a.storage_key and m.qc is null and m.disclosure='AI altered; compare with retained Original'from media_provenance m join capture_assets a on a.id=edcopy where m.id=f.provenance),'exact copy alias preserves legacy QC and disclosure rather than inventing pass');
 again:=studio_gallery_selection_snapshot(f.actor,f.org,f.listing);
 perform pg_temp.ok(exists(select 1 from jsonb_array_elements(again->'photos')p where p->>'photo_id'=edcopy::text and p->'can_use'='true'::jsonb and p->'selected'='false'::jsonb and p->'review_required'='true'::jsonb),'prepared edit exposes original comparison and separate explicit Use');
 perform pg_temp.ok(studio_gallery_copy_finish(f.actor,f.org,f.listing,edop,repeat('b',64),101)=r,'edited finalization replay does not re-alias or duplicate history');
 perform pg_temp.ok((select gallery_asset_ids='{}'::uuid[]and main_photo_key is null from listings where id=f.listing),'all source preparations leave selection and cover empty');
 perform pg_temp.ok(not exists(select 1 from cost_ledger where org_id=f.org)and not exists(select 1 from app_video_cost_reservations where org_id=f.org),'preparation creates no paid reservation or ledger');
end$$;
reset role;
-- A completed copy removed through canonical deletion must not be recreated by replay.
do $$declare f cf;op uuid;dest uuid;begin select *into f from cf;select operation_id,destination_asset_id into op,dest from studio_gallery_copies where actor_id=f.actor and source_asset_id=f.original;
 delete from photos where id=dest;
 perform pg_temp.denied(format('set local role service_role;select studio_gallery_copy_status(%L,%L,%L,%L)',f.actor,f.org,f.listing,op),'removed accepted history is never silently reattached');
end$$;
select jsonb_build_object('passed',true,'assertions',(select count(*)from checks));
rollback;
