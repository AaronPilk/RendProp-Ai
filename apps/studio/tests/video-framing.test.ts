import assert from 'node:assert/strict';
import {test} from 'node:test';
import {appendVisibleSelection,filterByOrientation,observedGeometry,orientationCounts,orientationSummary,photoFrame,photoOrientation,recordPreviewGeometry,withPreviewGeometry,framingSummary} from '../src/features/sync/video-framing';
import type {VideoSource} from '../src/features/sync/property-video';
const photo=(width?:number,height?:number)=>({width,height,photo_id:'saved',photo_asset_id:null,photo_version_id:'',photo_provenance_id:null,preview_url:null,bytes:0,sha256:null,eligible:false,reason:null})as VideoSource;
test('actual portrait/landscape geometry maps to centered target crop, with one aggregate mixed-orientation review',()=>{
 assert.deepEqual(photoFrame(photo(1920,1080),'listing'),{orientation:'landscape',cropFraction:0,majorCrop:false,width:1920,height:1080});
 const portrait=photoFrame(photo(1080,1920),'listing');assert.equal(portrait.orientation,'portrait');assert.ok(Math.abs(portrait.cropFraction!-.68359375)<1e-10);assert.equal(portrait.majorCrop,true);
 assert.equal(photoFrame(photo(1080,1920),'social').cropFraction,0);assert.equal(photoFrame(photo(4032,3024),'listing').cropFraction,.25);assert.equal(photoFrame(photo(),'listing').orientation,'unknown');
 assert.deepEqual(framingSummary([photo(1920,1080),photo(1080,1920),photo()],'listing'),{unknown:1,landscape:1,portrait:1,majorCrop:1,mixed:true});
});
test('prepared orientation-baked geometry wins over raw EXIF dimensions while master identity stays unchanged',()=>{
 const source={...photo(4000,2000),preparation:{preparation_id:'same',source_asset_id:'master',source_sha256:'a'.repeat(64),width:1024,height:2048,policy:'video-jpeg-v1'}}as VideoSource;assert.equal(photoFrame(source,'listing').orientation,'portrait');assert.equal(source.preparation!.source_asset_id,'master');
});
test('orientation counts include square and unknown without guessing from invalid dimensions',()=>{
 const values=[photoOrientation(observedGeometry(4000,3000)),photoOrientation(observedGeometry(3000,4000)),photoOrientation(observedGeometry(1000,1000)),photoOrientation(null)];
 assert.deepEqual(orientationCounts(values),{landscape:1,portrait:1,square:1,unknown:1});
 assert.equal(orientationSummary(values),'1 landscape · 1 portrait · 1 square · 1 unknown');
 for(const [width,height]of [[0,4],[-1,4],[NaN,4],[Infinity,4],[4.2,4],[4,undefined]])assert.equal(observedGeometry(width,height),null);
 assert.equal(photoFrame(photo(NaN,1080),'listing').orientation,'unknown');
});
test('filters preserve source order, hidden selections and global tap numbers across orientation changes',()=>{
 const rows=[{id:'A',width:4000,height:3000},{id:'B',width:3000,height:4000},{id:'C',width:1000,height:1000},{id:'D',width:4000,height:3000}];
 const selected=['B','A'];
 const visible=filterByOrientation(rows,'landscape',row=>photoOrientation(row));
 assert.deepEqual(visible.map(row=>row.id),['A','D']);
 assert.deepEqual(selected,['B','A']);assert.equal(selected.indexOf('A')+1,2);
 assert.deepEqual(appendVisibleSelection(selected,visible.map(row=>row.id)),['B','A','D']);
 assert.deepEqual(appendVisibleSelection(selected,['D','C'],3),['B','A','D']);
 assert.deepEqual(filterByOrientation(rows,'all',row=>photoOrientation(row)),rows);
 assert.deepEqual(filterByOrientation(rows,'unknown',row=>photoOrientation(row)),[]);
});
test('unprepared photos stay unknown until their exact current preview is decoded; late events cannot relabel a new version',()=>{
 const original=photo(4000,3000),selectedMaster={...original,needs_preparation:true};
 assert.equal(photoFrame(withPreviewGeometry(selectedMaster,undefined),'listing').orientation,'unknown');
 const current=new Set(['same-photo:new-version:new-url']);const previous={'same-photo:old-version:old-url':{width:3000,height:4000}};
 assert.equal(recordPreviewGeometry(previous,'same-photo:old-version:old-url',4000,3000,current),previous);
 assert.equal(recordPreviewGeometry(previous,'same-photo:new-version:new-url',0,3000,current),previous);
 const observed=recordPreviewGeometry(previous,'same-photo:new-version:new-url',3000,4000,current);
 assert.deepEqual(observed,{'same-photo:new-version:new-url':{width:3000,height:4000}});
 assert.equal(photoFrame(withPreviewGeometry(selectedMaster,observed['same-photo:new-version:new-url']),'listing').orientation,'portrait');
 const prepared={...selectedMaster,preparation:{preparation_id:'ready',source_asset_id:'exact-master',source_sha256:'a'.repeat(64),width:2048,height:1365,policy:'video-jpeg-v1' as const}};
 assert.equal(photoFrame(withPreviewGeometry(prepared,{width:3000,height:4000}),'listing').orientation,'landscape');
 assert.equal(prepared.preparation.source_asset_id,'exact-master');
});
