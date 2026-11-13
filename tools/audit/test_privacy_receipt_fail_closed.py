#!/usr/bin/env python3
"""Execute actual proof-runner terminal AST against owned files, without DB/network.

A real file-byte change must raise and leave the actual finally-written receipt
red. Reordering success ahead of the guard is compiled as a negative control;
its misleading green receipt must fail the verifier, and that evidence is kept.
"""
import argparse, ast, copy, hashlib, json, pathlib, subprocess, sys, tempfile
from datetime import datetime, timezone
ROOT=pathlib.Path(__file__).resolve().parents[2]
RUNNERS=('run_verified_recipients.py','run_privacy_cleanup_inventory.py','run_upload_privacy_admission.py','run_photographer_client_delivery.py')
def terminal(path,mutant=False):
 tree=ast.parse(path.read_text(),filename=str(path))
 outer=[n for n in tree.body if isinstance(n,ast.Try) and any(isinstance(x,ast.Call)and isinstance(x.func,ast.Attribute)and x.func.attr=='write_text' for n2 in n.finalbody for x in ast.walk(n2))]
 assert len(outer)==1,'actual finally receipt writer not unique'
 main=outer[0]
 guard=[n for n in main.body if isinstance(n,ast.Assert) and 'hashes' in ast.unparse(n.test)]
 success=[n for n in main.body if isinstance(n,ast.Expr) and isinstance(n.value,ast.Call) and isinstance(n.value.func,ast.Attribute) and ast.unparse(n.value.func)=='receipt.update' and any(k.arg=='passed'and isinstance(k.value,ast.Constant)and k.value.value is True for k in n.value.keywords)]
 assert len(guard)==len(success)==1,'exact final source check/success assignment required'
 gi=main.body.index(guard[0]);si=main.body.index(success[0]);assert si>gi,'success flag precedes final source assertion'
 body=[]
 if any(isinstance(n,ast.Name)and n.id=='current'for n in ast.walk(guard[0])):
  assigned=[n for n in main.body[:gi] if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name)and t.id=='current'for t in n.targets)]
  assert len(assigned)==1;body.append(assigned[0])
 body.extend([success[0],guard[0]]if mutant else[guard[0],success[0]])
 writer=[n for n in main.finalbody if isinstance(n,ast.Expr) and isinstance(n.value,ast.Call) and isinstance(n.value.func,ast.Attribute) and n.value.func.attr=='write_text']
 assert len(writer)==1
 module=ast.Module(body=[ast.Try(body=copy.deepcopy(body),handlers=[],orelse=[],finalbody=copy.deepcopy(writer))],type_ignores=[])
 return compile(ast.fix_missing_locations(module),str(path),'exec')
def child(name,out,drift,mutant):
 out.mkdir(parents=True,exist_ok=True);subject=out/'subject.sql';subject.write_text('select 1;\n');tracked=[subject]
 hashes={str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest()for p in tracked}
 if drift:subject.write_text('select 2;\n')
 env={'ROOT':out,'OUT':out,'tracked':tracked,'paths':tracked,'hashes':hashes,'hashlib':hashlib,'json':json,'datetime':datetime,'timezone':timezone,'controls':[],'receipt':{'passed':False,'sourceHashes':hashes,'syntheticControl':True,'faultInjected':mutant}}
 exec(terminal(ROOT/'tools/audit'/name,mutant),env)
def main():
 p=argparse.ArgumentParser();p.add_argument('--child',choices=RUNNERS);p.add_argument('--out',type=pathlib.Path);p.add_argument('--drift',action='store_true');p.add_argument('--mutant',action='store_true');p.add_argument('--evidence-dir',type=pathlib.Path);args=p.parse_args()
 if args.child:
  assert args.out is not None;child(args.child,args.out,args.drift,args.mutant);return
 out=args.evidence_dir or pathlib.Path(tempfile.mkdtemp(prefix='rendprop-privacy-receipt-',dir='/tmp'));out.mkdir(parents=True,exist_ok=True)
 receipt={'passed':False,'sourceHashes':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()for p in [pathlib.Path(__file__).resolve(),*[ROOT/'tools/audit'/name for name in RUNNERS]]},'checks':[],'productionMutations':0,'databaseCalls':0,'providerCalls':0}
 try:
  for name in RUNNERS:
   cases={}
   for label,extra in [('positive',[]),('source-drift',['--drift']),('reversed-success-control',['--drift','--mutant'])]:
    case=out/name.removesuffix('.py')/label
    result=subprocess.run([sys.executable,__file__,'--child',name,'--out',str(case),*extra],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=15)
    case.mkdir(parents=True,exist_ok=True);(case/'execution.log').write_text(result.stdout)
    data=json.loads((case/'receipt.json').read_text());cases[label]={'exit':result.returncode,'receiptPassed':data['passed'],'log':str(case/'execution.log')}
    if label=='positive':assert result.returncode==0 and data['passed']is True,(name,label,cases[label])
    else:assert result.returncode!=0 and 'Source changed during'in result.stdout,(name,label,cases[label])
    if label=='source-drift':assert data['passed']is False,(name,'source drift receipt must remain false')
    if label=='reversed-success-control':
     # Run the identical receipt assertion against the mutated writer's output;
     # this verifier MUST go red rather than bless a misleading success flag.
     verify=subprocess.run([sys.executable,'-c',"import json,sys; assert json.load(open(sys.argv[1]))['passed'] is False, 'source drift receipt must remain false'",str(case/'receipt.json')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=15)
     (case/'verifier.log').write_text(verify.stdout);assert verify.returncode!=0 and 'source drift receipt must remain false'in verify.stdout
     cases[label]['verifierExit']=verify.returncode;cases[label]['failedBoundary']='source drift receipt must remain false'
   receipt['checks'].append({'runner':name,'cases':cases})
  for path,digest in receipt['sourceHashes'].items():assert hashlib.sha256((ROOT/path).read_bytes()).hexdigest()==digest,'control source changed during proof'
  receipt.update(passed=True,finishedAt=datetime.now(timezone.utc).isoformat())
 finally:(out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
 print('PASS:',len(receipt['checks']),'actual AST positive/drift/reordered-success controls; evidence',out)
if __name__=='__main__':main()
