// Which accepted replies start the video controller at once instead of at its
// next cron minute. The production handler line runs unchanged; only the
// router and the wake are replaced, so no job, database or network is touched.
import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { pathSegments } from "../_shared/http.ts";

const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
const found = /^export async function handler\(req:Request\):Promise<Response>\{(.*)\}$/m.exec(source);
assert(found, "production handler anchor missing");
const build = new Function("route", "pathSegments", "wakePropertyVideoRender", `return async function handler(req){${found[1]}}`) as (
  route: (req: Request) => Promise<Response>,
  segments: typeof pathSegments,
  wake: () => Promise<boolean>,
) => (req: Request) => Promise<Response>;
const job = "f5000000-0000-4000-8000-000000000005";
async function wakes(method: string, path: string, status: number, wake?: () => Promise<boolean>) {
  let woke = 0;
  const handler = build(async () => new Response("{}", { status }), pathSegments, wake ?? (() => { woke++; return Promise.resolve(true); }));
  const reply = await handler(new Request("https://edge.fixture.invalid/functions/v1/property-video-jobs" + (path ? "/" + path : ""), { method }));
  assertEquals(reply.status, status, "the wake never changes the reply");
  return woke;
}

Deno.test("an accepted new or resumed video wakes the controller once", async () => {
  assertEquals(await wakes("POST", "", 202), 1);
  assertEquals(await wakes("POST", "", 200), 1);
  assertEquals(await wakes("POST", job + "/resume", 200), 1);
});

Deno.test("a queued photo preparation wakes the controller on both prepare routes", async () => {
  // Studio prepares through sources/prepare, the iOS app through sources/prepare-chosen.
  assertEquals(await wakes("POST", "sources/prepare", 202), 1);
  assertEquals(await wakes("POST", "sources/prepare-chosen", 202), 1);
});

Deno.test("nothing else wakes the controller", async () => {
  for (const [method, path, status] of [
    ["POST", "", 409], ["POST", "", 403], ["GET", "", 200],
    ["POST", job + "/resume", 409],
    // A preparation that is already ready has no work to start; a refused one has none either.
    ["POST", "sources/prepare", 200], ["POST", "sources/prepare", 409],
    ["POST", "sources/prepare-chosen", 200], ["POST", "sources/prepare-chosen", 409],
    // Reading a preparation, and every other accepted POST, starts no controller work.
    ["GET", "sources/prepare-chosen", 200], ["GET", "sources/prepare/" + job, 200],
    ["POST", "audio/prepare", 202], ["POST", "cancel-all", 200], ["POST", "operations/" + job + "/abandon", 200],
  ] as const) {
    assertEquals(await wakes(method, path, status), 0, `${method} /${path} ${status}`);
  }
});

Deno.test("a wake that throws cannot change the accepted reply", async () => {
  assertEquals(await wakes("POST", "sources/prepare", 202, () => { throw new Error("controller unreachable"); }), 0);
});
