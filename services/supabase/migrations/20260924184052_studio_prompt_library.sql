-- Personal prompt collections use existing user/workspace-scoped documents and
-- revision checks. This does not authorize or dispatch any AI generation.
begin;
alter table public.studio_documents drop constraint if exists studio_documents_kind_check;
alter table public.studio_documents add constraint studio_documents_kind_check
 check(kind in ('edit','planner','creative','native','production','prompts'));
alter table public.studio_documents drop constraint if exists studio_prompt_document_scope;
alter table public.studio_documents add constraint studio_prompt_document_scope
 check(kind<>'prompts' or coalesce((key='prompts' and listing_id is null and payload->>'schema'='1' and jsonb_typeof(payload->'entries')='array' and jsonb_array_length(payload->'entries')<=50),false));
commit;
