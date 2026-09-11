#!/usr/bin/env python3
"""Real provider-journal SQL in a new socket-only DB; no production URLs."""
from pathlib import Path
import json
import os
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    bins = Path('/opt/homebrew/opt/postgresql@17/bin')
    out = Path(tempfile.mkdtemp(prefix='rendprop-provider-db-', dir='/tmp'))
    cluster, socket = out / 'cluster', out / 'socket'
    socket.mkdir(mode=0o700)
    env = {'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'TZ': 'UTC'}
    receipt = {'accepted': False, 'commands': [], 'cluster_stopped': False}
    print('EVIDENCE:', out, flush=True)

    def run(name, command, expected=0, stdin=None):
        p = subprocess.run(list(map(str, command)), cwd=root, env=env, input=stdin,
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
        (out / (name + '.log')).write_text(p.stdout)
        receipt['commands'].append({'name': name, 'exit': p.returncode})
        assert p.returncode == expected, f'{name}: exit {p.returncode}; see {out}'
        print(name, 'exit', p.returncode, flush=True)
        return p.stdout
    connection = ['-h', socket, '-p', '55449', '-U', 'postgres']
    psql = [bins / 'psql', '-X', '--no-password', *connection, '-d', 'rendprop_provider_audit', '-v', 'ON_ERROR_STOP=1']
    target = root / 'services/supabase/migrations/0041_spatial_provider_attempts.sql'
    test = root / 'services/supabase/tests/spatial_provider_attempts.sql'
    started = False
    try:
        run('initdb', [bins / 'initdb', '-D', cluster, '-U', 'postgres', '-A', 'trust', '--no-locale', '--encoding=UTF8'])
        run('start', [bins / 'pg_ctl', '-D', cluster, '-l', out / 'postgres.log', '-w', '-t', '30', '-o',
                      f"-k {socket} -p 55449 -c listen_addresses='' -c shared_buffers=16MB -c max_connections=10", 'start'])
        started = True
        run('createdb', [bins / 'createdb', '--no-password', *connection, 'rendprop_provider_audit'])
        assert run('identity', psql + ['-Atc', "select current_setting('data_directory'),current_setting('listen_addresses'),current_database();"]).strip() == f'{cluster}||rendprop_provider_audit'
        env['PGOPTIONS'] = '-c statement_timeout=15000 -c lock_timeout=5000'
        run('bootstrap', psql + ['-q', '-f', root / 'services/supabase/tests/ci-bootstrap.sql'])
        run('auth-schema', psql + ['-qc', 'alter table auth.users add column is_anonymous boolean not null default false;'])
        for migration in sorted((root / 'services/supabase/migrations').glob('*.sql')):
            if migration.name < '0041':
                run('apply-' + migration.stem, psql + ['-q', '-1', '-f', migration])
        assert 'provider assertion failed: durable provider table exists' in run('before', psql + ['-f', test], 3)
        for phase in ('after', 'replayed'):
            run('apply-' + phase, psql + ['-q', '-1', '-f', target])
            assert 'PASS: 20 provider SQL assertions' in run(phase, psql + ['-f', test])
        definition = run('definition', psql + ['-Atc', "select pg_get_functiondef('spatial_provider_attempt_update(uuid,uuid,uuid,text,jsonb)'::regprocedure);"])
        needle = "'dispatch',dispatch"
        assert definition.count(needle) == 1
        run('mutate', psql, stdin=definition.replace(needle, "'dispatch',true"))
        assert 'provider assertion failed: plan replay never grants another dispatch' in run('reject-mutant', psql + ['-f', test], 3)
        run('restore', psql + ['-q', '-1', '-f', target])
        assert 'PASS: 20 provider SQL assertions' in run('restored', psql + ['-f', test])
        receipt['accepted'] = True
    finally:
        if started:
            run('stop', [bins / 'pg_ctl', '-D', cluster, '-m', 'fast', '-w', '-t', '30', 'stop'])
            receipt['cluster_stopped'] = True
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert receipt['accepted'] and receipt['cluster_stopped']


if __name__ == '__main__':
    main()
