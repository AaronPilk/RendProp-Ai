import type {VideoPurpose,VideoSource} from './property-video';
export const PHOTO_ORIENTATIONS=['landscape','portrait','square','unknown'] as const;
export type PhotoOrientation=typeof PHOTO_ORIENTATIONS[number];
export type PhotoOrientationFilter='all'|PhotoOrientation;
export type PhotoGeometry={width:number;height:number};
export const orientationLabel=(orientation:PhotoOrientationFilter)=>orientation==='all'?'All photos':orientation[0]!.toUpperCase()+orientation.slice(1);
/** Only dimensions of the actual displayed image, after EXIF orientation. */
export function observedGeometry(width:unknown,height:unknown):PhotoGeometry|null{
 return typeof width==='number'&&Number.isSafeInteger(width)&&width>0&&typeof height==='number'&&Number.isSafeInteger(height)&&height>0?{width,height}:null;
}
export function photoOrientation(geometry:PhotoGeometry|null|undefined):PhotoOrientation{
 const size=observedGeometry(geometry?.width,geometry?.height);
 return !size?'unknown':size.width===size.height?'square':size.width>size.height?'landscape':'portrait';
}
export function orientationCounts(orientations:readonly PhotoOrientation[]):Record<PhotoOrientation,number>{
 const counts={landscape:0,portrait:0,square:0,unknown:0};
 for(const orientation of orientations)counts[orientation]++;
 return counts;
}
/** Filtering preserves the source sequence and never changes selected IDs. */
export function filterByOrientation<T>(items:readonly T[],filter:PhotoOrientationFilter,orientation:(item:T)=>PhotoOrientation):T[]{
 return items.filter(item=>filter==='all'||orientation(item)===filter);
}
export function orientationSummary(orientations:readonly PhotoOrientation[]):string{
 const counts=orientationCounts(orientations);
 return PHOTO_ORIENTATIONS.filter(value=>counts[value]>0).map(value=>`${counts[value]} ${value}`).join(' · ');
}
/** Reject late image events and retain only observations for this exact view. */
export function recordPreviewGeometry(previous:Record<string,PhotoGeometry>,key:string,width:unknown,height:unknown,currentKeys:ReadonlySet<string>):Record<string,PhotoGeometry>{
 const size=observedGeometry(width,height);
 if(!size||!currentKeys.has(key))return previous;
 if(previous[key]?.width===size.width&&previous[key]?.height===size.height)return previous;
 const next:Record<string,PhotoGeometry>={};
 for(const current of currentKeys)if(previous[current])next[current]=previous[current];
 next[key]=size;
 return next;
}
export function withPreviewGeometry(source:VideoSource,geometry:PhotoGeometry|undefined):VideoSource{
 if(source.preparation)return source;
 const size=observedGeometry(geometry?.width,geometry?.height);
 if(size)return{...source,...size};
 return{...source,width:undefined,height:undefined};
}
export function appendVisibleSelection(selected:readonly string[],visible:readonly string[],maximum=100):string[]{
 const result=[...selected],seen=new Set(selected);
 for(const id of visible){if(result.length>=maximum)break;if(!seen.has(id)){result.push(id);seen.add(id);}}
 return result;
}
export type PhotoFrame={orientation:PhotoOrientation;cropFraction:number|null;majorCrop:boolean;width:number|null;height:number|null};
/** Centered full-screen crop shown in the UI is the same target aspect as output. */
export function photoFrame(source:VideoSource,purpose:VideoPurpose):PhotoFrame{
 const size=observedGeometry(source.preparation?.width??source.width,source.preparation?.height??source.height);
 if(!size)return{orientation:'unknown',cropFraction:null,majorCrop:false,width:null,height:null};
 const {width,height}=size;
 const ratio=width/height,target=purpose==='listing'?16/9:9/16;
 const crop=Math.max(0,1-Math.min(ratio/target,target/ratio));
 return{orientation:photoOrientation(size),cropFraction:crop,majorCrop:crop>.15,width,height};
}
export function framingSummary(sources:VideoSource[],purpose:VideoPurpose){
 const frames=sources.map(source=>photoFrame(source,purpose));return{unknown:frames.filter(frame=>frame.orientation==='unknown').length,landscape:frames.filter(frame=>frame.orientation==='landscape').length,portrait:frames.filter(frame=>frame.orientation==='portrait').length,majorCrop:frames.filter(frame=>frame.majorCrop).length,mixed:frames.some(frame=>frame.orientation==='landscape')&&frames.some(frame=>frame.orientation==='portrait')};
}
