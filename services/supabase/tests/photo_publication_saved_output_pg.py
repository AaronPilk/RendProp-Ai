#!/usr/bin/env python3
"""Owned PG17 accepted-output publication chain; no network or actual media."""
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
import argparse, datetime, hashlib, json, os, shutil, subprocess, tempfile

ROOT = Path(__file__).resolve().parents[3]
SQL = ROOT / 'services/supabase'
MIG = SQL / 'migrations/20261113213000_photo_publication_saved_output_compat.sql'
AUTH_MIG = SQL / 'migrations/20261113222000_photo_publication_authenticated_read.sql'
FIX = SQL / 'tests/photo_publication_saved_output.sql'
PG = Path('/opt/homebrew/opt/postgresql@17/bin')
EXPECTED = '8c487dce9151ddaba5d721b3514ef83c4ff9d5430f4e7420a5464c7d473736dc'
EXPECTED_AUTH = '6441321c2c6d646eab5fe5e920148f12b49e2654ea058d945fbce3686b0d3cc3'
REFUSAL = 'Review changed accepted-photo publication source before saved-output compatibility'
os.umask(0o077)
p = argparse.ArgumentParser(); p.add_argument('--evidence-dir', required=True, type=Path); args = p.parse_args()
OUT = args.evidence_dir.resolve(); OUT.mkdir(parents=True, mode=0o700, exist_ok=False)
DATA = OUT / 'owned-pg'; SOCK = Path(tempfile.mkdtemp(prefix='rp-pub-sock-', dir='/tmp'))
ENV = {'PATH': str(PG)+':/usr/bin:/bin', 'HOME': os.environ['HOME'], 'LC_ALL': 'C', 'TZ': 'UTC', 'PGOPTIONS': '-c statement_timeout=30000 -c lock_timeout=15000'}
if 'CODEX_HOME' in os.environ: ENV['CODEX_HOME'] = os.environ['CODEX_HOME']
sha = lambda f: hashlib.sha256(f.read_bytes()).hexdigest()
MIGRATIONS = sorted((SQL/'migrations').glob('*.sql'))
SOURCES = [*MIGRATIONS, FIX, Path(__file__).resolve(), SQL/'tests/fresh_schema_migrations.py', SQL/'tests/ci-bootstrap.sql', ROOT/'tools/audit/run_database_regression.py']
hashes = lambda: {str(f.relative_to(ROOT)): sha(f) for f in SOURCES}
r = {'schema':'photo-publication-saved-output-pg17-v2','status':'running','startedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'sourceHead':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'sourceStatus':subprocess.check_output(['git','status','--short'],cwd=ROOT,text=True).splitlines(),'sourceBefore':hashes(),'commands':[],'productionActions':False,'networkCalls':0,'providerCalls':0,'syntheticByteReceiptsOnly':True,'homePreserved':True,'codexHomePreserved':True}
started = False
def save(): (OUT/'receipt.json').write_text(json.dumps(r,indent=2)+'\n')
def run(name, argv, body=None, refuses=None):
    assert shutil.disk_usage(ROOT).free >= 3*1024**3
    c = subprocess.run([str(x) for x in argv], input=body, env=ENV, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    f=OUT/(name+'.log'); f.write_text(c.stdout)
    r['commands'].append({'name':name,'argv':[str(x)for x in argv],'exit':c.returncode,'log':str(f),'sha256':sha(f)}); save()
    if refuses: assert c.returncode != 0 and refuses in c.stdout, (name,c.stdout[-5000:])
    else: assert c.returncode == 0, (name,c.stdout[-5000:])
    return c.stdout
def query(name, body): return run(name,[*PSQL,'-Atq'],body)
def catalog(name): return query(name,"select md5(string_agg(oid::regprocedure::text||pg_get_functiondef(oid)||proowner::text||coalesce(proacl::text,'')||coalesce(proconfig::text,''),'|' order by oid::regprocedure::text))from pg_proc where pronamespace='public'::regnamespace and prokind='f';")
try:
    assert sha(MIG)==EXPECTED and sha(AUTH_MIG)==EXPECTED_AUTH, 'Frozen migration changed'
    r['runtime']={n:{'path':str(PG/n),'sha256':sha((PG/n).resolve())}for n in ['initdb','pg_ctl','createdb','psql','postgres']}
    r['postgresVersion']=run('pg-version',[PG/'postgres','--version']).strip(); assert ' 17.11 ' in r['postgresVersion']
    schema,live=partition_fresh_migrations(MIGRATIONS); r['excludedLiveStateOnly']=[m.name for m in live]
    run('initdb',[PG/'initdb','-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
    run('start',[PG/'pg_ctl','-D',DATA,'-l',OUT/'postgres.log','-w','-t','30','-o',f"-k {SOCK} -p 55633 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=10",'start']); started=True
    r['postmasterPid']=int((DATA/'postmaster.pid').read_text().splitlines()[0]); assert r['postmasterPid']>0
    conn=['-h',SOCK,'-p','55633','-U','postgres']; run('createdb',[PG/'createdb',*conn,'photo_publication_saved_output'])
    PSQL=[PG/'psql','-X','--no-password',*conn,'-d','photo_publication_saved_output','-v','ON_ERROR_STOP=1']
    assert query('owned-identity',"select current_setting('data_directory')||'|'||current_setting('listen_addresses');").strip()==str(DATA)+'|'
    run('bootstrap',[*PSQL,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
    for i,m in enumerate(schema):
        if m in (MIG,AUTH_MIG): continue
        run('apply-'+m.stem,[*PSQL,'-q','-1','-f',m])
        if i%60==0: print(f'Applied {i+1}/{len(schema)} schema migrations',flush=True)
    r['predecessorMd5']=query('predecessor-md5',"select md5(prosrc)from pg_proc where oid='public.photo_publication_source(uuid,uuid,uuid,uuid)'::regprocedure;").strip()
    assert r['predecessorMd5']=='aa0c5bc785a397f018d005a950f0fc93'
    run('baseline-reproduced',[*PSQL,'-Atq','-f',FIX],refuses='RP404: This saved photo is unavailable for publication')
    before=json.loads(query('metadata-before',"select (to_jsonb(p)-'prosrc'-'prosqlbody')::text from pg_proc p where oid='public.photo_publication_source(uuid,uuid,uuid,uuid)'::regprocedure;"))
    run('apply-frozen-compatibility',[*PSQL,'-q','-f',MIG])
    after=json.loads(query('metadata-after',"select (to_jsonb(p)-'prosrc'-'prosqlbody')::text from pg_proc p where oid='public.photo_publication_source(uuid,uuid,uuid,uuid)'::regprocedure;")); assert before==after
    assert query('pre-auth-body-md5',"select md5(prosrc)from pg_proc where oid='public.photo_publication_source(uuid,uuid,uuid,uuid)'::regprocedure;").strip()=='1fc4ef9f9702ca88d958915ee3ca5f2e'
    run('authenticated-read-baseline-refused',[*PSQL,'-Atq','-f',FIX],refuses='PUBLICATION FAIL: authenticated prepared output passes Presenter access')
    run('apply-authenticated-read-repair',[*PSQL,'-q','-f',AUTH_MIG])
    assert query('post-auth-body-md5',"select md5(prosrc)from pg_proc where oid='public.photo_publication_source(uuid,uuid,uuid,uuid)'::regprocedure;").strip()=='7320436e2ec027c83f3a2eddf50dc7af'
    auth_after=json.loads(query('auth-metadata-after',"select (to_jsonb(p)-'prosrc'-'prosqlbody')::text from pg_proc p where oid='public.photo_publication_source(uuid,uuid,uuid,uuid)'::regprocedure;")); assert before==auth_after
    r['ownerAclSecurityConfigUnchanged']=True
    original=query('current-source',"select pg_get_functiondef('public.photo_publication_source(uuid,uuid,uuid,uuid)'::regprocedure);")
    for stage in ['fresh','repeat']:
        out=run(stage+'-full-chain',[*PSQL,'-Atq','-f',FIX]); rows=[json.loads(x)for x in out.splitlines()if x.startswith('{')and'"suite": "photo-publication-saved-output"'in x]
        assert len(rows)==1 and rows[0]['passed'] and rows[0]['assertions']==38; r[stage]=rows[0]
    current=catalog('catalog-before-replay')
    run('exact-authenticated-replay',[*PSQL,'-q','-f',AUTH_MIG]); assert catalog('catalog-after-auth-replay')==current
    run('one-shot-replay-refused',[*PSQL,'-q','-f',MIG],refuses=REFUSAL); assert catalog('catalog-after-replay')==current
    r['oneShotReplayRefusedWithoutCatalogChange']=True
    needle="and saved_asset.sha256=e.output->>'sha256'"; assert original.count(needle)==1
    query('compile-hash-guard-omission',original.replace(needle,''))
    run('hash-omission-detected',[*PSQL,'-Atq','-f',FIX],refuses='PUBLICATION FAIL: NULL output hash refuses')
    query('restore-hash-guard',original); assert catalog('catalog-after-control')==current
    r['compiledGuardOmissionDetected']=True
    assert hashes()==r['sourceBefore'],'Consumed source changed'
    r['status']='passed'
except BaseException as e:
    r['status']='failed'; r['error']=repr(e); raise
finally:
    try:
        if started:
            c=subprocess.run([str(PG/'pg_ctl'),'-D',str(DATA),'-m','immediate','-w','-t','30','stop'],env=ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
            (OUT/'stop.log').write_text(c.stdout); r['stopExit']=c.returncode
            pid=r['postmasterPid']
            try: os.kill(pid,0); r['postmasterAbsent']=False
            except ProcessLookupError: r['postmasterAbsent']=True
            assert c.returncode==0 and r['postmasterAbsent'],'Owned postmaster cleanup failed'
        else: r['postmasterAbsent']=True
        shutil.rmtree(DATA,ignore_errors=True); shutil.rmtree(SOCK,ignore_errors=True)
        r['ownedDataRemoved']=not DATA.exists(); r['ownedSocketRemoved']=not SOCK.exists()
    except BaseException as e:
        r['cleanupError']=repr(e); r['status']='failed'
    r['sourceAfter']=hashes(); r['sourceStable']=r['sourceAfter']==r['sourceBefore']
    if not r['sourceStable']: r['status']='failed'
    r['finishedAt']=datetime.datetime.now(datetime.timezone.utc).isoformat(); save()
    print(json.dumps({'status':r['status'],'receipt':str(OUT/'receipt.json')}),flush=True)
