\set ON_ERROR_STOP on
begin;
do $$begin if inet_server_addr()is not null or current_database()<>'studio_explicit_gallery_proof'then raise exception'Use only owned socket fixture';end if;end$$;
create temp table checks(label text primary key);
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception'EXPLICIT GALLERY FAIL: %',label;end if;insert into checks values(label);end$$;
create function pg_temp.denied(command text,label text,expected text default'RP409:')returns void language plpgsql as $$declare message text;begin begin execute command;exception when others then message:=sqlerrm;end;perform pg_temp.ok(message like expected||'%',label);end$$;
-- BEGIN FIXTURE
create temp table bf(actor uuid,other_actor uuid,org uuid,other_org uuid,listing uuid,other_listing uuid,ids uuid[],photo_ids uuid[],provenance uuid,blocked_provenance uuid);
do $$declare a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();o uuid;oo uuid;l uuid:=gen_random_uuid();ol uuid:=gen_random_uuid();ids uuid[]:='{}';pids uuid[]:='{}';asset uuid;mp uuid:=gen_random_uuid();badmp uuid:=gen_random_uuid();n integer;begin
 insert into auth.users(id,email,is_anonymous)values(a,'explicit-gallery-owner@fixture.invalid',false),(b,'explicit-gallery-other@fixture.invalid',false);
 select org_id into o from memberships where user_id=a;select org_id into oo from memberships where user_id=b;
 insert into listings(id,org_id,agent_id,address)values(l,o,a,'Synthetic Studio home'),(ol,oo,b,'Other synthetic Studio home');
 for n in 1..105 loop asset:=gen_random_uuid();ids:=array_append(ids,asset);
  insert into capture_assets(id,listing_id,kind,bucket,storage_key,uploaded,created_at,bytes,content_type)values(asset,l,'photo','renders','renders/'||o||'/'||l||'/gallery-'||asset||'.jpg',true,'2026-01-01 00:00:00Z'::timestamptz+n*interval'1 second',100,'image/jpeg');
 end loop;
 for n in 1..4 loop pids:=array_append(pids,gen_random_uuid());end loop;
 insert into photos(id,listing_id,original_key,enhanced_key,is_staged,caption,sort,created_at)values
 (pids[1],l,'renders/'||o||'/'||l||'/gallery-'||ids[1]||'.jpg',null,false,'Original one',0,'2026-01-01 00:00:00Z'),
 (pids[2],l,'renders/'||o||'/'||l||'/gallery-'||ids[2]||'.jpg',null,false,'Original two',1,'2026-01-01 00:00:00Z'),
 (pids[3],l,'renders/'||o||'/'||l||'/gallery-'||ids[2]||'.jpg','renders/'||o||'/'||l||'/gallery-'||ids[3]||'.jpg',true,'Reviewed edit',2,'2026-01-01 00:00:00Z'),
 (pids[4],l,'renders/'||o||'/'||l||'/gallery-'||ids[2]||'.jpg','renders/'||o||'/'||l||'/gallery-'||ids[4]||'.jpg',true,'Held edit',3,'2026-01-01 00:00:00Z');
 insert into media_provenance(id,org_id,listing_id,kind,original_key,altered_key,disclosure,qc)values
 (mp,o,l,'photo_edit','renders/'||o||'/'||l||'/gallery-'||ids[2]||'.jpg','renders/'||o||'/'||l||'/gallery-'||ids[3]||'.jpg','AI-altered; compare with retained original','{"publishable":true,"action":"accept"}'),
 (badmp,o,l,'photo_edit','renders/'||o||'/'||l||'/gallery-'||ids[2]||'.jpg','renders/'||o||'/'||l||'/gallery-'||ids[4]||'.jpg','AI-altered; do not publish held result','{"publishable":false,"action":"hold"}');
 insert into bf values(a,b,o,oo,l,ol,ids,pids,mp,badmp);
end$$;
grant select on bf to service_role;
-- END FIXTURE
create function pg_temp.spec(o uuid,l uuid,a uuid,idem text,role_name text default'gallery')returns jsonb language sql as $$select jsonb_build_array(jsonb_build_object('id',a,'listing_id',l,'kind','photo','bucket','renders','storage_key','renders/'||o||'/'||l||'/'||role_name||'-'||a||'.jpg','bytes',100,'content_type','image/jpeg','content_type_declared',true,'idem_key',idem));$$;
create function pg_temp.expected(l uuid)returns jsonb language sql as $$select jsonb_build_object('gallery_asset_ids',gallery_asset_ids,'main_photo_key',main_photo_key)from public.listings where id=l;$$;
create function pg_temp.complete(a uuid)returns jsonb language plpgsql as $$declare op jsonb;c uuid;begin
 op:=public.plan_upload_operation(a,'single');c:=gen_random_uuid();perform public.claim_upload_operation((op->>'id')::uuid,c);perform public.finish_upload_operation((op->>'id')::uuid,c,'stored','synthetic-only-single-etag',null,'image/jpeg');
 op:=public.plan_upload_operation(a,'copy');c:=gen_random_uuid();perform public.claim_upload_operation((op->>'id')::uuid,c);perform public.finish_upload_operation((op->>'id')::uuid,c,'stored','synthetic-only-copy-etag',null,'image/jpeg');
 return public.settle_upload_reservation(a,true,(op->>'id')::uuid,'{}');end$$;
grant all on checks to service_role;
select pg_temp.ok(has_function_privilege('service_role','public.studio_gallery_selection_change(uuid,uuid,uuid,text,uuid,jsonb,jsonb,jsonb,boolean)','execute')and not has_function_privilege('authenticated','public.studio_gallery_selection_change(uuid,uuid,uuid,text,uuid,jsonb,jsonb,jsonb,boolean)','execute')and not has_function_privilege('anon','public.studio_gallery_selection_snapshot(uuid,uuid,uuid)','execute'),'selection API remains service-only');
select pg_temp.ok(not has_function_privilege('service_role','public.studio_gallery_photo_choice(uuid,uuid,uuid)','execute'),'photo choice remains owner-internal');
set local role service_role;
do $$declare f record;r jsonb;s jsonb;before_row jsonb;before_budget jsonb;before_count integer;new_id uuid:=gen_random_uuid();other_id uuid:=gen_random_uuid();ord jsonb;key text;bad_qc jsonb;begin
 select *into f from bf;key:='renders/'||f.org||'/'||f.listing||'/gallery-'||f.ids[1]||'.jpg';
 select to_jsonb(l)into before_row from listings l where id=f.listing;
 s:=studio_gallery_selection_snapshot(f.actor,f.org,f.listing);
 perform pg_temp.ok((select to_jsonb(l)=before_row from listings l where id=f.listing),'selection GET has no listing or selection side effect');
 perform pg_temp.ok(s->'gallery_asset_ids'='null'::jsonb and s->'effective_asset_ids'=to_jsonb(f.ids[1:100]),'NULL snapshot preserves same100 candidate set and order');
 perform pg_temp.ok(s->>'actor_id'=f.actor::text and s->>'org_id'=f.org::text and s->>'library_org_id'=f.org::text and s->>'listing_id'=f.listing::text,'snapshot echoes actual actor physical and library scope');
 perform pg_temp.ok(s#>>'{photos,0,asset_id}'=f.ids[1]::text and s#>>'{photos,0,photo_id}'=f.photo_ids[1]::text and f.photo_ids[1]<>f.ids[1],'selection maps exact stored key rather than treating photos ID as capture ID');
 perform pg_temp.ok(s#>'{photos,2,can_use}'='true'::jsonb and s#>'{photos,2,review_required}'='true'::jsonb and s#>'{photos,3,can_use}'='false'::jsonb,'accepted altered edit needs explicit review while held edit refuses');
 r:=reserve_upload_assets(f.actor,pg_temp.spec(f.org,f.listing,new_id,'gallery-new-immutable'));
 perform pg_temp.ok((select gallery_asset_ids=f.ids[1:100]from listings where id=f.listing),'gallery reservation freezes legacy100 before inserting unuploaded candidate');
 perform pg_temp.ok(not(new_id=any(array(select jsonb_array_elements_text(listing_gallery_projection(f.listing)->'effective_asset_ids')::uuid))),'new reservation is not publicly selected');
 update listings set gallery_asset_ids='{}'::uuid[]where id=f.listing;
 r:=reserve_upload_assets(f.actor,pg_temp.spec(f.org,f.listing,gen_random_uuid(),'gallery-new-immutable'));
 perform pg_temp.ok(r#>>'{0,id}'=new_id::text and r#>>'{0,replayed}'='true'and(select gallery_asset_ids='{}'::uuid[]from listings where id=f.listing),'same reservation replay preserves later explicit empty selection');
 r:=pg_temp.complete(new_id);
 perform pg_temp.ok(r->>'uploaded'='true'and(select gallery_asset_ids='{}'::uuid[]from listings where id=f.listing),'completion keeps uploaded version private under explicit empty selection');
 perform studio_attach_photo(f.actor,f.org,f.listing,new_id,'Saved history',null);
 perform pg_temp.ok((select gallery_asset_ids='{}'::uuid[]from listings where id=f.listing),'history attachment does not publish new original or edit');
 s:=studio_gallery_selection_snapshot(f.actor,f.org,f.listing);
 perform pg_temp.ok(exists(select 1 from jsonb_array_elements(s->'photos')p where p->>'photo_id'=new_id::text and p->'selected'='false'::jsonb and p->'can_use'='true'::jsonb),'saved history exposes usable unselected action');
 r:=studio_gallery_selection_change(f.actor,f.org,f.listing,'use',new_id,pg_temp.expected(f.listing),null,null,false);
 perform pg_temp.ok((select gallery_asset_ids=array[new_id]and main_photo_key is null from listings where id=f.listing),'explicit Use adds only chosen original and does not set cover');
 before_row:=pg_temp.expected(f.listing);r:=studio_gallery_selection_change(f.actor,f.org,f.listing,'use',new_id,before_row,null,null,false);
 perform pg_temp.ok((select gallery_asset_ids=array[new_id]from listings where id=f.listing),'repeat Use cannot duplicate an existing selection');
 perform pg_temp.denied(format('select studio_gallery_selection_change(%L,%L,%L,''use'',%L,%L::jsonb,null,null,true)',f.actor,f.org,f.listing,f.photo_ids[1],'{"gallery_asset_ids":[],"main_photo_key":null}'),'stale explicit selection is rejected');
 perform pg_temp.denied(format('select studio_gallery_selection_change(%L,%L,%L,''use'',%L,%L::jsonb,null,null,false)',f.actor,f.org,f.listing,f.photo_ids[3],pg_temp.expected(f.listing)),'altered photo requires actual explicit review flag','RP400:');
 perform pg_temp.denied(format('select studio_gallery_selection_change(%L,%L,%L,''use'',%L,%L::jsonb,null,null,true)',f.actor,f.org,f.listing,f.photo_ids[4],pg_temp.expected(f.listing)),'held edit cannot be selected even with browser review');
 for bad_qc in select v from(values('{"verdict":"unknown"}'::jsonb),('{"publishable":"true","action":"accept"}'::jsonb),('{"publishable":true,"action":"unknown"}'::jsonb))q(v)loop
  update media_provenance set qc=bad_qc where id=f.blocked_provenance;
  perform pg_temp.denied(format('select studio_gallery_selection_change(%L,%L,%L,''use'',%L,%L::jsonb,null,null,true)',f.actor,f.org,f.listing,f.photo_ids[4],pg_temp.expected(f.listing)),'unknown or malformed recorded QC refuses '||bad_qc::text);
 end loop;
 update media_provenance set qc='{"publishable":false,"action":"hold"}'where id=f.blocked_provenance;
 r:=studio_gallery_selection_change(f.actor,f.org,f.listing,'use_cover',f.photo_ids[3],pg_temp.expected(f.listing),null,null,true);
 perform pg_temp.ok((select gallery_asset_ids=array[new_id,f.ids[3]]and main_photo_key='renders/'||f.org||'/'||f.listing||'/gallery-'||f.ids[3]||'.jpg'from listings where id=f.listing),'unselected reviewed edit can be appended and chosen as cover atomically');
 perform pg_temp.ok((select is_main from photos where id=f.photo_ids[3])and not exists(select 1 from photos where listing_id=f.listing and id<>f.photo_ids[3]and is_main),'cover UI flag matches selected exact cover');
 update listings set gallery_asset_ids=array[f.ids[5],f.ids[2],f.ids[6],f.ids[1]],main_photo_key=key where id=f.listing;
 select jsonb_agg(id order by sort,created_at,id)into ord from photos where listing_id=f.listing;
 r:=studio_gallery_selection_change(f.actor,f.org,f.listing,'reorder_selected',null,pg_temp.expected(f.listing),ord,to_jsonb(array[f.photo_ids[1],f.photo_ids[3],f.photo_ids[2],f.photo_ids[4],new_id]),false);
 perform pg_temp.ok((select gallery_asset_ids=array[f.ids[5],f.ids[1],f.ids[6],f.ids[2]]and main_photo_key=key from listings where id=f.listing),'reorder moves mapped selected slots and preserves unknown anchors cover and exclusions');
 perform pg_temp.ok((select not(f.ids[3]=any(gallery_asset_ids))and not(new_id=any(gallery_asset_ids))from listings where id=f.listing),'reordering unselected saved versions never publishes them');
 perform pg_temp.denied(format('select studio_gallery_selection_change(%L,%L,%L,''reorder_selected'',null,%L::jsonb,%L::jsonb,%L::jsonb,false)',f.actor,f.org,f.listing,pg_temp.expected(f.listing),ord,ord),'stale Studio photo order refuses');
 update listings set gallery_asset_ids=null,main_photo_key=key where id=f.listing;
 select jsonb_agg(id order by sort,created_at,id)into ord from photos where listing_id=f.listing;
 r:=studio_gallery_selection_change(f.actor,f.org,f.listing,'reorder_selected',null,pg_temp.expected(f.listing),ord,to_jsonb(array[f.photo_ids[2],f.photo_ids[1],f.photo_ids[3],f.photo_ids[4],new_id]),false);
 perform pg_temp.ok((select gallery_asset_ids is null and main_photo_key=key from listings where id=f.listing),'NULL reorder retains automatic membership and exact cover');
 perform pg_temp.ok(listing_gallery_projection(f.listing)#>>'{effective_asset_ids,0}'=f.ids[2]::text and jsonb_array_length(listing_gallery_projection(f.listing)->'effective_asset_ids')=100,'NULL website projection follows saved order without adding history outside old100');
 update listings set gallery_asset_ids='{}'::uuid[],main_photo_key=null where id=f.listing;
 r:=reserve_upload_assets(f.actor,pg_temp.spec(f.org,f.listing,other_id,'explicit-empty-upload'));
 perform pg_temp.ok((select gallery_asset_ids='{}'::uuid[]from listings where id=f.listing),'new upload never rebuilds an explicit empty selection');
 update listings set gallery_asset_ids=array[f.ids[5],f.ids[1]],main_photo_key=key where id=f.listing;
 r:=reserve_upload_assets(f.actor,pg_temp.spec(f.org,f.listing,gen_random_uuid(),'explicit-unknown-upload'));
 perform pg_temp.ok((select gallery_asset_ids=array[f.ids[5],f.ids[1]]and main_photo_key=key from listings where id=f.listing),'upload preserves nonnull unknown IDs exclusions order and cover exactly');
 update listings set gallery_asset_ids=null,main_photo_key='renders/'||f.org||'/'||f.listing||'/gallery-'||f.ids[105]||'.jpg'where id=f.listing;
 select to_jsonb(l)into before_row from listings l where id=f.listing;select coalesce(jsonb_agg(to_jsonb(w)),'[]')into before_budget from upload_budget_windows w where org_id=f.org;select count(*)into before_count from capture_assets where listing_id=f.listing;
 perform pg_temp.denied(format('select reserve_upload_assets(%L,%L::jsonb)',f.actor,pg_temp.spec(f.org,f.listing,gen_random_uuid(),'cover-outside-first100')),'out-of-range legacy cover yields clear review refusal without dropping anything');
 perform pg_temp.ok((select to_jsonb(l)=before_row from listings l where id=f.listing)and(select count(*)=before_count from capture_assets where listing_id=f.listing)and(select coalesce(jsonb_agg(to_jsonb(w)),'[]')=before_budget from upload_budget_windows w where org_id=f.org),'failed freeze rolls back selection reservation and financial byte counters');
 update listings set gallery_asset_ids=null,main_photo_key=null where id=f.listing;
 r:=reserve_upload_assets(f.actor,pg_temp.spec(f.org,f.listing,gen_random_uuid(),'original-no-freeze','original'));
 perform pg_temp.ok((select gallery_asset_ids is null from listings where id=f.listing),'original-only upload does not materialize publication selection');
 perform pg_temp.denied(format('select studio_gallery_selection_snapshot(%L,%L,%L)',f.other_actor,f.org,f.listing),'outsider cannot read current photo selection','RP404:');
 perform pg_temp.denied(format('select studio_gallery_selection_change(%L,%L,%L,''use'',%L,%L::jsonb,null,null,true)',f.actor,f.other_org,f.listing,f.photo_ids[1],pg_temp.expected(f.listing)),'foreign physical org cannot mutate chosen listing','RP404:');
 perform pg_temp.denied(format('select studio_gallery_selection_change(%L,%L,%L,''use'',%L,%L::jsonb,null,null,true)',f.actor,f.org,f.listing,gen_random_uuid(),pg_temp.expected(f.listing)),'unknown photo cannot mint selection from guessed ID');
 -- Simulate an already-open pre-rollout ticket: reserve first, then restore the
 -- legacy NULL fixture state before exact normal completion. No migration/body
 -- swapping or immutable upload guard bypass is used.
 new_id:=gen_random_uuid();r:=reserve_upload_assets(f.actor,pg_temp.spec(f.org,f.listing,new_id,'pre-rollout-open-ticket'));
 update listings set gallery_asset_ids=null,main_photo_key=null where id=f.listing;
 r:=pg_temp.complete(new_id);
 perform pg_temp.ok((select gallery_asset_ids is not null and not(new_id=any(gallery_asset_ids))from listings where id=f.listing),'preexisting open ticket freezes NULL before uploaded transition');
 update listings set gallery_asset_ids='{}'::uuid[]where id=f.listing;
 r:=settle_upload_reservation(new_id,true,null,'{}');
 perform pg_temp.ok((select gallery_asset_ids='{}'::uuid[]from listings where id=f.listing),'completed settlement replay cannot freeze or re-add later removed photo');
 update orgs set deleted_at=now()where id=f.org;
 perform pg_temp.denied(format('select studio_gallery_selection_snapshot(%L,%L,%L)',f.actor,f.org,f.listing),'deleted organization cannot read snapshot','RP404:');
 update orgs set deleted_at=null where id=f.org;
 perform pg_temp.ok((select count(*)=4+1 from photos where listing_id=f.listing),'selection changes retain all saved photos and disclosures');
end$$;
reset role;
select jsonb_build_object('passed',true,'assertions',(select count(*)from checks));
rollback;
