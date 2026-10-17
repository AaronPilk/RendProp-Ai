-- SYNTHETIC DEMONSTRATION DATA FOR THE AI PHOTO QUALITY REPORT.
-- Not customer data. No image bytes, no provider calls, no network: every
-- "generation" below is a closed fixture driven through the actual SQL photo
-- journal (operation, evidence, recipe, candidate, provenance, judge path),
-- with synthetic verdict text and synthetic modeled costs. Timestamps are
-- moved back to spread the demo across the window.
--
-- Loaded only by services/supabase/tests/photo_feedback_report_demo.py into
-- its own disposable cluster, AFTER the shared synthetic helpers from the
-- SETUP section of services/supabase/tests/photo_feedback.sql (pg_temp.generate,
-- attempt, ledger, judge, verdict; users a=owner, e=editor, m=admin).
set local role service_role;
create temp table demo(label text primary key,day int,ev jsonb);grant all on demo to service_role;
-- label, edit, style, recipe (null = generated before recipes were recorded), provider, model, final chain step, days ago
create function pg_temp.make(label text,p_edit text,p_style text,p_recipe text,p_provider text,p_model text,p_stage int,p_day int)returns void language plpgsql as $$begin
 insert into demo values(label,p_day,pg_temp.generate(label,p_edit,p_style,p_recipe,p_provider,p_model,p_stage));end$$;
create function pg_temp.ev(label text)returns jsonb language sql as $$select ev from demo where demo.label=$1$$;
create function pg_temp.paid(label text,p_stage text,p_cents numeric)returns void language plpgsql as $$begin
 perform pg_temp.attempt(pg_temp.ev(label),p_stage,'succeeded',p_cents);perform pg_temp.ledger(pg_temp.ev(label),p_stage,p_cents);end$$;
create function pg_temp.accept(label text,ok boolean default true)returns void language plpgsql as $$begin
 update demo set ev=(pg_temp.judge(ev,pg_temp.verdict(ok)))->'evidence'where demo.label=$1;end$$;
create function pg_temp.rate(who uuid,label text,key text,v text,reasons text[],note text default null,rev int default 1)returns void language plpgsql as $$begin
 perform photo_feedback_submit(who,(select o from f),(pg_temp.ev(label)->>'provenance_id')::uuid,null,key,rev,v,reasons,note,'studio');end$$;
create function pg_temp.sig(who uuid,label text,key text,s text,d text)returns void language plpgsql as $$begin
 perform photo_feedback_signal(who,(select o from f),(pg_temp.ev(label)->>'provenance_id')::uuid,key,s,d,'ios');end$$;

-- Declutter: current recipe on Flash and Pro, one older-recipe output.
select pg_temp.make('demo-d01','declutter',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0,2);
select pg_temp.make('demo-d02','declutter',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0,3);
select pg_temp.make('demo-d03','declutter',null,'photo-recipe/2026-10-17.1','gemini','gemini-3-pro-image',0,5);
select pg_temp.make('demo-d04','declutter',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0,6);
select pg_temp.make('demo-d05','declutter',null,'photo-recipe/2026-10-16.9','gemini','gemini-3.1-flash-image',0,12);
select pg_temp.make('demo-d06','declutter',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0,14);
-- Staging: Pro preservation profile, one retry, one fallback after a failed dispatch.
select pg_temp.make('demo-s01','stage','modern','photo-recipe/2026-10-17.1','gemini','gemini-3-pro-image',0,1);
select pg_temp.make('demo-s02','stage','rustic','photo-recipe/2026-10-17.1','gemini','gemini-3-pro-image',1,4);
select pg_temp.make('demo-s03','stage','modern','photo-recipe/2026-10-17.1','fal','flux-kontext-pro',1,7);
select pg_temp.make('demo-s04','stage','contemporary','photo-recipe/2026-10-16.9','gemini','gemini-3.1-flash-image',0,15);
select pg_temp.make('demo-s05','stage','minimalist','photo-recipe/2026-10-17.1','gemini','gemini-3-pro-image',0,8);
-- Exterior edits, including two generated before recipes were recorded.
select pg_temp.make('demo-t01','twilight',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0,9);
select pg_temp.make('demo-t02','twilight',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0,9);
select pg_temp.make('demo-t03','twilight',null,null,'gemini','gemini-3.1-flash-image',0,20);
select pg_temp.make('demo-k01','sky',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0,10);
select pg_temp.make('demo-k02','sky',null,null,'gemini','gemini-3.1-flash-image',0,21);
select pg_temp.make('demo-l01','lawn',null,'photo-recipe/2026-10-17.1',null,null,0,11);
-- Custom edits.
select pg_temp.make('demo-c01','custom',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0,2);
select pg_temp.make('demo-c02','custom',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0,13);
select pg_temp.make('demo-c03','custom',null,'photo-recipe/2026-10-17.1','gemini','gemini-3.1-flash-image',0,0);

-- Paid attempts (synthetic modeled cents) and settlements.
select pg_temp.paid(label,'photo.'||(ev->>'edit')||':0',case when ev->>'generation_model'='gemini-3-pro-image'then 30.5536 else 16.7584 end)
 from demo where label in('demo-d01','demo-d02','demo-d03','demo-d04','demo-d05','demo-d06','demo-s01','demo-s04','demo-s05','demo-t01','demo-t02','demo-t03','demo-k01','demo-k02','demo-c01','demo-c02');
select pg_temp.attempt(pg_temp.ev('demo-s02'),'photo.stage:0','rejected',30.5536);select pg_temp.paid('demo-s02','photo.stage:1',30.5536);
select pg_temp.attempt(pg_temp.ev('demo-s03'),'photo.stage:0','uncertain',16.7584,'gemini','gemini-3.1-flash-image');select pg_temp.paid('demo-s03','photo.stage:1',8.0);
select pg_temp.attempt(pg_temp.ev('demo-l01'),'photo.lawn:0','uncertain',16.7584,'gemini','gemini-3.1-flash-image');
select pg_temp.attempt(pg_temp.ev('demo-c03'),'photo.custom:0','succeeded',16.7584);
update demo set ev=(select to_jsonb(v)from photo_edit_evidence v where v.id=(demo.ev->>'id')::uuid)where label='demo-l01';
select photo_quality_failure((select a from f),(pg_temp.ev('demo-l01')->>'id')::uuid,'generation',jsonb_build_object('provider_cost_incurred','possible','retained_output',false));
-- The fixed-feature judge: one twilight refused; c03 still waiting.
select pg_temp.accept(label)from demo where label not in('demo-t02','demo-l01','demo-c03');
select pg_temp.accept('demo-t02',false);

-- Explicit verdicts (each person's opinion on one exact output version).
select pg_temp.rate((select a from f),'demo-d01','demo-k-d01-a','useful','{}');
select pg_temp.rate((select a from f),'demo-d02','demo-k-d02-a','needs_work','{moved_or_changed_appliance}','Fridge moved to the left wall');
select pg_temp.rate((select a from f),'demo-d03','demo-k-d03-a','useful','{}');
select pg_temp.rate((select e from f),'demo-d05','demo-k-d05-e','needs_work','{visible_visual_artifacts}');
select pg_temp.rate((select a from f),'demo-d06','demo-k-d06-a','needs_work','{other}');
select pg_temp.rate((select a from f),'demo-d06','demo-k-d06-a','useful','{}',null,2);
select pg_temp.rate((select a from f),'demo-s01','demo-k-s01-a','useful','{}');
select pg_temp.rate((select a from f),'demo-s02','demo-k-s02-a','needs_work','{inconsistent_furniture_between_views}');
select pg_temp.rate((select a from f),'demo-s03','demo-k-s03-a','needs_work','{blocked_doorway_or_opening,changed_permanent_features}','Sofa across the hallway door');
select pg_temp.rate((select e from f),'demo-s03','demo-k-s03-e','needs_work','{personal_style_preference}');
select pg_temp.rate((select a from f),'demo-s04','demo-k-s04-a','needs_work','{personal_style_preference}');
select pg_temp.rate((select a from f),'demo-s05','demo-k-s05-a','useful','{}');
select pg_temp.rate((select e from f),'demo-s05','demo-k-s05-e','needs_work','{requested_edit_incomplete}');
select pg_temp.rate((select a from f),'demo-t01','demo-k-t01-a','useful','{}');
select pg_temp.rate((select a from f),'demo-t03','demo-k-t03-a','useful','{}');
select pg_temp.rate((select a from f),'demo-k02','demo-k-k02-a','needs_work','{other}');
select pg_temp.rate((select a from f),'demo-c01','demo-k-c01-a','useful','{}');
select pg_temp.rate((select a from f),'demo-c02','demo-k-c02-a','needs_work','{requested_edit_incomplete}');
-- Signals are a separate axis (never counted as Useful).
select pg_temp.sig((select a from f),'demo-d01','demo-s-d01-1','manual_selection','gallery_save');
select pg_temp.sig((select a from f),'demo-d03','demo-s-d03-1','export','download');
select pg_temp.sig((select a from f),'demo-d04','demo-s-d04-1','automatic_selection','listing_selection');
select pg_temp.sig((select a from f),'demo-k01','demo-s-k01-1','automatic_selection','listing_selection');
select pg_temp.sig((select a from f),'demo-s01','demo-s-s01-1','accuracy_ack','staging_review');
select pg_temp.sig((select a from f),'demo-s01','demo-s-s01-2','publication','published_tour');
select pg_temp.sig((select a from f),'demo-c01','demo-s-c01-1','export','kit_export');
-- Consented private regression cases (owner and admin).
select photo_regression_case_mark((select a from f),(select o from f),(pg_temp.ev('demo-d02')->>'provenance_id')::uuid,'moved_or_changed_appliance','Keep the refrigerator and range exactly where they are.',true,false);
select photo_regression_case_mark((select m from f),(select o from f),(pg_temp.ev('demo-s03')->>'provenance_id')::uuid,'blocked_doorway_or_opening','Keep both doorways and the hallway clear of furniture.',true,false);
-- Two historical outputs (generated before attribution existed): provenance only.
reset role;
insert into media_provenance(id,org_id,listing_id,kind,model_id,edit,disclosure)select'f8600000-0000-4000-8000-000000000091',o,l1,'photo_edit','legacy-model','twilight','Synthetic historical disclosure'from f;
insert into media_provenance(id,org_id,listing_id,kind,model_id,edit,disclosure)select'f8600000-0000-4000-8000-000000000092',o,l1,'declutter','legacy-model','declutter','Synthetic historical disclosure'from f;
set local role service_role;
select photo_feedback_submit((select a from f),(select o from f),'f8600000-0000-4000-8000-000000000091',null,'demo-k-h1-a',1,'needs_work','{changed_permanent_features}',null,'ios');
select photo_feedback_submit((select a from f),(select o from f),'f8600000-0000-4000-8000-000000000092',null,'demo-k-h2-a',1,'useful','{}',null,'ios');
-- Spread the synthetic timeline across the window.
reset role;
update photo_edit_evidence e set created_at=now()-make_interval(days=>d.day,hours=>2)from demo d where e.id=(d.ev->>'id')::uuid;
update photo_output_feedback x set created_at=now()-make_interval(days=>d.day),updated_at=now()-make_interval(days=>d.day)from demo d where x.evidence_id=(d.ev->>'id')::uuid;
