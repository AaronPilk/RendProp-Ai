import {assertEquals,assertThrows} from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {HttpError} from '../_shared/http.ts';
import {planInput,planOutput} from './plan.ts';
const id=(i:number)=>`e4000000-0000-4000-8000-${String(i).padStart(12,'0')}`;
const photos=Array.from({length:20},(_,i)=>({photo_id:`private-file-${i}`,asset_id:id(i+10)})),body={listing_id:id(1),expected_org_id:id(2),photos};
Deno.test('planner keeps every identity in original request order even when supplier returns reversed indexes',()=>{
 const value=JSON.stringify({photos:photos.map((_,i)=>({index:i+1,scene:'kitchen',confidence:.9,motion:'side_glide'})).reverse()});const result=planOutput(value,planInput(body).photos);assertEquals(result.map(p=>[p.photo_id,p.asset_id]),photos.map(p=>[p.photo_id,p.asset_id]));assertEquals(result.every(p=>p.seconds===5),true);
});
Deno.test('uncertain scene never sends unsupported static_parallax or invented drone motion',()=>{
 const result=planOutput(JSON.stringify({photos:[{index:1,scene:'unknown',confidence:.95,motion:'fly_through'},{index:2,scene:'entry',confidence:.4,motion:'fly_through'}]}),photos.slice(0,2));assertEquals(result.map(p=>p.motion),['push_in','push_in']);
});
Deno.test('missing,empty,duplicate,unbounded,foreignURL,client room/motion/photo facts cannot enter the planner',()=>{
 for(const value of [{...body,photos:[]},{...body,photos:undefined},{...body,photos:[...photos,photos[0]]},{...body,photos:[photos[0],photos[0]]},{...body,prompt:'invent a room'}, {...body,photos:[{photo_id:'x',asset_id:'https://arbitrary.invalid'}]},{...body,photos:[{...photos[0],room:'bedroom'}]}])assertThrows(()=>planInput(value),HttpError);
});
Deno.test('partial/duplicate/invented scenes,facts,duration and invalidconfidence are honestly refused',()=>{
 const one=photos.slice(0,1),valid={index:1,scene:'living',confidence:.9,motion:'push_in'};
 for(const value of [{photos:[]},{photos:[valid,valid]},{photos:[{...valid,index:2}]},{photos:[{...valid,scene:'wine cellar'}]},{photos:[{...valid,confidence:1.01}]},{photos:[{...valid,motion:'orbit'}]},{photos:[{...valid,seconds:8}]},{photos:[valid],script:'address claim'}])assertThrows(()=>planOutput(JSON.stringify(value),one),HttpError);
});
