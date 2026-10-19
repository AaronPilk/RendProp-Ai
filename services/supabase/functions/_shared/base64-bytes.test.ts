import {assertEquals,assertThrows} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {decodeBase64Bytes} from "./base64-bytes.ts";
Deno.test("chunked decoder preserves atob bytes across quartets, padding and legacy whitespace",()=>{
 for(const size of [0,1,2,3,24575,24576,24577,65537]){
  const bytes=Uint8Array.from({length:size},(_,i)=>i%256);let binary="";
  for(let i=0;i<bytes.length;i+=32768)binary+=String.fromCharCode(...bytes.subarray(i,i+32768));
  const encoded=btoa(binary);
  for(const value of [encoded,encoded.replace(/=/g,""),encoded.replace(/.{40}/g,"$&\r\n\t ")])assertEquals(decodeBase64Bytes(value),bytes);
 }
 // atob accepts nonzero pad bits; strict image admission independently rejects
 // them, while this shared decoder preserves its existing byte contract.
 assertEquals(decodeBase64Bytes("YR=="),new Uint8Array([97]));
});
Deno.test("chunked decoder cannot accept padding between chunks or salvage invalid encodings",()=>{
 for(const value of ["A","YQ=","====","AA=A","YWJj!","YQ==YQ==","AAAA".repeat(8191)+"YQ=="+"YWJj","YW\u00a0Jj"]){
  assertThrows(()=>atob(value));assertThrows(()=>decodeBase64Bytes(value));
 }
});
