begin;
-- Preserve explicitly reviewed guest contact only when the named account has
-- never reviewed a card. Empty destination JSON remains an explicit choice.
-- The disposition describes this accepted transaction, not later account state.
do $$
declare
 definition text;
 declaration text:='declare v_receipt jsonb; v_count integer;';
 declaration_new text:='declare v_receipt jsonb; v_count integer; v_personal_card_disposition text;';
 remap text:='  update public.memberships set user_id=p_user where user_id=p_anon_user and org_id=p_anon_org;';
 receipt_field text:='    ''source_cleanup_pending'',true);';
 receipt_field_new text:='    ''source_cleanup_pending'',true,''personal_card_disposition'',v_personal_card_disposition);';
 card_copy text:=E'  -- Both profiles and Auth identities are already locked and verified.\n  -- Receipt-only replay returns above, before any personal-card mutation.\n  v_personal_card_disposition := case\n    when (select public_card from public.profiles where id=p_user) is not null then \'destination_preserved\'\n    when (select public_card from public.profiles where id=p_anon_user) is not null then \'source_copied\'\n    else \'no_source_card\' end;\n  update public.profiles target set public_card=source.public_card\n    from public.profiles source where target.id=p_user and source.id=p_anon_user\n      and target.public_card is null and source.public_card is not null;\n';
begin
 definition:=pg_get_functiondef('public.adopt_anonymous_org(uuid,uuid,uuid,uuid)'::regprocedure);
 if (length(definition)-length(replace(definition,card_copy||remap,'')))/length(card_copy||remap)=1
  and (length(definition)-length(replace(definition,declaration_new,'')))/length(declaration_new)=1
  and (length(definition)-length(replace(definition,receipt_field_new,'')))/length(receipt_field_new)=1 then return;end if;
 if (length(definition)-length(replace(definition,remap,'')))/length(remap)<>1
  or (length(definition)-length(replace(definition,declaration,'')))/length(declaration)<>1
  or (length(definition)-length(replace(definition,receipt_field,'')))/length(receipt_field)<>1
  or position('set public_card='in definition)>0
  or position('personal_card_disposition'in definition)>0
  or position('perform 1 from public.profiles where id in (p_user,p_anon_user) order by id for update;'in definition)=0
  or position('current source and destination identity types do not permit transfer'in definition)=0
  or position('an account is being deleted'in definition)=0 then
  raise exception 'Anonymous adoption definition changed; review before preserving personal cards';
 end if;
 execute replace(replace(replace(definition,remap,card_copy||remap),declaration,declaration_new),receipt_field,receipt_field_new);
end $$;
commit;
