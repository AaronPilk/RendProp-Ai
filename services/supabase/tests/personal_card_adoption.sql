-- Explicit guest contact survives only the existing verified adoption.
-- These synthetic people, cards, orgs and receipts all roll back.
begin;
create temp table card_adoption_checks(label text primary key,ok boolean not null);
create function pg_temp.card_adoption_ok(label text,value boolean)returns void language plpgsql security definer as $$begin
 if value is distinct from true then raise exception 'CARD ADOPTION FAIL: %',label;end if;
 insert into pg_temp.card_adoption_checks values(label,true);
end $$;
create function pg_temp.card_adoption_denied(label text,command text,prefix text)returns void language plpgsql as $$declare message text;begin
 begin execute command;exception when others then message:=sqlerrm;end;
 perform pg_temp.card_adoption_ok(label,message like prefix||'%');
end $$;
create temp table card_adoption_fixture(n int,source uuid,destination uuid,org uuid,listing uuid,operation uuid,expected jsonb);
do $$declare s uuid;d uuid;o uuid;l uuid;op uuid;begin
 for n in 1..7 loop
  s:=('ca100512-0000-4000-8000-'||lpad((n*10+1)::text,12,'0'))::uuid;
  d:=('ca100512-0000-4000-8000-'||lpad((n*10+2)::text,12,'0'))::uuid;
  l:=('ca100512-0000-4000-8000-'||lpad((n*10+3)::text,12,'0'))::uuid;
  op:=('ca100512-0000-4000-8000-'||lpad((n*10+4)::text,12,'0'))::uuid;
  insert into auth.users(id,email,is_anonymous)values(s,'private-guest-'||n||'@fixture.invalid',true),(d,'private-destination-'||n||'@fixture.invalid',false);
  select org_id into strict o from memberships where user_id=s;
  insert into listings(id,org_id,agent_id,address)values(l,o,s,'Synthetic guest property');
  insert into card_adoption_fixture values(n,s,d,o,l,op,null);
 end loop;
end $$;
grant select,update on card_adoption_fixture to service_role;
select pg_temp.card_adoption_ok('adoption writer remains service only',not has_function_privilege('anon','adopt_anonymous_org(uuid,uuid,uuid,uuid)','execute')and not has_function_privilege('authenticated','adopt_anonymous_org(uuid,uuid,uuid,uuid)','execute')and has_function_privilege('service_role','adopt_anonymous_org(uuid,uuid,uuid,uuid)','execute'));
set local role service_role;
select merge_personal_public_card(source,'{"name":"Reviewed guest contact","email":"public-guest@fixture.invalid","phone":"+15550001234","space_type":"real_estate"}', '{"name":{"present":false},"email":{"present":false},"phone":{"present":false},"space_type":{"present":false}}')from card_adoption_fixture where n in(1,2,3,6,7);
-- Explicit empty is written through the same real public-card RPC.
select merge_personal_public_card(destination,'{"space_type":null}','{"space_type":{"present":false}}')from card_adoption_fixture where n=2;
select merge_personal_public_card(destination,'{"name":"Reviewed destination","space_type":"venue"}','{"name":{"present":false},"space_type":{"present":false}}')from card_adoption_fixture where n=3;
select merge_personal_public_card(source,'{"space_type":null}','{"space_type":{"present":false}}')from card_adoption_fixture where n=4;
reset role;
update card_adoption_fixture f set expected=case when n in(2,3)then d.public_card else s.public_card end from profiles s,profiles d where s.id=f.source and d.id=f.destination;
set local role service_role;
select adopt_anonymous_org(destination,source,org,operation)from card_adoption_fixture where n<=5;
select pg_temp.card_adoption_ok(case n when 1 then 'guest reviewed card follows verified adoption'when 2 then 'explicit empty destination card is preserved'when 3 then 'existing reviewed destination card is preserved'when 4 then 'explicit empty guest card follows adoption'else 'no card remains SQL NULL without inferred identity'end,(select public_card is not distinct from f.expected from profiles where id=f.destination))from card_adoption_fixture f where n<=5;
select pg_temp.card_adoption_ok('durable personal card disposition '||n,(select receipt->>'personal_card_disposition' from anonymous_adoption_receipts where source_user_id=f.source)=case when n in(2,3)then 'destination_preserved'when n=5 then 'no_source_card'else 'source_copied'end)from card_adoption_fixture f where n<=5;
select pg_temp.card_adoption_ok('verified adoption remaps only intended listing '||n,(select agent_id=f.destination from listings where id=f.listing)and exists(select 1 from memberships where org_id=f.org and user_id=f.destination)and not exists(select 1 from memberships where org_id=f.org and user_id=f.source))from card_adoption_fixture f where n<=5;
select pg_temp.card_adoption_ok('account GET exposes transferred reviewed contact',(read_personal_public_card(destination)->'public_card'->>'name')='Reviewed guest contact'and read_personal_public_card(destination)->>'space_type'='real_estate'and position('private-'in read_personal_public_card(destination)::text)=0)from card_adoption_fixture where n=1;
select pg_temp.card_adoption_ok('public listing identity exposes only reviewed adopted card',(public_listing_agent_identity(listing)->'personal_card'->>'name')='Reviewed guest contact'and (public_listing_agent_identity(listing)->'personal_card'->>'email')='public-guest@fixture.invalid'and position('private-'in public_listing_agent_identity(listing)::text)=0)from card_adoption_fixture where n=1;
select pg_temp.card_adoption_ok('explicit empty destination suppresses guest contact and legacy fallback',public_listing_agent_identity(listing)->'personal_card'='{}'::jsonb and not(public_listing_agent_identity(listing)->>'legacy_owned_single_member')::boolean)from card_adoption_fixture where n=2;
select pg_temp.card_adoption_ok('reviewed destination industry remains selected',read_personal_public_card(destination)->>'space_type'='venue')from card_adoption_fixture where n=3;
select merge_personal_public_card(destination,'{"name":"Later reviewed destination"}','{"name":{"present":true,"value":"Reviewed guest contact"}}')from card_adoption_fixture where n=1;
select merge_personal_public_card(source,'{"name":"Later guest text"}','{"name":{"present":true,"value":"Reviewed guest contact"}}')from card_adoption_fixture where n=1;
select adopt_anonymous_org(destination,source,org,operation)from card_adoption_fixture where n=1;
select pg_temp.card_adoption_ok('replayed receipt keeps its historical source-copy decision',adopt_anonymous_org(destination,source,org,operation)=(select receipt from anonymous_adoption_receipts where source_user_id=f.source)and adopt_anonymous_org(destination,source,org,operation)->>'personal_card_disposition'='source_copied')from card_adoption_fixture f where n=1;
select pg_temp.card_adoption_ok('receipt replay never overwrites later destination edits',read_personal_public_card(destination)->'public_card'->>'name'='Later reviewed destination'and(select count(*)=1 from anonymous_adoption_receipts where source_user_id=f.source))from card_adoption_fixture f where n=1;
reset role;
-- A receipt accepted by an older deployment has no disposition. Replay must
-- return that exact receipt, never invent authority from present card values.
update anonymous_adoption_receipts set receipt=receipt-'personal_card_disposition'where source_user_id=(select source from card_adoption_fixture where n=5);
set local role service_role;
select pg_temp.card_adoption_ok('legacy receipt never invents card disposition',not(adopt_anonymous_org(destination,source,org,operation)?'personal_card_disposition')and adopt_anonymous_org(destination,source,org,operation)=(select receipt from anonymous_adoption_receipts where source_user_id=f.source))from card_adoption_fixture f where n=5;
reset role;
update auth.users set is_anonymous=false where id=(select source from card_adoption_fixture where n=6);
insert into deletion_requests(user_id,status)select destination,'pending'from card_adoption_fixture where n=7;
set local role service_role;
select pg_temp.card_adoption_denied('source promotion rejects transfer',format('select adopt_anonymous_org(%L,%L,%L,%L)',destination,source,org,operation),'RP403:')from card_adoption_fixture where n=6;
select pg_temp.card_adoption_denied('destination deletion rejects transfer',format('select adopt_anonymous_org(%L,%L,%L,%L)',destination,source,org,operation),'RP409:')from card_adoption_fixture where n=7;
select pg_temp.card_adoption_ok('rejected adoption leaves both profiles and receipt unchanged '||n,(select public_card is null from profiles where id=f.destination)and(select public_card->>'name'='Reviewed guest contact'from profiles where id=f.source)and not exists(select 1 from anonymous_adoption_receipts where source_user_id=f.source)and exists(select 1 from memberships where user_id=f.source and org_id=f.org))from card_adoption_fixture f where n in(6,7);
reset role;
select count(*)as card_adoption_assertions from card_adoption_checks;
select 'PASS: personal card adoption SQL assertions; all fixtures rolled back.';
rollback;
