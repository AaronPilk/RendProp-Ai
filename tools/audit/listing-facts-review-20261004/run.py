#!/usr/bin/env python3
"""Compile native review row renderer, admission policy and sheet action bodies."""
from pathlib import Path
import argparse,hashlib,json,subprocess,tempfile
ROOT=Path(__file__).resolve().parents[3]
SOURCE=ROOT/'apps/ios/Rendprop/Screens/FlythroughDetailView.swift'
def block(source,marker):
 assert source.count(marker)==1,marker
 start=source.index(marker);opening=source.index('{',start);end=opening+1;depth=1
 while depth:
  depth+=(source[end]=='{')-(source[end]=='}');end+=1
 return source[start:end]
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--output-dir',type=Path);parser.add_argument('--inject-fault',choices=['drop-review-context','expose-private-details']);args=parser.parse_args()
 source=SOURCE.read_text();sheet=block(source,'private struct ListingFactsReviewSheet: View')
 bodies={'__ROWS__':block(source,'private enum ListingFactsReviewRows'),'__POLICY__':block(source,'    private var listingFactsNeedReview:'),'__CURRENT__':block(sheet,'    private var reviewIsCurrent:'),'__LOAD__':block(sheet,'    @MainActor private func load()'),'__RESOLVE__':block(sheet,'    @MainActor private func resolve(')}
 hashes={k:hashlib.sha256(v.encode()).hexdigest() for k,v in bodies.items()};expected=None
 if args.inject_fault=='drop-review-context':
  bodies['__CURRENT__']='    private var reviewIsCurrent: Bool { review != nil }';expected='changed review cannot invoke model resolution'
 elif args.inject_fault=='expose-private-details':
  needle='ListingFactsSync.detailValues(a), sharedDetails = ListingFactsSync.detailValues(b)';assert needle in bodies['__ROWS__']
  bodies['__ROWS__']=bodies['__ROWS__'].replace(needle,'a.details ?? [:], sharedDetails = b.details ?? [:]');expected='review excludes private geometry and unknown server metadata'
 assert '.disabled(loading || !reviewIsCurrent || error != nil)' in sheet
 assert 'Button("Cancel") { dismiss() }' in sheet
 assert 'ListingFactsReviewSheet(listingID: listing.id)' in source
 fixture=Path(__file__).with_name('Fixture.swift.template').read_text()
 for key,body in bodies.items():assert fixture.count(key)==1;fixture=fixture.replace(key,body)
 out=args.output_dir or Path(tempfile.mkdtemp(prefix='rendprop-listing-facts-review-'));out.mkdir(parents=True,exist_ok=True)
 swift=out/'ActualListingFactsReview.swift';swift.write_text(fixture)
 models=[ROOT/'apps/ios/Rendprop/Models'/name for name in ['Listing.swift','ListingClientContact.swift','Money.swift']]
 receipt={'sourceHashes':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [SOURCE,*models]},'actualBodyHashes':hashes,'fault':args.inject_fault,'networkCalls':0,'customerFileAccesses':0,'commands':[]}
 for label,command in [('compile',['xcrun','swiftc','-swift-version','5','-parse-as-library',*map(str,models),str(swift),'-o',str(out/'checks')]),('run',[str(out/'checks')])]:
  result=subprocess.run(command,cwd=ROOT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60);log=out/f'{label}.log';log.write_text(result.stdout)
  receipt['commands'].append({'name':label,'exit':result.returncode,'log':str(log)})
  if label=='run':receipt['passed']=result.returncode==1 and expected in result.stdout if expected else result.returncode==0
  (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(label,result.returncode,result.stdout.strip(),flush=True)
  if label=='compile' and result.returncode or label=='run' and not receipt['passed']:print('Evidence:',out);raise SystemExit(1)
 print('Evidence:',out)
if __name__=='__main__':main()
