#!/usr/bin/env python3
"""Owned local PG only, all migrations ordered,0055/0056 twice, real transactions."""
from pathlib import Path
import hashlib,json,os,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[4]
SQL=ROOT/'services/supabase'
BIN=Path('/opt/homebrew/opt/postgresql@17/bin')
OUT=Path(tempfile.mkdtemp(prefix='rendprop-erase-pg-',dir='/tmp'))
DATA=OUT/'data';SOCK=OUT/'socket';SOCK.mkdir()
ENV={'PATH':'/opt/homebrew/bin:/usr/bin:/bin','LC_ALL':'C','PGOPTIONS':'-c statement_timeout=30000 -c lock_timeout=5000'}
receipt={'kind':'native PostgreSQL17, not container proof','commands':[],'output':str(OUT)}
def run(name,args,expected=0):
    p=subprocess.run([str(x) for x in args],env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
    log=OUT/(name+'.log');log.write_text(p.stdout)
    receipt['commands'].append({'name':name,'exit':p.returncode,'log_sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
    if p.returncode!=expected:raise RuntimeError(f'{name} failed; see {log}')
    print(name+': pass',flush=True);return p.stdout
started=False
try:
    run('initdb',[BIN/'initdb','-D',DATA,'-U','postgres','-A','trust','--no-locale','--encoding=UTF8'])
    run('start',[BIN/'pg_ctl','-D',DATA,'-l',OUT/'server.log','-w','-t','30','-o',f"-k {SOCK} -p 55455 -c listen_addresses='' -c shared_buffers=16MB",'start']);started=True
    conn=['-h',SOCK,'-p','55455','-U','postgres']
    run('createdb',[BIN/'createdb',*conn,'erase_audit'])
    psql=[BIN/'psql','-X','--no-password',*conn,'-d','erase_audit','-v','ON_ERROR_STOP=1']
    run('bootstrap',[*psql,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
    migrations=sorted((SQL/'migrations').glob('*.sql'))
    receipt['migrations']={m.name:hashlib.sha256(m.read_bytes()).hexdigest() for m in migrations}
    for migration in migrations:run('apply-'+migration.stem,[*psql,'-q','-1','-f',migration])
    run('test-first',[*psql,'-f',SQL/'tests/video_erase.sql'])
    run('legacy-marker-first',[*psql,'-f',SQL/'tests/legacy_photo_fallback.sql'])
    run('replay-0055',[*psql,'-q','-1','-f',SQL/'migrations/0055_video_reflection_jobs.sql'])
    run('replay-0056',[*psql,'-q','-1','-f',SQL/'migrations/0056_active_photo_fallback.sql'])
    run('legacy-marker-replay',[*psql,'-f',SQL/'tests/legacy_photo_fallback.sql'])
    result=run('test-replay',[*psql,'-f',SQL/'tests/video_erase.sql'])
    concurrency=run('concurrency',['/usr/bin/python3',ROOT/'tools/audit/call-20260919/web/erase-concurrency.py',*psql])
    receipt['concurrency']=json.loads(concurrency)
    # The full existing invariant inventory must keep only its explicit #155 red.
    def invariants(name,connection):
        output=run(name,[*connection,'-f',SQL/'tests/invariants.sql'],expected=3)
        red=[line for line in output.splitlines() if '| f ' in line]
        assert len(red)==1 and 'each astra ceiling clears its route' in red[0],red
        return red
    # Concurrency alters its disposable fixtures/plan, so run full invariants in
    # the independently rebuilt historical replay database instead.
    run('createdb-historical',[BIN/'createdb',*conn,'erase_replay'])
    historical=[BIN/'psql','-X','--no-password',*conn,'-d','erase_replay','-v','ON_ERROR_STOP=1']
    run('bootstrap-historical',[*historical,'-q','-f',SQL/'tests/ci-bootstrap.sql'])
    for m in migrations:
        run('historical-'+m.stem,[*historical,'-q','-1','-f',m])
        if m.name.startswith(('0005b_','0008b_')) or m.name>='0009':run('historical-replay-'+m.stem,[*historical,'-q','-1','-f',m])
    receipt['kept_red']=invariants('historical-invariants',historical)
    run('historical-erase',[*historical,'-f',SQL/'tests/video_erase.sql'])
    run('historical-marker',[*historical,'-f',SQL/'tests/legacy_photo_fallback.sql'])
    receipt['result']=result.strip();receipt['passed']=True
finally:
    if started:run('stop',[BIN/'pg_ctl','-D',DATA,'-m','fast','-w','stop'])
    (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(str(OUT/'receipt.json'))
