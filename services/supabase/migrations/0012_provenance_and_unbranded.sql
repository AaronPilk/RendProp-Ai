-- 0012: AI media provenance + the disclosure/audit spine (compliance wave, 2026-09-04).
--
-- Why this exists (research/competitive-brief.md §5):
--   • California AB 723 (in force 1 Jan 2026) requires DISCLOSURE of digitally
--     altered listing imagery AND access to the ORIGINAL unaltered versions.
--     Up to $2,500 per violation, plus license risk. → `disclosure` (public
--     sentence) + `original_key` (the untouched source, published to the PUBLIC
--     renders bucket so "access to the original" is a real link).
--   • NorthstarMLS (10 Jul 2026): altered images must be identified, AND every
--     altered room needs at least one unaltered "Before" image. → the
--     original_key / altered_key pair per altered asset.
--   • Wisconsin 2025 Act 69 (1 Jan 2027) extends disclosure to generated VIDEO
--     (reels, animations). → kind in ('aerial','reel').
--   • HousingWire's disclosure test names simulated camera movement, with the
--     recommended language "Drone-style movement is simulated. No drone footage
--     was captured." → that exact sentence is what kind='aerial' discloses.
--   • HUD (May 2024) guidance on AI in housing advertising → never render
--     people or religious/cultural objects. Enforced in the edge functions'
--     prompts + denylist (_shared/fairhousing.ts); this table is the record of
--     what was generated.
--
-- Design notes:
--   • The DISCLOSURE SENTENCE IS SERVER-DERIVED from `kind` (+ `edit`), exactly
--     as `renders.staged` is derived from the job's enhancements in 0008/0011:
--     the caller gets no say in what its own listing discloses. The helper is
--     public.provenance_disclosure(kind, edit) so there is ONE source of truth
--     for the copy — the edge functions never send a sentence.
--   • Media keys are likewise SERVER-DERIVED: record_provenance /
--     set_provenance_media take capture_asset UUIDs and resolve the R2 key
--     themselves, after checking the asset belongs to the same listing, is
--     uploaded, and lives in the PUBLIC renders bucket. A free-text key would
--     let a caller point "View original" at any object in the bucket (this is
--     the same anti-spoof rule publish_render applies to the poster).
--   • RLS: org members SELECT; every write goes through the SECURITY DEFINER
--     RPCs (owner/admin/agent — marketing is read-only, as everywhere else).
--   • `renders.unbranded_url` is deliberately NOT added: the tour host derives
--     /u/<slug> from the slug, and a stored URL would be a second truth to keep
--     in sync (SPEC W2-B1).
--
-- Idempotent: every statement guards itself, so this file is safe to replay on
-- a database where it already ran and on a fresh database built from 0001.
-- Function signatures that CHANGE drop only their OLD signature first (a second
-- overload would make PostgREST RPC calls ambiguous).

-- ── 1. media_provenance ─────────────────────────────────────────────────────

create table if not exists public.media_provenance (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.orgs(id) on delete cascade,
  listing_id uuid references public.listings(id) on delete cascade,
  render_id uuid references public.renders(id) on delete set null,
  kind text not null check (kind in ('photo_edit','virtual_stage','declutter','aerial','reel','other')),
  label text,                     -- "Living room", "Aerial intro"
  model_id text,                  -- fal/gemini model string (internal, never public)
  edit text,                      -- twilight|sky|lawn|declutter|stage|custom
  style text,
  prompt_summary text,            -- short, no PII — INTERNAL ONLY, never public
  original_key text,              -- R2 key of the UNALTERED source, when we have it
  altered_key text,               -- R2 key of the result, when published
  disclosure text not null,       -- the sentence shown publicly (server-derived)
  created_at timestamptz not null default now()
);

comment on table public.media_provenance is
  'One row per AI-altered or AI-generated listing asset: what was changed, by which model, the unaltered original, and the public disclosure sentence. This is the broker-exportable audit log behind CA AB 723 / NorthstarMLS / WI Act 69 (GET /me/compliance).';
comment on column public.media_provenance.disclosure is
  'Server-derived from kind (+ edit) by provenance_disclosure(); shown publicly on /f/ and /u/. Callers cannot supply it.';
comment on column public.media_provenance.prompt_summary is
  'Internal only. NEVER returned by the public tours function — the public payload is the disclosure sentence, the label and the media URLs.';
comment on column public.media_provenance.original_key is
  'R2 key of the untouched source in the PUBLIC renders bucket (uploads role:"original"), so CA AB 723 "access to the original" is a real link.';

create index if not exists idx_provenance_listing on public.media_provenance (listing_id, created_at desc);
create index if not exists idx_provenance_org     on public.media_provenance (org_id, created_at desc);

-- RLS. (The platform's `ensure_rls` event trigger enables it on create; this is
-- belt-and-suspenders for a database where that trigger is absent.)
alter table public.media_provenance enable row level security;

drop policy if exists "org provenance read" on public.media_provenance;
create policy "org provenance read" on public.media_provenance for select
  using (public.is_org_member(org_id));

-- Supabase's default privileges hand every new public table to anon AND
-- authenticated, so both are cut back explicitly. anon loses the table entirely
-- (the PUBLIC tour reads provenance through the service-role client, which
-- returns only the disclosure/label/URL subset); members read via RLS; writes
-- are definer/service-role only, exactly like renders and render_jobs (0007).
revoke all on public.media_provenance from anon;
grant  select on public.media_provenance to authenticated;
revoke insert, update, delete on public.media_provenance from authenticated;
grant  select, insert, update, delete on public.media_provenance to service_role;

-- ── 2. provenance_disclosure(): the ONE source of the public sentence ───────
-- California AB 723 wants a disclosure a consumer can actually understand, and
-- NorthstarMLS wants altered media identified. HousingWire's recommended
-- simulated-movement wording is reproduced verbatim for aerials.

create or replace function public.provenance_disclosure(p_kind text, p_edit text default null)
returns text
language sql
immutable
set search_path = public
as $fn$
  select case
    when p_kind = 'virtual_stage' then
      'This photo was virtually staged with AI: furniture and decor were digitally added or restyled. The architecture, dimensions, and views are unchanged.'
    when p_kind = 'declutter' then
      'This photo was digitally decluttered with AI: clutter and personal items were removed. The architecture, dimensions, and views are unchanged.'
    when p_kind = 'aerial' then
      'Drone-style movement is simulated. No drone footage was captured. This establishing shot was generated by AI.'
    when p_kind = 'reel' then
      'This clip was generated by AI from a still photo of the property. The motion is simulated; no video of this view was captured.'
    when p_kind = 'photo_edit' and lower(coalesce(p_edit, '')) = 'twilight' then
      'This photo was digitally altered with AI: the sky and lighting were changed to simulate dusk. The property itself is unchanged.'
    when p_kind = 'photo_edit' and lower(coalesce(p_edit, '')) = 'sky' then
      'This photo was digitally altered with AI: the sky was replaced. The property itself is unchanged.'
    when p_kind = 'photo_edit' and lower(coalesce(p_edit, '')) = 'lawn' then
      'This photo was digitally altered with AI: the lawn and landscaping were digitally repaired. The property itself is unchanged.'
    when p_kind = 'photo_edit' then
      'This photo was digitally altered with AI. The architecture, dimensions, and views are unchanged.'
    else
      'This media was digitally altered or generated with AI.'
  end;
$fn$;

revoke execute on function public.provenance_disclosure(text, text) from public, anon;
grant  execute on function public.provenance_disclosure(text, text) to authenticated, service_role;

-- ── 3. Internal helper: resolve a capture asset to a PUBLIC R2 key ──────────
-- The asset must belong to the given listing, be uploaded, be a photo, and live
-- in the public `renders` bucket — otherwise the "View original" link would
-- either 404 or point at somebody else's object. Returns null for a null input.
-- Internal: callable only by the owner (the definer functions run as it).

create or replace function public.provenance_asset_key(p_asset uuid, p_listing uuid)
returns text
language plpgsql
set search_path = public
as $fn$
declare v capture_assets;
begin
  if p_asset is null then return null; end if;
  select a.* into v from capture_assets a where a.id = p_asset;
  if not found then
    raise exception 'RP400: media asset not found';
  end if;
  if v.listing_id is distinct from p_listing then
    raise exception 'RP400: media asset belongs to a different listing';
  end if;
  if coalesce(v.bucket, 'uploads') <> 'renders' then
    raise exception 'RP400: media asset must be an uploaded role:"original"/"render" photo in the public renders bucket';
  end if;
  if v.uploaded is not true then
    raise exception 'RP409: media asset upload is not complete';
  end if;
  if v.kind <> 'photo' then
    raise exception 'RP400: media asset must be a photo';
  end if;
  return v.storage_key;
end;
$fn$;

revoke execute on function public.provenance_asset_key(uuid, uuid) from public, anon, authenticated, service_role;

-- ── 4. record_provenance(): the write path the edge functions use ───────────
-- Called by ai-photo (after a successful edit) and ai-video (at submit time for
-- aerial / reel), as the CALLER — same owner/admin/agent gate every other RPC
-- uses, so a marketing member cannot mint disclosure rows.

drop function if exists public.record_provenance(uuid, text, text, text, text, text, text, uuid, uuid, uuid);

create or replace function public.record_provenance(
  p_listing uuid,
  p_kind text,
  p_label text default null,
  p_model_id text default null,
  p_edit text default null,
  p_style text default null,
  p_prompt_summary text default null,
  p_original_asset uuid default null,
  p_altered_asset uuid default null,
  p_render uuid default null
) returns public.media_provenance
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_org uuid;
  v_role text;
  v_kind text := lower(trim(coalesce(p_kind, '')));
  v_label text := nullif(left(regexp_replace(coalesce(p_label, ''), '[\r\n\t]+', ' ', 'g'), 80), '');
  v_edit text := nullif(lower(left(trim(coalesce(p_edit, '')), 40)), '');
  v_style text := nullif(lower(left(trim(coalesce(p_style, '')), 40)), '');
  v_model text := nullif(left(trim(coalesce(p_model_id, '')), 120), '');
  v_summary text := nullif(left(regexp_replace(coalesce(p_prompt_summary, ''), '[\r\n\t]+', ' ', 'g'), 300), '');
  v_original text;
  v_altered text;
  v_render uuid := null;
  v_count integer;
  v_row media_provenance;
begin
  if v_kind not in ('photo_edit','virtual_stage','declutter','aerial','reel','other') then
    raise exception 'RP400: kind must be photo_edit, virtual_stage, declutter, aerial, reel, or other';
  end if;

  select l.org_id into v_org from listings l where l.id = p_listing and l.deleted_at is null;
  if v_org is null then raise exception 'RP404: listing not found'; end if;

  v_role := org_role(v_org);
  if v_role is null then raise exception 'RP403: not a member of this workspace'; end if;
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit recording AI provenance';
  end if;

  -- Server-derived keys (see header). Either may be null at record time: the
  -- altered result is usually uploaded afterwards → set_provenance_media().
  v_original := provenance_asset_key(p_original_asset, p_listing);
  v_altered  := provenance_asset_key(p_altered_asset, p_listing);

  if p_render is not null then
    select r.id into v_render from renders r where r.id = p_render and r.listing_id = p_listing;
    if v_render is null then raise exception 'RP400: render_id does not belong to this listing'; end if;
  end if;

  -- A double-tapped edit must not print the same disclosure line twice on the
  -- public tour. An identical row recorded in the last minute is returned as-is.
  select mp.* into v_row from media_provenance mp
   where mp.listing_id = p_listing
     and mp.kind = v_kind
     and mp.created_at > now() - interval '60 seconds'
     and coalesce(mp.edit, '') = coalesce(v_edit, '')
     and coalesce(mp.label, '') = coalesce(v_label, '')
     and coalesce(mp.original_key, '') = coalesce(v_original, '')
   order by mp.created_at desc
   limit 1;
  if found then return v_row; end if;

  -- Bounded: a runaway client loop must not grow one listing's audit log
  -- without limit (the tour caps its disclosure list at 40 anyway).
  select count(*) into v_count from media_provenance mp where mp.listing_id = p_listing;
  if v_count >= 500 then
    raise exception 'RP429: this listing already has % provenance records — delete the listing or contact support', v_count;
  end if;

  insert into media_provenance (
    org_id, listing_id, render_id, kind, label, model_id, edit, style,
    prompt_summary, original_key, altered_key, disclosure)
  values (
    v_org, p_listing, v_render, v_kind, v_label, v_model, v_edit, v_style,
    v_summary, v_original, v_altered, provenance_disclosure(v_kind, v_edit))
  returning * into v_row;
  return v_row;
end;
$fn$;

revoke execute on function public.record_provenance(uuid, text, text, text, text, text, text, uuid, uuid, uuid) from public, anon;
grant  execute on function public.record_provenance(uuid, text, text, text, text, text, text, uuid, uuid, uuid) to authenticated, service_role;

-- ── 5. set_provenance_media(): attach the originals/results after upload ────
-- The altered result (and often the original) is uploaded AFTER the generation
-- call returns, so PATCH /me/compliance/:id fills the pair in. Same role gate;
-- keys are still server-derived from asset ids.

create or replace function public.set_provenance_media(
  p_id uuid,
  p_original_asset uuid default null,
  p_altered_asset uuid default null,
  p_label text default null
) returns public.media_provenance
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_row media_provenance;
  v_role text;
  v_label text := nullif(left(regexp_replace(coalesce(p_label, ''), '[\r\n\t]+', ' ', 'g'), 80), '');
begin
  select mp.* into v_row from media_provenance mp where mp.id = p_id;
  if not found then raise exception 'RP404: provenance record not found'; end if;

  v_role := org_role(v_row.org_id);
  if v_role is null then raise exception 'RP404: provenance record not found'; end if;  -- don't reveal existence
  if v_role not in ('owner','admin','agent') then
    raise exception 'RP403: your role does not permit editing AI provenance';
  end if;
  if v_row.listing_id is null then
    raise exception 'RP409: this provenance record has no listing to attach media to';
  end if;

  update media_provenance
     set original_key = coalesce(provenance_asset_key(p_original_asset, v_row.listing_id), original_key),
         altered_key  = coalesce(provenance_asset_key(p_altered_asset, v_row.listing_id), altered_key),
         label        = coalesce(v_label, label)
   where id = p_id
   returning * into v_row;
  return v_row;
end;
$fn$;

revoke execute on function public.set_provenance_media(uuid, uuid, uuid, text) from public, anon;
grant  execute on function public.set_provenance_media(uuid, uuid, uuid, text) to authenticated, service_role;
