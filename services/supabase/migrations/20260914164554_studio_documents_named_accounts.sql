-- Anonymous native onboarding sessions do not participate in cross-device drafts.
alter policy studio_documents_owner_read on public.studio_documents
using (user_id = (select auth.uid())
  and ((select auth.jwt())->>'is_anonymous')::boolean is not true
  and public.is_org_member(org_id)
  and exists (select 1 from public.orgs o where o.id = studio_documents.org_id and o.deleted_at is null)
  and (listing_id is null or exists (select 1 from public.listings l where l.id = studio_documents.listing_id and l.org_id = studio_documents.org_id and l.deleted_at is null)));
