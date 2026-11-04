#!/usr/bin/env python3
"""Synthetic native photo lineage proof in an owned socket-only PostgreSQL cluster."""
from pathlib import Path
from fresh_schema_migrations import partition_fresh_migrations
import json, os, shutil, subprocess, tempfile

root = Path(__file__).resolve().parents[3]
sql = root / 'services/supabase'
out = Path(tempfile.mkdtemp(prefix='native-photo-backup-proof-'))
data = out / 'data'
sock = Path(tempfile.mkdtemp(prefix='native-photo-backup-sock-', dir='/tmp'))
tools = {name: shutil.which(name) for name in ('initdb', 'pg_ctl', 'createdb', 'psql')}
assert all(tools.values())
env = {**os.environ, 'LC_ALL': 'C', 'PGOPTIONS': '-c statement_timeout=30000 -c lock_timeout=15000'}
started = False

def run(name, argv):
    result = subprocess.run([str(value) for value in argv], cwd=root, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
    (out / (name + '.log')).write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f'{name}: {result.stdout[-4000:]}')
    return result.stdout

try:
    run('initdb', [tools['initdb'], '-D', data, '-U', 'postgres', '-A', 'trust', '--no-locale', '--encoding=UTF8'])
    run('start', [tools['pg_ctl'], '-D', data, '-l', out / 'postgres.log', '-w', '-t', '30',
                  '-o', f"-k {sock} -p 55541 -c listen_addresses='' -c shared_buffers=16MB", 'start'])
    started = True
    conn = ['-h', sock, '-p', '55541', '-U', 'postgres']
    run('createdb', [tools['createdb'], *conn, 'native_photo_backup_proof'])
    psql = [tools['psql'], '-X', '--no-password', *conn, '-d', 'native_photo_backup_proof', '-v', 'ON_ERROR_STOP=1']
    run('bootstrap', [*psql, '-q', '-f', sql / 'tests/ci-bootstrap.sql'])
    migrations = partition_fresh_migrations(sorted((sql / 'migrations').glob('*.sql')))[0]
    for migration in migrations:
        run('apply-' + migration.stem, [*psql, '-q', '-1', '-f', migration])
    result = run('native-photo-backup', [*psql, '-Atq', '-f', sql / 'tests/native_photo_backup_versions.sql'])
    proof = [json.loads(line) for line in result.splitlines() if line.startswith('{') and 'assertions' in line]
    assert len(proof) == 1 and proof[0]['passed'] and proof[0]['assertions'] >= 15, proof
    print(json.dumps({'passed': True, 'assertions': proof[0]['assertions'], 'migrations': len(migrations),
                      'evidence': str(out)}))
finally:
    if started:
        subprocess.run([tools['pg_ctl'], '-D', str(data), '-m', 'immediate', '-w', 'stop'],
                       env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
    shutil.rmtree(data, ignore_errors=True)
    shutil.rmtree(sock, ignore_errors=True)
