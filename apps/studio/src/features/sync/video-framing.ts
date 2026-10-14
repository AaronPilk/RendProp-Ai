import type {VideoPurpose,VideoSource} from './property-video';
export type PhotoFrame={orientation:'landscape'|'portrait'|'square'|'unknown';cropFraction:number|null;majorCrop:boolean;width:number|null;height:number|null};
/** Centered full-screen crop shown in the UI is the same target aspect as output. */
export function photoFrame(source:VideoSource,purpose:VideoPurpose):PhotoFrame{
 const width=source.preparation?.width??source.width,height=source.preparation?.height??source.height;
 if(!width||!height)return{orientation:'unknown',cropFraction:null,majorCrop:false,width:null,height:null};
 const ratio=width/height,target=purpose==='listing'?16/9:9/16;
 const crop=Math.max(0,1-Math.min(ratio/target,target/ratio));
 return{orientation:width===height?'square':width>height?'landscape':'portrait',cropFraction:crop,majorCrop:crop>.15,width,height};
}
export function framingSummary(sources:VideoSource[],purpose:VideoPurpose){
 const frames=sources.map(source=>photoFrame(source,purpose));return{unknown:frames.filter(frame=>frame.orientation==='unknown').length,landscape:frames.filter(frame=>frame.orientation==='landscape').length,portrait:frames.filter(frame=>frame.orientation==='portrait').length,majorCrop:frames.filter(frame=>frame.majorCrop).length,mixed:frames.some(frame=>frame.orientation==='landscape')&&frames.some(frame=>frame.orientation==='portrait')};
}
