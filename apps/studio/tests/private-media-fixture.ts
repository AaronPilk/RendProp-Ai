import {mediaURL} from '../src/data/contracts';
import {downloadSavedMedia} from '../src/features/projects/cloud-media';
const actor='10000000-0000-4000-8000-000000000001',org='20000000-0000-4000-8000-000000000002',listing='30000000-0000-4000-8000-000000000003',id='40000000-0000-4000-8000-000000000004';
const exp=Math.floor(Date.now()/1000)+590,value={actor,org,listing,v:1,exp,bucket:'renders',key:`renders/${org}/${listing}/photo.jpg`};
const url=(p:unknown=value)=>'https://rendprop.com/private-media/'+btoa(JSON.stringify(p)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'')+'.'+'a'.repeat(64);
(async()=>{let checks=0;const scope={actor,org,listing:null};const admitted=mediaURL(url(),org,listing,new Date(exp*1000).toISOString(),Date.now(),actor);if(admitted!==url())throw Error('identity');checks++;
 for(const p of [{...value,actor:id},{...value,org:id},{...value,listing:id}]){let refused=false;try{mediaURL(url(p),org,listing,new Date(exp*1000).toISOString(),Date.now(),actor);}catch{refused=true;}if(!refused)throw Error('foreign identity accepted');checks++;}
 const r=await fetch(admitted,{credentials:'omit',redirect:'error',referrerPolicy:'no-referrer'});if(r.status!==200||new Uint8Array(await r.arrayBuffer()).join(',')!=='1,2,3')throw Error('bytes');checks++;
 const data=new Uint8Array([1,2,3]),sha=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',data)),v=>v.toString(16).padStart(2,'0')).join('');const part={index:0,bytes:3,sha256:sha,complete:true,url:url({...value,listing:null,bucket:'uploads',key:`studio-project/${org}/${actor}/${id}/0`})};const saved={id,sha256:sha,bytes:3,mime:'image/jpeg',filename:'owned.jpg',modified:0,complete:true,parts:[part]};if((await downloadSavedMedia(saved,new AbortController().signal,scope)).size!==3)throw Error('part');checks++;
 let refused=false;try{await downloadSavedMedia({...saved,parts:[{...part,url:url({...value,listing:null,bucket:'uploads',key:`studio-project/${org}/${actor}/${id}/1`})}]},new AbortController().signal,scope);}catch{refused=true;}if(!refused)throw Error('wrong part');checks++;
 document.querySelector('#state')!.textContent=JSON.stringify({status:'passed',checks});
})().catch(e=>{document.querySelector('#state')!.textContent=JSON.stringify({status:'failed',error:String(e.stack??e)});});
