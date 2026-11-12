// Each deliberate browser fault must be rejected by the unchanged real player
// gate at a product assertion, not a browser-launch or test-fixture error.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync,readFileSync,writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join,resolve } from 'node:path';
import { ROOT } from './build-src.mjs';
const arg=name=>process.argv.slice(2).find(x=>x.startsWith(name+'='))?.slice(name.length+1);
const evidence=arg('--evidence')?resolve(arg('--evidence')):mkdtempSync(join(tmpdir(),'rendprop-property-video-controls-'));
const cases=[['eager-media','No initial video download for basic'],['no-controls','Native controls available for basic'],['crop-master','Complete landscape master retained at mobile width for basic'],['preview-beacon','Actual preview playback emits no analytics/billing requests'],['retain-master','Page lifecycle releases primary master for basic']];
const results=[];
for(const [fault,label]of cases){
 const path=join(evidence,fault);
 const result=spawnSync(process.execPath,[join(ROOT,'scripts/check-property-video-browser.mjs'),'--fault='+fault,'--evidence='+path],{encoding:'utf8',timeout:90000,env:process.env});
 assert.notEqual(result.status,0,fault+' must fail the unchanged browser gate');
 const receipt=JSON.parse(readFileSync(join(path,'failure.json'),'utf8'));
 assert.ok(receipt.error.includes(label),fault+' must fail the intended product assertion: '+receipt.error);
 assert.equal(receipt.fault,fault);assert.deepEqual(receipt.errors,[],'Controls cannot succeed through unrelated browser JS exceptions');
 results.push({fault,rejected:true,label,sourceHashes:receipt.sourceHashes});
}
writeFileSync(join(evidence,'receipt.json'),JSON.stringify({passed:true,controls:results,scope:'Actual Chromium/1080p synthetic local media; no live customer/provider requests'},null,2));
console.log(`Property-video browser controls: ${results.length} deliberate faults rejected at intended actual-runtime assertions; ${evidence}`);
