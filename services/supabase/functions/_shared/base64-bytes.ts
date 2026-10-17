/** atob-compatible decoding without a full decoded binary string beside the
 * image buffer. Preserve ASCII whitespace/unpadded legacy inputs; callers
 * requiring canonical RFC4648 encoding must check their pad bits separately. */
export function decodeBase64Bytes(value:string):Uint8Array<ArrayBuffer> {
 const clean=/[\t\n\f\r ]/.test(value)?value.replace(/[\t\n\f\r ]/g,""):value;
 const padding=clean.endsWith("==")?2:clean.endsWith("=")?1:0;
 if(clean.length%4===1||(padding>0&&clean.length%4!==0)||/[^A-Za-z0-9+/=]/.test(clean)
  ||clean.indexOf("=")!==(padding?clean.length-padding:-1))throw new DOMException("Invalid base64 encoding","InvalidCharacterError");
 const bytes=new Uint8Array(new ArrayBuffer(Math.floor(clean.length*3/4)-padding));
 let written=0;
 // Align on complete base64 quartets; each temporary binary string is <=24KiB.
 for(let offset=0;offset<clean.length;offset+=32768){
  const chunk=atob(clean.slice(offset,offset+32768));
  for(let i=0;i<chunk.length;i++)bytes[written++]=chunk.charCodeAt(i);
 }
 return bytes;
}
