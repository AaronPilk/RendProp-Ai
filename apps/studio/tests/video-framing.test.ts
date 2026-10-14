import assert from 'node:assert/strict';
import {test} from 'node:test';
import {photoFrame,framingSummary} from '../src/features/sync/video-framing';
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
