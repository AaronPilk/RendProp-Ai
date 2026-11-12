import assert from "node:assert/strict";
import {getEventListeners} from "node:events";
import {test} from "node:test";
import {awaitMediaOperation} from "../src/editor/media";

const rejectionTurn=()=>new Promise<void>(resolve=>setImmediate(resolve));
async function observeUnhandled(action:()=>Promise<void>):Promise<void>{
  const unhandled:unknown[]=[];
  const listener=(reason:unknown)=>{unhandled.push(reason);};
  process.on("unhandledRejection",listener);
  try{await action();await rejectionTurn();assert.deepEqual(unhandled,[]);}
  finally{process.removeListener("unhandledRejection",listener);}
}

test("pre-aborted wrapper observes an already-started rejection while preserving synchronous cancellation",async()=>{
  await observeUnhandled(async()=>{
    const controller=new AbortController(),cancelled=new Error("Owner cancelled"),nativeFailure=new Error("Native late failure");
    controller.abort(cancelled);
    const started=Promise.reject(nativeFailure);
    assert.throws(()=>awaitMediaOperation(started,controller.signal,"Native operation"),error=>error===cancelled);
    assert.equal(getEventListeners(controller.signal,"abort").length,0);
  });
});
test("pre-aborted fulfilled work still throws cancellation and non-Error reasons retain AbortError",async()=>{
  const controller=new AbortController();controller.abort("Stop requested");
  assert.throws(()=>awaitMediaOperation(Promise.resolve(42),controller.signal,"Native operation"),
    error=>error instanceof DOMException && error.name==="AbortError");
  assert.equal(getEventListeners(controller.signal,"abort").length,0);
});
test("normal fulfillment and rejection preserve their native values and remove the abort listener",async()=>{
  const controller=new AbortController();
  assert.equal(await awaitMediaOperation(Promise.resolve(42),controller.signal,"Native operation"),42);
  assert.equal(getEventListeners(controller.signal,"abort").length,0);
  const nativeFailure=new Error("Decoder refused");
  await assert.rejects(awaitMediaOperation(Promise.reject(nativeFailure),controller.signal,"Native operation"),
    error=>error===nativeFailure);
  assert.equal(getEventListeners(controller.signal,"abort").length,0);
});
for(const outcome of ["resolve","reject"] as const){
  test(`cancellation wins and a later native ${outcome} is consumed`,async()=>{
    await observeUnhandled(async()=>{
      const controller=new AbortController(),cancelled=new Error("Owner cancelled");
      let resolve!:(value:number)=>void,reject!:(reason:unknown)=>void;
      const started=new Promise<number>((a,b)=>{resolve=a;reject=b;});
      const result=awaitMediaOperation(started,controller.signal,"Native operation");
      const refused=assert.rejects(result,error=>error===cancelled);
      controller.abort(cancelled);await refused;
      assert.equal(getEventListeners(controller.signal,"abort").length,0);
      if(outcome==="resolve")resolve(42);else reject(new Error("Native late failure"));
      await rejectionTurn();
      await assert.rejects(result,error=>error===cancelled);
    });
  });
}
