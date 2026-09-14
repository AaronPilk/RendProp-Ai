import test from "node:test";
import assert from "node:assert/strict";
import {resolvePhotoAliases,type ReadableMedia} from "../src/features/sync/media-aliases";
import type {StudioServices} from "../src/data/services";
const org="10000000-0000-4000-8000-000000000001",listing="20000000-0000-4000-8000-000000000002",original="30000000-0000-4000-8000-000000000003",altered="40000000-0000-4000-8000-000000000004",photo="50000000-0000-4000-8000-000000000005";
const originalKey=`uploads/${org}/${listing}/original.jpg`,alteredKey=`renders/${org}/${listing}/edited.jpg`;
function services(scope=org){return {api:async()=>({org_id:scope,listing_id:listing,assets:[{id:original,storage_key:originalKey},{id:altered,storage_key:alteredKey}],photos:[{id:photo,original_key:originalKey,enhanced_key:alteredKey}],next_offset:null})} as unknown as StudioServices;}
test("native capture ID aliases retain exact original pixels and never substitute an enhanced gallery URL",async()=>{
 const available=new Map<string,ReadableMedia>([[photo,{url:"https://fixture.invalid/edited",originalUrl:"https://fixture.invalid/original"}]]);
 await resolvePhotoAliases(services(),org,listing,available,[original,altered],new AbortController().signal);
 assert.equal(available.get(original)?.url,"https://fixture.invalid/original");assert.equal(available.get(altered)?.url,"https://fixture.invalid/edited");
});
test("an original with no signed original URL stays unavailable rather than silently becoming an altered file",async()=>{
 const available=new Map<string,ReadableMedia>([[photo,{url:"https://fixture.invalid/edited"}]]);
 await resolvePhotoAliases(services(),org,listing,available,[original],new AbortController().signal);assert.equal(available.has(original),false);
});
test("aliases reject another property's scoped state and perform no lookup for already available IDs",async()=>{
 const available=new Map<string,ReadableMedia>([[photo,{url:"https://fixture.invalid/edited"}]]);
 await assert.rejects(resolvePhotoAliases(services("other"),org,listing,available,[original],new AbortController().signal),/identities/);
 await resolvePhotoAliases({api:()=>{throw new Error("Unnecessary fetch");}} as unknown as StudioServices,org,listing,available,[photo],new AbortController().signal);
});
