import {assert,assertEquals,assertThrows,assertRejects,AssertionError} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {parsePhotoQuality,parsePhotoQualityWithDiagnostic,PHOTO_QC_JSON_SCHEMA,PHOTO_QC_PARSE_REASONS,photoQualityRubric,PHOTO_QC_AXES,PHOTO_QC_POLICY,MAX_PHOTO_QC_VERDICT_BYTES} from "./photo-qc-verdict.ts";
const good=()=>({policy:PHOTO_QC_POLICY,verdict:"pass",action:"accept",confidence:.85,preservation:{geometry:95,openings:95,fixtures:95,surfaces:95,viewpoint:95},artifacts:90,edit_quality:80,findings:[],reason:"Visible fixed features are preserved."});
const parsed=(value:unknown)=>parsePhotoQuality(JSON.stringify(value));
Deno.test("photo structured schema closes all objects while parser retains stricter numerical and evidence limits",()=>{
 const schema=PHOTO_QC_JSON_SCHEMA;
 assertEquals([...schema.required],Object.keys(good()));assertEquals(schema.additionalProperties,false);
 assertEquals(schema.properties.preservation.required,PHOTO_QC_AXES);assertEquals(schema.properties.preservation.additionalProperties,false);
 assertEquals(schema.properties.findings.items.additionalProperties,false);assertEquals(schema.properties.findings.items.required,["category","region","source","output","certainty"]);
 for(const axis of PHOTO_QC_AXES)assertEquals(schema.properties.preservation.properties[axis],{type:"integer"});
 assertEquals(schema.properties.artifacts,{type:"integer"});assertEquals(schema.properties.edit_quality,{type:"integer"});
 for(const unsupported of["minimum","maximum","minLength","maxLength","minItems","maxItems"])assert(!JSON.stringify(schema).includes('"'+unsupported+'"'));
 // A provider structural guarantee never authorizes out-of-range scores or
 // oversized evidence; those remain independently refused by our parser.
 for(const v of[{...good(),confidence:2},{...good(),artifacts:101},{...good(),reason:"x".repeat(301)}])assertEquals(parsed(v).action,"hold");
});
Deno.test("photo parse reasons are closed and never contain private provider text",()=>{
 const finding={category:"fixtures",region:"whole",source:"s",output:"o",certainty:"confirmed"};
 const cases:[any,string][]=[[null,"input_type"],["x".repeat(16385),"input_length"],["PRIVATE malformed answer","invalid_json"],["{}","schema"],[JSON.stringify({...good(),findings:[{...finding,source:""}]}),"findings"],[JSON.stringify({...good(),findings:Array(4).fill({...finding,source:"é".repeat(200),output:"é".repeat(200)})}),"verdict_size"],[JSON.stringify(good()),"verified"]];
 for(const[raw,reason]of cases){const diagnostic=parsePhotoQualityWithDiagnostic(raw);assertEquals(diagnostic.reason,reason);assert((PHOTO_QC_PARSE_REASONS as readonly string[]).includes(diagnostic.reason));assertEquals(diagnostic.verdict,parsePhotoQuality(raw));if(reason!=="verified")assertEquals(diagnostic.verdict.action,"hold");assert(!JSON.stringify(diagnostic).includes("PRIVATE"));}
});
Deno.test("photo QC accepts only the complete exact-schema threshold decision",()=>{
 assertEquals(parsed(good()).action,"accept");assertEquals(parsePhotoQuality("\x60\x60\x60json\n"+JSON.stringify(good())+"\n\x60\x60\x60").action,"accept");
 for(const axis of PHOTO_QC_AXES){const data=good();data.preservation[axis]=94;assertEquals(parsed(data).action,"hold");}
 for(const change of [{confidence:.8499},{artifacts:89},{edit_quality:79},{verdict:"unknown"},{action:"hold"},{findings:[{category:"openings",region:"tr",source:"Covered opening",output:"Clear glazing with a newly visible view",certainty:"confirmed"}]}])assertEquals(parsed({...good(),...change}).action,"hold");
});
Deno.test("photo QC distinguishes confirmed fixed-feature refusal from uncertain coverings/exposure",()=>{
 // Schema fixtures only; no vision provider has judged any image here.
 const finding={category:"openings",region:"tl",source:"The rear opening appears opaque/covered.",output:"It appears clear/glazed with a visible view.",certainty:"confirmed"};
 const fail={...good(),verdict:"fail",action:"refuse",confidence:.93,preservation:{...good().preservation,openings:35},findings:[finding],reason:"The visible rear-opening appearance changed."};
 assertEquals(parsed(fail).action,"refuse");
 assertEquals(parsed({...fail,findings:[{...finding,certainty:"uncertain"}]}).action,"hold");
 assertEquals(parsed({...fail,confidence:.84}).action,"hold");
 assertEquals(parsed({...fail,verdict:"unknown"}).action,"hold");
 assertEquals(parsed({...good(),verdict:"fail",action:"refuse",artifacts:55,reason:"The candidate has severe rendering artifacts."}).action,"refuse");
});
Deno.test("photo QC malformed, nonfinite, numeric-string and unknown schema evidence never passes",()=>{
 for(const raw of ["", "prefix "+JSON.stringify(good()),"{}",JSON.stringify(good()).replace('"confidence":0.85','"confidence":1e999')])assertEquals(parsePhotoQuality(raw).action,"hold");
 for(const value of [{...good(),policy:"video"}, {...good(),confidence:"0.99"}, {...good(),artifacts:101}, {...good(),edit_quality:-1}, {...good(),confidence:null}, {...good(),extra:"unapproved"},{...good(),verdict:["pass"]},{...good(),action:["accept"]},{...good(),preservation:{geometry:99}}, {...good(),findings:undefined}])assertEquals(parsed(value).verdict,"unknown");
 const f={category:"fixtures",region:"br",source:"Existing shelf",output:"New shelf",certainty:"confirmed"};
 for(const change of [{category:"contents"},{region:"unknown"},{certainty:["confirmed"]},{source:""},{output:"x".repeat(201)},{unexpected:true}])assertEquals(parsed({...good(),findings:[{...f,...change}]}).verdict,"unknown");
 assertEquals(parsed({...good(),findings:Array(9).fill(f)}).verdict,"unknown");
 const long={...f,source:"é".repeat(200),output:"é".repeat(200)},unicode={...good(),findings:Array(4).fill(long)};
 assert(JSON.stringify(unicode).length<MAX_PHOTO_QC_VERDICT_BYTES);assert(new TextEncoder().encode(JSON.stringify(unicode)).byteLength>MAX_PHOTO_QC_VERDICT_BYTES);
 assertEquals(parsed(unicode).verdict,"unknown","UTF8 evidence must leave room for server lineage in the actual4KiB persistence envelope");
});
Deno.test("photo rubric permits movable changes and exposure while protecting fixed features and unknown views",()=>{
 for(const edit of ["stage","declutter","sky","twilight","lawn","custom"]){
  const rubric=photoQualityRubric({edit,style:"modern",instruction:"Preserve the existing structure."});
  for(const required of ["SOURCE is the authority","movable furniture","loose clutter","EXISTING lights/windows","opaque","glazing","mounted/built-in","No generic visual","Never request another generation"]){
   assert(rubric.replace(/\s+/g," ").includes(required),required);
  }
  assert(rubric.includes(JSON.stringify({edit,style:"modern",instruction:"Preserve the existing structure."})));
 }
 const worst=photoQualityRubric({edit:"custom",style:"x".repeat(40),instruction:"\u0001".repeat(600)});
 assert(new TextEncoder().encode(worst).byteLength<=8192,"Actual rubric/context must fit the priced full-text bound");
 assertThrows(()=>photoQualityRubric({edit:"unsupported"}));
 assertThrows(()=>photoQualityRubric({edit:"custom",instruction:"x".repeat(601)}));
});
const encoded=(source:string)=>"data:application/typescript;base64,"+btoa(unescape(encodeURIComponent(source)));
Deno.test("compiled dropped findings/axis gates fail the unchanged release oracle",async()=>{
 const source=await Deno.readTextFile(new URL("./photo-qc-verdict.ts",import.meta.url));
 const cases=[
  {anchor:"&&parsed.findings.length===0",replacement:"",bad:{...good(),findings:[{category:"fixtures",region:"whole",source:"No shelf",output:"Added mounted shelf",certainty:"confirmed"}]}},
  {anchor:"parsed.preservation[axis]>=95",replacement:"parsed.preservation[axis]>=0",bad:{...good(),preservation:{...good().preservation,openings:20}}},
 ];
 for(const control of cases){assertEquals(source.split(control.anchor).length-1,1);const mutant=await import(encoded(source.replace(control.anchor,control.replacement)));
  await assertRejects(async()=>assertEquals(mutant.parsePhotoQuality(JSON.stringify(control.bad)).action,"hold"),AssertionError);
 }
});
