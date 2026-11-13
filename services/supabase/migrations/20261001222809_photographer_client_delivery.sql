-- Client-branded listings and transactional external lead forwarding.
-- Product role is a preference; memberships remain the only permission source.
-- New tables are service-only, RLS deny-all; verified edge routes pass actor IDs.
alter table public.profiles add column if not exists real_estate_role text not null default 'agent';
-- Existing people retain their experience; new people choose during onboarding.
alter table public.profiles alter column real_estate_role drop not null;
alter table public.profiles alter column real_estate_role set default null;
alter table public.profiles drop constraint if exists profiles_real_estate_role_check;
alter table public.profiles add constraint profiles_real_estate_role_check check(real_estate_role in('agent','photographer_videographer'));

create table if not exists public.listing_client_contacts (
 listing_id uuid primary key references public.listings(id) on delete cascade,
 org_id uuid not null references public.orgs(id) on delete cascade,
 enabled boolean not null default false,
 public_card jsonb not null default '{}' check(jsonb_typeof(public_card)='object' and pg_column_size(public_card)<=4500),
 recipient_email text not null default '' check(length(recipient_email)<=200),
 hide_rendprop_branding boolean not null default false,
 photo_asset_id uuid references public.capture_assets(id) on delete set null,
 revision integer not null default 1 check(revision>0),
 updated_by uuid references public.profiles(id) on delete set null,
 updated_at timestamptz not null default now()
);
create index if not exists idx_listing_client_contacts_org on public.listing_client_contacts(org_id);
create table if not exists public.client_lead_deliveries (
 id uuid primary key default gen_random_uuid(),
 lead_id uuid not null references public.leads(id) on delete cascade,
 listing_id uuid not null references public.listings(id) on delete cascade,
 org_id uuid not null references public.orgs(id) on delete cascade,
 contact_revision integer not null,
 request_id uuid not null,
 requested_by uuid references public.profiles(id) on delete set null,
 recipient_email text not null,
 client_name text not null,
 email_subject text not null,
 email_text text not null,
 email_from text,
 state text not null default 'queued' check(state in('queued','sending','email_sent','failed','skipped')),
 last_attempt_at timestamptz not null default now(),
 sent_at timestamptz,
 reason text,
 provider_message_id text,
 created_at timestamptz not null default now(),
 unique(lead_id,request_id)
);
create index if not exists idx_client_lead_deliveries_lead on public.client_lead_deliveries(lead_id,created_at desc);
alter table public.listing_client_contacts enable row level security;
alter table public.client_lead_deliveries enable row level security;
revoke all on public.listing_client_contacts,public.client_lead_deliveries from public,anon,authenticated,service_role;
grant select on public.listing_client_contacts,public.client_lead_deliveries to service_role;
alter table public.notification_outbox add column if not exists client_delivery_id uuid references public.client_lead_deliveries(id) on delete cascade;
alter table public.notification_outbox drop constraint if exists notification_outbox_category_check;
alter table public.notification_outbox add constraint notification_outbox_category_check check(category in(
 'lead_received','render_ready','upload_stuck','free_week_ending','allowance_low','first_tour_nudge','team_invite','client_lead_received'));
-- Full saved form answers can contain Unicode. Keep the original bound for
-- every existing category and allow only these bounded inquiry snapshots more.
alter table public.notification_outbox drop constraint if exists notification_outbox_payload_object;
alter table public.notification_outbox add constraint notification_outbox_payload_object check(jsonb_typeof(payload)='object'and pg_column_size(payload)<=case when category='client_lead_received'then 32768 else 8192 end);
create unique index if not exists uq_notification_client_delivery on public.notification_outbox(client_delivery_id) where client_delivery_id is not null;

create or replace function public.set_real_estate_role(p_user uuid,p_role text)returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if current_setting('role',true) is distinct from 'service_role' then raise insufficient_privilege using message='service role required';end if;
 if p_role is null or p_role not in('agent','photographer_videographer')then raise exception 'RP400: choose Agent or Photographer / videographer';end if;
 perform 1 from public.profiles where id=p_user for update;
 if not found then raise exception 'RP401: session no longer exists';end if;
 if exists(select 1 from public.deletion_requests where user_id=p_user and status in('pending','processing'))then raise exception 'RP409: this account is being deleted';end if;
 update public.profiles set real_estate_role=p_role where id=p_user;
 return jsonb_build_object('id',p_user,'real_estate_role',p_role);
end$$;

-- Service-only guard; callers never choose their identity in public request data.
create or replace function public.client_listing_access(p_user uuid,p_org uuid,p_listing uuid,p_write boolean default false)returns void
language plpgsql security definer set search_path='' as $$
declare v_role text;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 if not exists(select 1 from public.profiles where id=p_user)then raise exception 'RP401: session no longer exists';end if;
 if exists(select 1 from public.deletion_requests where user_id=p_user and status in('pending','processing'))then raise exception 'RP409: this account is being deleted';end if;
 select m.role into v_role from public.memberships m join public.orgs o on o.id=m.org_id where m.user_id=p_user and m.org_id=p_org and o.deleted_at is null;
 if v_role is null or not exists(select 1 from public.listings where id=p_listing and org_id=p_org and deleted_at is null)then raise exception 'RP404: listing not found in this workspace';end if;
 if p_write and v_role not in('owner','admin','agent')then raise exception 'RP403: your role does not permit editing client delivery';end if;
end$$;
create or replace function public.listing_client_contact_get(p_user uuid,p_org uuid,p_listing uuid)returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare c public.listing_client_contacts;
begin
 perform public.client_listing_access(p_user,p_org,p_listing,false);
 select * into c from public.listing_client_contacts where listing_id=p_listing and org_id=p_org;
 if not found then return null;end if;
 return to_jsonb(c)-'updated_by';
end$$;
create or replace function public.listing_client_contact_put(p_user uuid,p_org uuid,p_listing uuid,p_expected_revision integer,p_enabled boolean,p_public_card jsonb,p_recipient_email text,p_hide_branding boolean,p_photo_asset uuid default null)returns jsonb
language plpgsql security definer set search_path='' as $$
declare c public.listing_client_contacts;key text;value jsonb;v_email text:=lower(btrim(coalesce(p_recipient_email,'')));
begin
 -- Order matches account/team mutations: profile, org, listing, then contact.
 perform 1 from public.profiles where id=p_user for update;
 perform 1 from public.orgs where id=p_org for update;
 perform 1 from public.listings where id=p_listing and org_id=p_org for update;
 perform public.client_listing_access(p_user,p_org,p_listing,true);
 if p_expected_revision is null or p_expected_revision<0 or p_enabled is null or p_hide_branding is null or p_public_card is null or jsonb_typeof(p_public_card)<>'object' or pg_column_size(p_public_card)>4500 then raise exception 'RP400: enter valid client page details';end if;
 for key,value in select * from jsonb_each(p_public_card)loop
  if key not in('name','title','brokerage','phone','email','website','instagram','linkedin','avatar_url')or jsonb_typeof(value)<>'string' or length(value#>>'{}')>300 or (value#>>'{}')~'[[:cntrl:]]' then raise exception 'RP400: invalid public contact field';end if;
  if key in('name','title','brokerage')and position('@'in(value#>>'{}'))>0 then raise exception 'RP400: use a display name';end if;
  if key='avatar_url'and (value#>>'{}')<>''then raise exception 'RP400: choose an uploaded client photo';end if;
  if key='email'and (value#>>'{}')<>''and (value#>>'{}')!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'then raise exception 'RP400: invalid public email';end if;
  if key in('website','instagram','linkedin','avatar_url')and (value#>>'{}')<>''and (value#>>'{}')!~'^https://[^/[:space:]]+'then raise exception 'RP400: use an https address';end if;
 end loop;
 if length(v_email)>200 or(v_email<>''and v_email!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')or(p_enabled and (nullif(btrim(p_public_card->>'name'),'')is null or v_email=''))then raise exception 'RP400: a client name and valid lead email are required';end if;
 if p_photo_asset is not null then
  if not exists(select 1 from public.capture_assets where id=p_photo_asset and listing_id=p_listing and uploaded and kind='photo'and bucket='renders'and storage_key like 'renders/'||p_org||'/'||p_listing||'/contact-%')then raise exception 'RP400: choose an uploaded client photo from this listing';end if;
  p_public_card:=p_public_card-'avatar_url';
 end if;
 select * into c from public.listing_client_contacts where listing_id=p_listing for update;
 if coalesce(c.revision,0)<>p_expected_revision then raise exception 'RP409: client contact changed; refresh before saving';end if;
 insert into public.listing_client_contacts(listing_id,org_id,enabled,public_card,recipient_email,hide_rendprop_branding,photo_asset_id,revision,updated_by)
 values(p_listing,p_org,p_enabled,p_public_card,v_email,p_hide_branding,p_photo_asset,1,p_user)
 on conflict(listing_id)do update set enabled=excluded.enabled,public_card=excluded.public_card,recipient_email=excluded.recipient_email,hide_rendprop_branding=excluded.hide_rendprop_branding,photo_asset_id=excluded.photo_asset_id,revision=public.listing_client_contacts.revision+1,updated_by=p_user,updated_at=now()
 returning * into c;
 return to_jsonb(c)-'updated_by';
end$$;

-- Cancel already-queued immutable recipients whenever routing authority changes.
create or replace function public.client_delivery_cancel_for_listing(p_listing uuid,p_reason text)returns void
language plpgsql security definer set search_path='' as $$
begin
 update public.notification_outbox set state='skipped',last_error=p_reason,claimed_at=null
 where client_delivery_id in(select id from public.client_lead_deliveries where listing_id=p_listing)and state in('queued','sending');
 update public.client_lead_deliveries set state='skipped',reason=p_reason where listing_id=p_listing and state in('queued','sending');
end$$;
create or replace function public.client_contact_changed()returns trigger
language plpgsql security definer set search_path='' as $$begin
 if tg_op='DELETE'then perform public.client_delivery_cancel_for_listing(old.listing_id,'Client forwarding was removed.');return old;end if;
 if old.revision is distinct from new.revision then perform public.client_delivery_cancel_for_listing(new.listing_id,'Client contact changed before this email was sent.');end if;
 return new;
end$$;
drop trigger if exists trg_client_contact_changed on public.listing_client_contacts;
create trigger trg_client_contact_changed after update or delete on public.listing_client_contacts for each row execute function public.client_contact_changed();
create or replace function public.client_listing_deleted()returns trigger
language plpgsql security definer set search_path='' as $$begin
 if old.deleted_at is null and new.deleted_at is not null then perform public.client_delivery_cancel_for_listing(new.id,'The listing was deleted.');end if;return new;end$$;
drop trigger if exists trg_client_listing_deleted on public.listings;
create trigger trg_client_listing_deleted after update of deleted_at on public.listings for each row execute function public.client_listing_deleted();

-- Account deletion intent blocks dispatch immediately, before cleanup runs.
create or replace function public.client_routing_active(p_org uuid,p_listing uuid)returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.listings l join public.orgs o on o.id=l.org_id
  where l.id=p_listing and l.org_id=p_org and l.deleted_at is null and o.deleted_at is null
   and not exists(select 1 from public.deletion_requests d where d.status in('pending','processing')
    and(d.user_id=l.agent_id or exists(select 1 from public.memberships m where m.org_id=p_org and m.role='owner'and m.user_id=d.user_id))))
$$;
create or replace function public.client_routing_revoked()returns trigger
language plpgsql security definer set search_path='' as $$declare item uuid;begin
 if tg_table_name='orgs'then
  if old.deleted_at is not null or new.deleted_at is null then return new;end if;
  for item in select id from public.listings where org_id=new.id loop perform public.client_delivery_cancel_for_listing(item,'The listing workspace was deleted.');end loop;
 elsif new.status in('pending','processing')then
  for item in select l.id from public.listings l where l.agent_id=new.user_id or exists(select 1 from public.memberships m where m.org_id=l.org_id and m.role='owner'and m.user_id=new.user_id)loop
   perform public.client_delivery_cancel_for_listing(item,'The listing account is being deleted.');
  end loop;
 end if;return new;
end$$;
drop trigger if exists trg_client_routing_org_revoked on public.orgs;
create trigger trg_client_routing_org_revoked after update of deleted_at on public.orgs for each row execute function public.client_routing_revoked();
drop trigger if exists trg_client_routing_account_revoked on public.deletion_requests;
create trigger trg_client_routing_account_revoked after insert or update of status on public.deletion_requests for each row execute function public.client_routing_revoked();

-- Internal transaction helper. Capture/resend callers both hold the contact lock.
create or replace function public.client_lead_enqueue(p_lead uuid,p_request uuid,p_actor uuid default null)returns uuid
language plpgsql security definer set search_path='' as $$
declare l public.leads;c public.listing_client_contacts;d uuid;s text;a text;subject text;body text;answers text;message text;
begin
 select * into l from public.leads where id=p_lead;
 if not found or not public.client_routing_active(l.org_id,l.listing_id)then return null;end if;
 select * into c from public.listing_client_contacts where listing_id=l.listing_id and org_id=l.org_id and enabled for share;
 if not found or c.recipient_email=''then return null;end if;
 select address into a from public.listings where id=l.listing_id and org_id=l.org_id and deleted_at is null;
 if not found then return null;end if;
 select slug into s from public.renders where id=l.render_id;
 message:=coalesce(l.extra->>'message',l.extra->>'notes',l.extra->>'comment','Not provided');
 select string_agg(initcap(replace(key,'_',' '))||': '||case when jsonb_typeof(value)='string'then value#>>'{}'else value::text end,E'\n'order by key)
 into answers from jsonb_each(l.extra)where not(key in('message','notes','comment')and(value#>>'{}')=message);
 if pg_column_size(l.extra)>16000 then raise exception 'RP400: inquiry details exceed the email limit';end if;
 subject:=left('New inquiry: '||coalesce(nullif(a,''),'your listing'),200);
 body:='Hi '||coalesce(c.public_card->>'name','')||','||E'\n\n'||'Someone asked about '||coalesce(nullif(a,''),'your listing')||'.'||E'\n\n'||
 'Name: '||coalesce(nullif(l.name,''),'Not provided')||E'\n'||'Phone: '||coalesce(nullif(l.phone,''),'Not provided')||E'\n'||'Email: '||coalesce(nullif(l.email,''),'Not provided')||E'\n'||
 'Message: '||message||case when answers is not null then E'\n\nAdditional details:\n'||answers else ''end||E'\n\n'||
 case when s is not null then 'Listing: https://rendprop.com/f/'||s||E'\n\n'else ''end||'You received this inquiry because you are the contact for this listing. You can reply directly using the phone number or email above.';
 insert into public.client_lead_deliveries(lead_id,listing_id,org_id,contact_revision,request_id,requested_by,recipient_email,client_name,email_subject,email_text)
 values(l.id,l.listing_id,l.org_id,c.revision,p_request,p_actor,c.recipient_email,coalesce(c.public_card->>'name',''),subject,body)
 on conflict(lead_id,request_id)do nothing returning id into d;
 if d is null then select id into d from public.client_lead_deliveries where lead_id=p_lead and request_id=p_request;return d;end if;
 insert into public.notification_outbox(org_id,user_id,to_email,category,channel,dedupe_key,payload,client_delivery_id)
 values(l.org_id,null,c.recipient_email,'client_lead_received','email','client-lead:'||d,
 jsonb_build_object('data',jsonb_build_object('client_delivery_id',d),'email_subject',subject,'email_text',body),d);
 return d;
end$$;
create or replace function public.client_lead_inserted()returns trigger
language plpgsql security definer set search_path='' as $$begin
 if new.org_id is not null and new.listing_id is not null then perform public.client_lead_enqueue(new.id,new.id,null);end if;return new;
end$$;
drop trigger if exists trg_client_lead_inserted on public.leads;
create trigger trg_client_lead_inserted after insert on public.leads for each row execute function public.client_lead_inserted();

create or replace function public.client_delivery_summary(p_lead uuid)returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare d public.client_lead_deliveries;c public.listing_client_contacts;l public.leads;v_can boolean;
begin
 select * into l from public.leads where id=p_lead;
 if not found or not public.client_routing_active(l.org_id,l.listing_id)then return null;end if;
 select * into c from public.listing_client_contacts where listing_id=l.listing_id and org_id=l.org_id;
 select * into d from public.client_lead_deliveries where lead_id=p_lead order by created_at desc,id desc limit 1;
 if not found then
  -- Existing inquiries become explicitly forwardable when a client is assigned.
  -- Assignment never automatically sends historical inquiries.
  if not coalesce(c.enabled,false)or c.recipient_email=''or not exists(select 1 from public.listings where id=l.listing_id and org_id=l.org_id and deleted_at is null)then return null;end if;
  return jsonb_build_object('state','skipped','recipient_email',null,'client_name',null,'current_recipient_email',c.recipient_email,'current_client_name',c.public_card->>'name','last_attempt_at',null,'sent_at',null,'can_resend',true,'reason','This inquiry was recorded before client forwarding was enabled.');
 end if;
 v_can:=coalesce(c.enabled,false) and c.recipient_email<>''and public.client_routing_active(d.org_id,d.listing_id)
  and not exists(select 1 from public.client_lead_deliveries where lead_id=p_lead and(state in('queued','sending')or created_at>now()-interval '1 minute'));
 return jsonb_build_object('state',d.state,'recipient_email',d.recipient_email,'client_name',d.client_name,'current_recipient_email',case when c.enabled then c.recipient_email else null end,'current_client_name',case when c.enabled then c.public_card->>'name'else null end,'last_attempt_at',d.last_attempt_at,'sent_at',d.sent_at,'can_resend',v_can,'reason',d.reason);
end$$;
create or replace function public.client_lead_delivery_list(p_user uuid,p_org uuid,p_leads uuid[])returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb:='{}';item uuid;summary jsonb;v_role text;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 if cardinality(p_leads)>500 then raise exception 'RP400: too many leads';end if;
 if not exists(select 1 from public.profiles where id=p_user)then raise exception 'RP401: session no longer exists';end if;
 if exists(select 1 from public.deletion_requests where user_id=p_user and status in('pending','processing'))then raise exception 'RP409: this account is being deleted';end if;
 select m.role into v_role from public.memberships m join public.orgs o on o.id=m.org_id where m.user_id=p_user and m.org_id=p_org and o.deleted_at is null;
 if v_role is null then raise exception 'RP403: workspace is unavailable';end if;
 foreach item in array coalesce(p_leads,'{}')loop
  if exists(select 1 from public.leads where id=item and org_id=p_org)then
   summary:=public.client_delivery_summary(item);
   if summary is not null and v_role not in('owner','admin','agent')then summary:=summary||jsonb_build_object('can_resend',false);end if;
   result:=result||jsonb_build_object(item::text,summary);
  end if;
 end loop;return result;
end$$;
create or replace function public.client_lead_resend(p_user uuid,p_org uuid,p_lead uuid,p_request uuid,p_expected_email text)returns jsonb
language plpgsql security definer set search_path='' as $$
declare l public.leads;c public.listing_client_contacts;d public.client_lead_deliveries;created uuid;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 perform 1 from public.profiles where id=p_user for update;
 perform 1 from public.orgs where id=p_org for update;
 select * into l from public.leads where id=p_lead and org_id=p_org;
 if not found then raise exception 'RP404: lead not found in this workspace';end if;
 perform 1 from public.listings where id=l.listing_id and org_id=p_org for update;
 perform public.client_listing_access(p_user,p_org,l.listing_id,true);
 select * into c from public.listing_client_contacts where listing_id=l.listing_id and enabled for update;
 if not found or c.recipient_email=''then raise exception 'RP409: enable a client lead email before sending';end if;
 if p_request is null or p_expected_email is null or lower(btrim(p_expected_email))<>c.recipient_email then raise exception 'RP409: the client email changed; review the recipient before sending';end if;
 select * into d from public.client_lead_deliveries where lead_id=p_lead and request_id=p_request;
 if found then
  if d.recipient_email<>c.recipient_email or d.requested_by is distinct from p_user then raise exception 'RP409: this send request was already used';end if;
  return jsonb_build_object('ok',true,'delivery',public.client_delivery_summary(p_lead));
 end if;
 if exists(select 1 from public.client_lead_deliveries where lead_id=p_lead and(state in('queued','sending')or created_at>now()-interval '1 minute'))then raise exception 'RP429: an email was just requested; wait a minute before sending again';end if;
 -- Deliberate forwards are bounded across inquiries, as well as per lead.
 -- Existing profile/org locks serialize competing requests across workspaces.
 if (select count(*)from public.client_lead_deliveries where requested_by=p_user and created_at>now()-interval '10 minutes')>=20
  or(select count(*)from public.client_lead_deliveries where org_id=p_org and requested_by is not null and created_at>now()-interval '10 minutes')>=20 then
  raise exception 'RP429: too many client forwards; wait ten minutes before sending more';
 end if;
 created:=public.client_lead_enqueue(p_lead,p_request,p_user);
 if created is null then raise exception 'RP409: this client is no longer available';end if;
 return jsonb_build_object('ok',true,'delivery',public.client_delivery_summary(p_lead));
end$$;

-- The sender revalidates live authority immediately before the provider call.
-- Freeze From on the first attempt so retries have exactly the same payload.
create or replace function public.client_lead_prepare(p_delivery uuid,p_outbox uuid,p_from text)returns jsonb
language plpgsql security definer set search_path='' as $$
declare d public.client_lead_deliveries;c public.listing_client_contacts;o public.notification_outbox;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 select * into d from public.client_lead_deliveries where id=p_delivery;
 if not found then return null;end if;
 select * into c from public.listing_client_contacts where listing_id=d.listing_id and org_id=d.org_id for share;
 select * into o from public.notification_outbox where id=p_outbox and client_delivery_id=d.id for update;
 if not found or o.state<>'sending'then return null;end if;
 if not coalesce(c.enabled,false)or c.revision is distinct from d.contact_revision or c.recipient_email is distinct from d.recipient_email
  or not public.client_routing_active(d.org_id,d.listing_id)then
  update public.notification_outbox set state='skipped',last_error='Client forwarding is no longer authorized.',claimed_at=null where id=o.id;
  update public.client_lead_deliveries set state='skipped',reason='Client forwarding is no longer authorized.'where id=d.id;return null;
 end if;
 if o.created_at<now()-interval '23 hours'then
  update public.notification_outbox set state='failed',last_error='Automatic retry window expired; review and resend manually.',claimed_at=null where id=o.id;
  update public.client_lead_deliveries set state='failed',reason='Automatic retry window expired; review and resend manually.'where id=d.id;return null;
 end if;
 if nullif(btrim(p_from),'')is null or length(p_from)>320 then raise exception 'RP400: email sender is not configured';end if;
 update public.client_lead_deliveries set state='sending',last_attempt_at=now(),email_from=coalesce(email_from,p_from)where id=d.id returning * into d;
 return jsonb_build_object('to',d.recipient_email,'from',d.email_from,'subject',d.email_subject,'text',d.email_text,'idempotency_key','client-lead/'||d.id);
end$$;

-- Shared retry ladder stays unchanged. Client records retain permanent status.
create or replace function public.notification_mark(p_id uuid,p_state text,p_error text default null,p_provider_id text default null)returns public.notification_outbox
language plpgsql security definer set search_path='' as $$
declare v_max constant integer:=5;v_state text:=lower(btrim(coalesce(p_state,'')));v_row public.notification_outbox;v_err text:=left(nullif(btrim(coalesce(p_error,'')),''),500);v_late_accepted boolean:=false;
begin
 if v_state not in('queued','sent','failed','skipped','expired')then raise exception 'RP400: state must be queued, sent, failed, skipped or expired';end if;
 select * into v_row from public.notification_outbox where id=p_id for update;
 if not found then raise exception 'RP404: outbox row not found';end if;
 -- Cancellation prevents retries, but an already-dispatched provider acceptance
 -- must remain truthful history. A frozen prepared payload and provider receipt
 -- distinguish that boundary from unprepared or repeated acknowledgments.
 if v_row.client_delivery_id is not null and v_row.state<>'sending'then
  v_late_accepted:=v_row.state='skipped'and v_state='sent'and nullif(btrim(p_provider_id),'')is not null
   and exists(select 1 from public.client_lead_deliveries where id=v_row.client_delivery_id and email_from is not null);
  if not v_late_accepted then return v_row;end if;
 end if;
 if v_state='sent'then
  update public.notification_outbox set state='sent',sent_at=now(),last_error=case when v_late_accepted then 'Client routing changed while this email was already being sent; the provider accepted it and it cannot be recalled.'else null end,claimed_at=null where id=p_id returning * into v_row;
  insert into public.notification_log(category,channel,org_id,user_id,sent_at,provider_message_id)values(v_row.category,v_row.channel,v_row.org_id,v_row.user_id,v_row.sent_at,left(nullif(btrim(coalesce(p_provider_id,'')),''),200));
 elsif v_state='failed'and v_row.attempts<v_max then
  update public.notification_outbox set state='queued',scheduled_for=now()+make_interval(mins=>greatest(1,v_row.attempts*v_row.attempts)),last_error=v_err,claimed_at=null where id=p_id returning * into v_row;
 else
  update public.notification_outbox set state=v_state,last_error=v_err,claimed_at=case when v_state='queued'then null else claimed_at end where id=p_id returning * into v_row;
 end if;
 if v_row.client_delivery_id is not null then
  update public.client_lead_deliveries set state=case v_row.state when 'sent'then 'email_sent'when 'expired'then 'failed'else v_row.state end,
   reason=v_row.last_error,sent_at=v_row.sent_at,provider_message_id=case when v_row.state='sent'then p_provider_id else provider_message_id end,last_attempt_at=now()where id=v_row.client_delivery_id;
 end if;
 return v_row;
end$$;

-- A recovered worker claim / sweep must update the visible delivery status too.
create or replace function public.client_delivery_outbox_changed()returns trigger
language plpgsql security definer set search_path='' as $$begin
 if new.client_delivery_id is not null then update public.client_lead_deliveries set state=case new.state when 'sent'then 'email_sent'when 'expired'then 'failed'else new.state end,
  reason=new.last_error,sent_at=new.sent_at,last_attempt_at=case when new.state='sending'then now()else last_attempt_at end where id=new.client_delivery_id;end if;return new;
end$$;
drop trigger if exists trg_client_delivery_outbox_changed on public.notification_outbox;
create trigger trg_client_delivery_outbox_changed after update of state on public.notification_outbox for each row execute function public.client_delivery_outbox_changed();

-- Even internal helper functions have no default public execution permission.
revoke execute on function public.set_real_estate_role(uuid,text),public.client_listing_access(uuid,uuid,uuid,boolean),public.listing_client_contact_get(uuid,uuid,uuid),public.listing_client_contact_put(uuid,uuid,uuid,integer,boolean,jsonb,text,boolean,uuid),public.client_delivery_cancel_for_listing(uuid,text),public.client_contact_changed(),public.client_listing_deleted(),public.client_routing_active(uuid,uuid),public.client_routing_revoked(),public.client_lead_enqueue(uuid,uuid,uuid),public.client_lead_inserted(),public.client_delivery_summary(uuid),public.client_lead_delivery_list(uuid,uuid,uuid[]),public.client_lead_resend(uuid,uuid,uuid,uuid,text),public.client_lead_prepare(uuid,uuid,text),public.client_delivery_outbox_changed(),public.notification_mark(uuid,text,text,text)from public,anon,authenticated;
grant execute on function public.set_real_estate_role(uuid,text),public.client_listing_access(uuid,uuid,uuid,boolean),public.listing_client_contact_get(uuid,uuid,uuid),public.listing_client_contact_put(uuid,uuid,uuid,integer,boolean,jsonb,text,boolean,uuid),public.client_delivery_cancel_for_listing(uuid,text),public.client_lead_enqueue(uuid,uuid,uuid),public.client_delivery_summary(uuid),public.client_lead_delivery_list(uuid,uuid,uuid[]),public.client_lead_resend(uuid,uuid,uuid,uuid,text),public.client_lead_prepare(uuid,uuid,text),public.notification_mark(uuid,text,text,text)to service_role;
comment on column public.profiles.real_estate_role is 'UX preference only; never authorizes listings, teams, billing or lead access.';
comment on table public.client_lead_deliveries is 'Immutable external inquiry recipient/message per deliberate send; email_sent means provider accepted, not inbox delivery. Never exposed publicly.';

-- Existing transport reservations retain every fence; only the isolated photo role is added.
create or replace function public.reserve_upload_assets(p_actor uuid, p_assets jsonb)
returns jsonb language plpgsql security invoker set search_path = public as $$
declare
  s jsonb; a public.capture_assets; r public.upload_reservations; w public.upload_budget_windows;
  l public.listings; result jsonb := '[]'; n bigint; hold bigint; d date := (clock_timestamp() at time zone 'UTC')::date;
  spec jsonb; idem text; prefix text;
begin
  perform public.upload_service_only();
  if jsonb_typeof(p_assets) is distinct from 'array' or jsonb_array_length(p_assets) not between 1 and 200 then
    raise exception 'RP400: expected 1..200 assets';
  end if;
  select * into l from listings where id = (p_assets->0->>'listing_id')::uuid and deleted_at is null for update;
  if l.id is null or not exists (select 1 from orgs where id = l.org_id and deleted_at is null)
     or not exists (select 1 from memberships where org_id = l.org_id and user_id = p_actor and role in ('owner','admin','agent'))
     or exists (select 1 from deletion_requests where user_id = p_actor and status <> 'completed') then
    raise exception 'RP403: upload workspace is not writable';
  end if;
  insert into upload_budget_windows(org_id,day) values(l.org_id,d) on conflict do nothing;
  select * into strict w from upload_budget_windows where org_id=l.org_id and day=d for update;
  for s in select value from jsonb_array_elements(p_assets) loop
    if (s->>'listing_id')::uuid <> l.id or jsonb_typeof(s->'bytes') is distinct from 'number'
       or (s->>'bytes')::numeric <> trunc((s->>'bytes')::numeric) then raise exception 'RP400: invalid asset identity/bytes'; end if;
    n := (s->>'bytes')::bigint;
    if n not between 1 and 12884901888 or s->>'kind' not in ('photo','video') or s->>'bucket' not in ('uploads','renders')
       or coalesce(s->>'content_type','') !~ '^[a-z0-9.+-]+/[a-z0-9.+-]+$' then raise exception 'RP400: invalid upload specification'; end if;
    if s->>'kind' = 'photo' and n > 52428800 then raise exception 'RP400: photo exceeds 50 MiB'; end if;
    if s->>'parts_total' is not null and (s->>'part_size' is null or (s->>'part_size')::bigint <> 33554432 or
       (s->>'parts_total')::integer <> ceil(n::numeric/33554432) or s->>'kind' <> 'video') then
      raise exception 'RP400: invalid bounded multipart shape';
    end if;
    if s->>'parts_total' is null and n > 67108864 then raise exception 'RP400: single upload exceeds 64 MiB'; end if;
    prefix := (s->>'bucket') || '/' || l.org_id || '/' || l.id || '/';
    if left(s->>'storage_key',length(prefix)) <> prefix or
       substring(s->>'storage_key' from length(prefix)+1) !~ ('^(original-|gallery-|contact-)?' || (s->>'id') || '\.[a-zA-Z0-9]{1,8}$') then
      raise exception 'RP400: invalid server-generated upload key';
    end if;
    if (s->>'kind'='video' and s->>'content_type' not in ('video/mp4','video/quicktime','video/x-m4v')) or
       (s->>'kind'='photo' and s->>'content_type' not in ('image/jpeg','image/png','image/webp','image/heic','image/heif')) or
       (s->>'kind'='photo' and s->>'bucket'='renders' and s->>'content_type' not in ('image/jpeg','image/png','image/webp')) or
       (s->>'kind'='photo' and s->>'bucket'='renders' and s->>'storage_key' not like '%/original-%' and n>10485760) then
      raise exception 'RP400: role-specific upload type or size denied';
    end if;
    idem := nullif(s->>'idem_key','');
    if idem is not null and length(idem) not between 8 and 128 then raise exception 'RP400: invalid idempotency key'; end if;
    -- Client computes this advisory digest asynchronously; it is not transport
    -- authority and may arrive on a later retry/complete request.
    if s->>'storage_key' like '%/contact-%' and (s->>'kind'<>'photo' or s->>'bucket'<>'renders') then raise exception 'RP400: client headshots must be public photos';end if;
    spec := s - array['id','storage_key','idem_key','sha256'];
    -- Role-bearing prefix is part of request identity, not just bucket/type.
    spec := spec || jsonb_build_object('key_role', case when s->>'storage_key' like '%/original-%' then 'original'
      when s->>'storage_key' like '%/gallery-%' then 'gallery' when s->>'storage_key' like '%/contact-%' then 'contact_photo' else 'default' end);
    a := null;
    if idem is not null then
      select * into a from capture_assets where listing_id=l.id and idem_key=idem and not uploaded and not upload_aborted;
    end if;
    if a.id is not null then
      select * into r from upload_reservations where asset_id=a.id;
      if r.asset_id is null or r.spec is distinct from spec or r.state <> 'open' or r.expires_at <= clock_timestamp() then
        raise exception 'RP409: idempotency key conflicts with an existing or expired upload';
      end if;
      result := result || jsonb_build_array(to_jsonb(a) || '{"replayed":true}'::jsonb);
      continue;
    end if;
    hold := n * case when s->>'parts_total' is null then 2 else 1 end;
    if w.tickets + 1 > 2000 or w.held_bytes + w.spent_bytes + hold > 214748364800 then
      raise exception 'RP429: daily physical upload reservation budget exhausted';
    end if;
    insert into capture_assets(id,listing_id,kind,bucket,storage_key,sha256,bytes,content_type,content_type_declared,
      part_size,parts_total,idem_key,transport_version)
      values ((s->>'id')::uuid,l.id,s->>'kind',s->>'bucket',s->>'storage_key',s->>'sha256',n,s->>'content_type',
        (s->>'content_type_declared')::boolean,(s->>'part_size')::bigint,(s->>'parts_total')::integer,idem,2)
      returning * into a;
    insert into upload_reservations(asset_id,org_id,listing_id,actor_id,day,spec,held_bytes)
      values(a.id,l.org_id,l.id,p_actor,d,spec,hold);
    w.tickets := w.tickets+1; w.held_bytes := w.held_bytes+hold;
    result := result || jsonb_build_array(to_jsonb(a) || '{"replayed":false}'::jsonb);
  end loop;
  update upload_budget_windows set tickets=w.tickets,held_bytes=w.held_bytes where org_id=l.org_id and day=d;
  return result;
end $$;

-- Preserve an explicit guest choice within the existing verified adoption transaction.
create or replace function public.adopt_anonymous_org(
  p_user uuid, p_anon_user uuid, p_anon_org uuid, p_operation uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_receipt jsonb; v_count integer;
begin
  if current_setting('role', true) is distinct from 'service_role' then
    raise insufficient_privilege using message = 'service role required';
  end if;
  if p_user is null or p_anon_user is null or p_anon_org is null or p_operation is null or p_user=p_anon_user then
    raise exception 'RP400: invalid handoff binding';
  end if;
  -- Receipt-only replays do not change workspace selection or lock Auth rows.
  v_receipt := public.adoption_receipt(p_user,p_anon_user,p_operation);
  if v_receipt is not null then
    if (v_receipt->>'org_id')::uuid <> p_anon_org then raise exception 'RP403: workspace binding does not match'; end if;
    return v_receipt;
  end if;
  -- Auth -> profile -> org; sorted within each class. Auth can promote an
  -- anonymous identity while Edge waits for SQL. Its live row, not the earlier
  -- GET/JWT snapshot, must still authorize the transfer. Auth-first also agrees
  -- with auth.users deletion cascading into profiles. No HTTP inside the lock.
  perform 1 from auth.users where id in(p_user,p_anon_user) order by id for update;
  perform 1 from public.profiles where id in (p_user,p_anon_user) order by id for update;
  v_receipt := public.adoption_receipt(p_user,p_anon_user,p_operation);
  if v_receipt is not null then
    if (v_receipt->>'org_id')::uuid <> p_anon_org then raise exception 'RP403: workspace binding does not match'; end if;
    return v_receipt;
  end if;
  select count(*) into v_count from public.profiles where id in (p_user,p_anon_user);
  if v_count <> 2 then raise exception 'RP401: session no longer exists'; end if;
  if (select is_anonymous from auth.users where id=p_anon_user) is distinct from true
     or (select is_anonymous from auth.users where id=p_user) is distinct from false then
    raise exception 'RP403: current source and destination identity types do not permit transfer';
  end if;
  if exists(select 1 from public.deletion_requests where user_id in (p_user,p_anon_user)
            and status in ('pending','processing')) then raise exception 'RP409: an account is being deleted'; end if;
  perform 1 from public.orgs where id=p_anon_org and deleted_at is null for update;
  if not found then raise exception 'RP404: that workspace no longer exists'; end if;
  -- Recheck the boundary inside the transaction, not only at Edge preflight.
  if (select count(*) from public.memberships where user_id=p_anon_user) <> 1
     or not exists(select 1 from public.memberships where user_id=p_anon_user and org_id=p_anon_org and role='owner')
     or exists(select 1 from public.memberships where org_id=p_anon_org and user_id<>p_anon_user) then
    raise exception 'RP409: original workspace ownership changed';
  end if;
  -- Both profiles are locked and the anonymous source was verified above.
  -- A prior explicit named-account choice always wins. Receipt replay returns
  -- before this write and never re-applies a preference.
  update public.profiles target set real_estate_role=source.real_estate_role
    from public.profiles source where target.id=p_user and source.id=p_anon_user
      and target.real_estate_role is null and source.real_estate_role is not null;
  update public.memberships set user_id=p_user where user_id=p_anon_user and org_id=p_anon_org;
  update public.listings set agent_id=p_user where org_id=p_anon_org and agent_id=p_anon_user;
  insert into public.user_workspace_state(user_id,active_org_id) values(p_user,p_anon_org)
    on conflict(user_id) do update set active_org_id=excluded.active_org_id, updated_at=now();
  v_receipt := jsonb_build_object('ok',true,'adopted',true,'operation_id',p_operation,
    'source_user_id',p_anon_user,'destination_user_id',p_user,'org_id',p_anon_org,
    'source_cleanup_pending',true);
  insert into public.anonymous_adoption_receipts(operation_id,source_user_id,destination_user_id,org_id,receipt)
    values(p_operation,p_anon_user,p_user,p_anon_org,v_receipt);
  return v_receipt;
end;
$$;

revoke execute on function public.adopt_anonymous_org(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.adopt_anonymous_org(uuid,uuid,uuid,uuid) to service_role;
