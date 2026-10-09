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
MIGRATION = SQL / 'migrations/20261006193633_cas_conflicts_terminal.sql'
TERMINAL_PREREQUISITES = [SQL / 'migrations' / name for name in (
    '20261004220253_listing_measurement_compare_and_set.sql',
    '20261005024702_listing_facts_intent_cas.sql',
    '20261005034754_studio_floorplan_attachment_cas.sql',
    '20261005150951_nearby_places_reviewed_facts.sql',
)]
LIBRARY_AUTHORITY = SQL / 'migrations/20261009192550_team_private_listing_libraries.sql'
FIXTURE = SQL / 'tests/listing_facts_cas.sql'
NEARBY_FIXTURE = SQL / 'tests/nearby_places_facts.sql'
FLOORPLAN_FIXTURE = SQL / 'tests/studio_floorplan_cas.sql'
TOOLS = {name: shutil.which(name) or str(Path('/opt/homebrew/opt/postgresql@17/bin') / name)
         for name in ('initdb', 'pg_ctl', 'psql', 'createdb')}
assert all(Path(p).is_file() and os.access(p, os.X_OK) for p in TOOLS.values()), 'Use existing PostgreSQL binaries'
OUT = Path(tempfile.mkdtemp(prefix='rendprop-listing-facts-pg-', dir='/tmp'))
DATA, SOCK = OUT / 'data', OUT / 'socket'
SOCK.mkdir()
ENV = {'PATH': '/opt/homebrew/bin:/usr/bin:/bin', 'LC_ALL': 'C', 'PGOPTIONS': '-c statement_timeout=30000 -c lock_timeout=15000'}
PORT = '55483'
SOURCES = [*sorted((SQL / 'migrations').glob('*.sql')), SQL / 'tests/ci-bootstrap.sql', FIXTURE, NEARBY_FIXTURE, FLOORPLAN_FIXTURE, Path(__file__).resolve()]
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
    run('createdb', [TOOLS['createdb'], *conn, 'rendprop_audit'])
    psql = [TOOLS['psql'], '-X', '--no-password', *conn, '-d', 'rendprop_audit', '-v', 'ON_ERROR_STOP=1']
    run('bootstrap', [*psql, '-q', '-f', SQL / 'tests/ci-bootstrap.sql'])
    for m in sorted((SQL / 'migrations').glob('*.sql')):
        run('apply-' + m.stem, [*psql, '-q', '-1', '-f', m])
    receipt['fresh'] = json.loads(run('fresh', [*psql, '-Atq', '-f', FIXTURE]).strip())
    receipt['nearbyFresh'] = json.loads(run('nearby-fresh', [*psql, '-Atq', '-f', NEARBY_FIXTURE]).strip())
    receipt['floorplanFresh'] = json.loads(run('floorplan-fresh', [*psql, '-Atq', '-f', FLOORPLAN_FIXTURE]).strip().splitlines()[-1])
    signatures = [
        'public.save_listing_facts(uuid,uuid,uuid,jsonb,jsonb,jsonb,jsonb)',
        'public.save_listing_measurements(uuid,uuid,uuid,text,text)',
        'public.studio_attach_floorplan(uuid,uuid,uuid,uuid,jsonb,text)',
    ]
    catalog = "select jsonb_agg(jsonb_build_object('identity',oid::regprocedure::text,'body',prosrc,'owner',proowner,'acl',proacl::text,'config',proconfig,'security',prosecdef,'volatility',provolatile) order by proname) from pg_proc where oid=any(array[" + ','.join("'" + s + "'::regprocedure" for s in signatures) + "]);"
    final_catalog = run('library-catalog-before-historical-replay', [*psql, '-Atq'], catalog)
    # Test the exact historical transformation and its drift/ACL refusals on
    # the bodies it reviewed. The final Team-library migration intentionally
    # supersedes those bodies; it must be restored before current assertions.
    for prerequisite in TERMINAL_PREREQUISITES:
        run('terminal-prerequisite-' + prerequisite.stem, [*psql, '-q', '-1', '-f', prerequisite])
    run('historical-terminal-transform', [*psql, '-q', '-1', '-f', MIGRATION])
    before = run('terminal-catalog-before', [*psql, '-Atq'], catalog)
    assert all("errcode='40001'" not in row['body'] for row in json.loads(before))
    run('replay', [*psql, '-q', '-1', '-f', MIGRATION])
    assert run('terminal-catalog-after-replay', [*psql, '-Atq'], catalog) == before
    receipt['historicalReplay'] = json.loads(run('historical-replay-fixture', [*psql, '-Atq', '-f', FIXTURE]).strip())
    receipt['nearbyHistoricalReplay'] = json.loads(run('nearby-historical-replay', [*psql, '-Atq', '-f', NEARBY_FIXTURE]).strip())
    # The historical body checked listing existence before its role guard.
    # The final private-library body correctly refuses the same two requests
    # with 42501 first. Bind this historical-only copy to those exact labels;
    # the unmodified, stronger final fixture runs both before and after replay.
    historical_floorplan = FLOORPLAN_FIXTURE.read_text()
    for label in ('Scoped actor cannot target foreign listing', 'Deleted listing cannot attach'):
        anchor = "'42501','" + label + "'"
        assert historical_floorplan.count(anchor) == 1, 'Historical floorplan refusal anchor changed: ' + label
        historical_floorplan = historical_floorplan.replace(anchor, "'P0002','" + label + "'")
    historical_floorplan_path = OUT / 'historical-floorplan-fixture.sql'
    historical_floorplan_path.write_text(historical_floorplan)
    receipt['historicalFloorplanOracle'] = {'expectedExistenceFirstCode': 'P0002', 'finalFixtureUsesAuthorityFirstCode': '42501',
        'sourceSHA256': hashlib.sha256(FLOORPLAN_FIXTURE.read_bytes()).hexdigest(),
        'copySHA256': hashlib.sha256(historical_floorplan_path.read_bytes()).hexdigest(),
        'onlyChangedLabels': ['Scoped actor cannot target foreign listing', 'Deleted listing cannot attach']}
    receipt['floorplanHistoricalReplay'] = json.loads(run('floorplan-historical-replay', [*psql, '-Atq', '-f', historical_floorplan_path]).strip().splitlines()[-1])

    # Each complete-body precondition must refuse unknown drift, and the entire
    # attempted migration must roll back. These changes exist only in this owned
    # socket-only database; no hosted requests or genuine transaction faults.
    receipt['terminalBodyGuards'] = []
    for i, signature in enumerate(signatures):
        drift = f"""begin;
do $drift$ declare fn oid:='{signature}'::regprocedure; b text; d text; begin
 select prosrc into b from pg_proc where oid=fn; d:=pg_get_functiondef(fn);
 execute replace(d,b,b||E'\\n-- synthetic unreviewed body drift\\n');
end $drift$;
"""
        run('terminal-drift-guard-' + str(i), [*psql, '-Atq'], drift + MIGRATION.read_text() + '\nrollback;', refuses='Terminal CAS reviewed body changed:')
        assert run('terminal-drift-rollback-' + str(i), [*psql, '-Atq'], catalog) == before
        receipt['terminalBodyGuards'].append({'identity': signature, 'unreviewedBodyRefused': True, 'rollbackPreservedAllBodiesAndAuthority': True})
    grant_drift = 'begin; grant execute on function ' + signatures[0] + ' to authenticated;\n'
    run('terminal-authority-guard', [*psql, '-Atq'], grant_drift + MIGRATION.read_text() + '\nrollback;', refuses='Terminal CAS authority prerequisite changed:')
    assert run('terminal-authority-rollback', [*psql, '-Atq'], catalog) == before
    receipt['terminalAuthorityGuard'] = {'exposedClientGrantRefused': True, 'rollbackPreservedAllBodiesAndAuthority': True}

    # Restore the old semantic SQLSTATE without removing CAS comparisons. The
    # fixture must reject the transient code itself, even though values remain
    # protected. Then restore the exact additive production migration.
    run('transient-code-control-install', [*psql, '-Atq'], "do $$ declare d text; begin d:=pg_get_functiondef('" + signatures[0] + "'::regprocedure); execute replace(d,'errcode=''PT409''','errcode=''40001'''); end $$;")
    run('transient-code-control-fixture', [*psql, '-Atq', '-f', FIXTURE], refuses='expected PT409, got 40001')
    run('restore-terminal-code-after-control', [*psql, '-q', '-1', '-f', MIGRATION])
    assert run('terminal-catalog-after-control', [*psql, '-Atq'], catalog) == before
    receipt['terminalCodeNegativeControl'] = {'restoredTransientApplicationCodeCaught': True, 'exactHistoricalTerminalAuthorityRestored': True}

    run('restore-library-authority', [*psql, '-q', '-1', '-f', LIBRARY_AUTHORITY])
    assert run('library-catalog-after-replay', [*psql, '-Atq'], catalog) == final_catalog
    receipt['finalLibraryBodiesAndAuthorityPreserved'] = True
    receipt['replay'] = json.loads(run('replay-fixture', [*psql, '-Atq', '-f', FIXTURE]).strip())
    receipt['nearbyReplay'] = json.loads(run('nearby-replay', [*psql, '-Atq', '-f', NEARBY_FIXTURE]).strip())
    receipt['floorplanReplay'] = json.loads(run('floorplan-replay', [*psql, '-Atq', '-f', FLOORPLAN_FIXTURE]).strip().splitlines()[-1])

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
