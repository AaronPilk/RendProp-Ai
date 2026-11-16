-- Inserted immediately after canonical finish/readability checks and BEFORE
-- any attach or listing-selection call in photo_publication_saved_output.sql.
-- All objects are owned local fixtures; no R2 I/O or provider requests.
set local role service_role;
select pg_temp.ok((select gallery_asset_ids='{}'::uuid[] and main_photo_key is null from listings where id=(select listing from f)),
 'completion prepares without selecting a gallery or cover');
select pg_temp.ok((select count(*)=0 from photos where listing_id=(select listing from f)),
 'completion does not implicitly attach a gallery photo');
select pg_temp.ok((select property_photo_reference(actor,listing,(select output from ids),(select(x#>>'{publication,id}')::uuid from finished))->>'asset_id'=(select output::text from ids)from f),
 'unselected prepared edit is a valid exact video source before Use on listing');
select pg_temp.ok((select photo_publication_resolve(actor,org,org,listing,(select output from ids),null,(select t from proof))#>>'{evidence,id}'=(select x#>>'{evidence,id}'from evidence)from f),
 'completion discovers exact accepted evidence without client supplied provenance');
select pg_temp.ok((select to_jsonb(e)=b.evidence from photo_edit_evidence e cross join before_save b where e.id=(select(x#>>'{evidence,id}')::uuid from evidence))
 and(select to_jsonb(q)=b.check_row from photo_quality_checks q cross join before_save b where q.id=(select(x#>>'{check,id}')::uuid from evidence)),
 'completion preserves historical evidence and advisory checks before attachment');
select pg_temp.ok((select uploaded and not upload_aborted and sha256=repeat('b',64) and bytes=80000 and content_type='image/jpeg'from capture_assets where id=(select output from ids)),
 'completion keeps the exact durable uploaded master');
select pg_temp.ok((select photo_publication_reserve(actor,org,org,listing,(select output from ids),(select(x#>>'{evidence,id}')::uuid from evidence),
 jsonb_build_object('sha256',repeat('a',64),'bytes',60000,'mime','image/jpeg','etag','prepared-etag'),
 jsonb_build_object('sha256',repeat('b',64),'bytes',80000,'mime','image/jpeg','etag','candidate-etag'),(select t from proof),gen_random_uuid())->>'dispatch'='false'from f),
 'completion replay does not dispatch a second source copy before attachment');
select pg_temp.ok((select photo_publication_finish(actor,org,org,listing,(select(x#>>'{publication,id}')::uuid from reserved),
 jsonb_build_object('sha256',repeat('a',64),'bytes',60000,'mime','image/jpeg','etag','copied-source'),(select t from proof))#>>'{publication,id}'=(select x#>>'{publication,id}'from finished)from f),
 'completion replay retains the same canonical publication before attachment');
select pg_temp.ok((select gallery_asset_ids='{}'::uuid[] and main_photo_key is null from listings where id=(select listing from f)),
 'completion replay leaves gallery and cover unchanged');
