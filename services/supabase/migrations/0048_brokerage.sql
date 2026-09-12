-- 0048: the BROKERAGE becomes the customer — bulk seats, a seat ledger, one
--       overview and an org-wide compliance export (2026-09-12, brokerage-pilot
--       wave: three warm-introduction pilots into large Keller Williams teams).
--
-- NUMBERING: 0045 is reserved for a parallel branch (upload explicit restart)
-- and 0047 for a concurrent branch. Nothing in this file references either, and
-- nothing here depends on anything newer than 0046; migrations apply in number
-- order, so 0048 is correct whether or not 0045/0047 are present.
--
-- ── THE DECISION ────────────────────────────────────────────────────────────
--
-- Selling listing media one agent at a time does not reach scale; the market
-- buys it at the brokerage level (Zillow sells Showcase through brokerage-wide
-- volume agreements). A broker evaluating this product asks exactly three
-- questions, and before this migration the database could answer none of them:
--
--   1. "Can I get my 80 agents on this in an afternoon?"
--      create_org_invite() (0033) issues ONE invite per call, each its own
--      transaction and its own org row lock. Eighty calls is eighty chances to
--      half-succeed, and the seat cap bites on whichever call happens to be the
--      (allowed+1)-th — leaving an unknown subset invited. §3 makes the whole
--      list one transaction under one lock: every invite, or none.
--
--   2. "What are my agents publishing?"
--      Nothing joined a member to their work. `renders` has no org_id and no
--      agent column at all (0001) — a tour reaches a person only through
--      listings.agent_id — and `memberships` is a bare join row with NO
--      created_at, so even "when did she join?" was unanswerable. §2 records
--      the seat, §5 reports the work.
--
--   3. "Can I prove to my compliance officer that every AI-altered image was
--      disclosed?"  GET /me/compliance (W2-B3) exports media_provenance for the
--      workspace, but it cannot say WHICH AGENT published each row: the join it
--      would need is `profiles`, whose only RLS policy is `id = auth.uid()`
--      (0001:207). §6 is that export with the agent attached, through a definer
--      that reads profiles on the broker's behalf. It WEAKENS NOTHING: the
--      media_provenance policy already lets any org member read the whole org's
--      provenance (0012 §1, `is_org_member(org_id)`), and profiles keeps its
--      self-only policy exactly as it is.
--
-- ── WHAT IS DELIBERATELY NOT HERE ───────────────────────────────────────────
--
-- The plan matrix. `team` is 2 seats (0044 §1) and an 80-agent brokerage does
-- not fit in it. That is a PRICING decision — a brokerage tier with a real seat
-- count and a per-seat price — and inventing one inside a schema migration
-- would put a number on a contract nobody has agreed. Every function here reads
-- org_seats_allowed() and refuses to exceed it; the day the matrix grows a
-- brokerage row, all of this works unchanged.
--
-- ── IDEMPOTENCY ─────────────────────────────────────────────────────────────
--
-- `create table if not exists`, `create index if not exists`, `create or
-- replace function`, `drop trigger if exists` before `create trigger`, and one
-- backfill guarded by NOT EXISTS so a replay writes zero rows. CI applies this
-- file twice (tools/audit/run_database_regression.py).

-- ── 1. Why there is a LEDGER and not a column ───────────────────────────────
--
-- The brokerage needs to see seats AS THEY CHANGE — "who occupied which seat,
-- when, and who revoked it" — and the record has to survive the member being
-- removed. Three candidates were considered against the actual schema:
--
--   • A column on `memberships` (joined_at / removed_by). REJECTED, and not on
--     taste: removal is a DELETE (functions/team/index.ts "DELETE
--     /team/members/:id", and 0039:242/263 during account deletion), and
--     `memberships.user_id references profiles(id) on delete cascade`, so the
--     row carrying the answer is the row that disappears. A column cannot
--     record its own deletion.
--
--   • A column on `org_invites`. REJECTED: invites cover only ONE of the three
--     ways a seat gets occupied. The owner's seat is created by
--     handle_new_user() with no invite at all, and adopt_anonymous_org()
--     (0038) RE-POINTS an existing membership row rather than inserting one.
--     Two of three paths would leave no record. `revoked_at` there is also a
--     different fact — the INVITE was withdrawn, not the SEAT released.
--
--   • A dedicated append-only table. CHOSEN. It is the only shape that outlives
--     the membership, and it is written by a TRIGGER on `memberships` rather
--     than by the four functions that happen to write seats today — so a path
--     added later cannot silently escape the ledger.
--
-- DELIBERATE FK CHOICES, because they are what makes it durable:
--   • user_id carries NO foreign key. A member who deletes their account takes
--     `profiles` with them; an FK would cascade the evidence away at exactly
--     the moment a broker needs it. Same reason `actor_id` has none.
--   • member_name / member_email are SNAPSHOTS taken when the event happens,
--     so a released seat still NAMES a person whose profile is already gone.
--   • org_id DOES cascade. A deleted workspace is the tenant's own data leaving,
--     not evidence being destroyed, and it is what lets §1's writer skip the
--     insert mid-cascade instead of failing somebody's account deletion.
--
-- NOTE ON "WHICH SEAT": seats are fungible. plan_entitlements.seats is a COUNT,
-- not a set of numbered slots, so there is no seat #3 to name. The ledger
-- records which PERSON held a seat over which interval, which is the question
-- the broker is actually asking.

create table if not exists public.org_seat_events (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references public.orgs(id) on delete cascade,
  user_id      uuid not null,                 -- no FK: must outlive the profile
  member_name  text,                          -- snapshot at event time
  member_email text,                          -- snapshot at event time
  role         text,                          -- the role held at the event
  event        text not null check (event in ('occupied', 'released')),
  actor_id     uuid,                          -- who did it; null = not attested
  backfilled   boolean not null default false,
  occurred_at  timestamptz not null default now()
);

comment on table public.org_seat_events is
  'Append-only seat ledger: one row each time a membership is created, moved or '
  'removed, so a brokerage can see who held a seat over which interval and who '
  'took it back. Written by a trigger on memberships, never by hand. user_id and '
  'actor_id deliberately carry NO foreign key and member_name/member_email are '
  'snapshots, so the record still names a person whose account has since been '
  'deleted. Cross-tenant PII: service_role only, read by brokerage_overview().';
comment on column public.org_seat_events.actor_id is
  'The person who caused the change, when the route attested it (remove_org_member '
  'passes it; an occupation is attributed to the person gaining the seat, which is '
  'true of all three paths — signup, invite acceptance and adoption). NULL means '
  'the change arrived by a path that did not attest an actor, e.g. an account '
  'deletion cascade — never guess a name for it.';
comment on column public.org_seat_events.backfilled is
  'TRUE when this row was reconstructed by 0048 for a membership that predates the '
  'ledger; its occurred_at is the accepted invite''s timestamp when one exists and '
  'otherwise the ORG''s creation time — an estimate, not an observation. '
  'brokerage_overview() reports it as joined_estimated so no broker mistakes one '
  'for the other.';

create index if not exists org_seat_events_org_idx
  on public.org_seat_events (org_id, occurred_at desc);
create index if not exists org_seat_events_member_idx
  on public.org_seat_events (org_id, user_id, occurred_at);

-- RLS ON WITH NO POLICIES, exactly like org_invites (0032) and app_events
-- (0020 §2). This table names every member of a workspace and who removed
-- them; `authenticated` must not be able to select one, not even its own org's.
-- Every legitimate read goes through brokerage_overview(), which checks the
-- caller is that org's owner or admin first.
alter table public.org_seat_events enable row level security;
-- service_role is revoked FIRST and re-granted narrowly, because Supabase's
-- default privileges hand every new public table ALL to the three API roles
-- (mirrored in tests/ci-bootstrap.sql) — `grant select, insert` on its own
-- would have left the UPDATE and DELETE that arrived with the table.
revoke all on public.org_seat_events from public, anon, authenticated, service_role;
grant select, insert on public.org_seat_events to service_role;
-- No UPDATE and no DELETE, even for service_role: an append-only ledger that
-- anything can rewrite is not evidence. Rows leave only with their org.

-- ── 2. The writer, and the trigger that cannot be bypassed ──────────────────

create or replace function public.record_org_seat_event(
  p_org uuid, p_user uuid, p_role text, p_event text, p_actor uuid
) returns void
language plpgsql
security definer
set search_path = public
as $record_org_seat_event$
declare
  v_name  text;
  v_email text;
begin
  -- A workspace being deleted takes its ledger with it (org_id cascades), and
  -- 0039 deletes memberships BEFORE orgs in some paths and relies on the
  -- cascade in others. Writing here mid-cascade would either be pointless or
  -- fail the FK and abort somebody's account deletion, so: no org, no row.
  if not exists (select 1 from orgs o where o.id = p_org) then
    return;
  end if;

  select p.name, p.email into v_name, v_email from profiles p where p.id = p_user;
  if v_name is null and v_email is null then
    -- The profile is already gone — account deletion cascades profiles →
    -- memberships, so the DELETE trigger fires after the parent row went. Carry
    -- the snapshot forward from this seat's own `occupied` row, which is the
    -- whole reason the snapshot exists.
    select e.member_name, e.member_email into v_name, v_email
      from org_seat_events e
     where e.org_id = p_org and e.user_id = p_user and e.event = 'occupied'
     order by e.occurred_at desc, e.id desc
     limit 1;
  end if;

  insert into org_seat_events (org_id, user_id, member_name, member_email, role, event, actor_id)
    values (p_org, p_user, v_name, v_email, p_role, p_event, p_actor);
end;
$record_org_seat_event$;

comment on function public.record_org_seat_event(uuid, uuid, text, text, uuid) is
  'Appends one seat-ledger row, snapshotting the member''s name/e-mail (falling '
  'back to their own occupation row when the profile is already gone) and '
  'skipping silently when the org is mid-delete. Internal: the memberships '
  'trigger is the only caller.';

create or replace function public.org_seat_event_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $org_seat_event_log$
declare
  v_actor uuid;
begin
  -- Transaction-local, set only by remove_org_member(). Absent on every other
  -- path, which is recorded honestly as "not attested" rather than guessed.
  begin
    v_actor := nullif(current_setting('rendprop.seat_actor', true), '')::uuid;
  exception when others then
    v_actor := null;
  end;

  if tg_op = 'INSERT' then
    -- Every insert path — the signup trigger, accept_org_invite() — is started
    -- by the person gaining the seat, so attributing it to them is a fact.
    perform record_org_seat_event(new.org_id, new.user_id, new.role, 'occupied',
                                  coalesce(v_actor, new.user_id));
    return new;
  elsif tg_op = 'DELETE' then
    perform record_org_seat_event(old.org_id, old.user_id, old.role, 'released', v_actor);
    return old;
  else
    -- adopt_anonymous_org() (0033/0038) MOVES a membership by rewriting
    -- user_id rather than inserting a new row. That is one seat changing hands
    -- and reads as exactly that: released by the anonymous identity, occupied
    -- by the real one. A role change is not a seat change and records nothing —
    -- the current role lives on the membership row.
    if new.user_id is distinct from old.user_id or new.org_id is distinct from old.org_id then
      perform record_org_seat_event(old.org_id, old.user_id, old.role, 'released',
                                    coalesce(v_actor, new.user_id));
      perform record_org_seat_event(new.org_id, new.user_id, new.role, 'occupied',
                                    coalesce(v_actor, new.user_id));
    end if;
    return new;
  end if;
end;
$org_seat_event_log$;

-- INTERNAL, including from service_role: forging a ledger row is exactly what
-- the append-only posture above forbids, and a trigger firing does not check
-- EXECUTE on the invoking role (0005b) — org_seat_event_log() is SECURITY
-- DEFINER, so it reaches record_org_seat_event() as the owner regardless.
revoke execute on function public.record_org_seat_event(uuid, uuid, text, text, uuid)
  from public, anon, authenticated, service_role;
revoke execute on function public.org_seat_event_log()
  from public, anon, authenticated, service_role;

drop trigger if exists trg_org_seat_ledger on public.memberships;
create trigger trg_org_seat_ledger
  after insert or update or delete on public.memberships
  for each row execute function public.org_seat_event_log();

-- Backfill, guarded so a replay writes nothing. `memberships` has no created_at
-- at all, so the best available estimate is used and FLAGGED as one: the
-- accepted invite's timestamp where there is an invite, and otherwise the org's
-- creation time (correct for an owner, whose membership handle_new_user()
-- inserts in the same block as the org).
insert into public.org_seat_events
  (org_id, user_id, member_name, member_email, role, event, actor_id, occurred_at, backfilled)
select m.org_id, m.user_id, p.name, p.email, m.role, 'occupied', m.user_id,
       coalesce((select max(i.accepted_at) from public.org_invites i
                  where i.org_id = m.org_id and i.accepted_by = m.user_id
                    and i.accepted_at is not null),
                o.created_at),
       true
  from public.memberships m
  join public.orgs o on o.id = m.org_id
  left join public.profiles p on p.id = m.user_id
 where not exists (select 1 from public.org_seat_events e
                    where e.org_id = m.org_id and e.user_id = m.user_id
                      and e.event = 'occupied');

-- ── 3. Bulk invites ─────────────────────────────────────────────────────────
--
-- The code generator, in SQL, because the signature the brokerage route needs
-- (`p_emails text[]`) cannot carry eighty pre-hashed tokens without the edge
-- inventing a second invite mechanism. This is the SAME mechanism as
-- functions/team/codes.ts, digit for digit:
--   • the same 30-symbol alphabet (no 0/O/1/I/L/U — the pairs people mistype
--     reading a code aloud, plus U so no arrangement spells a word),
--   • the same 12 characters formatted XXXX-XXXX-XXXX (~59 bits),
--   • the same sha256-of-the-undashed-code stored in org_invites.token_hash, so
--     a code minted here is accepted verbatim by POST /team/accept.
-- Built-in sha256() and gen_random_uuid(), not pgcrypto — the same
-- no-extension-dependency rule 0038 §legacyOperation states.
--
-- ENTROPY: gen_random_uuid() is 16 cryptographically-random bytes with six bits
-- spent on the version/variant fields (bytes 6 and 8), so those two bytes are
-- skipped and the other fourteen are the pool. `byte % 30` carries the same
-- negligible modulo bias as the TypeScript (16 of 256 values very slightly
-- favoured, well under one bit across twelve single-use, expiring, rate-limited
-- characters).

create or replace function public.mint_org_invite_code()
returns text
language plpgsql
volatile
set search_path = public
as $mint_org_invite_code$
declare
  c_alphabet constant text      := '23456789ABCDEFGHJKMNPQRSTVWXYZ';
  c_free     constant integer[] := array[0, 1, 2, 3, 4, 5, 7, 9, 10, 11, 12, 13];
  v_bytes    bytea := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
  v_raw      text  := '';
  i          integer;
begin
  for i in 1 .. 12 loop
    v_raw := v_raw || substr(c_alphabet, (get_byte(v_bytes, c_free[i]) % 30) + 1, 1);
  end loop;
  return substr(v_raw, 1, 4) || '-' || substr(v_raw, 5, 4) || '-' || substr(v_raw, 9, 4);
end;
$mint_org_invite_code$;

comment on function public.mint_org_invite_code() is
  'One invite code in the same alphabet, length and XXXX-XXXX-XXXX form as '
  'functions/team/codes.ts generateCode(), so codes minted in the database and '
  'codes minted at the edge are the same credential. The PLAINTEXT is returned '
  'once and never stored; org_invites keeps sha256 of the undashed form.';

-- create_org_invites_bulk — eighty agents, one transaction, one org row lock.
--
-- ALL-OR-NOTHING ON SEATS, PER-ADDRESS ON EVERYTHING ELSE. Those are different
-- failures and they deserve different answers:
--   • A typo in row 14 of a pasted list must not cost the other seventy-nine
--     their invites. Bad addresses come back as an `invalid` outcome.
--   • Not enough seats is not a per-address problem — it is the plan. Issuing
--     "as many as fit" would leave the broker with a silently partial team and
--     no way to tell which half went out, so the whole call raises RP402 and
--     the transaction rolls back. The message carries how many seats the list
--     ACTUALLY needs after the already-members and already-invited are removed,
--     because "you need 3 more, not 80" is the useful sentence.
--
-- OUTCOMES, exactly:
--   issued            a fresh org_invites row; `code` is the plaintext, and
--                     this response is the only place it will ever exist.
--   already_a_member  a membership in THIS org whose profile e-mail matches.
--   already_invited   a live invite (unaccepted, unrevoked, unexpired) for this
--                     org and address — including an address listed twice in
--                     one request, whose second occurrence is exactly that.
--   invalid           not an e-mail address (same shape test as
--                     codes.ts normalizeEmail: non-empty, ≤254 chars,
--                     local@domain.tld with no whitespace).
--
-- THE E-MAIL MATCH IS BEST-EFFORT AND SAYS SO. 0032's header is right that an
-- invite is a TOKEN and not an e-mail match, because Sign in with Apple hands
-- back a private-relay address for most people — so `already_a_member` can miss
-- somebody who signed in with a relay address. It never produces a FALSE
-- positive (a matching stored address is that person), and the cost of a miss
-- is one wasted invite the seat cap still accounts for, not a wrong grant.
create or replace function public.create_org_invites_bulk(
  p_org uuid, p_actor uuid, p_emails text[], p_role text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $create_org_invites_bulk$
declare
  c_max_emails constant integer := 200;
  v_role       text;
  v_allowed    integer;
  v_used       integer;
  v_pending    integer;
  v_count      integer;
  v_issuable   integer := 0;
  v_issued     integer := 0;
  v_emails     text[]  := '{}';
  v_outcomes   text[]  := '{}';
  v_details    jsonb[] := '{}';
  v_seen       text[]  := '{}';
  v_results    jsonb   := '[]'::jsonb;
  v_email      text;
  v_code       text;
  v_row        public.org_invites%rowtype;
  v_member     uuid;
  v_invite     uuid;
  i            integer;
begin
  if p_org is null or p_actor is null then
    raise exception 'RP400: workspace and caller are required';
  end if;
  -- Belt and braces: this function is granted to service_role only and the edge
  -- resolves p_actor from the verified JWT, but if it is ever handed to
  -- `authenticated` a caller must not be able to act as somebody else. Under
  -- the service role auth.uid() is null and this is a no-op.
  if auth.uid() is not null and auth.uid() <> p_actor then
    raise exception 'RP403: the caller does not match the session';
  end if;
  if p_emails is null or cardinality(p_emails) = 0 then
    raise exception 'RP400: send at least one email address';
  end if;
  v_count := cardinality(p_emails);
  if v_count > c_max_emails then
    raise exception 'RP400: at most % addresses in one bulk invite', c_max_emails;
  end if;
  if p_role is null or p_role not in ('admin', 'agent', 'marketing') then
    raise exception 'RP400: role must be admin, agent or marketing';
  end if;

  -- The same two preconditions create_org_invite() takes, in the same order.
  perform 1 from public.profiles where id = p_actor for update;
  if not found then raise exception 'RP401: session no longer exists'; end if;
  if exists (select 1 from public.deletion_requests
             where user_id = p_actor and status in ('processing', 'pending')) then
    raise exception 'RP409: this account is being deleted';
  end if;

  -- THE lock — the same org row every seat mutation takes before it reads any
  -- count (0033). It is what makes "every invite or none" true against two
  -- managers pasting overlapping lists at the same moment.
  perform 1 from public.orgs where id = p_org and deleted_at is null for update;
  if not found then raise exception 'RP404: workspace not found'; end if;

  select role into v_role from public.memberships
   where org_id = p_org and user_id = p_actor;
  if v_role is null or v_role not in ('owner', 'admin') then
    raise exception 'RP403: only the owner or an admin can change who is on the team';
  end if;

  -- Retire already-expired invites first, exactly as create_org_invite() does:
  -- org_seats_used() already ignores them, but the one-live-invite-per-e-mail
  -- index (0032) does not, and it would block re-inviting somebody whose code
  -- ran out. No live invite is touched.
  update public.org_invites set revoked_at = now()
   where org_id = p_org and accepted_at is null and revoked_at is null
     and expires_at <= now();

  -- PASS 1 — classify every address before issuing anything, because the seat
  -- test needs to know how many will actually be issued.
  for i in 1 .. v_count loop
    v_email := nullif(lower(btrim(coalesce(p_emails[i], ''))), '');
    v_emails[i] := coalesce(v_email, btrim(coalesce(p_emails[i], '')));
    v_details[i] := '{}'::jsonb;

    if v_email is null or length(v_email) > 254
       or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]{2,}$' then
      v_outcomes[i] := 'invalid';
      v_details[i]  := jsonb_build_object('reason', 'not an email address');
    elsif v_email = any (v_seen) then
      v_outcomes[i] := 'already_invited';
      v_details[i]  := jsonb_build_object('reason', 'listed more than once in this request');
    else
      v_seen := v_seen || v_email;
      v_member := null;
      select m.user_id into v_member
        from public.memberships m
        join public.profiles p on p.id = m.user_id
       where m.org_id = p_org and lower(p.email) = v_email
       limit 1;
      if v_member is not null then
        v_outcomes[i] := 'already_a_member';
        v_details[i]  := jsonb_build_object('user_id', v_member);
      else
        v_invite := null;
        select i2.id into v_invite from public.org_invites i2
         where i2.org_id = p_org and lower(i2.email) = v_email
           and i2.accepted_at is null and i2.revoked_at is null
           and i2.expires_at > now()
         limit 1;
        if v_invite is not null then
          v_outcomes[i] := 'already_invited';
          v_details[i]  := jsonb_build_object('invite_id', v_invite);
        else
          v_outcomes[i] := 'issue';
          v_issuable := v_issuable + 1;
        end if;
      end if;
    end if;
  end loop;

  v_allowed := public.org_seats_allowed(p_org);
  if v_allowed is null or v_allowed < 1 then
    raise exception 'RP503: this plan is unavailable right now';
  end if;
  v_used := public.org_seats_used(p_org);
  -- A list of people who are ALL already on the team needs no seats and must
  -- not be refused just because the org is already full.
  if v_issuable > 0 and v_used + v_issuable > v_allowed then
    raise exception
      'RP402: % of these need a seat and only % of your % are free — nobody was invited',
      v_issuable, greatest(v_allowed - v_used, 0), v_allowed;
  end if;

  -- PASS 2 — issue. Any failure here (including the astronomically unlikely
  -- token_hash collision) aborts the transaction, which is the contract.
  for i in 1 .. v_count loop
    if v_outcomes[i] = 'issue' then
      v_code := public.mint_org_invite_code();
      insert into public.org_invites (org_id, email, role, token_hash, invited_by)
        values (p_org, v_emails[i], p_role,
                encode(sha256(convert_to(replace(v_code, '-', ''), 'UTF8')), 'hex'),
                p_actor)
        returning * into v_row;
      v_outcomes[i] := 'issued';
      v_issued := v_issued + 1;
      -- The plaintext code leaves the database HERE and nowhere else, ever.
      v_details[i] := jsonb_build_object(
        'id', v_row.id, 'code', v_code,
        'created_at', v_row.created_at, 'expires_at', v_row.expires_at);
    end if;
  end loop;

  for i in 1 .. v_count loop
    v_results := v_results || jsonb_build_array(
      jsonb_build_object('email', v_emails[i], 'outcome', v_outcomes[i]) || v_details[i]);
  end loop;

  select count(*) into v_pending from public.org_invites i3
   where i3.org_id = p_org and i3.accepted_at is null and i3.revoked_at is null
     and i3.expires_at > now();

  return jsonb_build_object(
    'ok', true,
    'org_id', p_org,
    'role', p_role,
    'requested', v_count,
    'issued', v_issued,
    'results', v_results,
    'seats', jsonb_build_object(
      'used', public.org_seats_used(p_org),
      'allowed', v_allowed,
      'pending', v_pending));
end;
$create_org_invites_bulk$;

comment on function public.create_org_invites_bulk(uuid, uuid, text[], text) is
  'Invites a whole list in ONE transaction under the same org row lock every '
  'seat mutation takes. Per-address outcomes (issued / already_a_member / '
  'already_invited / invalid) so one typo costs one address, but ALL-OR-NOTHING '
  'on seats: if the list needs more seats than org_seats_allowed() leaves free '
  'it raises RP402 naming how many are actually needed and issues nothing. '
  'Reuses org_invites and the codes.ts code/hash form exactly. Owner/admin of '
  'the org only; service_role only.';

-- ── 4. Removal, with the actor recorded ─────────────────────────────────────
--
-- The ledger's whole point is that it can say WHO revoked a seat, and a
-- PostgREST DELETE cannot tell it: the service role does the delete and the
-- acting person's identity never reaches the database. So removal becomes an
-- RPC like every other seat mutation, taking the same org row lock and
-- re-checking the same rules the edge checks (which stay where they are — they
-- give a better message; this is the authoritative copy, exactly the split
-- create_org_invite() already uses).
create or replace function public.remove_org_member(
  p_org uuid, p_actor uuid, p_user uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $remove_org_member$
declare
  v_actor_role  text;
  v_target_role text;
begin
  if p_org is null or p_actor is null or p_user is null then
    raise exception 'RP400: workspace, caller and member are required';
  end if;
  if auth.uid() is not null and auth.uid() <> p_actor then
    raise exception 'RP403: the caller does not match the session';
  end if;
  if p_actor = p_user then
    raise exception 'RP400: you can''t remove yourself from your own team';
  end if;

  perform 1 from public.orgs where id = p_org and deleted_at is null for update;
  if not found then raise exception 'RP404: workspace not found'; end if;

  select role into v_actor_role from public.memberships
   where org_id = p_org and user_id = p_actor;
  if v_actor_role is null or v_actor_role not in ('owner', 'admin') then
    raise exception 'RP403: only the owner or an admin can change who is on the team';
  end if;

  select role into v_target_role from public.memberships
   where org_id = p_org and user_id = p_user for update;
  if v_target_role is null then
    raise exception 'RP404: that person isn''t on this team';
  end if;
  if v_target_role = 'owner' then
    raise exception 'RP403: the owner can''t be removed from their own team';
  end if;
  -- An admin may not remove another admin — only the owner may.
  if v_target_role = 'admin' and v_actor_role <> 'owner' then
    raise exception 'RP403: only the owner can remove an admin';
  end if;

  -- Transaction-local, read by the ledger trigger and cleared straight after so
  -- no later statement in the same transaction inherits an actor.
  perform set_config('rendprop.seat_actor', p_actor::text, true);
  delete from public.memberships where org_id = p_org and user_id = p_user;
  perform set_config('rendprop.seat_actor', '', true);

  -- Their listings and tours stay with the ORG, which is what the team paid for.
  return jsonb_build_object(
    'ok', true, 'org_id', p_org, 'user_id', p_user, 'role', v_target_role,
    'seats', jsonb_build_object(
      'used', public.org_seats_used(p_org),
      'allowed', public.org_seats_allowed(p_org)));
end;
$remove_org_member$;

comment on function public.remove_org_member(uuid, uuid, uuid) is
  'Removes one member under the org row lock, re-checking the same rules the '
  'team route checks (not yourself, never the owner, an admin only by the owner) '
  'and recording WHO did it in the seat ledger — which a PostgREST delete on the '
  'service role cannot. Owner/admin only; service_role only.';

-- ── 5. brokerage_overview() — the screen a broker is actually buying ────────
--
-- EVERY NUMBER, DEFINED. A number whose definition does not fit on one line is
-- not in this function.
--
-- WINDOW. `p_window` clamped to 1…365 days, same as admin_cohorts(). `from` =
-- now() − window, `to` = now(). Every "…_in_window" number below is
-- [from, to]; every "…_ever" number is all of time up to `to`.
--
-- SEATS.
--   seats.used      org_seats_used() — memberships + LIVE invites (0032). A
--                   pending invite holds a seat; that is the existing rule and
--                   this screen does not invent a second one.
--   seats.allowed   org_seats_allowed() — the CURRENT effective plan's count.
--   seats.pending   the live invites inside `used`: unaccepted, unrevoked and
--                   not yet expired. Shown apart so "used" is explicable.
--
-- PER MEMBER — one entry for every row of `memberships` in this org, never
-- filtered, so a member who has done nothing still appears.
--   user_id         memberships.user_id.
--   name            profiles.name, else profiles.email, else 'member <8 hex>'.
--                   There is no per-user handle in this schema (orgs.handle is
--                   the WORKSPACE's portfolio slug), so this is the display
--                   name the team screen already shows.
--   email           profiles.email as stored — frequently an Apple private
--                   relay address, which is not a mistake.
--   role            memberships.role.
--   joined_at       the EARLIEST `occupied` row for this member in this org.
--   joined_estimated  TRUE when that row is a 0048 backfill: its timestamp is
--                   the accepted invite's time, or failing that the org's
--                   creation time. An estimate, flagged as one.
--   joined_via      'invite' when any org_invites row in this org has
--                   accepted_by = this member; 'direct' otherwise (the owner's
--                   own workspace, or an adopted anonymous one).
--   listings        listings with org_id = this org, agent_id = this member and
--                   deleted_at IS NULL. Lifetime, not windowed — "how big is
--                   her book" is not a 30-day question.
--   listings_including_deleted  the same without the deleted_at filter.
--   tours_published a RENDER with published_at inside the window, reached
--                   through listings.agent_id — `renders` has no org or agent
--                   column, so a tour belongs to whoever the listing belongs
--                   to. Counts renders, not listings: publishing the same home
--                   twice is two published tours. Includes renders on
--                   soft-deleted listings — the tour WAS published — and
--                   excludes renders whose published_at was cleared by account
--                   deletion (0039), because those are no longer published.
--   tours_published_ever   the same with no lower bound.
--   ai_assets_published    media_provenance rows for THIS org with
--                   altered_key IS NOT NULL (the altered result reached the
--                   public bucket, i.e. it was published — a row without one is
--                   a generation that never shipped) and created_at inside the
--                   window, attributed through listings.agent_id where the
--                   listing is in the same org.
--   ai_assets_published_ever  the same with no lower bound.
--   last_activity_at  the latest of: their newest listing's created_at, their
--                   newest published render's published_at, and their newest
--                   attributed provenance row's created_at — all in this org.
--                   NOT app_events: those are device-scoped, purged at 180 days
--                   (0022) and cannot be tied to a person. NULL means this
--                   member has never done any of the three.
--   published_nothing  tours_published = 0. The per-member form of the count
--                   below, so a UI does not have to recompute it.
--
-- ORG TOTALS. Computed org-wide, NOT summed from the member rows, because work
-- can belong to an agent who has since been removed and because a provenance
-- row can carry no listing at all.
--   totals.members          rows in memberships for this org.
--   totals.members_published_nothing       members with tours_published = 0 in
--                           the window. THE number a broker opens this for.
--   totals.members_published_nothing_ever  members who have never published.
--   totals.listings / listings_including_deleted   as above, org-wide.
--   totals.tours_published / tours_published_ever  as above, org-wide.
--   totals.ai_assets_published             as above, org-wide, INCLUDING rows
--                           that cannot be attributed to a member.
--   totals.ai_assets_unattributed          the subset of that with no listing in
--                           this org to attribute through. Published rather than
--                           hidden, because it is exactly the gap between the
--                           org total and the sum of the member rows.
--
-- COST: one pass per measure over this org's listings/renders/provenance. A
-- brokerage console read, not a hot path.
create or replace function public.brokerage_overview(
  p_org uuid, p_actor uuid, p_window interval default interval '30 days'
) returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $brokerage_overview$
declare
  c_iso     constant text := 'YYYY-MM-DD"T"HH24:MI:SS"Z"';
  v_role    text;
  v_window  interval;
  v_now     timestamptz := now();
  v_from    timestamptz;
  v_members jsonb;
  v_counts  jsonb;
  v_totals  jsonb;
  v_used    integer;
  v_allowed integer;
  v_pending integer;
begin
  if p_org is null or p_actor is null then
    raise exception 'RP400: workspace and caller are required';
  end if;
  if auth.uid() is not null and auth.uid() <> p_actor then
    raise exception 'RP403: the caller does not match the session';
  end if;

  perform 1 from orgs where id = p_org and deleted_at is null;
  if not found then raise exception 'RP404: workspace not found'; end if;

  -- The gate is the CALLER'S ROLE IN THIS ORG, not "is the caller privileged":
  -- a broker reaches this through the app, and an agent on the same team must
  -- not be able to read what everybody else has published.
  select role into v_role from memberships where org_id = p_org and user_id = p_actor;
  if v_role is null or v_role not in ('owner', 'admin') then
    raise exception 'RP403: only the owner or an admin can see the team overview';
  end if;

  v_window := coalesce(p_window, interval '30 days');
  if v_window < interval '1 day'    then v_window := interval '1 day';    end if;
  if v_window > interval '365 days' then v_window := interval '365 days'; end if;
  v_from := v_now - v_window;

  v_used    := org_seats_used(p_org);
  v_allowed := org_seats_allowed(p_org);
  select count(*) into v_pending from org_invites i
   where i.org_id = p_org and i.accepted_at is null and i.revoked_at is null
     and i.expires_at > v_now;

  with member as (
    select m.user_id, m.role, p.name as pname, p.email as pemail
      from memberships m
      left join profiles p on p.id = m.user_id
     where m.org_id = p_org
  ), seat as (
    select distinct on (e.user_id)
           e.user_id, e.occurred_at as joined_at, e.backfilled
      from org_seat_events e
     where e.org_id = p_org and e.event = 'occupied'
     order by e.user_id, e.occurred_at asc, e.id asc
  ), book as (
    select li.agent_id,
           count(*) filter (where li.deleted_at is null) as listings_live,
           count(*)                                      as listings_all,
           max(li.created_at)                            as last_listing
      from listings li
     where li.org_id = p_org
     group by li.agent_id
  ), tour as (
    select li.agent_id,
           count(*) filter (where r.published_at >= v_from) as tours_window,
           count(*)                                         as tours_ever,
           max(r.published_at)                              as last_tour
      from renders r
      join listings li on li.id = r.listing_id and li.org_id = p_org
     where r.published_at is not null and r.published_at <= v_now
     group by li.agent_id
  ), ai as (
    select li.agent_id,
           count(*) filter (where mp.created_at >= v_from) as ai_window,
           count(*)                                        as ai_ever,
           max(mp.created_at)                              as last_ai
      from media_provenance mp
      join listings li on li.id = mp.listing_id and li.org_id = mp.org_id
     where mp.org_id = p_org and mp.altered_key is not null and mp.created_at <= v_now
     group by li.agent_id
  ), sheet as (
    select m.user_id,
           m.role,
           coalesce(nullif(btrim(m.pname), ''), nullif(btrim(m.pemail), ''),
                    'member ' || left(m.user_id::text, 8)) as display_name,
           m.pemail,
           s.joined_at,
           coalesce(s.backfilled, false)                   as joined_estimated,
           exists (select 1 from org_invites i2
                    where i2.org_id = p_org and i2.accepted_by = m.user_id
                      and i2.accepted_at is not null)       as via_invite,
           coalesce(b.listings_live, 0)                     as listings_live,
           coalesce(b.listings_all, 0)                      as listings_all,
           coalesce(t.tours_window, 0)                      as tours_window,
           coalesce(t.tours_ever, 0)                        as tours_ever,
           coalesce(a.ai_window, 0)                         as ai_window,
           coalesce(a.ai_ever, 0)                           as ai_ever,
           greatest(b.last_listing, t.last_tour, a.last_ai) as last_activity
      from member m
      left join seat s on s.user_id = m.user_id
      left join book b on b.agent_id = m.user_id
      left join tour t on t.agent_id = m.user_id
      left join ai   a on a.agent_id = m.user_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
             'user_id',                    x.user_id,
             'name',                       x.display_name,
             'email',                      x.pemail,
             'role',                       x.role,
             'joined_at',                  to_char(x.joined_at at time zone 'UTC', c_iso),
             'joined_estimated',           x.joined_estimated,
             'joined_via',                 case when x.via_invite then 'invite' else 'direct' end,
             'listings',                   x.listings_live,
             'listings_including_deleted', x.listings_all,
             'tours_published',            x.tours_window,
             'tours_published_ever',       x.tours_ever,
             'ai_assets_published',        x.ai_window,
             'ai_assets_published_ever',   x.ai_ever,
             'last_activity_at',           to_char(x.last_activity at time zone 'UTC', c_iso),
             'published_nothing',          x.tours_window = 0)
           order by x.tours_window desc, lower(x.display_name), x.user_id), '[]'::jsonb),
         jsonb_build_object(
           'members',                       count(*),
           'members_published_nothing',     count(*) filter (where x.tours_window = 0),
           'members_published_nothing_ever',count(*) filter (where x.tours_ever = 0))
    into v_members, v_counts
    from sheet x;

  select jsonb_build_object(
    'listings', (select count(*) from listings li
                  where li.org_id = p_org and li.deleted_at is null),
    'listings_including_deleted', (select count(*) from listings li where li.org_id = p_org),
    'tours_published', (select count(*) from renders r
                          join listings li on li.id = r.listing_id
                         where li.org_id = p_org
                           and r.published_at >= v_from and r.published_at <= v_now),
    'tours_published_ever', (select count(*) from renders r
                          join listings li on li.id = r.listing_id
                         where li.org_id = p_org
                           and r.published_at is not null and r.published_at <= v_now),
    'ai_assets_published', (select count(*) from media_provenance mp
                         where mp.org_id = p_org and mp.altered_key is not null
                           and mp.created_at >= v_from and mp.created_at <= v_now),
    'ai_assets_published_ever', (select count(*) from media_provenance mp
                         where mp.org_id = p_org and mp.altered_key is not null
                           and mp.created_at <= v_now),
    'ai_assets_unattributed', (select count(*) from media_provenance mp
                         where mp.org_id = p_org and mp.altered_key is not null
                           and mp.created_at >= v_from and mp.created_at <= v_now
                           and not exists (select 1 from listings li
                                            where li.id = mp.listing_id
                                              and li.org_id = mp.org_id)))
    into v_totals;

  return jsonb_build_object(
    'generated_at',   to_char(v_now  at time zone 'UTC', c_iso),
    'org_id',         p_org,
    'org_name',       (select o.name from orgs o where o.id = p_org),
    'plan',           effective_plan(p_org),
    'from',           to_char(v_from at time zone 'UTC', c_iso),
    'to',             to_char(v_now  at time zone 'UTC', c_iso),
    'window_seconds', floor(extract(epoch from v_window))::bigint,
    'seats', jsonb_build_object('used', v_used, 'allowed', v_allowed, 'pending', v_pending),
    'totals', v_counts || v_totals,
    'members', v_members);
end;
$brokerage_overview$;

comment on function public.brokerage_overview(uuid, uuid, interval) is
  'One screen for a brokerage: seats used/allowed/pending, and for every member '
  'their name, role, joined date, listings, tours published in the window, '
  'AI-altered assets published in the window and last activity — plus org totals '
  'and how many members published nothing. Tours and AI assets reach a person '
  'through listings.agent_id, because renders and media_provenance carry no '
  'agent column. Window clamped to 1…365 days. The gate is the CALLER''S role '
  'in that org (owner or admin), not the connection''s: a broker calls this '
  'through the app. service_role only.';

-- ── 6. compliance_audit() — the whole brokerage's AI record ─────────────────
--
-- What GET /me/compliance exports today (media_provenance for the workspace:
-- what was altered, by which model, against which unaltered original, and the
-- exact disclosure sentence the public tour prints) — for EVERY member, with
-- the agent named on each row. The question it exists to answer is a compliance
-- officer's: "show me every AI-altered image we published in March, and prove
-- the disclosure ran."
--
-- WHAT MAKES IT NEED A DEFINER, PRECISELY. Not the provenance: 0012 §1 already
-- gives every org member SELECT on the whole org's media_provenance
-- (`is_org_member(org_id)`), so the rows were always readable. It is the AGENT
-- COLUMN — `profiles` has exactly one policy, `id = auth.uid()` (0001:207), so
-- no query run as the broker can name anybody but the broker. This function
-- reads profiles as the definer for owners and admins of one org. NO EXISTING
-- POLICY IS CHANGED, ADDED TO OR DROPPED by this migration.
--
-- ROW SHAPE mirrors the /me/compliance row exactly, so one renderer serves
-- both, and returns R2 KEYS rather than URLs: publicR2Url() lives in the edge
-- and stays the single place a key becomes a link.
--
-- prompt_summary IS included, as it is today: the org's own audit export may
-- see it (the public tour never does). It never leaves the org.
--
-- BOUNDS. p_from inclusive, p_to exclusive, either may be null for unbounded —
-- the same convention the route already documents. At most 5000 rows, the same
-- ceiling as COMPLIANCE_MAX_LIMIT in functions/me/index.ts, with `truncated`
-- reported honestly rather than a short answer pretending to be complete.
create or replace function public.compliance_audit(
  p_org uuid, p_actor uuid, p_from timestamptz, p_to timestamptz
) returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $compliance_audit$
declare
  c_iso  constant text    := 'YYYY-MM-DD"T"HH24:MI:SS"Z"';
  c_max  constant integer := 5000;
  v_role text;
  v_rows jsonb;
  v_seen bigint;
begin
  if p_org is null or p_actor is null then
    raise exception 'RP400: workspace and caller are required';
  end if;
  if auth.uid() is not null and auth.uid() <> p_actor then
    raise exception 'RP403: the caller does not match the session';
  end if;

  perform 1 from orgs where id = p_org and deleted_at is null;
  if not found then raise exception 'RP404: workspace not found'; end if;

  select role into v_role from memberships where org_id = p_org and user_id = p_actor;
  if v_role is null or v_role not in ('owner', 'admin') then
    raise exception 'RP403: only the owner or an admin can export the team''s AI record';
  end if;

  with src as (
    select mp.id, mp.created_at, mp.listing_id, mp.render_id, mp.kind, mp.label,
           mp.edit, mp.style, mp.model_id, mp.prompt_summary, mp.disclosure,
           mp.original_key, mp.altered_key,
           li.address as listing_address, li.space_type, li.agent_id
      from media_provenance mp
      left join listings li on li.id = mp.listing_id and li.org_id = mp.org_id
     where mp.org_id = p_org
       and (p_from is null or mp.created_at >= p_from)
       and (p_to   is null or mp.created_at <  p_to)
     order by mp.created_at desc, mp.id desc
     limit c_max + 1
  ), numbered as (
    select s.*, row_number() over (order by s.created_at desc, s.id desc) as rn
      from src s
  )
  select coalesce(jsonb_agg(jsonb_build_object(
             'id',              n.id,
             'created_at',      to_char(n.created_at at time zone 'UTC', c_iso),
             'listing_id',      n.listing_id,
             'listing_address', n.listing_address,
             'space_type',      n.space_type,
             'render_id',       n.render_id,
             'kind',            n.kind,
             'label',           n.label,
             'edit',            n.edit,
             'style',           n.style,
             'model_id',        n.model_id,
             'prompt_summary',  n.prompt_summary,
             'disclosure',      n.disclosure,
             'original_key',    n.original_key,
             'altered_key',     n.altered_key,
             'agent_id',        n.agent_id,
             'agent_name',      case when n.agent_id is null then null else
                                  coalesce(nullif(btrim(p.name), ''),
                                           nullif(btrim(p.email), ''),
                                           'member ' || left(n.agent_id::text, 8)) end,
             'agent_email',     p.email)
           order by n.rn) filter (where n.rn <= c_max), '[]'::jsonb),
         count(*)
    into v_rows, v_seen
    from numbered n
    left join profiles p on p.id = n.agent_id;

  return jsonb_build_object(
    'org_id',    p_org,
    'scope',     'org',
    'from',      to_char(p_from at time zone 'UTC', c_iso),
    'to',        to_char(p_to   at time zone 'UTC', c_iso),
    'count',     least(v_seen, c_max),
    'truncated', v_seen > c_max,
    'max_rows',  c_max,
    'rows',      v_rows);
end;
$compliance_audit$;

comment on function public.compliance_audit(uuid, uuid, timestamptz, timestamptz) is
  'The whole org''s AI-disclosure record across every member, one row per '
  'media_provenance entry with the agent named — what GET /me/compliance exports '
  'per workspace, plus the profiles join that the self-only profiles policy makes '
  'impossible for a broker to do themselves. Adds no policy and weakens none: '
  'media_provenance was already org-readable by members (0012). p_from inclusive, '
  'p_to exclusive, either may be null; at most 5000 rows with `truncated` told '
  'straight. Owner/admin only; service_role only.';

-- ── 7. Grants ───────────────────────────────────────────────────────────────
--
-- `create function` carries an implicit PUBLIC EXECUTE, and revoking from
-- `anon` alone does NOT remove it — the bug Astra caught in 0032 and 0033 §Grants
-- fixed. Every new function is revoked from public, anon AND authenticated.
--
-- All four callable functions take an ACTOR and decide on that actor's role in
-- the org. That is only trustworthy while the caller cannot choose the actor,
-- so EXECUTE stays with service_role and the edge resolves the actor from the
-- verified JWT. (The auth.uid() check inside each is the second lock, for the
-- day somebody widens one of these grants.)

revoke execute on function public.mint_org_invite_code()
  from public, anon, authenticated, service_role;
revoke execute on function public.create_org_invites_bulk(uuid, uuid, text[], text)
  from public, anon, authenticated;
revoke execute on function public.remove_org_member(uuid, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.brokerage_overview(uuid, uuid, interval) from public, anon, authenticated;
revoke execute on function public.compliance_audit(uuid, uuid, timestamptz, timestamptz)
  from public, anon, authenticated;

grant execute on function public.create_org_invites_bulk(uuid, uuid, text[], text) to service_role;
grant execute on function public.remove_org_member(uuid, uuid, uuid) to service_role;
grant execute on function public.brokerage_overview(uuid, uuid, interval) to service_role;
grant execute on function public.compliance_audit(uuid, uuid, timestamptz, timestamptz) to service_role;
