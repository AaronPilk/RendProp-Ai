import {probeMP4Duration} from '../../../../services/supabase/functions/ai-video/mp4duration.ts';
const path=Deno.args[0],expected=Number(Deno.args[1]),refuse=Deno.args[2]==='refuse';
const data=await Deno.readFile(path);let requested=0,calls=0;
try{
 const actual=await probeMP4Duration('https://synthetic.invalid/video',async(_url,init)=>{
  calls++;const match=/bytes=(\d+)-(\d+)/.exec(new Headers(init.headers).get('range')??'');if(!match)throw Error('Missing range');
  const first=Number(match[1]),last=Number(match[2]);requested+=last-first+1;
  return new Response(data.slice(first,last+1),{status:206,headers:{'content-range':`bytes ${first}-${last}/${data.length}`}});
 });
 if(refuse)throw Error('Forged movie duration was accepted');
 if(Math.abs(actual-expected)>.02)throw Error(`Expected ${expected}, actual ${actual}`);
 console.log(JSON.stringify({passed:true,path,duration:actual,rangeCalls:calls,bytesRequested:requested,fileBytes:data.length}));
}catch(error){
 if(!refuse||!(error instanceof Error)||!error.message.includes('timelines disagree'))throw error;
 console.log(JSON.stringify({passed:true,path,forgedDurationRefused:true,reason:error.message,rangeCalls:calls,bytesRequested:requested,fileBytes:data.length}));
}
