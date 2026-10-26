do $$begin
  if not exists(select 1 from pg_roles where rolname='service_role')then create role service_role;end if;
  if not exists(select 1 from pg_roles where rolname='anon')then create role anon;end if;
  if not exists(select 1 from pg_roles where rolname='authenticated')then create role authenticated;end if;
end$$;
create table public.orgs (id uuid primary key, deleted_at timestamptz);
create table public.listings (
  id uuid primary key, org_id uuid not null, agent_id uuid not null,
  space_type text not null, address text not null, status text not null,
  details jsonb not null default '{}'::jsonb,
  deleted_at timestamptz
);
create table public.renders (
  id uuid primary key, listing_id uuid not null, slug text not null,
  published_at timestamptz
);
create table public.deletion_requests (user_id uuid, status text);
create function public.studio_presenter_render_access(uuid)
  returns boolean language sql stable as $$select true$$;
create function public.hosting_retention_state(uuid)
  returns jsonb language sql stable as $$select '{"hosting_available":true}'::jsonb$$;
insert into public.orgs(id) values ('00000000-0000-4000-8000-000000000001');
insert into public.listings(id,org_id,agent_id,space_type,address,status,details) values
  ('55739bcb-e589-853b-ad28-92a3a5521823','00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000002','real_estate','855 Central Ave, 1120 Saint Petersburg, FL 33701','ready','{"allow_indexing":true}'),
  ('3f329de6-b9ff-8b9c-b58f-662b2a4f060f','00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000005','real_estate','855 Central Ave #1120, Saint Petersburg, FL 33701','ready','{}'),
  ('00000000-0000-4000-8000-000000000006','00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000005','real_estate','123 Other St, Saint Petersburg, FL 33701','ready','{"allow_indexing":true}');
insert into public.renders(id,listing_id,slug,published_at) values
  ('00000000-0000-4000-8000-000000000003','55739bcb-e589-853b-ad28-92a3a5521823','g2afbgmv32',now()),
  ('00000000-0000-4000-8000-000000000004','3f329de6-b9ff-8b9c-b58f-662b2a4f060f','3482b697c5f34c26a83b5d1b2b6f429a',now()),
  ('00000000-0000-4000-8000-000000000007','00000000-0000-4000-8000-000000000006','other-unique-slug',now());
