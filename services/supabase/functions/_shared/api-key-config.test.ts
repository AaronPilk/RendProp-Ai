import { assertEquals, assertThrows } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { runtimeApiKey, serviceKeyMatches } from "./api-key-config.ts";
import { HttpError } from "./http.ts";
const secret="sb_secret_"+"s".repeat(32),publishable="sb_publishable_"+"p".repeat(32),legacy="synthetic-legacy-service";
Deno.test("runtime selects independently revocable named keys over legacy",()=>{
  assertEquals(runtimeApiKey(JSON.stringify({default:secret}),"default","secret",legacy),secret);
  assertEquals(runtimeApiKey(JSON.stringify({default:publishable}),"default","publishable","legacy-anon"),publishable);
  assertEquals(runtimeApiKey(JSON.stringify({worker:secret}),"worker","secret",legacy),secret);
  assertEquals(runtimeApiKey(undefined,"default","secret",legacy),legacy);
});
Deno.test("malformed or wrong-role injected dictionaries cannot fall back to legacy",()=>{
  for(const value of ["", "[]", "null", "{}", '{"other":"'+secret+'"}', JSON.stringify({default:publishable}),JSON.stringify({default:"secret-in-error-must-not-appear"})]){
    const error=assertThrows(()=>runtimeApiKey(value,"default","secret",legacy),HttpError);
    assertEquals(error.status,503);assertEquals(error.message.includes("secret-in-error"),false);
  }
});
Deno.test("modern service access requires exact apikey, with explicit legacy bridge only",()=>{
  const req=(headers:Record<string,string>)=>new Request("https://fixture.invalid",{headers});
  assertEquals(serviceKeyMatches(req({apikey:secret}),secret,legacy,undefined),true);
  const refused:Record<string,string>[]=[{apikey:publishable},{apikey:secret+"x"},{authorization:"Bearer "+secret},{authorization:"Bearer "+legacy},{authorization:"Bearer synthetic-user-jwt"}];
  for(const headers of refused)
    assertEquals(serviceKeyMatches(req(headers),secret,legacy,undefined),false);
  assertEquals(serviceKeyMatches(req({authorization:"Bearer "+legacy}),secret,legacy,"enabled"),true);
  assertEquals(serviceKeyMatches(req({authorization:"Bearer "+legacy}),secret,legacy,"disabled"),false);
  assertEquals(serviceKeyMatches(req({authorization:"Bearer "+legacy}),legacy,legacy,undefined),true);
});
