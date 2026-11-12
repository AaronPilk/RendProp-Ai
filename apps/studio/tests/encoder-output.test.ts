import assert from "node:assert/strict";
import {test} from "node:test";
import {createPagedWritableTarget,outputBlob,MAX_EXTENT,PAGE_BYTES} from "../src/editor/encoder-output";

test("seekable writes preserve overwrites, sparse positions and exact output extent",async()=>{
  const target=createPagedWritableTarget(),writer=target.writable.getWriter();
  await writer.write({type:"write",position:PAGE_BYTES+2,data:new Uint8Array([1,2,3])});
  await writer.write({type:"write",position:PAGE_BYTES+3,data:new Uint8Array([9])});
  await writer.close();const output=target.claimSuccessfulOutput();
  assert.equal(output.extent,PAGE_BYTES+5);assert.equal(output.pages.length,1);
  const bytes=new Uint8Array(await outputBlob(output).arrayBuffer());
  assert.equal(bytes.length,PAGE_BYTES+5);assert(bytes.subarray(0,PAGE_BYTES+2).every(n=>n===0));
  assert.deepEqual([...bytes.subarray(-3)],[1,9,3]);assert.equal(target.stats().state,"claimed");
  target.dispose();assert.deepEqual([...new Uint8Array(output.pages[0]!.bytes).subarray(2,5)],[1,9,3]);
});
test("extent cap is checked before allocation; repeated metadata writes do not consume an append budget",async()=>{
  const target=createPagedWritableTarget(),writer=target.writable.getWriter();
  for(let i=0;i<4;i++)await writer.write({type:"write",position:MAX_EXTENT-1,data:new Uint8Array([i])});
  assert.equal(target.stats().allocatedPages,1);assert.equal(target.stats().extent,MAX_EXTENT);
  await assert.rejects(writer.write({type:"write",position:MAX_EXTENT,data:new Uint8Array([1])}),/128 MiB/);
  assert.equal(target.stats().allocatedPages,1);target.dispose();assert.equal(target.stats().allocatedPages,0);
});
test("output cannot be claimed before stream close or after abort",async()=>{
  const target=createPagedWritableTarget();assert.throws(()=>target.claimSuccessfulOutput());
  const writer=target.writable.getWriter();await writer.write({type:"write",position:0,data:new Uint8Array([7])});
  await writer.abort();assert.throws(()=>target.claimSuccessfulOutput());assert.equal(target.stats().allocatedBytes,0);
  assert.throws(()=>outputBlob({extent:1,pages:[{index:1,bytes:new ArrayBuffer(PAGE_BYTES)}]}));
  assert.throws(()=>outputBlob({extent:1,pages:[{index:0,bytes:new ArrayBuffer(1)}]}));
  assert.throws(()=>outputBlob({extent:MAX_EXTENT,pages:[{index:0,bytes:new ArrayBuffer(PAGE_BYTES)}]}),/final output page/);
});
