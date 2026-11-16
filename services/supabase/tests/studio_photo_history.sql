\set ON_ERROR_STOP on
begin;
create temporary table checks(n integer);insert into checks values(0);grant all on checks to authenticated;
create function pg_temp.ok(v boolean,label text)returns void language plpgsql as $$begin if v is distinct from true then raise exception'STUDIO PHOTO FAIL: %',label;end if;update checks set n=n+1;end$$;
insert into auth.users(id,email,is_anonymous)values('e1100000-0000-4000-8000-000000000001','studio-history-owner@fixture.invalid',false),('e1100000-0000-4000-8000-000000000002','studio-history-other@fixture.invalid',false);
create temporary table f as select 'e1100000-0000-4000-8000-000000000001'::uuid actor,'e1100000-0000-4000-8000-000000000002'::uuid other,(select org_id from memberships where user_id='e1100000-0000-4000-8000-000000000001'and role='owner'limit 1)org,(select org_id from memberships where user_id='e1100000-0000-4000-8000-000000000002'and role='owner'limit 1)other_org,'e1300000-0000-4000-8000-000000000001'::uuid listing,'e1300000-0000-4000-8000-000000000002'::uuid other_listing;
grant select on f to authenticated;
-- This is a private-history/RLS fixture, not an unpaid listing-admission test.
update orgs set plan='starter',plan_source='manual' where id in((select org from f),(select other_org from f));
insert into listings(id,org_id,agent_id,address)values((select listing from f),(select org from f),(select actor from f),'Private history fixture'),((select other_listing from f),(select other_org from f),(select other from f),'Other private fixture');
insert into media_provenance(org_id,listing_id,kind,edit,original_key,altered_key,disclosure,qc)
select org,listing,'virtual_stage','stage','uploads/'||org||'/'||listing||'/original.jpg','renders/'||org||'/'||listing||'/staged.jpg','Exact stage proof','{"publishable":true}'::jsonb from f
union all select org,listing,'declutter','declutter','uploads/'||org||'/'||listing||'/original.jpg','renders/'||org||'/'||listing||'/decluttered.jpg','Exact declutter proof','{"publishable":true}'::jsonb from f
union all select other_org,other_listing,'virtual_stage','stage','uploads/'||other_org||'/'||other_listing||'/original.jpg','renders/'||other_org||'/'||other_listing||'/staged.jpg','Other private proof','{"publishable":true}'::jsonb from f;
insert into photos(listing_id,original_key,enhanced_key,caption,is_staged,sort)select listing,'uploads/'||org||'/'||listing||'/original.jpg','renders/'||org||'/'||listing||'/staged.jpg','Decluttered: deliberately misleading editable caption',true,0 from f;
select set_config('request.jwt.claim.sub',(select actor::text from f),true);set local role authenticated;
select pg_temp.ok((select count(*)=2 from media_provenance),'RLS returns only the actor private property history');
select pg_temp.ok((select count(*)=0 from media_provenance where listing_id=(select other_listing from f)),'foreign property history is inaccessible');
select pg_temp.ok((select array_agg(edit order by edit)=array['declutter','stage']::text[] from media_provenance where org_id=(select org from f)and listing_id=(select listing from f)and altered_key in('renders/'||(select org from f)||'/'||(select listing from f)||'/staged.jpg','renders/'||(select org from f)||'/'||(select listing from f)||'/decluttered.jpg')),'bounded selected-key projection reads exact immutable edits');
select pg_temp.ok((select p.edit='stage'and p.original_key=photo.original_key from photos photo join media_provenance p on p.altered_key=coalesce(photo.enhanced_key,photo.original_key)where photo.listing_id=(select listing from f)),'editable misleading caption cannot change selected result classification or original lineage');
select pg_temp.ok(not has_table_privilege('authenticated','media_provenance','update'),'consumer cannot overwrite immutable history');
reset role;select json_build_object('passed',true,'assertions',(select n from checks),'scope','Actual isolated PostgreSQL authenticated RLS and selected-key history projection, synthetic data only');rollback;
