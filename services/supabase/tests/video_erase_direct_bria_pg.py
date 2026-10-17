#!/usr/bin/env python3
"""Owned disposable local PostgreSQL; fresh/replay migrations and real races.
Does not read credentials or contact any provider or production database.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib, json, os, shutil, subprocess, tempfile, uuid
ROOT=Path(__file__).resolve().parents[3]
SQL=ROOT/'services/supabase'
TOOLS={name:shutil.which(name) or str(Path('/opt/homebrew/opt/postgresql@17/bin')/name)
       for name in ('initdb','pg_ctl','psql','createdb')}
assert all(Path(path).is_file() and os.access(path,os.X_OK) for path in TOOLS.values()), 'Use already installed PostgreSQL binaries'
OUT=Path(tempfile.mkdtemp(prefix='rendprop-bria-pg-',dir='/tmp'))
DATA=OUT/'data'; SOCK=OUT/'socket'; SOCK.mkdir()
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=15000'}
PORT='55475'
receipt={'kind':'owned disposable local PostgreSQL; not hosted or container proof','output':str(OUT),'commands':[],
    'sourceHashes':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in
        [*sorted((SQL/'migrations').glob('*.sql')),SQL/'tests/ci-bootstrap.sql',
         SQL/'tests/video_erase.sql',SQL/'tests/video_erase_direct_bria.sql',Path(__file__).resolve()]}}
def run(name,args,sql=None):
    p=subprocess.run([str(x) for x in args],input=sql,env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
    log=OUT/(name+'.log'); log.write_text(p.stdout)
    receipt['commands'].append({'name':name,'exit':p.returncode,'log_sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
    if p.returncode: raise RuntimeError(f'{name} failed: {p.stdout[-1800:]} ({log})')
    print(name+': pass',flush=True); return p.stdout
started=False
try:
    receipt['postgresVersion']=run('version',[TOOLS['psql'],'--version']).strip()
    run('initdb',[TOOLS['initdb'],'-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
    run('start',[TOOLS['pg_ctl'],'-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p {PORT} -c listen_addresses='' -c shared_buffers=16MB",'start']); started=True
    conn=['-h',SOCK,'-p',PORT,'-U','postgres']
    run('createdb',[TOOLS['createdb'],*conn,'bria_audit'])
    psql=[TOOLS['psql'],'-X','--no-password',*conn,'-d','bria_audit','-v','ON_ERROR_STOP=1']
    run('bootstrap',[*psql,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
    migrations=sorted((SQL/'migrations').glob('*.sql'))
    for m in migrations: run('apply-'+m.stem,[*psql,'-q','-1','-f',m])
    for name in ('video_erase','video_erase_direct_bria'): receipt[name+'-fresh']=run(name+'-fresh',[*psql,'-f',SQL/f'tests/{name}.sql'])
    # Replay reflection migrations immediately after their ordered application
    # in a second fresh DB. Some existing Studio migrations are deliberately
    # one-time CREATE TABLE scripts, so do not claim full historical idempotency.
    # Replaying an old writer over the final schema would replace its newer
    # exact-attempt ledger identity and would not represent a supported upgrade.
    run('createdb-historical',[TOOLS['createdb'],*conn,'bria_historical'])
    historical=[TOOLS['psql'],'-X','--no-password',*conn,'-d','bria_historical','-v','ON_ERROR_STOP=1']
    run('bootstrap-historical',[*historical,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
    for m in migrations:
        run('historical-'+m.stem,[*historical,'-q','-1','-f',m])
        if m.name in ('0055_video_reflection_jobs.sql','0056_active_photo_fallback.sql','20261002225458_video_erase_direct_bria.sql'): run('ordered-replay-'+m.stem,[*historical,'-q','-1','-f',m])
    for name in ('video_erase','video_erase_direct_bria'): receipt[name+'-replay']=run(name+'-ordered-replay',[*historical,'-f',SQL/f'tests/{name}.sql'])
    receipt['replayMode']='second clean database; reflection migrations twice at their historical schema points'
    # Eight actual transactions compete for each durable paid admission/receipt.
    u,o,l,a,b,idem=[str(uuid.uuid4()) for _ in range(6)]
    config=json.dumps({'mask_unit_cost_cents':2,'erase_unit_cost_cents':3,'price_version':'synthetic-race','output_hosts':['outputs.example.com']})
    setup=f"""insert into auth.users(id,email) values('{u}','bria-race@example.invalid');
insert into orgs(id,name,plan) values('{o}','Synthetic concurrent Bria','pro');
insert into memberships(user_id,org_id,role) values('{u}','{o}','owner');
insert into listings(id,org_id,agent_id,address) values('{l}','{o}','{u}','Synthetic race');
insert into capture_assets(id,listing_id,kind,storage_key,bucket,uploaded,duration_s) values('{a}','{l}','video','synthetic/race.mp4','renders',true,2);
update plan_entitlements set reels_per_month=50,cogs_ceiling_cents=2000 where plan='pro';"""
    run('race-setup',[*psql,'-q'],setup)
    reserve=f"select video_erase_reserve_direct('{o}','{u}','{l}','{b}','{a}','{idem}','{'a'*64}',2,'{config}','bria-video-v1');"
    def compete(name,query):
        with ThreadPoolExecutor(max_workers=8) as pool:
            outputs=list(pool.map(lambda i:run(f'{name}-{i}',[*psql,'-Atq'],query),range(8)))
        return [json.loads(s.strip()) for s in outputs]
    results=compete('race-reserve',reserve); assert sum(r['dispatch'] for r in results)==1
    job=results[0]['job']['id']; assert len({r['job']['id'] for r in results})==1
    mr=json.dumps({'request_id':'synthetic-mask','status_url':'https://engine.prod.bria-api.com/v2/status/synthetic-mask'})
    outputs=compete('race-mask-receipt',f"select video_erase_finish_stage('{job}','mask','completed','{mr}','https://outputs.example.com/mask.mp4');")
    results=compete('race-erase-admit',f"select video_erase_admit_stage('{o}','{u}','{job}','bria-video-v1');")
    assert sum(r['dispatch'] for r in results)==1
    checks=run('race-counts',[*psql,'-Atq'],f"select jsonb_build_object('jobs',(select count(*) from video_erase_jobs where batch_id='{b}'),'ledgers',(select count(*) from cost_ledger where meta->>'erase_job_id'='{job}'),'quota',(select count from rate_limits where key='reelmo:{o}'),'held',video_erase_held_cents('{o}'),'spend',org_month_spend_cents('{o}'));")
    assert json.loads(checks.strip())=={'jobs':1,'ledgers':1,'quota':1,'held':6,'spend':10}
    # The cancelled stage may receive a late paid receipt but cannot resurrect.
    run('race-cancel',[*psql,'-Atq'],f"select video_erase_cancel('{o}','{u}','{job}',null);")
    results=compete('race-cancelled-admit',f"select video_erase_admit_stage('{o}','{u}','{job}','bria-video-v1');")
    assert not any(r['dispatch'] for r in results)
    er=json.dumps({'request_id':'synthetic-erase','status_url':'https://engine.prod.bria-api.com/v2/status/synthetic-erase'})
    results=compete('race-late-erase-receipt',f"select video_erase_finish_stage('{job}','erase','completed','{er}','https://outputs.example.com/edited.mp4');")
    assert all(r['state']=='cancelled' and r['output_url'] is None for r in results)
    final=run('race-final',[*psql,'-Atq'],f"select jsonb_build_object('ledgers',(select count(*) from cost_ledger where meta->>'erase_job_id'='{job}'),'quota',(select count from rate_limits where key='reelmo:{o}'),'held',video_erase_held_cents('{o}'),'spend',org_month_spend_cents('{o}'));")
    assert json.loads(final.strip())=={'ledgers':2,'quota':0,'held':0,'spend':10}
    receipt['races']='8 concurrent reservations,8 mask receipts,8 erase admissions,8 cancelled admissions,8 late erase receipts; each paid admission/ledger exactly once'
    receipt['passed']=True
finally:
    if started: run('stop',[TOOLS['pg_ctl'],'-D',DATA,'-m','fast','-w','stop'])
    (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(str(OUT/'receipt.json'),flush=True)
