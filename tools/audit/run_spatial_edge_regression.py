#!/usr/bin/env python3
"""Exercise real Edge handler branches and reject a copied-source hash mutant.

The DB and R2 dependencies are fixture doubles here. PostgreSQL transactions
are exercised independently by run_spatial_regression.py; this is not live-R2
or phone proof. Source and command receipts make that distinction durable.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile


def main():
    root=Path(__file__).resolve().parents[2]
    out=Path(tempfile.mkdtemp(prefix='rendprop-spatial-edge-',dir='/tmp'))
    functions=root/'services/supabase/functions'
    copy=out/'functions';shutil.copytree(functions/'spatial',copy/'spatial');(copy/'_shared').mkdir()
    for name in ('http.ts','cors.ts','supabase.ts'):shutil.copy2(functions/'_shared'/name,copy/'_shared'/name)
    deno=shutil.which('deno');assert deno
    receipt={'accepted':False,'commands':[],'sourceSha256':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (functions/'spatial').glob('*.ts')}}
    def run(name,path,expected):
        command=[deno,'test','--cached-only','--allow-env','--allow-read',
                 '--deny-net','--deny-run','--deny-write',str(path)]
        p=subprocess.run(command,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
        log=out/f'{name}.log';log.write_text(p.stdout)
        receipt['commands'].append({'name':name,'exit':p.returncode,'command':command,'log':str(log),'sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
        assert p.returncode==expected,f'{name} wrong exit {p.returncode}; see {log}'
        return p.stdout
    try:
        baseline=run('baseline',functions/'spatial',0)
        # A new provider-journal route added the 26th test. Keep exact counts so
        # missing/skipped tests cannot make a partial run look green; normalize
        # terminal coloring, not assertions or failures.
        plain=re.sub(r'\x1b\[[0-9;]*m','',baseline)
        summary=re.search(r'ok \| (\d+) passed \| (\d+) failed(?: \| (\d+) ignored)?',plain)
        assert summary and tuple(int(x or 0) for x in summary.groups())==(26,0,0)
        file=copy/'spatial/index.ts';source=file.read_text();needle='await digest(bytes) === j.output_sha256'
        assert source.count(needle)==1,'output hash mutation target missing or ambiguous'
        file.write_text(source.replace(needle,'true /* deliberate copied-source negative control */'))
        rejected=run('reject-output-hash-mutant',copy/'spatial',1)
        assert 'actual output bytes hash checked before physical storage' in rejected and 'FAILED' in rejected
        receipt['accepted']=True
    finally:
        (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
        print(f'EVIDENCE: {out}',flush=True)
    assert receipt['accepted']
    print('PASS: 26 Edge tests, 0 ignored; copied-source output-hash mutant rejected.')


if __name__=='__main__':main()
