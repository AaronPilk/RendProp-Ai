import assert from "node:assert/strict";
import test from "node:test";
import {readFileSync} from "node:fs";
import {PHOTO_OUTPUT_BYTES,PHOTO_OUTPUT_BASE64_CHARS,PHOTO_OUTPUT_WIRE_BYTES,photoOutputSize} from "../src/data/photo-output";
import {editedImage} from "../src/features/creative/media";
test("retained4K supplier25MiB is admitted exactly and the next byte refuses before decoding",()=>{
 assert.equal(PHOTO_OUTPUT_BYTES,25*1024*1024);assert.equal(PHOTO_OUTPUT_WIRE_BYTES,35_052_536);
 const at="A".repeat(PHOTO_OUTPUT_BASE64_CHARS-2)+"==",above="A".repeat(PHOTO_OUTPUT_BASE64_CHARS-1)+"=";
 assert.equal(at.length,above.length);assert.equal(photoOutputSize(at),PHOTO_OUTPUT_BYTES);assert.equal(photoOutputSize(above),null);
 const old=globalThis.atob;let calls=0;globalThis.atob=(s)=>{calls++;return old(s);};
 try{assert.throws(()=>editedImage(above,"image/png"));assert.equal(calls,0);assert.equal(editedImage(at,"image/png").size,PHOTO_OUTPUT_BYTES);assert.equal(calls,1);}finally{globalThis.atob=old;}
 for(const bad of["A===","A",at+"AAAA","_AAA","AABA===",at.slice(0,-3)+"B=="])assert.equal(photoOutputSize(bad),null);
});
test("Studio output envelope stays paired with server output-only policy",()=>{
 const policy=readFileSync(new URL("../../../services/supabase/functions/_shared/photo-output-policy.ts",import.meta.url),"utf8");
 assert.match(policy,/PHOTO_OUTPUT_MAX_BYTES = 25 \* 1024 \* 1024/);assert.match(policy,/PHOTO_OUTPUT_MAX_WIRE_BYTES = PHOTO_OUTPUT_MAX_BASE64_CHARS \+ 100_000/);
});
