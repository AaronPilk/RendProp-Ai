import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  forwardExactBody,
  gatewayOrigin,
  TransportError,
  uploadCapability,
  verifyCapability,
} from "./gateway_contract.ts";

const ID = "00000000-0000-4000-8000-000000000037",
  ORIGIN = "https://upload-fixture.invalid";
const SECRET = "synthetic-capability-fixture-not-a-production-secret";
for (const chunks of [[4], [1, 1, 1, 1], [0, 2, 0, 2], [3, 1]]) {
  Deno.test(`exact streaming accepts EOF for ${JSON.stringify(chunks)}`, async () => {
    let count = 0, closed = false;
    const input = new ReadableStream<Uint8Array>({
      start(c) {
        for (const n of chunks) c.enqueue(new Uint8Array(n));
        c.close();
      },
    });
    await forwardExactBody(
      input,
      new WritableStream({
        write(v) {
          count += v.length;
        },
        close() {
          closed = true;
        },
      }),
      4,
      new AbortController().signal,
    );
    assertEquals(count, 4);
    assert(closed);
  });
}
for (const chunks of [[5], [4, 1], [3, 2], [1], [], [4, 0, 1]]) {
  Deno.test(`invalid stream cannot commit expected-length prefix ${JSON.stringify(chunks)}`, async () => {
    let count = 0, closed = false, aborted = false;
    const input = new ReadableStream<Uint8Array>({
      start(c) {
        for (const n of chunks) c.enqueue(new Uint8Array(n));
        c.close();
      },
    });
    await assertRejects(
      () =>
        forwardExactBody(
          input,
          new WritableStream({
            write(v) {
              count += v.length;
            },
            close() {
              closed = true;
            },
            abort() {
              aborted = true;
            },
          }),
          4,
          new AbortController().signal,
        ),
      TransportError,
    );
    assert(
      count < 4,
      "An invalid stream released its commit-enabling last byte",
    );
    assertEquals(closed, false);
    assert(aborted);
  });
}
Deno.test("withholds final byte while EOF is still unknown", async () => {
  let source!: ReadableStreamDefaultController<Uint8Array>, count = 0;
  const body = new ReadableStream<Uint8Array>({
    start(c) {
      source = c;
      c.enqueue(new Uint8Array(4));
    },
  });
  const promise = forwardExactBody(
    body,
    new WritableStream({
      write(v) {
        count += v.length;
      },
    }),
    4,
    new AbortController().signal,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  assertEquals(count, 3);
  source.close();
  await promise;
  assertEquals(count, 4);
});
Deno.test("abort interrupts a body stalled at EOF without committing prefix", async () => {
  const controller = new AbortController();
  let count = 0;
  const promise = forwardExactBody(
    new ReadableStream({
      start(c) {
        c.enqueue(new Uint8Array(4));
      },
    }),
    new WritableStream({
      write(v) {
        count += v.length;
      },
    }),
    4,
    controller.signal,
  );
  await new Promise((resolve) => setTimeout(resolve, 0));
  controller.abort();
  await assertRejects(() => promise, TransportError);
  assert(count < 4);
});
Deno.test("capability binds exact origin, operation ID, PUT scope and expiry", async () => {
  const url = new URL(await uploadCapability(ORIGIN, SECRET, ID, 10000));
  assertEquals(await verifyCapability(url, ORIGIN, SECRET, 9999), ID);
  for (
    const mutate of [
      (u: URL) => u.hostname = "other.invalid",
      (u: URL) => u.pathname = u.pathname.replace(/37$/, "38"),
      (u: URL) => u.searchParams.set("expires", "10001"),
      (u: URL) => u.searchParams.append("expires", "10000"),
      (u: URL) => u.searchParams.set("signature", "0".repeat(64)),
      (u: URL) => u.searchParams.set("other", "1"),
    ]
  ) {
    const bad = new URL(url);
    mutate(bad);
    await assertRejects(() => verifyCapability(bad, ORIGIN, SECRET, 9999));
  }
  await assertRejects(() => verifyCapability(url, ORIGIN, SECRET, 10000));
});
Deno.test("gateway configuration is explicit, HTTPS and exact-allowlist only", () => {
  assertEquals(gatewayOrigin(ORIGIN, ORIGIN), ORIGIN);
  for (
    const [a, b] of [
      [undefined, undefined],
      [ORIGIN, undefined],
      [ORIGIN, "https://other.invalid"],
      ["http://upload-fixture.invalid", "http://upload-fixture.invalid"],
      [ORIGIN + "/", ORIGIN + "/"],
      [
        "https://u:p@upload-fixture.invalid",
        "https://u:p@upload-fixture.invalid",
      ],
    ]
  ) {
    let rejected = false;
    try {
      gatewayOrigin(a, b);
    } catch {
      rejected = true;
    }
    assert(rejected);
  }
});
