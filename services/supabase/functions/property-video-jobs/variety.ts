// Server-side camera-move variety for a saved property-video recipe.
//
// The planner (LLM) and both clients choose one of four moves per photo and
// nothing checked the finished sequence: rejected job c40f4860 froze as
// 6 push_in / 8 side_glide and "looked like someone walking". Admission is the
// single place every recipe passes through (planned, planner-fallback and
// saved Studio recipes alike), so the pass runs here, after jobInput() and
// before the manifest is hashed and frozen. Clients need no change: the job
// reply never carries per-shot motion, and the stored manifest records both
// the requested and the chosen sequence for QC and the owner.
//
// Rules (pure, deterministic, order-preserving):
//   1. no two adjacent photos share a move;
//   2. every window of VARIETY_WINDOW photos holds >= VARIETY_WINDOW_DISTINCT moves;
//   3. a requested move is kept whenever it already satisfies 1 and 2 given
//      the finalized prefix (minimal reshuffle), unless it is the third or
//      later move of an identical requested run: that is the signature of a
//      planner fallback or a monotonous plan, and those rows are redistributed
//      through the cycle instead of alternating with one neighbour;
//   4. substitutes come only from VARIETY_CYCLE. Every prompt builder keeps
//      push_in, side_glide and pull_back inside the photographed scene, so they
//      are safe for any room; fly_through needs a visible entry/corridor and is
//      only ever kept where the planner chose it, never introduced;
//   5. the seed (the job's operation identity) only rotates the cycle phase so
//      jobs do not all share one pattern; the same recipe and seed replay the
//      same sequence.
import type {JobInput,Motion}from'./contracts.ts';
export const PROPERTY_VIDEO_VARIETY_VERSION='property-video-variety-v1'as const;
export const VARIETY_CYCLE:readonly Motion[]=['push_in','side_glide','pull_back'];
export const VARIETY_WINDOW=4,VARIETY_WINDOW_DISTINCT=3;
export interface MotionVariety{version:typeof PROPERTY_VIDEO_VARIETY_VERSION;seed:string;requested:Motion[];chosen:Motion[];changed:number[]}
/** FNV-1a 32-bit of the seed text; only its residue picks the cycle phase. */
export function varietySeed(seed:string):number{let h=0x811c9dc5;for(const byte of new TextEncoder().encode(seed)){h^=byte;h=Math.imul(h,0x01000193)>>>0;}return h>>>0;}
const legal=(prefix:readonly Motion[],candidate:Motion)=>{const i=prefix.length;if(i>0&&prefix[i-1]===candidate)return false;if(i+1<VARIETY_WINDOW)return true;return new Set([...prefix.slice(i-(VARIETY_WINDOW-1)),candidate]).size>=VARIETY_WINDOW_DISTINCT;};
/** True when a finished sequence satisfies rules 1 and 2. */
export function motionVarietySatisfied(motions:readonly Motion[]):boolean{return motions.every((m,i)=>legal(motions.slice(0,i),m));}
export function varyMotions(requested:readonly Motion[],seed:string):MotionVariety{
 const phase=varietySeed(seed)%VARIETY_CYCLE.length,chosen:Motion[]=[],changed:number[]=[];
 for(let i=0;i<requested.length;i++){
  const run=i>=2&&requested[i]===requested[i-1]&&requested[i]===requested[i-2];
  if(!run&&legal(chosen,requested[i])){chosen.push(requested[i]);continue;}
  // Rotate from the seed phase; prefer a substitute that lets the next requested
  // move stand, so one illegal row costs one change.
  const order=VARIETY_CYCLE.map((_,k)=>VARIETY_CYCLE[(phase+i+k)%VARIETY_CYCLE.length]).filter(m=>legal(chosen,m));
  const pick=order.find(m=>m!==requested[i+1])??order[0];
  // Adjacency excludes one move and a 3-photo prefix holds at most two distinct
  // moves, so a third cycle member is always legal; this guard is unreachable.
  if(!pick)throw new Error('property-video variety pass has no legal move');
  chosen.push(pick);if(pick!==requested[i])changed.push(i);
 }
 return{version:PROPERTY_VIDEO_VARIETY_VERSION,seed,requested:[...requested],chosen,changed};
}
/** The frozen manifest: chosen moves on each source plus the variety record. Photo order is untouched. */
export function variedJobInput(input:JobInput):JobInput&{motion_variety:MotionVariety}{
 const motion_variety=varyMotions(input.sources.map(s=>s.motion),input.operation_id);
 return{...input,sources:input.sources.map((s,i)=>({...s,motion:motion_variety.chosen[i]})),motion_variety};
}
