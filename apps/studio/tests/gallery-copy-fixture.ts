// Synthetic transport/database only. Production authority/immutability/races
// are executed separately by studio_gallery_source_copy_pg.py.
export function installGalleryCopyFixture(input:{org:string;listing:string;actor:string;image:string;services:any;gallery:any;getAssets:()=>any[];setAssets:(v:any[])=>void;getPhotos:()=>any[];setPhotos:(v:any[])=>void}){
 const{org,listing,actor,services,gallery}=input,original='81000000-0000-4000-8000-000000000001',edited='81000000-0000-4000-8000-000000000002',provenance='81000000-0000-4000-8000-000000000003',dbKey='synthetic-gallery-copy-server';
 const sourceKey=(id:string)=>`renders/${org}/${listing}/${id===original?'original-':''}${id}.jpg`;
 const canvas=document.createElement('canvas');canvas.width=896;canvas.height=1195;const ctx=canvas.getContext('2d')!;ctx.fillStyle='#dce3d6';ctx.fillRect(0,0,896,1195);ctx.fillStyle='#3a624d';ctx.fillRect(50,60,400,800);const image=canvas.toDataURL('image/jpeg',.97),bytes=Uint8Array.from(atob(image.split(',')[1]),c=>c.charCodeAt(0));
 const digest=async(b:Uint8Array)=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',b as Uint8Array<ArrayBuffer>)),n=>n.toString(16).padStart(2,'0')).join('');const sha=digest(bytes);
 const base={created_at:'2026-10-15T12:00:00Z',listing_id:listing,kind:'photo',bucket:'renders',uploaded:true,bytes:bytes.length,duration_s:0};
 const initial={assets:[{...base,id:original,storage_key:sourceKey(original)},{...base,id:edited,storage_key:sourceKey(edited)}],photos:[{id:original,listing_id:listing,original_key:sourceKey(original),enhanced_key:null,is_staged:false,is_main:false,caption:'Previously saved source',sort:0,created_at:base.created_at}],operations:{}as Record<string,any>,selection:null as string[]|null,uploads:{}as Record<string,any>,putCount:0,aliasCount:0};
 let db=JSON.parse(localStorage.getItem(dbKey)??'null')??initial,badBytes=false,hold=false,loseFinish=false;input.setAssets(db.assets);input.setPhotos(db.photos);gallery.set(listing,db.selection);
 const persist=()=>{db.assets=input.getAssets();db.photos=input.getPhotos();db.selection=gallery.read(listing).gallery_asset_ids;localStorage.setItem(dbKey,JSON.stringify(db));};
 const oldAPI=services.api,oldFetch=window.fetch.bind(window),calls:any[]=[];
 function download(key:string){const exp=Math.floor(Date.now()/1000)+590,c={v:1,actor,org,listing,bucket:'renders',key,exp};return{url:`https://rendprop.com/private-media/${btoa(JSON.stringify(c)).replaceAll('+','-').replaceAll('/','_').replaceAll('=','')}.${'a'.repeat(64)}`,expires_at:new Date(exp*1000).toISOString()};}
 async function response(row:any){return{schema:1,actor_id:actor,org_id:org,library_org_id:org,listing_id:listing,operation_id:row.operation,source:{asset_id:row.source,key:sourceKey(row.source),bytes:bytes.length,sha256:await sha,mime:'image/jpeg',kind:row.source===original?'original':'altered',provenance:row.source===original?null:{id:provenance,original_asset_id:original,original_key:sourceKey(original),disclosure:'AI altered; compare with retained Original'}},destination_asset_id:row.destination??null,complete:row.complete??false,photo:row.complete?input.getPhotos().find(p=>p.id===row.destination):null,download:row.complete?null:download(sourceKey(row.source))};}
 window.fetch=async(url,options)=>{if(typeof url==='string'&&url.startsWith('https://rendprop.com/private-media/')){const b=bytes.slice();if(badBytes)b[b.length-1]^=1;return new Response(b,{headers:{'content-type':'image/jpeg','content-length':String(b.length)}});}return await oldFetch(url,options);};
 services.listMedia=async()=>({orgId:org,listingId:listing,photos:[...input.getPhotos().map(p=>{const a=input.getAssets().find(a=>a.storage_key===(p.enhanced_key||p.original_key));return{id:p.id,listingId:listing,url:image,expiresAt:'2099-01-01T00:00:00Z',caption:p.caption,isStaged:p.is_staged,isAltered:p.is_staged,editKind:p.is_staged?'stage':null,originalUrl:p.is_staged?image:null,sort:p.sort};}),...input.getAssets().filter(a=>a.uploaded&&!input.getPhotos().some(p=>(p.enhanced_key||p.original_key)===a.storage_key)).map(a=>({id:a.id,listingId:listing,url:image,expiresAt:'2099-01-01T00:00:00Z',caption:'Legacy edited source',isStaged:false,isAltered:true,editKind:'stage',originalUrl:null,sort:0}))],videos:[],nextOffset:null,unavailableCount:0});
 services.upload=async(_url:string,file:Blob)=>{db.putCount++;const data=new Uint8Array(await file.arrayBuffer());const current=Object.values(db.uploads).find((u:any)=>!u.uploaded)as any;if(!current)throw Error('No bound upload');if(!Object.values(db.operations).some((r:any)=>r.destination===current.id))throw Error('PUT occurred before binding');current.sha=await digest(data);persist();return{etag:'synthetic-exact-byte-receipt'};};
 services.api=async(path:string,options:any)=>{
  const body=options.body;calls.push({path,method:options.method??'GET',body});
  if(path==='/functions/v1/studio/photo-copy'){
   if(body.listing_id!==listing)throw Error('Wrong source property');
   if(body.action==='prepare'){
    if(hold&&body.source_asset_id===edited)throw Error('This edited photo has not passed its required accuracy review');
    if(![original,edited].includes(body.source_asset_id))throw Error('Unknown source');
    const row=db.operations[body.source_asset_id]??{operation:body.operation_id,source:body.source_asset_id};db.operations[body.source_asset_id]=row;persist();return await response(row);
   }
   const row=Object.values(db.operations).find((r:any)=>r.operation===body.operation_id)as any;if(!row)throw Error('Unknown operation');
   if(body.action==='bind'){if(row.destination&&row.destination!==body.destination_asset_id)throw Error('Different destination');row.destination=body.destination_asset_id;persist();return await response(row);}
   if(body.action==='finish'){
    if(!row.complete){const a=input.getAssets().find(a=>a.id===row.destination),upload=db.uploads[row.destination];if(!a?.uploaded||upload?.sha!==await sha)throw Error('Not the exact stored source bytes');if(hold&&row.source===edited)throw Error('This edited photo has not passed its required accuracy review');
     input.setPhotos([...input.getPhotos(),{id:a.id,listing_id:listing,original_key:row.source===original?a.storage_key:sourceKey(original),enhanced_key:row.source===edited?a.storage_key:null,is_staged:row.source===edited,is_main:false,caption:row.source===original?'Prepared original':'Prepared edited version · AI altered',sort:input.getPhotos().length,created_at:base.created_at}]);if(row.source===edited)db.aliasCount++;row.complete=true;persist();}
    if(loseFinish){loseFinish=false;throw Error('Unknown preparation reply. Resume the same photo.');}return await response(row);
   }
  }
  if(path==='/functions/v1/uploads'){
   const operation=options.idempotencyKey;if(!operation)throw Error('Missing exact upload operation');let upload=Object.values(db.uploads).find((u:any)=>u.operation===operation)as any;
   if(!upload){gallery.freeze(listing);const id=crypto.randomUUID();upload={id,operation,listing_id:listing,storage_key:`renders/${org}/${listing}/gallery-${id}.jpg`,kind:'photo',bucket:'renders',uploaded:false,bytes:body.bytes,created_at:base.created_at};db.uploads[id]=upload;input.setAssets([...input.getAssets(),upload]);persist();}
   return{asset_id:upload.id,storage_key:upload.storage_key,mode:'single',uploaded:upload.uploaded,put_url:'https://uploads.rendprop.com/synthetic-only'};
  }
  const match=/^\/functions\/v1\/uploads\/([^/]+)\/(renew|complete)$/.exec(path);
  if(match){const upload=db.uploads[match[1]];if(!upload)throw Error('Missing upload');if(match[2]==='complete'){upload.uploaded=true;input.setAssets(input.getAssets().map(a=>a.id===upload.id?{...a,uploaded:true}:a));persist();return{...upload};}return{asset_id:upload.id,storage_key:upload.storage_key,mode:'single',uploaded:upload.uploaded,put_url:'https://uploads.rendprop.com/synthetic-only'};}
  const result=await oldAPI(path,options);if(options.method==='PATCH')persist();return result;
 };
 return{original,edited,snapshot:()=>structuredClone({...db,calls}),loseFinish:()=>{loseFinish=true;},badBytes:(v:boolean)=>{badBytes=v;},hold:(v:boolean)=>{hold=v;},image};
}
