import {assertEquals,assertRejects} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {boundedPhotoResultBytes} from "./photo-result.ts";
import {HttpError} from "../_shared/http.ts";
Deno.test('saved photo recovery rejects changed body length/status and bounded nonprogress',async()=>{
 assertEquals(await boundedPhotoResultBytes(new Response(new Uint8Array([1,2])),2),new Uint8Array([1,2]));
 for(const r of [new Response(new Uint8Array([1,2,3])),new Response(new Uint8Array([1])),new Response(new Uint8Array([1,2]),{headers:{'content-length':'3'}}),new Response(null,{status:302})])await assertRejects(()=>boundedPhotoResultBytes(r,2),HttpError);
 let chunks=0;const stream=new ReadableStream<Uint8Array>({pull(c){chunks++;c.enqueue(new Uint8Array());}});
 await assertRejects(()=>boundedPhotoResultBytes(new Response(stream),2),HttpError);assertEquals(chunks<=66,true);
});
