/** URL admission validates identity, not HMAC. Every byte still requires the
 * gateway's signature, current custody and durable request/byte allowance. */
export type PrivateMediaScope = { actor: string; org: string; listing: string | null; bucket?: "uploads" | "renders"; key?: string; review?: {owner:string;result:string;revision:number} };
export type PrivateMediaCapability = Required<Omit<PrivateMediaScope,"review">> & {v:1;exp:number;review?:PrivateMediaScope["review"]};
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
export function privateMediaCapability(raw:string,scope:PrivateMediaScope,now=Date.now()):PrivateMediaCapability {
 const fail=():never=>{throw new Error("The private download address does not match this account or saved media. Refresh its library.");};
 try {
  const u=new URL(raw),m=/^\/private-media\/([A-Za-z0-9_-]+)\.([a-f0-9]{64})$/.exec(u.pathname);
  if(u.origin!=="https://rendprop.com"||u.username||u.password||u.port||u.search||u.hash||!m||u.pathname.length>4096)return fail();
  const bytes=Uint8Array.from(atob(m[1].replaceAll("-","+").replaceAll("_","/")),c=>c.charCodeAt(0));
  const c=JSON.parse(new TextDecoder("utf-8",{fatal:true}).decode(bytes)) as PrivateMediaCapability;
  if(!c||typeof c!=="object"||Array.isArray(c)||!["actor,bucket,exp,key,listing,org,v","actor,bucket,exp,key,listing,org,review,v"].includes(Object.keys(c).sort().join(","))||
   c.v!==1||!Number.isSafeInteger(c.exp)||c.exp*1000<=now||c.exp*1000>now+600000||typeof c.actor!=="string"||!UUID.test(c.actor)||c.actor!==scope.actor||typeof c.org!=="string"||!UUID.test(c.org)||c.org!==scope.org||
   !(c.listing===null||typeof c.listing==="string"&&UUID.test(c.listing))||c.listing!==scope.listing||!["uploads","renders"].includes(c.bucket)||scope.bucket!==undefined&&c.bucket!==scope.bucket||
   typeof c.key!=="string"||!c.key||new TextEncoder().encode(c.key).length>1024||c.key.split("/").some(v=>!v||v==="."||v===".."||/[\\%?#\u0000-\u001f]/.test(v))||scope.key!==undefined&&c.key!==scope.key)return fail();
  if(c.review!==undefined){const r=c.review;if(c.listing===null||!r||typeof r!=="object"||Array.isArray(r)||Object.keys(r).sort().join(",")!=="owner,result,revision"||typeof r.owner!=="string"||!UUID.test(r.owner)||typeof r.result!=="string"||!UUID.test(r.result)||!Number.isSafeInteger(r.revision)||r.revision<1||r.revision>=2147483647||!scope.review||r.owner!==scope.review.owner||r.result!==scope.review.result||r.revision!==scope.review.revision)return fail();}
  else if(scope.review)return fail();
  return c;
 }catch{return fail();}
}
export function isPrivateMediaURL(raw:string):boolean {try{return new URL(raw).hostname==="rendprop.com";}catch{return false;}}
