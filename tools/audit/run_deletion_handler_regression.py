#!/usr/bin/env python3
"""Exercise the actual baseline/new /me handler offline with asserted results.

Only temporary test artifacts are written. Provider URLs are fixtures, Deno
network permission is denied, and the subprocess inherits no credentials.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile

BASE = 'baf77f93082e608b1321fdb0927bdabba08bb3fa'


def main():
    root = Path(__file__).resolve().parents[2]
    out = Path(tempfile.mkdtemp(prefix='rendprop-deletion-handler-', dir='/tmp'))
    env = {'PATH': '/opt/homebrew/bin:/usr/bin:/bin', 'NO_COLOR': '1'}
    functions = root / 'services/supabase/functions'
    receipt = {'accepted': False, 'baselineCommit': BASE, 'sourceHashes': {}, 'commands': []}
    paths = [Path(__file__), *sorted((functions / '_shared').glob('*.ts')), *sorted((functions / 'me').glob('*.ts'))]
    for path in paths:
        receipt['sourceHashes'][str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f'EVIDENCE: {out}', flush=True)

    def run(label, args, expected):
        result = subprocess.run(args, cwd=root, env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=90)
        log = out / f'{label}.log'
        log.write_text(result.stdout)
        receipt['commands'].append({'name': label, 'command': args, 'exit': result.returncode,
                                    'log': str(log), 'sha256': hashlib.sha256(log.read_bytes()).hexdigest()})
        assert result.returncode == expected, f'{label}: unexpected exit {result.returncode}; {log}'
        print(f'{label}: exit={result.returncode}', flush=True)
        return result.stdout

    deno = ['/opt/homebrew/bin/deno', 'test', '--cached-only', '--no-config', '--no-lock', '--node-modules-dir=none',
            '--allow-env', '--allow-read', '--deny-net', '--deny-run', '--deny-write']
    try:
        before = out / 'baseline' / 'me'
        before.mkdir(parents=True)
        (before.parent / '_shared').symlink_to(functions / '_shared', target_is_directory=True)
        # Reuse unchanged actual shared helpers, not handwritten replacement
        # implementations. Every shared source is compared with the baseline.
        for path in sorted((functions / '_shared').glob('*.ts')):
            saved = subprocess.run(['/usr/bin/git', 'show', f'{BASE}:{path.relative_to(root)}'], cwd=root,
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            assert saved.returncode == 0 and saved.stdout == path.read_bytes(), f'Shared helper changed since baseline: {path.name}'
        for name in ['index.ts', 'logic.ts']:
            saved = subprocess.run(['/usr/bin/git', 'show', f'{BASE}:services/supabase/functions/me/{name}'], cwd=root,
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            assert saved.returncode == 0
            (before / name).write_bytes(saved.stdout)
        (before / 'deletion.test.ts').write_bytes((functions / 'me/deletion.test.ts').read_bytes())
        baseline = run('before-stale-handler', deno + ['--filter', 'adoption winner', str(before / 'deletion.test.ts')], 1)
        assert 'adopted workspace was destroyed from stale ownership' in baseline
        assert re.search(r'0 passed \| 1 failed \| 26 filtered out', baseline), 'Unexpected baseline execution count'
        after = run('after-handler-and-logic', deno + [str(functions / 'me/deletion.test.ts'), str(functions / 'me/logic.test.ts')], 0)
        # Match the summary, not test titles containing words like "ignored".
        assert re.search(r'^ok \| 41 passed \| 0 failed \([^\n]+\)$', after, re.MULTILINE), 'Unexpected complete-suite summary'
        receipt['accepted'] = True
    finally:
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    assert receipt['accepted'], f'Handler gate failed: {out}'


if __name__ == '__main__':
    main()
