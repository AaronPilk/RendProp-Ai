import{assert,assertEquals,assertNotEquals}from'https://deno.land/std@0.224.0/assert/mod.ts';
import type{Motion}from'./contracts.ts';
import{motionVarietySatisfied,varyMotions,variedJobInput,varietySeed,VARIETY_CYCLE,VARIETY_WINDOW,VARIETY_WINDOW_DISTINCT,PROPERTY_VIDEO_VARIETY_VERSION}from'./variety.ts';
const id=(i:number)=>`e7000000-0000-4000-8000-${String(i).padStart(12,'0')}`;
const P:Motion='push_in',S:Motion='side_glide',B:Motion='pull_back',F:Motion='fly_through';
const seed=id(4);
function windows(m:readonly Motion[]){const out:Motion[][]=[];for(let i=0;i+VARIETY_WINDOW<=m.length;i++)out.push(m.slice(i,i+VARIETY_WINDOW));return out;}
function check(requested:Motion[],s=seed){const v=varyMotions(requested,s);
 assertEquals(v.requested,requested);assertEquals(v.chosen.length,requested.length);
 for(let i=1;i<v.chosen.length;i++)assertNotEquals(v.chosen[i],v.chosen[i-1],'adjacent repeat at '+i);
 for(const w of windows(v.chosen))assert(new Set(w).size>=VARIETY_WINDOW_DISTINCT,'window '+w.join(','));
 assert(motionVarietySatisfied(v.chosen));
 for(let i=0;i<requested.length;i++)assertEquals(v.chosen[i]!==requested[i],v.changed.includes(i));
 // fly_through is never introduced; everything else is from the closed cycle.
 for(let i=0;i<requested.length;i++)if(v.chosen[i]===F)assertEquals(requested[i],F);
 for(const i of v.changed)assert(VARIETY_CYCLE.includes(v.chosen[i]));
 return v;}
Deno.test('the rejected 6 push_in / 8 side_glide shape becomes varied with photo order untouched',()=>{
 const rejected:Motion[]=[P,P,P,S,S,S,P,P,S,S,S,P,S,S];assertEquals(motionVarietySatisfied(rejected),false);
 const v=check(rejected);assert(new Set(v.chosen).size>=3);assert(v.chosen.includes(B));
 assertEquals(v.version,PROPERTY_VIDEO_VARIETY_VERSION);assertEquals(v.seed,seed);
});
Deno.test('an all push_in planner fallback is redistributed through the cycle, not left as fourteen push-ins',()=>{
 const v=check(Array(14).fill(P)as Motion[]);assertEquals(v.chosen.filter(m=>m===P).length<=5,true);assertEquals(new Set(v.chosen).size,3);
 for(let i=1;i<14;i++)assertNotEquals(v.chosen[i],v.chosen[i-1]);
});
Deno.test('a sequence that already satisfies the rules is kept exactly (minimal reshuffle)',()=>{
 for(const ok of[[P],[P,S],[S,P,B],[F,P,S,B,P,S,B,F,S],[P,S,B,P,S,B,P,S,B,P,S,B,P,S,B,P,S,B,P,S]]as Motion[][]){const v=check(ok);assertEquals(v.chosen,ok);assertEquals(v.changed,[]);}
});
Deno.test('only the illegal position changes and later legal planner choices survive',()=>{
 const v=check([P,P,S,B,P]);assertEquals(v.changed,[1]);assertEquals(v.chosen,[P,B,S,B,P]);
 // P S P S breaks the window rule only at the fourth photo; the one legal third move there is pull_back, so the planned pull_back behind it must move too.
 const w=check([P,S,P,S,B]);assertEquals(w.changed,[3,4]);assertEquals(w.chosen[3],B);assertEquals(w.chosen[4]!==B,true);
});
Deno.test('fly_through is kept where planned but never introduced and a planned fly_through repeat is replaced by a safe move',()=>{
 const v=check([F,F,F,P]);assertEquals(v.chosen[0],F);assertEquals(v.changed.includes(1),true);assert(!v.chosen.slice(1).includes(F));
 const w=check([P,P,P,P,P,P,P,P]);assert(!w.chosen.includes(F));
});
Deno.test('same recipe and seed replay the same sequence; a different operation rotates the pattern but keeps the rules',()=>{
 const requested=Array(20).fill(P)as Motion[];const a=check(requested),b=check(requested);assertEquals(a,b);assertEquals(varietySeed(seed),varietySeed(seed));
 const other=[5,6,7,8,9,10].map(id).find(s=>varietySeed(s)%3!==varietySeed(seed)%3)!;assert(other);const c=check(requested,other);assertNotEquals(a.chosen,c.chosen);assertEquals(c.seed,other);
});
Deno.test('every requested shape from 1 to 24 photos satisfies the rules (exhaustive short shapes, cycled long ones)',()=>{
 const moves:Motion[]=[P,S,B,F];
 for(let n=1;n<=6;n++)for(let code=0;code<4**n;code++){const requested=Array.from({length:n},(_,i)=>moves[Math.floor(code/4**i)%4]);check(requested);}
 for(let n=7;n<=24;n++)for(const pattern of[[P],[S],[P,S],[S,S,P],[P,P,S,S,S],[F,P],[B,B,S]]){check(Array.from({length:n},(_,i)=>pattern[i%pattern.length]));}
});
Deno.test('variedJobInput writes chosen moves on each source and a record, keeping identity, order and every other field',()=>{
 const sources=Array.from({length:14},(_,i)=>({photo_id:'selected-'+i,photo_asset_id:id(100+i),photo_version_id:'exact-'+i,photo_provenance_id:i%2?id(200+i):null,motion:(i<6?P:S)as Motion}));
 const input={operation_id:seed,listing_id:id(3),expected_org_id:id(2),purpose:'listing'as const,aspect:'16:9'as const,sources,narration_result_id:null,narration_asset_id:null,narration_words:[],music:null,presentation:{transition:'cut'as const,shot_caption_style:'off'as const,spoken_captions:false,shot_labels:sources.map(()=>null),title_card:null},allow_original_photo_fallback:true};
 const out=variedJobInput(input);
 assertEquals(out.sources.map(s=>({...s,motion:undefined})),sources.map(s=>({...s,motion:undefined})));
 assertEquals(out.sources.map(s=>s.motion),out.motion_variety.chosen);assertEquals(out.motion_variety.requested,sources.map(s=>s.motion));assertEquals(out.motion_variety.seed,seed);
 assert(motionVarietySatisfied(out.sources.map(s=>s.motion)));
 const{sources:_a,motion_variety:_b,...rest}=out;const{sources:_c,...expected}=input;assertEquals(rest,expected);
 assertEquals(variedJobInput(input),out);assertEquals(input.sources.map(s=>s.motion),sources.map(s=>s.motion));
});
Deno.test('seeded random recipes of 1 to 100 photos (the admission bound) always freeze a compliant, replayable sequence',()=>{
 // Deterministic LCG: arbitrary planner/client shapes and operation identities,
 // including long single-move runs, every move mixed and fly_through anywhere.
 let state=0x9e3779b9;const next=()=>(state=(Math.imul(state,1664525)+1013904223)>>>0);
 const moves:Motion[]=[P,S,B,F];let changedTotal=0;
 for(let trial=0;trial<3000;trial++){
  const n=1+next()%100,runBias=next()%4;let current=moves[next()%4];const requested:Motion[]=[];
  for(let i=0;i<n;i++){if(next()%4>=runBias)current=moves[next()%4];requested.push(current);}
  const op=[8,4,4,4,12].map(len=>Array.from({length:len},()=>(next()%16).toString(16)).join('')).join('-');
  const v=check(requested,op);assertEquals(varyMotions(requested,op),v);changedTotal+=v.changed.length;
 }
 assert(changedTotal>0,'the sweep must exercise the rewrite path');
});
Deno.test('deliberate defect control: the rule checker rejects the exact rejected shapes',()=>{
 assertEquals(motionVarietySatisfied([P,P]),false);assertEquals(motionVarietySatisfied([P,S,P,S]),false);assertEquals(motionVarietySatisfied([P,S,B,P]),true);assertEquals(motionVarietySatisfied([]),true);
});
