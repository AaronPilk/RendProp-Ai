-- Included in the complete evidence/payment/history corpus after its real
-- historical owned-pointer fixture exists. Descriptor bytes are synthetic;
-- this proves SQL authority, not a provider/image-quality claim.
reset role;update app_config set value=jsonb_set(value,'{enabled}','true')where key='photo_quality';set local role service_role;
select serving_operation_begin((select actor from f),(select org from f),'photo-quality:9mb-boundary','photo_edit',repeat('d',64));
select pg_temp.no($q$select photo_quality_begin((select actor from f),(select org from f),'photo-quality:9mb-boundary',(select listing from f),'declutter',null,null,jsonb_set(pg_temp.input(),'{bytes}','9000001'))$q$,'RP400','prospective one byte above9MB refused');
select pg_temp.ok(not exists(select 1 from photo_edit_evidence where request_key='photo-quality:9mb-boundary'),'oversize source leaves no evidence/check to dispatch');
create temporary table boundary as select photo_quality_begin((select actor from f),(select org from f),'photo-quality:9mb-boundary',(select listing from f),'declutter',null,null,pg_temp.input())x;
select pg_temp.ok((select (x->>'created')::boolean and x#>>'{evidence,input,bytes}'='9000000'from boundary),'exact9MB prospective descriptor admitted');
select pg_temp.ok((photo_quality_begin((select actor from f),(select org from f),'photo-quality:9mb-boundary',(select listing from f),'declutter',null,null,pg_temp.input())->>'created')='false','exact9MB replay has no second generation owner');
select pg_temp.no($q$select photo_quality_begin((select actor from f),(select org from f),'photo-quality:9mb-boundary',(select listing from f),'declutter',null,null,jsonb_set(pg_temp.input(),'{sha256}',to_jsonb(repeat('f',64))))$q$,'RP409','same9MB key cannot substitute source SHA');
select pg_temp.ok(not exists(select 1 from serving_cost_reservations where request_key='photo-quality:9mb-boundary'),'admission creates no fabricated paid generation receipt');
reset role;update app_config set value=jsonb_set(value,'{enabled}','false')where key='photo_quality';set local role service_role;
select pg_temp.no($q$select photo_quality_calibration_begin((select actor from f),(select org from f),'photo-quality:historical-2k',repeat('7',64),(select listing from f),'declutter',null,'f8200000-0000-4000-8000-000000000031',jsonb_set(pg_temp.input(),'{bytes}','9000001'),(select o from calibration_output))$q$,'RP400','calibration one byte above9MB refused');
select pg_temp.ok(not exists(select 1 from photo_edit_evidence where request_key='photo-quality:historical-2k'),'oversize calibration cannot replace historical pointer');
select pg_temp.ok((select bytes=60000 and sha256=repeat('a',64)from capture_assets where id='f8200000-0000-4000-8000-000000000031'),'original master receipt is independent and unchanged');
