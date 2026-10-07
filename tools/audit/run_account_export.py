#!/usr/bin/env python3
"""Source-bound actual export handler tests and compiled semantic controls."""
from pathlib import Path
import argparse, hashlib, json, re, subprocess, tempfile
root=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser();p.add_argument('--evidence-dir',type=Path);args=p.parse_args()
out=args.evidence_dir or Path(tempfile.mkdtemp(prefix='rendprop-account-export-handler-'));out.mkdir(parents=True,exist_ok=True)
source=root/'services/supabase/functions/me/export.ts';tests=source.with_name('export.test.ts')
dependencies=[source,tests,source.with_name('index.ts'),root/'services/supabase/functions/_shared/http.ts',root/'services/supabase/functions/_shared/cors.ts',Path(__file__).resolve()]
dependencies+=list((root/'services/supabase/migrations').glob('*.sql'))
hashes=lambda:{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in dependencies}
start=hashes();code=source.read_text();test=tests.read_text()
cases=[('actual',None,None),('actor-predicate','if (spec.actorColumn) scopes.push({ column: spec.actorColumn, values: [actor] });',''),('final-authority','assert(signature(first) === signature(final),','assert(true,'),('redaction','.filter(([key]) => !secretKey.test(key))',''),('referenced-listing','await checkReferences();',''),('photo-admission-projection','own("serving_photo_admissions", "funding_id,slice_index,org_id,actor_id,request_key,task,created_at"','own("serving_photo_admissions", "funding_id,slice_index,org_id,actor_id,request_key,task,created_at,input_sha256"')]
runs=[]
for name,old,new in cases:
    modified=code if old is None else code.replace(old,new)
    assert old is None or (code.count(old)==1 and modified!=code)
    folder=out/name;folder.mkdir(exist_ok=True)
    # Copy only owned sources, resolving dependencies back to their real paths.
    def imports(text,base):
        return re.sub(r'from "(\.[^"]+)"',lambda m:'from '+json.dumps((base/m.group(1)).resolve().as_uri()),text)
    copied=folder/'export.ts';copied.write_text(imports(modified,source.parent))
    copied_test=folder/'export.test.ts'
    test_copy=imports(test,tests.parent).replace(source.as_uri(),copied.as_uri())
    # Auth/dispatch extraction deliberately reads the real entrypoint.
    test_copy=test_copy.replace('new URL("./index.ts", import.meta.url)','new URL('+json.dumps(source.with_name('index.ts').as_uri())+')')
    test_copy=test_copy.replace('new URL("../_shared/http.ts", import.meta.url)','new URL('+json.dumps((source.parent/'../_shared/http.ts').resolve().as_uri())+')').replace('new URL("../_shared/cors.ts", import.meta.url)','new URL('+json.dumps((source.parent/'../_shared/cors.ts').resolve().as_uri())+')')
    copied_test.write_text(test_copy)
    check=subprocess.run(['deno','check',str(copied),str(copied_test)],capture_output=True,text=True)
    (folder/'compile.log').write_text(check.stdout+check.stderr);assert check.returncode==0,(name,check.stderr[-2000:])
    result=subprocess.run(['deno','test','--allow-read',str(copied_test)],capture_output=True,text=True)
    (folder/'run.log').write_text(result.stdout+result.stderr)
    assert (name=='actual')==(result.returncode==0),(name,result.stdout[-2500:]+result.stderr[-2000:])
    assert 'running 13 tests' in result.stdout
    runs.append({'name':name,'compiled':True,'exit':result.returncode,'expectedFailure':name!='actual'})
end=hashes();receipt={'sourceBoundAtEnd':start==end,'sourceSHA256':start,'runs':runs,'scope':'Actual handler queries and payload assembly with only Auth/DB transport closed; dispatch extracted from actual me entrypoint. No live customer export.'}
(out/'receipt.json').write_text(json.dumps(receipt,indent=2));assert start==end
print(json.dumps({'runs':len(runs),'sourceBoundAtEnd':True,'evidence':str(out)},indent=2))
