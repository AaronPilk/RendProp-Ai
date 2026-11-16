import {assert,HttpError} from '../_shared/http.ts';
import {inspectPhotoOutputBytes} from '../ai-photo/input-policy.ts';
import {bytesFrom} from './runtime.ts';

// This is an early refusal for measurable, definitely undersized masters. The
// container still decodes/orients every source and enforces native pixels on
// every output frame. Keep quote latency and memory bounded for large recipes.
const MAX_SOURCE_READ=8*1024*1024;
const MAX_READS=3;
const MAX_TOTAL_READ=24*1024*1024;
const ZOOM=1.12;
const TOO_SMALL='This photo is too small for a 1080p Photo motion video. Choose a higher-resolution original. No video was started.';

export type PhotoMotionPreflightBudget={remainingReads:number;remainingBytes:number};
export function photoMotionPreflightBudget():PhotoMotionPreflightBudget{
 return{remainingReads:MAX_READS,remainingBytes:MAX_TOTAL_READ};
}
export function photoMotionRequestCurrent(signal:AbortSignal):void{
 assert(!signal.aborted,409,'This Photo motion request stopped before creating a video. No video was started.');
}

/** EXIF may exchange the axes. Only refuse if neither orientation can retain
 * the exact centered crop at the renderer's maximum zoom. */
export function definitelyUndersized(width:number,height:number,aspect:'16:9'|'9:16'):boolean{
 const [targetWidth,targetHeight]=aspect==='16:9'?[1920,1080]:[1080,1920];
 const lacks=(w:number,h:number)=>{
  const cropWidth=Math.min(w,h*targetWidth/targetHeight);
  const cropHeight=cropWidth*targetHeight/targetWidth;
  return cropWidth/ZOOM<targetWidth||cropHeight/ZOOM<targetHeight;
 };
 return lacks(width,height)&&lacks(height,width);
}

/** The caller has already checked the actor/listing reference and object HEAD.
 * bytesFrom rechecks ETag before/after a bounded If-Match GET and exact SHA.
 * Oversized, uninspectable sources stay under the renderer's final authority;
 * this result is never an eligibility certificate. */
export async function preflightPhotoMotionSource(
 source:any,aspect:'16:9'|'9:16',budget:PhotoMotionPreflightBudget,
 signal?:AbortSignal,
 read:typeof bytesFrom=bytesFrom,
):Promise<void>{
 if(signal)photoMotionRequestCurrent(signal);
 if(!Number.isSafeInteger(source.bytes)||source.bytes<1||source.bytes>MAX_SOURCE_READ||
    source.bytes>budget.remainingBytes||budget.remainingReads<1)return;
 budget.remainingReads--;
 budget.remainingBytes-=source.bytes;
 const {bytes}=await read(source,MAX_SOURCE_READ);
 if(signal)photoMotionRequestCurrent(signal);
 let dimensions:{width:number;height:number};
 try {dimensions=inspectPhotoOutputBytes(bytes,source.content_type);}
 catch(error){
  // This structural parser is narrower than the renderer's actual decoder.
  // An unknown/overbound image is never an early eligibility certificate.
  if(error instanceof HttpError&&[400,413].includes(error.status))return;
  throw error;
 }
 assert(!definitelyUndersized(dimensions.width,dimensions.height,aspect),422,TOO_SMALL);
}
