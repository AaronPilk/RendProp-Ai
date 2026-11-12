import assert from 'node:assert/strict';
import {capabilities,outputCapabilities,egress,mediaURL,isTerminal,sanitizedFailure} from '../src/controller.ts';

const job='00000000-0000-4000-8000-000000000001',lease='00000000-0000-4000-8000-000000000002';
const hosts=new Set(['media.example.test']);
const source={url:'https://media.example.test/private/clip?signature=one',sha256:'a'.repeat(64),bytes:12};
const action:any={action:'compose',state:'composing',job_id:job,lease_token:lease,expires_at:new Date(Date.now()+60_000).toISOString(),sources:[source],purpose:'listing',aspect:'16:9'};
const props=capabilities(action,hosts);
assert.equal(props.capabilities.length,1);
assert.throws(()=>capabilities({...action,expires_at:'2000-01-01T00:00:00Z'},hosts));
assert.throws(()=>capabilities({...action,job_id:'../x'},hosts));
for (const bad of ['http://media.example.test/x','https://evil.test/x','https://user:pass@media.example.test/x','https://media.example.test:8443/x','https://media.example.test/x#secret','https://127.0.0.1/x']) assert.throws(()=>mediaURL(bad,hosts));
assert.equal((await egress(new Request('https://media.example.test/private/other'),props)).status,403);
assert.equal((await egress(new Request(source.url,{method:'POST'}),props)).status,403);
let calls=0;
const transport:any=async(request:Request)=>{calls++;assert.equal(request.redirect,'manual');assert.equal(request.headers.get('Authorization'),null);return new Response('abcdefghijkl',{headers:{'content-length':'12'}});};
assert.equal((await egress(new Request(source.url,{headers:{Authorization:'Bearer stolen'}}),props,transport)).status,200);
assert.equal(calls,1);
assert.equal((await egress(new Request(source.url),{...props,expiresAt:0},transport)).status,403);
assert.equal(calls,1);
assert.equal((await egress(new Request(source.url),props,async()=>new Response('',{status:302,headers:{location:'https://evil.test'}}))).status,502);
assert.equal((await egress(new Request(source.url),props,async()=>new Response('x',{headers:{'content-length':'1'}}))).status,502);
const receipt={asset_id:job,poster_asset_id:lease,bytes:12,poster_bytes:4,sha256:'a'.repeat(64),poster_sha256:'b'.repeat(64)};
const output={...receipt,put_url:source.url,poster_put_url:'https://media.example.test/private/poster?signature=two',expires_at:action.expires_at,
  headers:{'content-length':'12','content-type':'video/mp4','if-none-match':'*','x-amz-meta-sha256':receipt.sha256},
  poster_headers:{'content-length':'4','content-type':'image/jpeg','if-none-match':'*','x-amz-meta-sha256':receipt.poster_sha256}};
const puts=outputCapabilities(output,receipt,hosts);
assert.equal(puts.capabilities.length,2);
assert.throws(()=>outputCapabilities({...output,asset_id:lease},receipt,hosts));
assert.throws(()=>outputCapabilities({...output,headers:{...output.headers,'x-amz-meta-sha256':'c'.repeat(64)}},receipt,hosts));
const successfulPut=await egress(new Request(source.url,{method:'PUT',body:'abcdefghijkl',headers:output.headers}),puts,async(request)=>{
  assert.equal(request.headers.get('if-none-match'),'*');assert.equal(request.headers.get('x-amz-meta-sha256'),receipt.sha256);
  assert.equal(await request.text(),'abcdefghijkl');return new Response(null,{status:204});
});
assert.equal(successfulPut.status,204);
assert.equal((await egress(new Request(source.url,{method:'PUT',body:'x',headers:{'content-type':'video/mp4','content-length':'1'}}),puts,transport)).status,403);
assert.equal((await egress(new Request(source.url,{method:'PUT',body:'abcdefghijkl',headers:{'content-type':'text/html','content-length':'12'}}),puts,transport)).status,403);
const fail=sanitizedFailure(action);
assert.deepEqual(Object.keys(fail).sort(),['code','job_id','lease_token','phase']);
assert.ok(!JSON.stringify(fail).includes('signature'));
assert.equal(isTerminal({action:'wait',state:'cancelled',job_id:job}),true);
assert.equal(isTerminal({action:'wait',state:'generating',job_id:job}),false);
const prep:any={action:'prepare_image',state:'preparing',job_id:job,lease_token:lease,source,output:{asset_id:job,key:'prepared/a.jpg'},expires_at:action.expires_at};
const prepCaps=capabilities(prep,hosts);assert.equal(prepCaps.capabilities.length,1);assert.equal(prepCaps.capabilities[0].url,source.url);
const prepReceipt={asset_id:job,bytes:12,sha256:'a'.repeat(64),mime:'image/jpeg'};
const prepOutput={asset_id:job,put_url:source.url,expires_at:action.expires_at,headers:{'content-length':'12','content-type':'image/jpeg','if-none-match':'*','x-amz-meta-sha256':prepReceipt.sha256}};
assert.equal(outputCapabilities(prepOutput,prepReceipt,hosts).capabilities.length,1);
assert.throws(()=>outputCapabilities({...prepOutput,headers:{...prepOutput.headers,'content-type':'video/mp4'}},prepReceipt,hosts));
assert.deepEqual(sanitizedFailure(prep),{job_id:job,lease_token:lease,phase:'prepare_image',code:'cpu_attempt_failed'});
console.log('Private controller: exact capabilities, expiry, byte/host/redirect fences passed.');
const audio:any={action:'inspect_audio',state:'queued',job_id:job,lease_token:lease,manifest_sha256:'a'.repeat(64),source,max_duration_s:10,expires_at:action.expires_at};
assert.deepEqual(capabilities(audio,hosts).capabilities,[{url:source.url,method:'GET',bytes:12}]);
assert.throws(()=>capabilities({...audio,source:{...source,bytes:20*1024*1024+1}},hosts));
assert.deepEqual(sanitizedFailure(audio),{job_id:job,lease_token:lease,phase:'inspect_audio',code:'cpu_attempt_failed'});
// A steady-profile extract_frames task carries the renderer's temporal QC request
// (ExtractAction.temporal_qc); it changes no capability, failure shape or identity.
import type {ExtractAction} from '../../../supabase/functions/property-video-jobs/contracts.ts';
const extract:ExtractAction={action:'extract_frames',state:'quality_review',job_id:job,attempt_id:'00000000-0000-4000-8000-000000000003',lease_token:lease,source:{...source,asset_id:job},clip:{url:'https://media.example.test/private/clip-bytes?signature=three',sha256:'b'.repeat(64),bytes:34},temporal_qc:{profile:'temporal-motion-v2',aspect:'16:9'},expires_at:action.expires_at};
assert.deepEqual(capabilities(extract,hosts).capabilities,[{url:extract.clip.url,method:'GET',bytes:34}]);
const {temporal_qc:_temporal,...legacyExtract}=extract;
assert.deepEqual(capabilities(legacyExtract as ExtractAction,hosts),capabilities(extract,hosts));
assert.deepEqual(sanitizedFailure(extract),{job_id:job,lease_token:lease,attempt_id:extract.attempt_id,phase:'extract_frames',code:'cpu_attempt_failed'});
assert.ok(!JSON.stringify(sanitizedFailure(extract)).includes('temporal'));
console.log('Private controller: temporal QC request rides the extract task without widening any capability.');
