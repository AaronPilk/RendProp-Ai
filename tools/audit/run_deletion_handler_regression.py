#!/usr/bin/env python3
"""Exercise the actual baseline/new /me handler offline with asserted results.

Only temporary test artifacts are written. Provider URLs are fixtures, Deno
network permission is denied for every test run, and the subprocesses inherit
no credentials. The one preparation step (`deno install --entrypoint`) may use
the network to fill the Deno cache with the pinned std/npm imports; it runs no
handler or test code.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

BASE = 'baf77f93082e608b1321fdb0927bdabba08bb3fa'
# Exact counts, so a partial or skipped run cannot look green. deletion.test.ts
# registers 39 tests and logic.test.ts 14; the baseline control filters
# everything but "adoption winner" out of deletion.test.ts.
FULL_SUITE = 53
BASELINE_FILTERED_OUT = 38
# Homebrew locations this gate was first written against; PATH wins when it
# has the tool (CI installs deno with setup-deno and git is /usr/bin/git).
HOMEBREW_DENO = '/opt/homebrew/bin/deno'
PREPARATION_ENV_PASSTHROUGH = (
    'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'no_proxy',
    'DENO_CERT', 'DENO_TLS_CA_STORE', 'SSL_CERT_FILE', 'NPM_CONFIG_REGISTRY',
)


def tool(name, fallback):
    found = shutil.which(name) or (fallback if Path(fallback).is_file() else None)
    if not found:
        raise SystemExit(f'{name} was not found on PATH or at {fallback}')
    return str(Path(found).resolve())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-baseline-control', action='store_true',
                        help='Run only the positive suite when the baseline commit is not in the local git objects '
                             '(a shallow or snapshot checkout). The receipt records that the negative control did not run.')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = Path(tempfile.mkdtemp(prefix='rendprop-deletion-handler-', dir='/tmp'))
    deno, git = tool('deno', HOMEBREW_DENO), tool('git', '/usr/bin/git')
    # Discovered, not guessed: the same cache `deno` would use on this machine.
    info = json.loads(subprocess.check_output([deno, 'info', '--no-config', '--json'], text=True))
    env = {'PATH': os.pathsep.join(dict.fromkeys([str(Path(deno).parent), str(Path(git).parent), '/usr/bin', '/bin'])),
           'DENO_DIR': info['denoDir'], 'NO_COLOR': '1', 'DENO_NO_PROMPT': '1'}
    preparation_env = dict(env, **{k: os.environ[k] for k in PREPARATION_ENV_PASSTHROUGH if k in os.environ})
    functions = root / 'services/supabase/functions'
    receipt = {'accepted': False, 'baselineCommit': BASE, 'sourceHashes': {}, 'commands': [],
               'deno': deno, 'denoVersion': info['denoVersion'], 'expectedTests': FULL_SUITE}
    paths = [Path(__file__), *sorted((functions / '_shared').glob('*.ts')), *sorted((functions / 'me').glob('*.ts'))]
    for path in paths:
        receipt['sourceHashes'][str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f'EVIDENCE: {out}', flush=True)

    def run(label, args, expected, cwd=root, environment=env):
        result = subprocess.run(args, cwd=cwd, env=environment, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=180)
        log = out / f'{label}.log'
        log.write_text(result.stdout)
        receipt['commands'].append({'name': label, 'command': args, 'exit': result.returncode,
                                    'log': str(log), 'sha256': hashlib.sha256(log.read_bytes()).hexdigest()})
        assert result.returncode == expected, f'{label}: unexpected exit {result.returncode}; {log}'
        print(f'{label}: exit={result.returncode}', flush=True)
        return result.stdout

    # No node_modules directory: the npm import resolves from the global cache
    # the preparation step fills, and every test run is --cached-only.
    deno_test = [deno, 'test', '--cached-only', '--no-config', '--no-lock', '--node-modules-dir=none',
                 '--allow-env', '--allow-read', '--deny-net', '--deny-run', '--deny-write']
    try:
        run('prepare-dependencies', [deno, 'install', '--no-config', '--no-lock', '--node-modules-dir=none',
                                     '--entrypoint', 'me/deletion.test.ts', 'me/logic.test.ts'],
            0, cwd=functions, environment=preparation_env)
        receipt['preparation'] = {'networkPermitted': True,
                                  'inheritedEnvironment': sorted(k for k in PREPARATION_ENV_PASSTHROUGH if k in preparation_env)}
        baseline_present = subprocess.run([git, 'cat-file', '-e', BASE + '^{commit}'], cwd=root, env=env,
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10).returncode == 0
        if not baseline_present and not args.skip_baseline_control:
            raise SystemExit(f'Baseline commit {BASE} is not in the local git objects; fetch full history '
                             '(git fetch --unshallow) so the negative control can run, or pass --skip-baseline-control '
                             'to run the positive suite alone with that recorded in the receipt')
        if baseline_present:
            before = out / 'baseline' / 'me'
            before.mkdir(parents=True)
            (before.parent / '_shared').symlink_to(functions / '_shared', target_is_directory=True)
            # Reuse unchanged actual shared helpers, not handwritten replacement
            # implementations. Every shared source is compared with the baseline.
            for path in sorted((functions / '_shared').glob('*.ts')):
                saved = subprocess.run([git, 'show', f'{BASE}:{path.relative_to(root)}'], cwd=root,
                                       env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
                assert saved.returncode == 0 and saved.stdout == path.read_bytes(), f'Shared helper changed since baseline: {path.name}'
            for name in ['index.ts', 'logic.ts']:
                saved = subprocess.run([git, 'show', f'{BASE}:services/supabase/functions/me/{name}'], cwd=root,
                                       env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
                assert saved.returncode == 0
                (before / name).write_bytes(saved.stdout)
            (before / 'deletion.test.ts').write_bytes((functions / 'me/deletion.test.ts').read_bytes())
            baseline = run('before-stale-handler', deno_test + ['--filter', 'adoption winner', str(before / 'deletion.test.ts')], 1)
            assert 'adopted workspace was destroyed from stale ownership' in baseline
            assert re.search(rf'0 passed \| 1 failed \| {BASELINE_FILTERED_OUT} filtered out', baseline), 'Unexpected baseline execution count'
            receipt['baselineControl'] = {'executed': True, 'detected': True}
        else:
            receipt['baselineControl'] = {'executed': False,
                                          'reason': f'commit {BASE} not in local git objects; --skip-baseline-control given'}
            print(f'WARNING: negative baseline control skipped; {BASE} is not in the local git objects', flush=True)
        after = run('after-handler-and-logic', deno_test + [str(functions / 'me/deletion.test.ts'), str(functions / 'me/logic.test.ts')], 0)
        # Match the summary, not test titles containing words like "ignored".
        assert re.search(rf'^ok \| {FULL_SUITE} passed \| 0 failed \([^\n]+\)$', after, re.MULTILINE), 'Unexpected complete-suite summary'
        receipt['accepted'] = True
    finally:
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert receipt['accepted'], f'Handler gate failed: {out}'
    control = 'baseline negative control detected' if receipt['baselineControl']['executed'] else 'baseline negative control SKIPPED'
    print(f'PASS: {FULL_SUITE} handler/logic tests, 0 failed; {control}; {out / "receipt.json"}', flush=True)


if __name__ == '__main__':
    try:
        main()
    except SystemExit:
        raise
    except Exception as error:
        print(f'FAIL: {type(error).__name__}: {error}', file=sys.stderr)
        sys.exit(1)
