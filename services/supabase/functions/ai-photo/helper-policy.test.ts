import {assert,assertEquals,assertThrows} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {photoHelperPayload,photoHelperQuote} from "./helper-policy.ts";
Deno.test("same bounded helper payload prices1024 combined output tokens and full vision input",()=>{
 const text=photoHelperPayload([{text:"synthetic instruction"}]),vision=photoHelperPayload([{text:"synthetic instruction"},{inline_data:{mime_type:"image/jpeg",data:"AAAA"}}]);
 assertEquals(text.generationConfig.maxOutputTokens,1024);
 assertEquals(photoHelperQuote("gemini-3.6-flash",vision)?.cents,158.0544);
 assertEquals(photoHelperQuote("gemini-3.6-flash",text)?.cents,158.0544);
 assertEquals(photoHelperQuote("gemini-3.6-flash",photoHelperPayload([{text:"x"}]))?.cents,158.0544);
 assertEquals(photoHelperQuote("unknown",vision),null);
 for(const change of [{maxOutputTokens:65536},{candidateCount:2},{tools:[]},{responseMimeType:"text/plain"}]){
  const bad={...vision,generationConfig:{...vision.generationConfig,...change}};assertEquals(photoHelperQuote("gemini-3.6-flash",bad),null);
 }
 for(const bad of [{...vision,tools:[]},{...vision,contents:[...vision.contents,...vision.contents]},{...vision,contents:[{role:"user",parts:[{text:"x"},{file_data:{file_uri:"https://synthetic.invalid"}}]}]}])assertEquals(photoHelperQuote("gemini-3.6-flash",bad),null);
 assertThrows(()=>photoHelperPayload([{text:"😀".repeat(2049)}]));
 assertThrows(()=>photoHelperPayload([{text:""}]));
});
Deno.test("actual Gemini helper sends exactly the priced payload without cap override",async()=>{
 const source=await Deno.readTextFile(new URL("./index.ts",import.meta.url));
 const a=source.indexOf("async function geminiText("),b=source.indexOf("\n/** Defensive JSON parse",a);assert(a>0&&b>a);
 const encoded=btoa(unescape(encodeURIComponent(`// @ts-nocheck\nclass HttpError extends Error{}\nconst TEXT_MODEL="gemini-3.6-flash",GEMINI_KEY="synthetic";\nexport ${source.slice(a,b)}`)));
 const actual=await import(`data:application/typescript;base64,${encoded}`);
 const payload=photoHelperPayload([{text:"actual exact text"}]);let sent:unknown;
 const old=globalThis.fetch;globalThis.fetch=async(_url,init)=>{sent=JSON.parse(String((init as {body?:unknown})?.body));return Response.json({candidates:[{content:{parts:[{text:'{"prompt":"synthetic"}'}]}}]});};
 try{await actual.geminiText(payload);assertEquals(sent,payload);assertEquals(photoHelperQuote("gemini-3.6-flash",sent),photoHelperQuote("gemini-3.6-flash",payload));}finally{globalThis.fetch=old;}
});
