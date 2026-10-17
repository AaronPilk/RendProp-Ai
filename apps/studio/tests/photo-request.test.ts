import assert from "node:assert/strict";
import test from "node:test";
import {definitivePhotoRefusal} from "../src/features/creative/creative-request";
import {photoRequestScope} from "../src/features/creative/photo-request-journal";
import {StudioError} from "../src/data/config";
test("only definite no-dispatch/terminal refusal releases a saved photo operation",()=>{
 for(const error of[new Error("lost"),new StudioError("photo_quality_pending","saved",409),new StudioError("photo_quality_hold","uncertain",409),new StudioError("request-failed","access changed",403),new StudioError("request-failed","missing",404),new StudioError("request-failed","provider failed",503),new StudioError("request-failed","possibly paid",402,{provider_cost_incurred:"possible",no_provider_dispatch:true})])assert.equal(definitivePhotoRefusal(error),false);
 for(const error of[new StudioError("photo_quality_refused","refused",422),new StudioError("request-failed","quota before dispatch",402),new StudioError("request-failed","invalid before dispatch",400),new StudioError("request-failed","too large",413),new StudioError("request-failed","no dispatch",409,{no_provider_dispatch:true})])assert.equal(definitivePhotoRefusal(error),true);
});
test("photo recovery scope binds canonical actor/library/property without adopting another identity",()=>{
 const id=(n:number)=>`f8600000-0000-4000-8000-${String(n).padStart(12,"0")}`,scope={actor:id(1),library:id(2),listing:id(3)};
 assert.equal(photoRequestScope({...scope,actor:scope.actor.toUpperCase()}),photoRequestScope(scope));
 for(const key of["actor","library","listing"]as const)assert.notEqual(photoRequestScope({...scope,[key]:id(4)}),photoRequestScope(scope));
 assert.throws(()=>photoRequestScope({...scope,actor:""}));
});

test("only authoritative closed422 may release a paid HOLD; active/unknown and marker mismatches remain retained",()=>{
 for(const cost of[true,"possible",false])assert.equal(definitivePhotoRefusal(new StudioError("photo_quality_closed","Closed; another edit may use allowance",422,{operation_closed:true,provider_cost_incurred:cost})),true);
 for(const error of[
  new StudioError("photo_quality_closed","Wrong status",409,{operation_closed:true}),
  new StudioError("photo_quality_closed","Missing marker",422),
  new StudioError("photo_quality_closed","Not closed",422,{operation_closed:false,no_provider_dispatch:true}),
  new StudioError("photo_quality_hold","Still checking",409,{operation_closed:true,provider_cost_incurred:"possible"}),
  new StudioError("photo_quality_pending","Still pending",409,{provider_cost_incurred:true}),
  new StudioError("request-failed","Unknown network",503,{operation_closed:true}),
 ])assert.equal(definitivePhotoRefusal(error),false);
});
