#!/usr/bin/env python3
"""Legacy push account-switch recovery: owned synthetic PostgreSQL, no hosted writes."""
from datetime import datetime, timezone
import hashlib,json,os,pathlib,re,shutil,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2];SQL=ROOT/'services/supabase';TARGET=SQL/'migrations/20261010042000_legacy_notification_session_retirement.sql'
OUT=pathlib.Path(tempfile.mkdtemp(prefix='rp-legacy-notification-',dir='/tmp'));DATA=OUT/'cluster';SOCK=OUT/'socket';SOCK.mkdir(mode=0o700)
ENV={'PATH':os.environ.get('PATH','/usr/bin:/bin'),'LC_ALL':'C','TZ':'UTC'};BIN={n:shutil.which(n)for n in['initdb','pg_ctl','psql','createdb']};assert all(BIN.values())
CONN=['-h',str(SOCK),'-p','55494','-U','postgres'];PSQL=[BIN['psql'],'-X','--no-password',*CONN,'-d','rendprop_audit','-v','ON_ERROR_STOP=1','-Atq']
SOURCES=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',SQL/'tests/legacy_notification_sessions.sql',SQL/'tests/reaudit_device_takeover.sql',SQL/'tests/notification_session_fencing.sql',pathlib.Path(__file__).resolve()]
HASHES=[{'path':str(p.relative_to(ROOT)),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}for p in SOURCES]
R={'startedAt':datetime.now(timezone.utc).isoformat(),'sourceHashes':HASHES,'commands':[],'passed':False,'productionMutations':0,'providerCalls':0,'limitations':['Synthetic Auth session rows, owned socket-only PostgreSQL; no hosted JWT or physical APNs certification']}
def run(name,args,body=None,expected=0,label=None):
 p=subprocess.run(list(map(str,args)),input=body,text=True,cwd=ROOT,env=ENV,capture_output=True,timeout=120);log=OUT/(name+'.log');log.write_text(p.stdout+p.stderr)
 R['commands'].append({'name':name,'exit':p.returncode,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()});assert p.returncode==expected,(name,p.returncode,p.stderr[-1800:])
 if label:assert label in p.stderr,(name,p.stderr[-1800:])
 print(name,p.returncode,flush=True);return p.stdout

def q(name,body,expected=0,label=None):return run(name,PSQL,body,expected,label)
def definition(name,sig):return q('definition-'+name,"select pg_get_functiondef('public."+sig+"'::regprocedure);").strip()+';'
def suite(phase):
 for name,count in [('legacy_notification_sessions',23),('reaudit_device_takeover',10),('notification_session_fencing',29)]:
  result=q(name+'-'+phase,(SQL/'tests'/f'{name}.sql').read_text());rows=[json.loads(l)for l in result.splitlines()if l.startswith('{')and'"suite"'in l];assert len(rows)==1 and rows[0].get('suite')==name and rows[0].get('assertions')==count,rows
started=False;print('EVIDENCE:',OUT,flush=True)
try:
 run('init',[BIN['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
 run('start',[BIN['pg_ctl'],'-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p 55494 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=20",'start']);started=True
 run('create',[BIN['createdb'],'--no-password',*CONN,'rendprop_audit']);assert q('identity',"select current_setting('data_directory'),current_setting('listen_addresses');").strip()==str(DATA)+'|'
 q('bootstrap',(SQL/'tests/ci-bootstrap.sql').read_text())
 for p in sorted((SQL/'migrations').glob('*.sql')):q('migration-'+p.stem,p.read_text())
 suite('fresh')
 catalog="select md5(string_agg(oid::regprocedure::text||prosrc||coalesce(proacl::text,'')||proowner::text||prosecdef::text||coalesce(proconfig::text,''),'|'order by oid::regprocedure::text))from pg_proc where pronamespace='public'::regnamespace;"
 before=q('catalog-final',catalog);q('exact-final-replay',TARGET.read_text());assert q('catalog-replayed',catalog)==before;suite('replay')
 reg=definition('register','notification_register_device_session(uuid,uuid,text,text,text,text,text)');unreg=definition('unregister','notification_unregister_device(uuid,uuid,text,text)');body=(SQL/'tests/legacy_notification_sessions.sql').read_text()
 start=reg.index(' -- A legacy row');end=reg.index(' -- A failed/expired',start)
 mutations=[('remove-legacy-check',reg[:start]+reg[end:],'delayed legacy A is refused'),('environment-scoped-check',reg.replace('where r.user_id=p_user and r.token_sha256=digest','where r.user_id=p_user and r.token_sha256=digest and r.environment=v_env'),'caller environment'),('wrong-Auth-owner',reg.replace('s.id=p_session and s.user_id=p_user','s.id=p_session'),'another users fresh'),('remove-current-binding-exception',reg.replace('and d.registration_session_id=p_session','and false'),'This device session has signed out'),('allow-undated-session',reg.replace('s.created_at>r.retired_at','coalesce(s.created_at,pg_catalog.clock_timestamp())>r.retired_at'),'undated Auth session'),('overbroad-current-binding',reg.replace('and d.registration_session_id=p_session',''),'a different old session')]
 for name,code,label in mutations:
  q(name+'-install',code);q(name,body,3,label);q(name+'-restore',reg)
 start=unreg.index(' -- Preserve the legacy');end=unreg.index(' delete from public.notification_devices',start);q('remove-legacy-unregister-install',unreg[:start]+unreg[end:]);q('remove-legacy-unregister',body,3,'after successful legacy DELETE');q('remove-legacy-unregister-restore',unreg)
 # Modern session fencing follows the global token, too; caller environment
 # must not admit a displaced session after its legacy binding was resolved.
 assert reg.count('t.token_sha256=digest)')==1
 q('modern-env-control-install',reg.replace('t.token_sha256=digest)','t.token_sha256=digest and t.environment=v_env)'))
 q('modern-env-control',(SQL/'tests/reaudit_device_takeover.sql').read_text(),3,'caller environment')
 q('modern-env-control-restore',reg)
 for name,code in [('register',reg),('unregister',unreg)]:
  marker=re.search(r'AS (\$[^$]*\$)',code)[0];q('unknown-'+name+'-install',code.replace(marker,marker+'\n-- unreviewed definition\n',1));q('unknown-'+name+'-refused',TARGET.read_text(),3,'Review changed function');q('unknown-'+name+'-restore',code)
 assert q('catalog-restored',catalog)==before;suite('restored')
 R.update(passed=True,legacyAssertions=23,modernAssertions=10,sessionFencingAssertions=29,compiledFunctionControls=8,predecessorsRefused=2,exactReplay=True)
finally:
 if started and(DATA/'postmaster.pid').exists():run('stop',[BIN['pg_ctl'],'-D',DATA,'-m','fast','-w','stop'])
 R['sourceUnchanged']=all(hashlib.sha256((ROOT/h['path']).read_bytes()).hexdigest()==h['sha256']for h in HASHES);R['passed']=R['passed']and R['sourceUnchanged'];R['finishedAt']=datetime.now(timezone.utc).isoformat();(OUT/'receipt.json').write_text(json.dumps(R,indent=2)+'\n')
assert R['passed'];print('PASS: legacy23/modern10/fencing29 fresh/replay/restored, eight compiled controls and two predecessor guards',flush=True)
