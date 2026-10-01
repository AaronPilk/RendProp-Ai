import assert from 'node:assert/strict';
import {buildSrc} from '../../../../services/edge/tour-host/scripts/build-src.mjs';
const {renderTourPage}=await buildSrc('call-video-provenance')('player');
const original='https://cdn.example.invalid/full-original.mp4',altered='https://cdn.example.invalid/full-reflection-edit.mp4';
const tour={slug:'synthetic-reflections',space_type:'real_estate',published_at:'2026-09-19T00:00:00Z',listing:{address:'Synthetic audit room',details:{}},video_url:altered,duration_s:10,cta:{label:'Book a showing',mode:'lead_form',secondary:[],lead_fields:[]},chapters:[],agent_card:{name:'BrandSentinel',phone:'555-010-9999'},altered_media:[{kind:'video_reflection_removal',label:'Walkthrough reflection removal',disclosure:'Selected portions of this walkthrough were edited with AI to remove visible people and reflections of the photographer or camera. The unedited walkthrough is provided for comparison.',original_url:original,altered_url:altered}]};
let checks=0;const check=(ok,m)=>{checks++;assert.ok(ok,m);};
for(const unbranded of [false,true]){
 const html=renderTourPage(tour,'https://functions.invalid','synthetic-anon','synthetic-site',{unbranded});
 const disc=html.match(/<section[^>]+id="disclosure"[\s\S]*?<\/section>/)?.[0];check(!!disc,'disclosure included');
 check(disc.includes('AI video edit'),'truthful video family');check(disc.includes('people and reflections removed with AI'),'truthful kind');
 check(disc.includes(`<video src="${original}"`),'original is playable video');check(disc.includes(`<video src="${altered}"`),'altered is playable video');
 check((disc.match(/controls playsinline preload="none"/g)||[]).length===2,'both usable without JS');
 check(!disc.includes('data-ba')&&!disc.includes('Drag to compare'),'no photo slider on videos');check(!disc.includes(`<img src="${original}"`),'original video never emitted as broken photo');
 check(disc.includes(`href="${original}"`),'full original linked');check(disc.includes('Compare the edited media with the unedited originals'),'accurate compare summary');
 check(!disc.includes('Edits change styling and furnishing only'),'no false photo-only disclosure');check(!disc.includes('bria/video')&&!disc.includes('14¢'),'no vendor/pricing detail in tour');
 if(unbranded)check(!html.includes('BrandSentinel')&&!/<form\b|<input\b/i.test(html),'MLS-safe public pair');
}
console.log(JSON.stringify({passed:true,checks,renderer:'actual player.ts',media:'synthetic URLs, no network'}));
