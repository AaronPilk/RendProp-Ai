import{AwsClient}from'https://esm.sh/aws4fetch@1.0.20';
import{assert,HttpError}from'../_shared/http.ts';
import{bucket}from'./runtime.ts';
export class MissingPrivateMedia extends HttpError{constructor(){super(409,'The completed private output is unavailable.');}}
const client=()=>new AwsClient({accessKeyId:Deno.env.get('R2_ACCESS_KEY_ID')?.trim()??'',secretAccessKey:Deno.env.get('R2_SECRET_ACCESS_KEY')?.trim()??'',service:'s3',region:'auto'});
const AERIAL_UUID='[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}';
// These keys come only from the existing scoped SQL reservations. This grammar
// admits their exact layout; job/lease/source authority stays with the callers.
const AERIAL_KEY=new RegExp(`^renders/${AERIAL_UUID}/${AERIAL_UUID}/(?:aerial-input/${AERIAL_UUID}\\.jpg|aerial-provider/${AERIAL_UUID}\\.mp4|aerial-opening/${AERIAL_UUID}\\.(?:mp4|jpg)|aerial-review/${AERIAL_UUID}/frame-(?:0|60|119|120)\\.jpg)$(?![\\s\\S])`);
function url(which:string,key:string){assert(/^(renders\/[a-f0-9-]{36}\/[a-f0-9-]{36}\/background\/[a-f0-9-]{36}\/[a-f0-9-]{36}\/(master\.mp4|first-clip\.jpg)|uploads\/[a-f0-9-]{36}\/[a-f0-9-]{36}\/prepared-video\/[a-f0-9-]{36}\/[a-f0-9-]{36}\.jpg|presenter-private\/[a-f0-9-]{36}\/[a-f0-9-]{36}\/[a-f0-9-]{36}\/narration\/[a-f0-9-]{36}\.(m4a|mp3))$/.test(key)||(which==='renders'&&AERIAL_KEY.test(key)),403,'Use an exact private job media key.');const account=Deno.env.get('CLOUDFLARE_ACCOUNT_ID');assert(account,503,'Private storage activation pending.');return new URL(`https://${account}.r2.cloudflarestorage.com/${bucket(which)}/${key}`);}
/** A single immutable object write binds all bytes/type/digest capability headers.
 * Browser/audio and trusted CPU call no cookies/JWT; one lost PUT stays retained.
 * R2 Content-Length is signed; digest metadata is independently checked by the
 * audio reader or trusted CPU byte hasher, never treated as user pixel proof. */
export async function putCapability(which:string,key:string,bytes:number,mime:string,sha256:string){const target=url(which,key);target.searchParams.set('X-Amz-Expires','600');const headers={'content-type':mime,'content-length':String(bytes),'x-amz-meta-sha256':sha256,'if-none-match':'*'};const signed=await client().sign(target,{method:'PUT',headers,aws:{signQuery:true,allHeaders:true}});return{put_url:signed.url,headers,expires_at:new Date(Date.now()+600000).toISOString()};}
export async function outputHead(which:string,key:string){const response=await fetch(await client().sign(url(which,key),{method:'HEAD'}),{redirect:'error',signal:AbortSignal.timeout(10000)});if(response.status===404)throw new MissingPrivateMedia();assert(response.status===200,503,'Private storage could not confirm the completed output.');return{exists:true,bytes:Number(response.headers.get('content-length')),etag:response.headers.get('etag'),contentType:response.headers.get('content-type'),sha256:response.headers.get('x-amz-meta-sha256')};}
