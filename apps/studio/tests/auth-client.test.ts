import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { createStudioAuth } from "../src/data/auth-client.ts";

const config = { supabaseUrl: "https://auth-fixture.supabase.co", publishableKey: "sb_publishable_ISOLATED_FIXTURE_NOT_REAL", redirectTo: "https://studio.rendprop.com/" };
const storageKey = "rendprop-studio-auth:auth-fixture.supabase.co";
const actor = "11111111-1111-4111-8111-111111111111";
function memory(): Storage {
  const values = new Map<string, string>();
  return { get length() { return values.size; }, clear: () => values.clear(), getItem: key => values.get(key) ?? null,
    setItem: (key, value) => { values.set(key, value); }, removeItem: key => { values.delete(key); }, key: n => [...values.keys()][n] ?? null };
}
function session(suffix: string) {
  const expires_at = Math.floor(Date.now() / 1000) + 3600;
  const part = (data: unknown) => Buffer.from(JSON.stringify(data)).toString("base64url");
  return { access_token: `${part({alg:"HS256",typ:"JWT"})}.${part({sub:actor,exp:expires_at})}.${suffix}`, refresh_token: `fixture-refresh-${suffix}`,
    expires_at, expires_in: 3600, token_type:"bearer", user:{id:actor,aud:"authenticated",email:"fixture@example.invalid",app_metadata:{},user_metadata:{},created_at:"2026-09-24T00:00:00Z"} };
}

test("official Auth-only SDK restores the existing Studio session key without a request", async () => {
  const storage=memory(), original=session("old");storage.setItem(storageKey,JSON.stringify(original));
  let requests=0;const auth=createStudioAuth(config,storage,async()=>{requests++;throw new Error("Unexpected network request");});
  try {
    const restored=await auth.getSession();assert.equal(restored.error,null);assert.equal(restored.data.session?.user.id,actor);
    assert.equal(restored.data.session?.access_token,original.access_token);assert.equal(requests,0);
  } finally { await auth.stopAutoRefresh(); }
});

test("Apple OAuth retains Studio redirect and PKCE S256 verifier storage", async () => {
  const storage=memory();const auth=createStudioAuth(config,storage,async()=>{throw new Error("OAuth URL creation must not call a provider");});
  try {
    const result=await auth.signInWithOAuth({provider:"apple",options:{redirectTo:config.redirectTo,skipBrowserRedirect:true}});
    assert.equal(result.error,null);const url=new URL(result.data.url!);
    assert.equal(url.origin,config.supabaseUrl);assert.equal(url.pathname,"/auth/v1/authorize");
    assert.equal(url.searchParams.get("provider"),"apple");assert.equal(url.searchParams.get("redirect_to"),config.redirectTo);
    assert.equal(url.searchParams.get("code_challenge_method"),"s256");
    const verifier=JSON.parse(storage.getItem(`${storageKey}-code-verifier`)!);
    assert.equal(typeof verifier,"string");assert(verifier.length>=43);
    assert.equal(url.searchParams.get("code_challenge"),createHash("sha256").update(verifier).digest("base64url"));
  } finally { await auth.stopAutoRefresh(); }
});

test("PKCE exchange, refresh and local logout use the same auth endpoint and preserve session ownership", async () => {
  const storage=memory(),calls:{url:URL;headers:Headers;body:unknown}[]=[];const original=session("exchanged"),renewed=session("renewed");
  storage.setItem(`${storageKey}-code-verifier`,JSON.stringify("a".repeat(64)));
  const auth=createStudioAuth(config,storage,async(input,init)=>{
    const url=new URL(String(input));calls.push({url,headers:new Headers(init?.headers),body:init?.body?JSON.parse(String(init.body)):null});
    if(url.pathname==="/auth/v1/token")return Response.json(url.searchParams.get("grant_type")==="pkce"?original:renewed);
    if(url.pathname==="/auth/v1/logout")return new Response(null,{status:204});
    throw new Error(`Unexpected auth path: ${url.pathname}`);
  });
  try {
    const exchanged=await auth.exchangeCodeForSession("fixture-code");assert.equal(exchanged.error,null);assert.equal(exchanged.data.session?.user.id,actor);
    assert.deepEqual(calls[0].body,{auth_code:"fixture-code",code_verifier:"a".repeat(64)});
    assert.equal(calls[0].headers.get("apikey"),config.publishableKey);assert.equal(calls[0].url.searchParams.get("grant_type"),"pkce");
    assert.equal(storage.getItem(`${storageKey}-code-verifier`),null);
    const refresh=await auth.refreshSession();assert.equal(refresh.error,null);assert.equal(refresh.data.session?.access_token,renewed.access_token);
    assert.equal(calls[1].url.searchParams.get("grant_type"),"refresh_token");
    assert.equal(JSON.parse(storage.getItem(storageKey)!).access_token,renewed.access_token);
    assert.equal((await auth.signOut({scope:"local"})).error,null);
    assert.equal(calls[2].url.searchParams.get("scope"),"local");assert.equal(calls[2].headers.get("authorization"),`Bearer ${renewed.access_token}`);
    assert.equal(storage.getItem(storageKey),null);assert.equal(calls.length,3);
  } finally { await auth.stopAutoRefresh(); }
});
