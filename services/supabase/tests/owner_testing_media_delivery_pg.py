#!/usr/bin/env python3
"""Socket-only real PG: authoritative owner usage, unchanged financial guards."""
from pathlib import Path
import argparse,hashlib,json,os,shutil,subprocess,tempfile

ROOT=Path(__file__).resolve().parents[3];SQL=ROOT/'services/supabase'
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);a=p.parse_args()
OUT=a.evidence_dir or Path(tempfile.mkdtemp(prefix='owner-media-evidence-'));OUT.mkdir(parents=True,exist_ok=True)
DATA=Path(tempfile.mkdtemp(prefix='owner-media-pg-',dir=os.environ.get('RENDPROP_PG_DATA_ROOT')))
SOCK=Path(tempfile.mkdtemp(prefix='owner-media-sock-'))
TOOLS={n:shutil.which(n)or str(Path('/opt/homebrew/opt/postgresql@17/bin')/n)for n in ['initdb','pg_ctl','psql','createdb']}
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
MIG=SQL/'migrations/20261015170710_owner_testing_media_delivery_usage.sql';TEST=SQL/'tests/owner_testing_media_delivery.sql'
FILES=[*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',TEST,Path(__file__).resolve()]
hashes=lambda:{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()for f in FILES}
r={'passed':False,'scope':'Actual disposable socket-only PostgreSQL; synthetic identities and usage only',
   'sourceHashes':hashes(),'controls':[],'commands':[],'networkCalls':0,'providerCalls':0,'productionMutations':0}
started=False
def run(name,args,stdin=None,okay=True):
    x=subprocess.run([str(v)for v in args],input=stdin,env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
    (OUT/(name+'.log')).write_text(x.stdout)
    r['commands'].append({'name':name,'exit':x.returncode,'sha256':hashlib.sha256(x.stdout.encode()).hexdigest()})
    assert not okay or x.returncode==0,(name,x.stdout[-3500:])
    return x
try:
    run('initdb',[TOOLS['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
    run('start',[TOOLS['pg_ctl'],'-D',DATA,'-l',OUT/'postgres.log','-w','-t','30','-o',f"-k {SOCK} -p 55562 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
    conn=['-h',SOCK,'-p','55562','-U','postgres'];run('createdb',[TOOLS['createdb'],*conn,'owner_testing_media'])
    P=[TOOLS['psql'],'-X','--no-password',*conn,'-d','owner_testing_media','-v','ON_ERROR_STOP=1']
    run('bootstrap',[*P,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
    for m in sorted((SQL/'migrations').glob('*.sql')):run('apply-'+m.stem,[*P,'-q','-1','-f',m])
    for name in ['fresh','replay']:
        if name=='replay':run('replay-migration',[*P,'-q','-1','-f',MIG])
        x=run(name,[*P,'-Atq'],TEST.read_text())
        proof=[json.loads(l)for l in x.stdout.splitlines()if l.startswith('{')and'assertions'in l]
        assert len(proof)==1 and proof[0]['passed'];r[name]=proof[0]
    definition=run('definition',P+['-Atq','-c',"select pg_get_functiondef('public.media_delivery_admit(uuid,bigint,boolean)'::regprocedure)"]).stdout
    start=definition.index('    insert into public.owner_testing_media_usage(');end=definition.index('    return jsonb_build_object',start)
    controls=[('owner-authority','if public.org_has_internal_testing_grant(billing) then','if true then','ordinary Team is not testing authority'),
              ('request-byte-meter',definition[start:end],'    null;\n','HEAD and bytes both metered'),
              ('generic-byte-bound','268435456','536870912','owner cannot bypass generic byte cap')]
    for name,before,after,expected in controls:
        assert definition.count(before)==1,(name,before)
        run('install-'+name,[*P,'-Atq'],definition.replace(before,after))
        x=run('fault-'+name,[*P,'-Atq'],TEST.read_text(),False)
        assert x.returncode!=0 and expected in x.stdout,(name,x.stdout[-2000:])
        r['controls'].append({'name':name,'compiledActualSQL':True,'oracleRejected':expected})
        run('restore-'+name,[*P,'-Atq'],definition)
    # Two simultaneous actual service transactions must retain both counts.
    run('race-setup',[*P,'-Atq'],"""insert into auth.users(id,email)values('c1600000-0000-4000-8000-000000000001','concurrent-owner@fixture.invalid');
update public.profiles set is_admin=true where id='c1600000-0000-4000-8000-000000000001';
update public.orgs set plan='team',plan_source='manual',plan_expires_at=null where id in(select org_id from memberships where user_id='c1600000-0000-4000-8000-000000000001');
insert into public.org_internal_testing_grants(org_id,owner_user_id,unmetered_business_allowances)select org_id,user_id,true from memberships where user_id='c1600000-0000-4000-8000-000000000001';""")
    org=run('race-org',[*P,'-Atq','-c',"select org_id from memberships where user_id='c1600000-0000-4000-8000-000000000001'"]).stdout.strip()
    children=[subprocess.Popen([str(v)for v in [*P,'-Atq']],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,env=ENV)for _ in range(2)]
    for i,c in enumerate(children):c.stdin.write(f"begin;set local role service_role;select public.media_delivery_admit('{org}',{100+i},true);select pg_sleep(0.1);commit;");c.stdin.close()
    for i,c in enumerate(children):
        c.wait(timeout=30);s=c.stdout.read();(OUT/f'race-{i}.log').write_text(s);assert c.returncode==0,s
    value=run('race-counts',[*P,'-Atq','-c',f"select used_requests=2 and used_bytes=201 from public.owner_testing_media_usage where org_id='{org}'"]).stdout.strip();assert value=='t',value
    r['concurrentMetering']={'requests':2,'bytes':201,'lostUpdates':False}
    assert hashes()==r['sourceHashes'],'source changed during verification'
    r['passed']=True
finally:
    if started:run('stop',[TOOLS['pg_ctl'],'-D',DATA,'-m','immediate','-w','stop'])
    r['clusterStopped']=not(DATA/'postmaster.pid').exists()
    (OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
    shutil.rmtree(DATA,ignore_errors=True);shutil.rmtree(SOCK,ignore_errors=True)
    print(json.dumps({'passed':r['passed'],'receipt':str(OUT/'receipt.json')}))
