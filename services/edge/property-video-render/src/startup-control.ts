/** Fixed synthetic startup control. No media capability, provider or real CPU secret. */
export interface StartupControlReceipt {
  phase:'boot'|'python'|'cleanup';
  reason:'ready'|'configuration'|'import'|'path'|'permission'|'ssl'|'syntax'|'listen'|'process_exit'|'timeout'|'unknown';
  python_ready:boolean;
  error_name?:'ModuleNotFoundError'|'ImportError'|'FileNotFoundError'|'PermissionError'|'SSLError'|'SSLCertVerificationError'|'SyntaxError'|'IndentationError'|'OSError';
  module?:'PIL'|'renderer'|'compose'|'capabilities'|'prepare_image'|'photo_motion'|'music_catalog'|'unknown';
  exit_code?:number;
  stderr_bytes:number;
  stdout_bytes:number;
  output_truncated:boolean;
  cleanup_complete:boolean;
  timestamp:number;
}
const SYNTHETIC_TOKEN='rendprop-startup-control-synthetic-not-a-secret-000000000000000000';
const RETAIN_BYTES=16*1024;
const sleep=(ms:number)=>new Promise<void>(resolve=>setTimeout(resolve,ms));
function exitCode(value:unknown):number|undefined {return Number.isInteger(value)&&Number(value)>=0&&Number(value)<=255?Number(value):undefined;}
export function startupStderrReason(stderr:string):StartupControlReceipt['reason'] {
  if(stderr.includes('private_renderer_configuration_missing'))return 'configuration';
  if(/ModuleNotFoundError|ImportError/.test(stderr))return 'import';
  if(/FileNotFoundError|can't open file|No such file/.test(stderr))return 'path';
  if(/PermissionError|Permission denied/.test(stderr))return 'permission';
  if(/SSLError|SSLCertVerificationError|CERTIFICATE_VERIFY_FAILED/.test(stderr))return 'ssl';
  if(/SyntaxError|IndentationError/.test(stderr))return 'syntax';
  if(/Address already in use/.test(stderr))return 'listen';
  return 'unknown';
}
async function collect(stream:ReadableStream|null):Promise<{text:string;bytes:number;truncated:boolean}> {
  if(!stream)return {text:'',bytes:0,truncated:false};
  const reader=stream.getReader(),kept=new Uint8Array(RETAIN_BYTES);let used=0,bytes=0;
  try {while(true){const {value,done}=await reader.read();if(done)break;
    const chunk=value as Uint8Array;bytes+=chunk.byteLength;const count=Math.min(chunk.byteLength,RETAIN_BYTES-used);
    if(count>0){kept.set(chunk.subarray(0,count),used);used+=count;}
  }}finally{reader.releaseLock();}
  return {text:new TextDecoder().decode(kept.subarray(0,used)),bytes,truncated:bytes>RETAIN_BYTES};
}
export async function startupControl(container:Container):Promise<StartupControlReceipt> {
  const receipt:StartupControlReceipt={phase:'boot',reason:'unknown',python_ready:false,stderr_bytes:0,stdout_bytes:0,output_truncated:false,cleanup_complete:false,timestamp:Date.now()};
  let processEnded=false,processCode:number|undefined,monitorEnded=false,monitorCode:number|undefined;
  let watchdog:ReturnType<typeof setTimeout>|undefined;
  try {
    container.start({image:container.images.cpu,instance:'standard-3',entrypoint:['/usr/bin/sleep','infinity'],enableInternet:false,
      env:{CONTAINER_TOKEN:SYNTHETIC_TOKEN,MEDIA_HOSTS:'media.invalid'},labels:{workload:'startup-control'}});
    void container.monitor().then(()=>{monitorEnded=true;monitorCode=0;},error=>{monitorEnded=true;monitorCode=exitCode((error as {exitCode?:unknown})?.exitCode);});
    await container.setInactivityTimeout(15_000);
    const bootDeadline=Date.now()+120_000;
    while(!container.running&&!monitorEnded&&Date.now()<bootDeadline)await sleep(300);
    if(!container.running){receipt.reason=monitorEnded?'process_exit':'timeout';if(monitorCode!==undefined)receipt.exit_code=monitorCode;return receipt;}
    receipt.phase='python';
    const process=await container.exec(['/usr/bin/timeout','--kill-after=2','8','/usr/local/bin/python3','/app/http_adapter.py'],{
      cwd:'/app',user:'10001:10001',env:{CONTAINER_TOKEN:SYNTHETIC_TOKEN,MEDIA_HOSTS:'media.invalid'},stdout:'pipe',stderr:'pipe'});
    const captured=Promise.all([collect(process.stdout),collect(process.stderr),process.exitCode.then(code=>{processEnded=true;processCode=exitCode(code);})]);
    const timed=new Promise<never>((_,reject)=>{watchdog=setTimeout(()=>reject(new Error('control_timeout')),15_000);});
    const completion=Promise.race([captured,timed]);void completion.catch(()=>{});
    const readyDeadline=Date.now()+8_000;
    while(!processEnded&&Date.now()<readyDeadline){
      try {const response=await container.getTcpPort(8080).fetch('http://container/ready',{signal:AbortSignal.timeout(1_000)});
        if(response.ok){const value=await response.json() as {ready?:unknown;provider_dispatch?:unknown};if(value.ready===true&&value.provider_dispatch===false){receipt.python_ready=true;break;}}
      }catch{/* The bounded process/port control retries no job or supplier work. */}
      await sleep(100);
    }
    const [stdout,stderr]=await completion;
    receipt.stdout_bytes=stdout.bytes;receipt.stderr_bytes=stderr.bytes;receipt.output_truncated=stdout.truncated||stderr.truncated;
    if(processCode!==undefined)receipt.exit_code=processCode;
    receipt.reason=receipt.python_ready?(processCode===124||processCode===137?'ready':'process_exit'):processCode===124||processCode===137?'timeout':startupStderrReason(stderr.text);
    const errorName=stderr.text.match(/\b(ModuleNotFoundError|ImportError|FileNotFoundError|PermissionError|SSLError|SSLCertVerificationError|SyntaxError|IndentationError|OSError)\b/)?.[1];
    if(errorName)receipt.error_name=errorName as NonNullable<StartupControlReceipt['error_name']>;
    if(receipt.reason==='import'){const module=stderr.text.match(/(?:No module named ['"]|from ['"]?)(PIL|renderer|compose|capabilities|prepare_image|photo_motion|music_catalog)(?:[.'"\s]|$)/)?.[1];receipt.module=(module??'unknown') as NonNullable<StartupControlReceipt['module']>;}
  }catch(error){receipt.reason=error instanceof Error&&error.message==='control_timeout'?'timeout':'unknown';}
  finally {
    if(watchdog!==undefined)clearTimeout(watchdog);
    try {await container.destroy();receipt.cleanup_complete=true;}catch{receipt.phase='cleanup';receipt.cleanup_complete=false;}
    receipt.timestamp=Date.now();
  }
  return receipt;
}
