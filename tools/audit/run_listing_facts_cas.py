#!/usr/bin/env python3
"""Actual measurement CAS/legacy preservation in an owned disposable PostgreSQL.
No inherited credentials, hosted DB, network listener, provider calls or user edits.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[2]
SQL = ROOT / 'services/supabase'
MIGRATION = SQL / 'migrations/20261005024702_listing_facts_intent_cas.sql'
FIXTURE = SQL / 'tests/listing_facts_cas.sql'
TOOLS = {name: shutil.which(name) or str(Path('/opt/homebrew/opt/postgresql@17/bin') / name)
         for name in ('initdb', 'pg_ctl', 'psql', 'createdb')}
assert all(Path(p).is_file() and os.access(p, os.X_OK) for p in TOOLS.values()), 'Use existing PostgreSQL binaries'
OUT = Path(tempfile.mkdtemp(prefix='rendprop-listing-facts-pg-', dir='/tmp'))
DATA, SOCK = OUT / 'data', OUT / 'socket'
SOCK.mkdir()
ENV = {'PATH': '/opt/homebrew/bin:/usr/bin:/bin', 'LC_ALL': 'C', 'PGOPTIONS': '-c statement_timeout=30000 -c lock_timeout=15000'}
PORT = '55483'
SOURCES = [*sorted((SQL / 'migrations').glob('*.sql')), SQL / 'tests/ci-bootstrap.sql', FIXTURE, Path(__file__).resolve()]
receipt = {'kind': 'owned disposable local PostgreSQL; no hosted DB/providers', 'output': str(OUT), 'commands': [],
           'sourceHashes': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}}

def run(name, args, sql=None, refuses=None):
    p = subprocess.run([str(x) for x in args], input=sql, env=ENV, cwd=ROOT, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    log = OUT / (name + '.log')
    log.write_text(p.stdout)
    receipt['commands'].append({'name': name, 'exit': p.returncode, 'log_sha256': hashlib.sha256(log.read_bytes()).hexdigest()})
    if refuses:
        assert p.returncode != 0 and refuses in p.stdout, f'{name}: expected {refuses}, got {p.stdout}'
    elif p.returncode:
        raise RuntimeError(f'{name} failed: {p.stdout[-2500:]} ({log})')
    print(name + ': pass', flush=True)
    return p.stdout

started = False
try:
    receipt['postgresVersion'] = run('version', [TOOLS['psql'], '--version']).strip()
    run('initdb', [TOOLS['initdb'], '-D', DATA, '-U', 'postgres', '-A', 'trust', '--no-locale', '--encoding=UTF8'])
    run('start', [TOOLS['pg_ctl'], '-D', DATA, '-l', OUT / 'server.log', '-w', '-t', '30', '-o',
                  f"-k {SOCK} -p {PORT} -c listen_addresses='' -c shared_buffers=16MB", 'start'])
    started = True
    conn = ['-h', SOCK, '-p', PORT, '-U', 'postgres']
    run('createdb', [TOOLS['createdb'], *conn, 'listing_facts_audit'])
    psql = [TOOLS['psql'], '-X', '--no-password', *conn, '-d', 'listing_facts_audit', '-v', 'ON_ERROR_STOP=1']
    run('bootstrap', [*psql, '-q', '-f', SQL / 'tests/ci-bootstrap.sql'])
    for m in sorted((SQL / 'migrations').glob('*.sql')):
        run('apply-' + m.stem, [*psql, '-q', '-1', '-f', m])
    receipt['fresh'] = json.loads(run('fresh', [*psql, '-Atq', '-f', FIXTURE]).strip())
    run('replay', [*psql, '-q', '-1', '-f', MIGRATION])
    receipt['replay'] = json.loads(run('replay-fixture', [*psql, '-Atq', '-f', FIXTURE]).strip())

    # Two real concurrent SQL clients, not a sequential RPC stub.
    actor, other, org, listing = [str(uuid.uuid4()) for _ in range(4)]
    def quote(s): return "'"+s.replace("'","''")+"'"
    run('race-setup', [*psql,'-q'], f"""
insert into auth.users(id,email) values('{actor}','facts-race-owner@example.invalid'),('{other}','facts-race-agent@example.invalid');
insert into orgs(id,name,plan) values('{org}','Synthetic concurrent facts','pro');
insert into memberships(user_id,org_id,role) values('{actor}','{org}','owner'),('{other}','{org}','agent');
insert into listings(id,org_id,agent_id,address,sqft,tagline,details) values('{listing}','{org}','{actor}','Race property',2345,'Old', '{{"floorplan_asset_id":"unchanged"}}');
""")
    def race(fields):
        barrier=Barrier(2)
        def writer(item):
            who, expected, changes=item
            sql=f"set role service_role; select public.save_listing_facts('{who}','{org}','{listing}',{quote(json.dumps(expected))}::jsonb,{quote(json.dumps(changes))}::jsonb,'{{}}','{{}}');"
            barrier.wait(timeout=10)
            result=subprocess.run([*psql,'-Atq'],input=sql,env=ENV,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
            return {'exit':result.returncode,'conflict':'Listing details changed elsewhere' in result.stdout,'output':result.stdout[-1500:]}
        with ThreadPoolExecutor(max_workers=2) as pool:return list(pool.map(writer,fields))
    receipt['sameFieldRace']=race([(actor,{'tagline':'Old'},{'tagline':'Left'}),(other,{'tagline':'Old'},{'tagline':'Right'})])
    assert sum(x['exit']==0 for x in receipt['sameFieldRace'])==1 and sum(x['conflict'] for x in receipt['sameFieldRace'])==1,receipt['sameFieldRace']
    receipt['disjointFieldRace']=race([(actor,{'address':'Race property'},{'address':'Office address'}),(other,{'sqft':2345},{'sqft':2500})])
    assert all(x['exit']==0 for x in receipt['disjointFieldRace']),receipt['disjointFieldRace']
    after=json.loads(run('race-readback',[*psql,'-Atq'],f"select to_jsonb(l) from listings l where id='{listing}';").strip())
    assert after['address']=='Office address' and after['sqft']==2500 and after['details']['floorplan_asset_id']=='unchanged'
    receipt['raceReadback']={'address':after['address'],'sqft':after['sqft'],'planPreserved':True}
    receipt['sourceBoundAtEnd']=all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h for p,h in receipt['sourceHashes'].items())
    assert receipt['sourceBoundAtEnd']
    receipt['passed']=True
finally:
    if started:
        stop=subprocess.run([TOOLS['pg_ctl'],'-D',str(DATA),'-m','fast','-w','-t','30','stop'],env=ENV,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=40)
        (OUT/'stop.log').write_text(stop.stdout)
        receipt['stopped']=stop.returncode==0
    (OUT/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print('Evidence:',OUT,flush=True)
