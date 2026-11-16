#!/usr/bin/env python3
"""Narrow real-Postgres seed/replay/RLS proof; no hosted calls or funding grants.

Uses the actual existing router schema/RLS migrations, not a substitute table.
The closed fixture is_admin=false supplies only their existing auth dependency.
Full application migration closure remains the separate CI regression suite.
"""
from pathlib import Path
import argparse,datetime,hashlib,json,os,shutil,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
MIG=SQL/'migrations/20261015074002_normal_photo_pro4k_quality_profile.sql'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
OUT=args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-normal-photo-quality-proof-'));OUT.mkdir(parents=True,exist_ok=True)
assert shutil.disk_usage(ROOT).free>=3*1024**3,'Preserve internal3GiB reserve'
DATA=Path(tempfile.mkdtemp(prefix='rendprop-normal-photo-owned-pg-'));SOCK=Path(tempfile.mkdtemp(prefix='photo-quality-sock-',dir='/tmp'))
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
tool=lambda n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)
SOURCES=[MIG,SQL/'tests/ci-bootstrap.sql',SQL/'migrations/0018_ai_routes.sql',SQL/'migrations/0030_route_params.sql',Path(__file__).resolve()]
r={'passed':False,'scope':'narrow actual router schema seed/replay/RLS; not full application replay','networkCalls':0,'providerCalls':0,'fundingGrants':0,'commands':[],'controls':[],'sourceHashes':{str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest()for x in SOURCES}};started=False
def run(name,cmd,body=None,refuses=None):
 v=subprocess.run([str(x)for x in cmd],input=body,text=True,env=ENV,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
 log=OUT/(name+'.log');log.write_text(v.stdout);log.chmod(0o600);r['commands'].append({'name':name,'exit':v.returncode,'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
 assert (v.returncode and refuses in v.stdout)if refuses else v.returncode==0,(name,v.stdout[-2500:]);return v.stdout
try:
 run('initdb',[tool('initdb'),'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8']);run('start',[tool('pg_ctl'),'-D',DATA,'-l',OUT/'postgres.log','-w','-o',f"-k {SOCK} -p 55563 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
 conn=['-h',SOCK,'-p','55563','-U','postgres'];run('createdb',[tool('createdb'),*conn,'quality_base']);base=[tool('psql'),'-X','--no-password',*conn,'-d','quality_base','-v','ON_ERROR_STOP=1','-Atq']
 run('bootstrap',base+['-f',SQL/'tests/ci-bootstrap.sql']);run('nonadmin-closed-auth-dependency',base,'create function public.is_admin()returns boolean language sql stable as $$select false$$;')
 for n in ['0018_ai_routes.sql','0030_route_params.sql']:run('actual-router-'+n,base+['-f',SQL/'migrations'/n])
 run('snapshot-legacy',base,"create table public.closed_legacy_snapshot as select md5(coalesce(string_agg(to_jsonb(r)::text,','order by id),''))digest from ai_routes r where task in('photo.stage','photo.declutter','photo.sky','photo.twilight','photo.lawn','photo.custom');")
 for database in ['quality_actual','quality_bad_flag','quality_bad_route']:run('clone-'+database,[tool('createdb'),*conn,'-T','quality_base',database])
 def psql(db):return[tool('psql'),'-X','--no-password',*conn,'-d',db,'-v','ON_ERROR_STOP=1','-Atq']
 check="""do $$begin
 if(select value from app_config where key='photo_preservation_quality')is distinct from'{"enabled":false,"profile":"gemini-pro-4k-preservation-v1","tasks":[]}'::jsonb then raise exception'closed_policy_not_off';end if;
 if(select count(*)from ai_routes where task in('photo.quality_stage','photo.quality_declutter')and provider='gemini'and model='gemini-3-pro-image'and unit_cents=30.5536 and enabled=false and note='legacy'and params='{"image_size":"4K"}'::jsonb and min_plan='free'and privacy_tier='retained_30d'and capabilities@>array['prompt-edit','fidelity','4K'])<>2 then raise exception'closed_routes_not_off';end if;
 if(select digest from closed_legacy_snapshot)is distinct from(select md5(coalesce(string_agg(to_jsonb(r)::text,','order by id),''))from ai_routes r where task in('photo.stage','photo.declutter','photo.sky','photo.twilight','photo.lawn','photo.custom'))then raise exception'legacy_routes_changed';end if;
 end$$;select 'ordinary-photo-profile-default-off-legacy-unchanged';"""
 run('apply-normal-quality',psql('quality_actual')+['-f',MIG]);run('assert-default-off-isolated',psql('quality_actual'),check)
 run('nonadmin-cannot-enable-policy',psql('quality_actual'),"set role authenticated;update app_config set value='{}'where key='photo_preservation_quality';",refuses='permission denied')
 run('nonadmin-cannot-enable-routes',psql('quality_actual'),"set role authenticated;update ai_routes set enabled=true where task='photo.quality_stage';",refuses='permission denied')
 visible=run('nonadmin-policy-not-readable',psql('quality_actual'),"set role authenticated;select count(*)from app_config where key='photo_preservation_quality';");assert visible.strip()=='0'
 run('local-operator-settings',psql('quality_actual'),"update app_config set value=jsonb_build_object('enabled',true,'profile','gemini-pro-4k-preservation-v1','tasks',jsonb_build_array('photo.stage'),'changed_by','closed-test-owner')where key='photo_preservation_quality';update ai_routes set enabled=true,min_plan='pro'where task in('photo.quality_stage','photo.quality_declutter');")
 run('replay-own-seed',psql('quality_actual')+['-f',MIG])
 run('assert-replay-preserves-operator',psql('quality_actual'),"do $$begin if(select value->>'changed_by'from app_config where key='photo_preservation_quality')<>'closed-test-owner'or(select count(*)from ai_routes where task in('photo.quality_stage','photo.quality_declutter')and enabled and min_plan='pro')<>2 then raise exception'replay_changed_operator';end if;end$$;")
 source=MIG.read_text()
 for database,anchor,replacement,refusal in [('quality_bad_flag','"enabled":false','"enabled":true','closed_policy_not_off'),('quality_bad_route',"'retained_30d',false,'legacy'","'retained_30d',true,'legacy'",'closed_routes_not_off')]:
  assert anchor in source;run('mutant-apply-'+database,psql(database),source.replace(anchor,replacement));run('mutant-oracle-'+database,psql(database),check,refuses=refusal);r['controls'].append({'name':database,'refused':True})
 r['passed']=True;r['recordedUTC']=datetime.datetime.now(datetime.timezone.utc).isoformat()
finally:
 if started:run('stop',[tool('pg_ctl'),'-D',DATA,'-m','immediate','-w','stop'])
 shutil.rmtree(DATA,ignore_errors=True);shutil.rmtree(SOCK,ignore_errors=True);r['temporaryClusterRemoved']=not DATA.exists();p=OUT/'receipt.json';p.write_text(json.dumps(r,indent=2)+'\n');p.chmod(0o600)
print(json.dumps({'passed':r['passed'],'receipt':str(OUT/'receipt.json'),'controls':r['controls']}))
