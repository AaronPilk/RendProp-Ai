import { assertEquals, assertRejects, assertNotEquals, assertMatch } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { createListingRow, draftListingID } from "./create.ts";
const user = "11111111-1111-4111-8111-111111111111", org = "22222222-2222-4222-8222-222222222222", local = "33333333-3333-4333-8333-333333333333", other = "44444444-4444-4444-8444-444444444444";
const key = `listing-create:${local}`;
function fixture(returningDenied = false) {
  const rows = new Map<string, any>(); let inserts = 0, selects = 0, representations = 0;
  const db = {from(table: string) {
    assertEquals(table, "listings");
    return {insert(row: any) { inserts++; const write = (representation: boolean) => {
      if (representation) { representations++; if (returningDenied) return {data:null,error:{code:"42501"}}; }
      const id = row.id ?? crypto.randomUUID();
      if (rows.has(id)) return {data:null,error:{code:"23505"}};
      const saved = {...row,id,deleted_at:null}; rows.set(id,saved); return {data:representation?saved:null,error:null};
    }; return {then(resolve:any,reject:any) {return Promise.resolve(write(false)).then(resolve,reject);},select:()=>({single:async()=>write(true)})}; }, select() {
      selects++; const filters: Record<string, unknown> = {};
      const q = {eq(k:string,v:unknown) {filters[k]=v;return q;},is(k:string,v:unknown) {filters[k]=v;return q;},async maybeSingle() {
        return {data:[...rows.values()].find(row=>Object.entries(filters).every(([k,v])=>row[k]===v))??null,error:null};
      }}; return q;
    }};
  }};
  return {db,rows,counts:()=>({inserts,selects}),representations:()=>representations};
}
Deno.test("create uses no RETURNING and reads its new exact scoped row in a fresh statement",async()=>{
  for(const requestKey of[key,null]){
    const f=fixture(true),result=await createListingRow(f.db,{address:"Synthetic draft",id:other},user,org,requestKey);
    assertEquals(result.replayed,false);assertEquals(result.data.agent_id,user);assertEquals(result.data.org_id,org);
    assertNotEquals(result.data.id,other);assertEquals(f.representations(),0);assertEquals(f.counts(),{inserts:1,selects:1});
  }
});
Deno.test("draft IDs are stable, caller/workspace bound, and distinct for identical-looking drafts", async()=>{
  const id = await draftListingID(key,user,org);
  assertMatch(id!,/^[a-f0-9-]{14}8[a-f0-9-]{21}$/);
  assertEquals(await draftListingID(key.toUpperCase().replace("LISTING-CREATE:","listing-create:"),user,org),id);
  assertNotEquals(await draftListingID(key,other,org),id);
  assertNotEquals(await draftListingID(key,user,other),id);
  assertNotEquals(await draftListingID(`listing-create:${other}`,user,org),id);
  await assertRejects(()=>draftListingID("listing-create:bad",user,org));
  await assertRejects(()=>draftListingID(key+" ",user,org));
  assertEquals(await draftListingID(null,user,org),null);
  assertEquals(await draftListingID("legacy-derived-key",user,org),null);
});
Deno.test("lost create reply and simultaneous retry yield one row without overwriting office edits",async()=>{
  const f=fixture();
  const [first,second] = await Promise.all([createListingRow(f.db,{address:"Phone draft"},user,org,key),createListingRow(f.db,{address:"Phone draft"},user,org,key)]);
  assertEquals(first.data.id,second.data.id); assertEquals(f.rows.size,1);
  f.rows.get(first.data.id).address="Office edit";
  const again=await createListingRow(f.db,{address:"Old retry"},user,org,key);
  assertEquals(again.replayed,true); assertEquals(again.data.address,"Office edit");
  assertEquals(f.counts(),{inserts:3,selects:3});
});
Deno.test("replay never revives a deleted row or crosses ownership",async()=>{
  const f=fixture(); const result=await createListingRow(f.db,{address:"Draft"},user,org,key);
  f.rows.get(result.data.id).deleted_at="2026-09-14T00:00:00Z";
  await assertRejects(()=>createListingRow(f.db,{address:"Retry"},user,org,key),Error,"deleted");
  f.rows.get(result.data.id).deleted_at=null; f.rows.get(result.data.id).agent_id=other;
  await assertRejects(()=>createListingRow(f.db,{address:"Retry"},user,org,key),Error,"no longer");
  assertEquals(f.rows.size,1);
});
Deno.test("legacy no-key creates remain separate",async()=>{
  const f=fixture(); await createListingRow(f.db,{address:"Same"},user,org,null); await createListingRow(f.db,{address:"Same"},user,org,null);
  assertEquals(f.rows.size,2);assertEquals(f.counts().selects,2);
});
