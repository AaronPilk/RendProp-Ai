import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { deflateSync } from "node:zlib";
import { HttpError } from "../_shared/http.ts";
import { PHOTO_INPUT_POLICY, validatePhotoInput, validatePhotoInputs, validatePhotoPrompt } from "./input-policy.ts";

const bytes64 = (bytes: Uint8Array) => { const pieces: string[]=[]; for(let i=0;i<bytes.length;i+=32768)pieces.push(String.fromCharCode(...bytes.subarray(i,i+32768))); return btoa(pieces.join("")); };
// Actual PNG encoding (zlib-compressed scanline), independent of the parser.
function crc(bytes: Uint8Array) { let c = -1; for (const b of bytes) { c ^= b; for (let i = 0; i < 8; i++) c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0); } return (c ^ -1) >>> 0; }
function chunk(kind: string, data: Uint8Array) {
  const out = new Uint8Array(12 + data.length), view = new DataView(out.buffer);
  view.setUint32(0, data.length); out.set(new TextEncoder().encode(kind), 4); out.set(data, 8);
  view.setUint32(out.length - 4, crc(out.subarray(4, out.length - 4))); return out;
}
export function pngFixture(width = 1, height = 1, extra: Uint8Array[] = []) {
  const h = new Uint8Array(13), v = new DataView(h.buffer); v.setUint32(0, width); v.setUint32(4, height); h[8] = 8; h[9] = 6;
  const parts = [new Uint8Array([137,80,78,71,13,10,26,10]), chunk("IHDR", h), ...extra, chunk("IDAT", deflateSync(new Uint8Array([0,255,0,0,255]))), chunk("IEND", new Uint8Array())];
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let i = 0; for (const p of parts) { out.set(p, i); i += p.length; } return out;
}
export function jpegFixture(width = 1, height = 1) {
  // Complete structural baseline frame and scan; no provider is called by the
  // geometry tests. Production validation does not claim to decode entropy.
  return new Uint8Array([255,216,255,192,0,11,8,height>>8,height&255,width>>8,width&255,1,1,17,0,255,218,0,8,1,1,0,0,63,0,1,255,217]);
}
function webpFixture(width = 1, height = 1, animation = false) {
  const data = new Uint8Array(5), bits = (width-1) | ((height-1)<<14); data[0] = 47; new DataView(data.buffer).setUint32(1,bits,true);
  const image = new Uint8Array(14); image.set(new TextEncoder().encode("VP8L")); new DataView(image.buffer).setUint32(4,5,true); image.set(data,8);
  const anim = animation ? new Uint8Array([65,78,73,77,0,0,0,0]) : new Uint8Array();
  const out = new Uint8Array(12 + image.length + anim.length); out.set(new TextEncoder().encode("RIFF")); new DataView(out.buffer).setUint32(4,out.length-8,true); out.set(new TextEncoder().encode("WEBP"),8); out.set(image,12); out.set(anim,12+image.length); return out;
}
const invalid = (b: Uint8Array, mime = "image/png") => assertThrows(() => validatePhotoInput(bytes64(b),mime),HttpError);

Deno.test("still image policy reads complete JPEG, real PNG and static lossless WebP geometry",()=>{
  for(const [b,m] of [[jpegFixture(3000,2000),"image/jpeg"],[pngFixture(),"image/png"],[webpFixture(2048,1024),"image/webp"]] as const) {
    const result=validatePhotoInput(bytes64(b),m); assertEquals(result.bytes,b.length); assertEquals(result.mime,m);
  }
  assertEquals(validatePhotoInput(bytes64(jpegFixture(3000,2000)),"image/jpeg").width,3000);
});
Deno.test("declared MIME cannot hide another container, animation or HEIC",()=>{
  invalid(pngFixture(),"image/jpeg"); invalid(jpegFixture(),"image/png"); invalid(webpFixture(),"image/heic");
  invalid(pngFixture(1,1,[chunk("acTL",new Uint8Array(8))])); invalid(webpFixture(1,1,true),"image/webp");
});
Deno.test("full answer bytes reject truncated/trailing images and PNG integrity damage",()=>{
  for(const [b,m] of [[pngFixture(),"image/png"],[jpegFixture(),"image/jpeg"],[webpFixture(),"image/webp"]] as const) {
    invalid(b.subarray(0,b.length-1),m); const trailing=new Uint8Array(b.length+1); trailing.set(b); invalid(trailing,m);
  }
  const corrupt=pngFixture(); corrupt[20]^=1; invalid(corrupt);
  const duplicate=pngFixture(1,1,[chunk("IHDR",new Uint8Array(13))]); invalid(duplicate);
});
Deno.test("canonical base64 refuses decoder salvage before geometry parsing",()=>{
  const p=bytes64(pngFixture()); for(const bad of ["",p+"\n","data:image/png;base64,"+p,p.slice(1),"AA=A",p.replace(/=$/,"A")]) assertThrows(()=>validatePhotoInput(bad,"image/png"),HttpError);
});
Deno.test("input geometry is bounded without pretending geometry is a token invoice",()=>{
  validatePhotoInput(bytes64(jpegFixture(6000,4000)),"image/jpeg");
  for(const [w,h] of [[6001,4000],[8193,1],[0,1]]) invalid(jpegFixture(w,h),"image/jpeg");
  validatePhotoInput(bytes64(jpegFixture(8192,1)),"image/jpeg");
});
Deno.test("source and mask have one combined byte allowance and exact dimensions",()=>{
  const image=bytes64(pngFixture()); validatePhotoInputs(image,"image/png",image,"image/png");
  assertThrows(()=>validatePhotoInputs(image,"image/png",bytes64(jpegFixture(2,1)),"image/jpeg"),HttpError,"same dimensions");
  const giant=new Uint8Array(PHOTO_INPUT_POLICY.maxDecodedBytes+1); assertThrows(()=>validatePhotoInput(bytes64(giant),"image/jpeg"),HttpError);
  const frame=jpegFixture(), segments:Uint8Array[]=[]; let size=frame.length;
  while(size<4_500_100){const n=Math.min(65_000,4_500_100-size); const segment=new Uint8Array(n);segment.set([255,224,(n-2)>>8,(n-2)&255]);segments.push(segment);size+=n;}
  const large=new Uint8Array(size);large.set(frame.subarray(0,2));let offset=2;for(const s of segments){large.set(s,offset);offset+=s.length;}large.set(frame.subarray(2),offset);
  const b64=bytes64(large); validatePhotoInput(b64,"image/jpeg");
  assertThrows(()=>validatePhotoInputs(b64,"image/jpeg",b64,"image/jpeg"),HttpError,"at most 9 MB");
});
Deno.test("prompt limits measure UTF-8 before dispatch and never silently truncate",()=>{
  validatePhotoPrompt("a".repeat(600),true); assertThrows(()=>validatePhotoPrompt("a".repeat(601),true),HttpError);
  validatePhotoPrompt("é".repeat(300),true); assertThrows(()=>validatePhotoPrompt("é".repeat(301),true),HttpError);
  validatePhotoPrompt("a".repeat(8192)); assertThrows(()=>validatePhotoPrompt("a".repeat(8193)),HttpError);
});
