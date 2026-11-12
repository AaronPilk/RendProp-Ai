-- Operator-only production switch for the ordinary 2K photo hotfix.
-- Run AFTER deploying the ai-photo Edge Function from this hotfix and
-- verifying that new Stage/Declutter requests pin Gemini Flash imageSize 2K.
-- This disables the legacy Pro4K selector without deleting its route or
-- changing owner-only comparison grants. Safe to run twice.
begin;
do $disable_legacy_photo_profile$
declare
  prior jsonb;
  next_value jsonb;
begin
  select value into prior from public.app_config
    where key='photo_preservation_quality' for update;
  if prior is null
    or prior->>'profile' is distinct from 'gemini-pro-4k-preservation-v1'
    or (prior->'tasks' is distinct from '["photo.stage","photo.declutter"]'::jsonb
        and prior->'tasks' is distinct from '["photo.declutter","photo.stage"]'::jsonb)
    or (prior->'enabled' is distinct from 'true'::jsonb
        and prior->'enabled' is distinct from 'false'::jsonb)
  then
    raise exception 'PHOTO-2K activation refused: unexpected photo_preservation_quality config';
  end if;
  next_value:=jsonb_set(prior,'{enabled}','false'::jsonb,false);
  if prior is distinct from next_value then
    update public.app_config
      set value=next_value,updated_at=now()
      where key='photo_preservation_quality' and value=prior;
    if not found then
      raise exception 'PHOTO-2K activation refused: config changed during update';
    end if;
  end if;
  raise notice 'photo_preservation_quality before: %; after: %',prior,next_value;
end
$disable_legacy_photo_profile$;
commit;

-- Readback: enabled must be false; profile and tasks remain intact.
select key,value,updated_at from public.app_config
 where key='photo_preservation_quality';
