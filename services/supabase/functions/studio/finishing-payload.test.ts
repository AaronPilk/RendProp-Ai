import {assertThrows} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {assertFinishingPayload} from "./finishing-payload.ts";
import {HttpError} from "../_shared/http.ts";
const source={name:"track.mp3",size:10,lastModified:0,sha256:"a".repeat(64),duration:10,mime:"audio/mpeg"};
const music={source,start:0,end:10,offset:0,volume:.3,fadeIn:1,fadeOut:1,ducking:"original",licensed:true};
const speech={sourceSha256:"b".repeat(64),sourceDuration:10,reviewed:true,words:[{text:"Welcome",start:0,end:1}]};
Deno.test("finishing payload accepts legacy edits and bounded user-declared tracks",()=>{assertFinishingPayload({clips:[]});assertFinishingPayload({music,speech:[speech]});});
Deno.test("finishing payload rejects invalid audio, license, bounds and injected unreadable transcript",()=>{
 for(const invalid of [{...music,licensed:false},{...music,source:{...source,size:17*1024*1024}},{...music,end:11},{...music,volume:2},{...music,source:{...source,mime:"video/mp4"}}])assertThrows(()=>assertFinishingPayload({music:invalid}),HttpError);
 for(const invalid of [{...speech,reviewed:false},{...speech,words:[{text:"private\ntext",start:0,end:1}]},{...speech,words:[{text:"beyond",start:0,end:11}]}])assertThrows(()=>assertFinishingPayload({speech:[invalid]}),HttpError);
 assertThrows(()=>assertFinishingPayload({speech:[speech,speech]}),HttpError);
 assertThrows(()=>assertFinishingPayload({speech:[speech],clips:[{source:{sha256:speech.sourceSha256,kind:"video",duration:20}}]}),HttpError);
});
