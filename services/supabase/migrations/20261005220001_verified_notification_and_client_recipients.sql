-- Private messages are addressed from trusted Auth or an explicit recipient
-- verification. Editable public cards/profile emails never grant authority.
begin;

create or replace function public.notification_verified_recipients(p_users uuid[])
returns table(id uuid,email text) language plpgsql stable security definer set search_path='' as $$
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 if p_users is null or cardinality(p_users)>200 then raise exception 'RP400: invalid recipient batch';end if;
 return query select u.id,lower(btrim(u.email)) from auth.users u join public.profiles p on p.id=u.id
  where u.id=any(p_users) and not u.is_anonymous and u.email_confirmed_at is not null
   and nullif(btrim(u.email),'')is not null
   and not exists(select 1 from public.deletion_requests d where d.user_id=u.id and d.status in('pending','processing'));
end$$;

-- Default-on lifecycle rows cannot establish email marketing consent. Keep
-- promotional emails disabled until explicit opt-in/unsubscribe are supported.
-- Transactional lead/render/upload/allowance messages retain their switches.
do $$declare body text;old text;patched text;begin
 body:=pg_get_functiondef('public.notification_enqueue(uuid,uuid,text,jsonb,text,timestamptz)'::regprocedure);
 old:='  insert into notification_outbox'||E'\n    (org_id, user_id, category, channel, dedupe_key, payload, scheduled_for)';
 patched:='  if v_channel = ''email'' and v_cat in (''first_tour_nudge'',''free_week_ending'') then'||E'\n'||
  '    return jsonb_build_object(''state'',''skipped'',''reason'',''promotional_email_disabled'',''category'',v_cat,''dedupe_key'',v_key,''id'',null);'||E'\n'||
  '  end if;'||E'\n'||old;
 if position(patched in body)=0 then
  if position(old in body)=0 or(length(body)-length(replace(body,old,'')))/length(old)<>1 then raise exception 'RP409: unexpected notification producer body';end if;
  execute replace(body,old,patched);
 end if;
end$$;
update public.notification_outbox set state='skipped',last_error='Promotional lifecycle email is disabled.',claimed_at=null
 where channel='email'and category in('first_tour_nudge','free_week_ending')and state in('queued','sending');

alter table public.listing_client_contacts add column if not exists recipient_verified_email text;
alter table public.listing_client_contacts add column if not exists recipient_verified_at timestamptz;
alter table public.listing_client_contacts drop constraint if exists listing_client_recipient_verification_pair;
alter table public.listing_client_contacts add constraint listing_client_recipient_verification_pair
 check((recipient_verified_email is null and recipient_verified_at is null)or
  (recipient_verified_at is not null and recipient_verified_email=recipient_email and recipient_email<>''));

create table if not exists public.client_recipient_verifications(
 id uuid primary key default gen_random_uuid(),
 listing_id uuid not null references public.listings(id)on delete cascade,
 org_id uuid not null references public.orgs(id)on delete cascade,
 requested_by uuid references public.profiles(id)on delete set null,
 recipient_email text not null check(length(recipient_email)<=200),
 contact_revision integer not null check(contact_revision>0),
 token_hash text not null unique check(token_hash~'^[0-9a-f]{64}$'),
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '24 hours',
 consumed_at timestamptz,
 email_from text,
 check(expires_at>created_at and expires_at<=created_at+interval '24 hours')
);
create index if not exists client_recipient_verifications_listing on public.client_recipient_verifications(listing_id,created_at desc);
alter table public.client_recipient_verifications enable row level security;
revoke all on public.client_recipient_verifications from public,anon,authenticated,service_role;
grant select on public.client_recipient_verifications to service_role;
alter table public.notification_outbox add column if not exists client_verification_id uuid references public.client_recipient_verifications(id)on delete cascade;
create unique index if not exists notification_client_verification on public.notification_outbox(client_verification_id)where client_verification_id is not null;
alter table public.notification_outbox drop constraint if exists notification_outbox_category_check;
alter table public.notification_outbox add constraint notification_outbox_category_check check(category in(
 'lead_received','render_ready','upload_stuck','free_week_ending','allowance_low','first_tour_nudge','team_invite','client_lead_received','client_recipient_verification'));

create or replace function public.client_recipient_verified(p_listing uuid,p_email text)returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.listing_client_contacts c where c.listing_id=p_listing
  and c.enabled and c.recipient_email=p_email and c.recipient_verified_email=p_email and c.recipient_verified_at is not null)
$$;

create or replace function public.client_recipient_changed()returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT'or old.recipient_email is distinct from new.recipient_email then
  new.recipient_verified_email:=null;new.recipient_verified_at:=null;
 end if;
 return new;
end$$;
drop trigger if exists trg_client_recipient_changed on public.listing_client_contacts;
create trigger trg_client_recipient_changed before insert or update on public.listing_client_contacts for each row execute function public.client_recipient_changed();

-- Callers are verified by the edge handler. SQL rechecks named Auth, current
-- membership, role, account/listing deletion and the saved recipient under locks.
create or replace function public.client_recipient_verification_request(p_user uuid,p_org uuid,p_listing uuid,p_nonce text)returns jsonb
language plpgsql security definer set search_path='' as $$
declare c public.listing_client_contacts;v_id uuid;v_hash text;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 if p_nonce is null or p_nonce!~'^[0-9a-f]{64}$'then raise exception 'RP400: invalid verification request';end if;
 perform 1 from public.profiles where id=p_user for update;
 perform 1 from public.orgs where id=p_org for update;
 perform 1 from public.listings where id=p_listing and org_id=p_org for update;
 perform public.client_listing_access(p_user,p_org,p_listing,true);
 if not exists(select 1 from auth.users u where u.id=p_user and not u.is_anonymous)then raise exception 'RP403: sign in to request client verification';end if;
 select * into c from public.listing_client_contacts where listing_id=p_listing and org_id=p_org for update;
 if not found or not c.enabled or c.recipient_email=''then raise exception 'RP409: save a client lead email first';end if;
 if public.client_recipient_verified(c.listing_id,c.recipient_email)then return jsonb_build_object('ok',true,'state','verified');end if;
 if exists(select 1 from public.client_recipient_verifications where listing_id=p_listing and created_at>now()-interval '1 minute')
  or(select count(*)from public.client_recipient_verifications where listing_id=p_listing and created_at>now()-interval '24 hours')>=5
  or(select count(*)from public.client_recipient_verifications where requested_by=p_user and created_at>now()-interval '24 hours')>=20 then
  raise exception 'RP429: a verification email was already requested; wait before retrying';end if;
 v_hash:=encode(sha256(convert_to(p_nonce,'UTF8')),'hex');
 insert into public.client_recipient_verifications(listing_id,org_id,requested_by,recipient_email,contact_revision,token_hash)
 values(p_listing,p_org,p_user,c.recipient_email,c.revision,v_hash)returning id into v_id;
 insert into public.notification_outbox(org_id,user_id,to_email,category,channel,dedupe_key,payload,client_verification_id)
 values(p_org,null,c.recipient_email,'client_recipient_verification','email','client-verification:'||v_id,
  jsonb_build_object('deep_link','https://rendprop.com/verify-client-email#token='||p_nonce),v_id);
 return jsonb_build_object('ok',true,'state','queued');
end$$;

-- Generic false is deliberate: a public token probe never reveals a recipient,
-- listing, address or membership. Only POST with possession can change state.
create or replace function public.client_recipient_verification_consume(p_nonce text)returns boolean
language plpgsql security definer set search_path='' as $$
declare v public.client_recipient_verifications;c public.listing_client_contacts;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 if p_nonce is null or p_nonce!~'^[0-9a-f]{64}$'then return false;end if;
 -- Lock order matches contact writers; first locate, then lock org/listing,
 -- contact and token. A recipient edit cannot race a stale verification.
 select * into v from public.client_recipient_verifications where token_hash=encode(sha256(convert_to(p_nonce,'UTF8')),'hex');
 if not found then return false;end if;
 perform 1 from public.orgs where id=v.org_id for update;
 perform 1 from public.listings where id=v.listing_id and org_id=v.org_id for update;
 select * into c from public.listing_client_contacts where listing_id=v.listing_id and org_id=v.org_id for update;
 select * into v from public.client_recipient_verifications where id=v.id for update;
 if not found or v.expires_at<=now()or not coalesce(c.enabled,false)
  or c.recipient_email is distinct from v.recipient_email or c.revision is distinct from v.contact_revision
  or not public.client_routing_active(v.org_id,v.listing_id)then return false;end if;
 update public.listing_client_contacts set recipient_verified_email=recipient_email,recipient_verified_at=coalesce(recipient_verified_at,now())where listing_id=v.listing_id;
 update public.client_recipient_verifications set consumed_at=coalesce(consumed_at,now())where id=v.id;
 return true;
end$$;

create or replace function public.client_recipient_verification_prepare(p_verification uuid,p_outbox uuid,p_from text)returns jsonb
language plpgsql security definer set search_path='' as $$
declare v public.client_recipient_verifications;c public.listing_client_contacts;o public.notification_outbox;link text;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 select * into v from public.client_recipient_verifications where id=p_verification;
 if not found then return null;end if;
 select * into c from public.listing_client_contacts where listing_id=v.listing_id and org_id=v.org_id for share;
 select * into o from public.notification_outbox where id=p_outbox and client_verification_id=v.id and category='client_recipient_verification'for update;
 if not found or o.state<>'sending'then return null;end if;
 if v.expires_at<=now()or v.consumed_at is not null or not coalesce(c.enabled,false)
  or c.recipient_email is distinct from v.recipient_email or c.revision is distinct from v.contact_revision
  or o.to_email is distinct from v.recipient_email or not public.client_routing_active(v.org_id,v.listing_id)then
  update public.notification_outbox set state='skipped',last_error='Recipient verification is no longer current.',claimed_at=null,payload='{}'where id=o.id;return null;end if;
 link:=o.payload->>'deep_link';
 if link is null or link!~'^https://rendprop\.com/verify-client-email#token=[0-9a-f]{64}$'
  or encode(sha256(convert_to(substring(link from '#token=(.*)$'),'UTF8')),'hex')<>v.token_hash then raise exception 'RP409: verification message is damaged';end if;
 if nullif(btrim(p_from),'')is null or length(p_from)>320 then raise exception 'RP400: email sender is not configured';end if;
 update public.client_recipient_verifications set email_from=coalesce(email_from,p_from)where id=v.id returning * into v;
 return jsonb_build_object('to',v.recipient_email,'from',v.email_from,'subject','Confirm your listing inquiry email',
  'text','The listing owner asked Rendprop to forward listing inquiries to this email address. Confirm only if you expect to receive these inquiries.'||E'\n\n'||link||E'\n\n'||'This link expires in 24 hours. If you did not expect this request, ignore it. No buyer information has been included.',
  'idempotency_key','client-verification/'||v.id);
end$$;

create or replace function public.scrub_verification_outbox_token()returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.client_verification_id is not null and new.state in('sent','failed','skipped','expired')then new.payload:='{}';end if;
 return new;
end$$;
drop trigger if exists trg_scrub_verification_outbox_token on public.notification_outbox;
create trigger trg_scrub_verification_outbox_token before update of state on public.notification_outbox for each row execute function public.scrub_verification_outbox_token();

create or replace function public.privacy_retention_sweep()returns jsonb
language plpgsql security definer set search_path='' as $$
declare tokens integer;messages integer;outbox integer;
begin
 if current_setting('role',true)is distinct from 'service_role'then raise insufficient_privilege using message='service role required';end if;
 delete from public.client_recipient_verifications where id in(select id from public.client_recipient_verifications where expires_at<now()-interval '7 days'order by expires_at,id limit 500);get diagnostics tokens=row_count;
 update public.client_lead_deliveries set email_text='',email_subject=''where id in(select id from public.client_lead_deliveries where state in('email_sent','failed','skipped')and created_at<now()-interval '30 days'and(email_text<>''or email_subject<>'')order by created_at,id limit 500);get diagnostics messages=row_count;
 update public.notification_outbox set payload='{}'where id in(select id from public.notification_outbox where state in('sent','failed','skipped','expired')and created_at<now()-interval '30 days'and payload<>'{}'::jsonb order by created_at,id limit 500);get diagnostics outbox=row_count;
 return jsonb_build_object('verification_tokens',tokens,'message_snapshots',messages,'outbox_payloads',outbox);
end$$;

-- Preserve existing helpers exactly except the recipient authority predicate.
-- A missing anchor aborts the whole transaction, including schema changes.
do $$
declare spec record;body text;old text;replacement text;
begin
 for spec in select * from(values
  ('public.client_lead_enqueue(uuid,uuid,uuid)', 'if not found or c.recipient_email=''''then return null;end if;', 'if not found or c.recipient_email=''''or not public.client_recipient_verified(c.listing_id,c.recipient_email)then return null;end if;'),
  ('public.client_lead_resend(uuid,uuid,uuid,uuid,text)', 'if not found or c.recipient_email=''''then raise exception ''RP409: enable a client lead email before sending'';end if;', 'if not found or c.recipient_email=''''then raise exception ''RP409: enable a client lead email before sending'';end if;'||E'\n if not public.client_recipient_verified(c.listing_id,c.recipient_email)then raise exception ''RP409: verify the client lead email before sending'';end if;'),
  ('public.client_lead_prepare(uuid,uuid,text)', 'if not coalesce(c.enabled,false)or c.revision is distinct from d.contact_revision', 'if not public.client_recipient_verified(d.listing_id,d.recipient_email)or not coalesce(c.enabled,false)or c.revision is distinct from d.contact_revision'),
  ('public.client_delivery_summary(uuid)', 'v_can:=coalesce(c.enabled,false) and c.recipient_email<>''''and public.client_routing_active(d.org_id,d.listing_id)', 'v_can:=public.client_recipient_verified(c.listing_id,c.recipient_email)and coalesce(c.enabled,false) and c.recipient_email<>''''and public.client_routing_active(d.org_id,d.listing_id)'),
  ('public.client_delivery_summary(uuid)', '''can_resend'',true,''reason'',''This inquiry was recorded before client forwarding was enabled.''', '''can_resend'',public.client_recipient_verified(c.listing_id,c.recipient_email),''reason'',case when public.client_recipient_verified(c.listing_id,c.recipient_email)then ''This inquiry was recorded before client forwarding was enabled.''else ''Verify the client lead email before sending.''end')
 )as patches(fn,anchor,patched)loop
  body:=pg_get_functiondef(spec.fn::regprocedure);old:=spec.anchor;replacement:=spec.patched;
  if position(replacement in body)>0 then continue;end if;
  if position(old in body)=0 or(length(body)-length(replace(body,old,'')))/length(old)<>1 then raise exception 'RP409: unexpected recipient helper body: %',spec.fn;end if;
  execute replace(body,old,replacement);
 end loop;
end$$;

-- One verification step must also gate already-queued client snapshots.
update public.notification_outbox o set state='skipped',last_error='Client recipient email needs verification.',claimed_at=null
 where o.category='client_lead_received'and o.state in('queued','sending')and exists(
  select 1 from public.client_lead_deliveries d where d.id=o.client_delivery_id and not public.client_recipient_verified(d.listing_id,d.recipient_email));
update public.client_lead_deliveries d set state='skipped',reason='Client recipient email needs verification.'where d.state in('queued','sending')and not public.client_recipient_verified(d.listing_id,d.recipient_email);

revoke execute on function public.notification_verified_recipients(uuid[]),public.client_recipient_verified(uuid,text),public.client_recipient_changed(),public.client_recipient_verification_request(uuid,uuid,uuid,text),public.client_recipient_verification_consume(text),public.client_recipient_verification_prepare(uuid,uuid,text),public.scrub_verification_outbox_token(),public.privacy_retention_sweep()from public,anon,authenticated;
grant execute on function public.notification_verified_recipients(uuid[]),public.client_recipient_verified(uuid,text),public.client_recipient_verification_request(uuid,uuid,uuid,text),public.client_recipient_verification_consume(text),public.client_recipient_verification_prepare(uuid,uuid,text),public.privacy_retention_sweep()to service_role;
comment on table public.client_recipient_verifications is 'Service-only hashed recipient confirmation tokens; explicit POST only. A verified email grants transactional inquiry forwarding, never marketing call/text consent.';
commit;
