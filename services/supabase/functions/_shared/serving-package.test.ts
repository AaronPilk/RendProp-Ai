import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { photoAdmissionHoldCents, packageCost, retailPackageScenario, trialPackageScenario, validateServingReserves, type ServingReserves } from "./serving-package.ts";
const zero: ServingReserves={storage:0,delivery:0,compute:0,email:0,support:0,retention:0,uncertainty:0};
Deno.test("package liability is tied to the actual4096/1K payload and rounds aggregate cents upward",()=>{
 assertEquals(photoAdmissionHoldCents(),35.1296);
 assertEquals(packageCost({photoAdmissions:5,otherAiHoldCents:0,reserves:zero}).photoCents,176);
 for(const [count,cents] of [[10,352],[25,879],[60,2108]])assertEquals(packageCost({photoAdmissions:count,otherAiHoldCents:0,reserves:zero}).photoCents,cents);
});
Deno.test("all seven explicit reserves are required; missing/extra/noninteger/negative cost is refused",()=>{
 assertEquals(validateServingReserves(zero),zero);
 for(const bad of [null,[],{}, {...zero,delivery:undefined},{...zero,support:-1},{...zero,compute:1.5},{...zero,email:Infinity},{...zero,extra:0}])assertThrows(()=>validateServingReserves(bad));
 assertThrows(()=>packageCost({photoAdmissions:NaN,otherAiHoldCents:0,reserves:zero}));
 assertThrows(()=>packageCost({photoAdmissions:5,otherAiHoldCents:-1,reserves:zero}));
});
Deno.test("annual discounted package is bounded by the smallest immutable funding slice",()=>{
 const starter=retailPackageScenario(41650,12,{photoAdmissions:10,otherAiHoldCents:0,reserves:zero});
 assertEquals(starter.minimumIntervalCents,867);assertEquals(starter.remainderCents,515);
 const pro=retailPackageScenario(84150,12,{photoAdmissions:25,otherAiHoldCents:0,reserves:zero});
 assertEquals(pro.minimumIntervalCents,1753);assertEquals(pro.remainderCents,874);
});
Deno.test("marketed100/200/400 fail before nonAI; candidate10/25/60 never imply approval",()=>{
 for(const [net,photos] of [[4165,100],[8415,200],[21165,400]])assertEquals(retailPackageScenario(net,1,{photoAdmissions:photos,otherAiHoldCents:0,reserves:zero}).arithmeticallyFits,false);
 for(const [net,photos] of [[4165,10],[8415,25],[21165,60]]){
  const result=retailPackageScenario(net,1,{photoAdmissions:photos,otherAiHoldCents:0,reserves:zero});
  assertEquals(result.arithmeticallyFits,true);assertEquals(result.financiallyCertified,false);assertEquals(result.activated,false);
 }
});
Deno.test("whole cost includes otherAI and fixed infrastructure; a balance cannot approve a trial",()=>{
 const trial=trialPackageScenario(500,{photoAdmissions:5,otherAiHoldCents:0,reserves:zero});assertEquals(trial.remainderCents,324);assertEquals(trial.activated,false);
 const helpers=trialPackageScenario(500,{photoAdmissions:5,otherAiHoldCents:413,reserves:zero});assertEquals(helpers.arithmeticallyFits,false);
 const whole=retailPackageScenario(4165,1,{photoAdmissions:0,otherAiHoldCents:0,reserves:{...zero,compute:4000}});assertEquals(whole.arithmeticallyFits,false);
 assertThrows(()=>trialPackageScenario(500,{photoAdmissions:4,otherAiHoldCents:0,reserves:zero}));
});
Deno.test("conservative30percent Apple scenario keeps protected photos and separate bounded helpers finite",()=>{
 const reserves:ServingReserves={storage:16,retention:49,delivery:96,compute:130,email:1,support:100,uncertainty:108};
 for(const [net,months,count,wallet]of [[34300,12,5,38],[69300,12,20,240],[17430,1,60,1749]]as const){
  const p=retailPackageScenario(net,months,{photoAdmissions:count,otherAiHoldCents:wallet,reserves});
  assertEquals(p.remainderCents,0);assertEquals(p.arithmeticallyFits,true);assertEquals(p.financiallyCertified,false);assertEquals(p.activated,false);
 }
 // Two full-context vision helpers at the actual1024 combined output ceiling
 // leave only7c for all seven nonAI reserves in a500c trial.
 assertEquals(trialPackageScenario(500,{photoAdmissions:5,otherAiHoldCents:317,reserves:zero}).remainderCents,7);
 assertEquals(trialPackageScenario(500,{photoAdmissions:5,otherAiHoldCents:317,reserves:{...zero,storage:8}}).arithmeticallyFits,false);
 assertEquals(trialPackageScenario(400,{photoAdmissions:5,otherAiHoldCents:0,reserves:{storage:4,retention:20,delivery:20,compute:23,email:1,support:100,uncertainty:56}}).remainderCents,0);
});
