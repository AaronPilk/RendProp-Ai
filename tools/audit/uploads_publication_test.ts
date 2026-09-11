import {
  assert,
  assertEquals,
  assertRejects,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  fixture,
  latch,
  object,
  PARTS,
  type Row,
  TICKET,
} from "./upload_route_fixture.ts";

// Deno 2.9 lazily exposes serve through an accessor; older runtimes use a data
// property. Exercise both shapes even on a runtime that supplies only one.
for (const shape of ["data", "accessor"] as const) {
  for (const failure of [false, true]) {
    Deno.test(`actual route fixture restores ${shape} descriptor after ${failure ? "failure" : "success"}`, async () => {
      const native = Object.getOwnPropertyDescriptor(Deno, "serve")!;
      const originalFetch = globalThis.fetch;
      const nativeServe = Deno.serve;
      const supplied: PropertyDescriptor = shape === "accessor"
        ? {
          configurable: true,
          enumerable: native.enumerable,
          get: () => nativeServe,
          set: () => {
            throw new Error(
              "Fixture must replace the property, not invoke its setter",
            );
          },
        }
        : {
          configurable: true,
          enumerable: native.enumerable,
          writable: false,
          value: nativeServe,
        };
      try {
        Object.defineProperty(Deno, "serve", supplied);
        const run = () =>
          fixture(async (f) => {
            const winner = await f.ok();
            assertEquals(f.asset!.uploaded, true);
            assertEquals(
              f.objects.get(String(winner.storage_key))?.body,
              "AAAA",
            );
            if (failure) throw new Error("synthetic scenario failure");
          });
        if (failure) {
          await assertRejects(run, Error, "synthetic scenario failure");
        } else await run();
        assertEquals(Object.getOwnPropertyDescriptor(Deno, "serve"), supplied);
        assertEquals(globalThis.fetch, originalFetch);
      } finally {
        Object.defineProperty(Deno, "serve", native);
        globalThis.fetch = originalFetch;
      }
    });
  }
}

Deno.test("complete first: stale abort loses without deleting/resetting winner", () =>
  fixture(async (f) => {
    const waiting = latch(), release = latch();
    f.beforePatch = async (patch) => {
      if (patch.upload_aborted) {
        waiting.resolve();
        await release.promise;
      }
    };
    const abort = f.request("abort");
    await waiting.promise;
    const winner = await f.ok();
    release.resolve();
    assertEquals((await abort).status, 409);
    assertEquals(f.asset!.uploaded, true);
    assertEquals(f.asset!.upload_aborted, false);
    assertEquals(f.objects.get(String(winner.storage_key))?.body, "AAAA");
    assertEquals(f.deletes.includes(String(winner.storage_key)), false);
  }));

Deno.test("ticket refuses transport when no gateway is configured", () =>
  fixture(async (f) => {
    Deno.env.delete("UPLOAD_GATEWAY_ORIGIN");
    Deno.env.delete("UPLOAD_GATEWAY_ALLOWED_ORIGIN");
    const response = await f.request("ticket", {
      listing_id: "fixture-listing",
      filename: "fixture.mov",
      bytes: 4,
    });
    assertEquals(
      response.status,
      503,
      "Missing gateway must never fall back to a reusable R2 PUT URL",
    );
    assertEquals(
      f.charges.length,
      0,
      "Configuration refusal must precede any reservation",
    );
  }));

Deno.test("abort first: delayed copy cannot publish and cleans only its candidate", () =>
  fixture(async (f) => {
    const waiting = latch(), release = latch();
    f.beforeCopy = async () => {
      waiting.resolve();
      await release.promise;
    };
    const complete = f.request("complete");
    await waiting.promise;
    await f.ok("abort");
    release.resolve();
    assertEquals((await complete).status, 409);
    assertEquals(f.asset!.uploaded, false);
    assertEquals(f.asset!.upload_aborted, true);
    assert(f.cleanup.size > 0, "Late copy must remain registered for cleanup");
    assertEquals((await f.sweep()).status, 200);
    assertEquals(f.objects.size, 0);
  }));

Deno.test("stale mismatch loses to completion without erasing winner", () =>
  fixture(async (f) => {
    const waiting = latch(), release = latch();
    f.objects.set(`_staging/${TICKET}`, object("bad", 5));
    let first = true;
    f.afterHead = async () => {
      if (first) {
        first = false;
        waiting.resolve();
        await release.promise;
      }
    };
    const mismatch = f.request("complete");
    await waiting.promise;
    f.objects.set(`_staging/${TICKET}`, object());
    const winner = await f.ok();
    release.resolve();
    const response = await mismatch;
    assertEquals(response.status, 200);
    assertEquals((await response.json()).storage_key, winner.storage_key);
    assertEquals(f.objects.get(String(winner.storage_key))?.body, "AAAA");
    assertEquals(f.asset!.upload_aborted, false);
  }));

Deno.test("mismatch first fences a delayed valid snapshot from publication", () =>
  fixture(async (f) => {
    const waiting = latch(), release = latch();
    f.beforeCopy = async () => {
      waiting.resolve();
      await release.promise;
    };
    const good = f.request("complete");
    await waiting.promise;
    f.objects.set(`_staging/${TICKET}`, object("bad", 5));
    assertEquals((await f.request("complete")).status, 400);
    release.resolve();
    assertEquals((await good).status, 409);
    assertEquals(f.asset!.uploaded, false);
    assertEquals(f.asset!.upload_aborted, true);
    assert(f.cleanup.size > 0);
    assertEquals((await f.sweep()).status, 200);
    assertEquals(f.objects.size, 0);
  }));

Deno.test("ambiguous DB commit error preserves potential winner; replay returns it", () =>
  fixture(async (f) => {
    f.loseCommitResponse = true;
    assertEquals((await f.request("complete")).status, 503);
    const key = String(f.asset!.storage_key);
    assertEquals(f.asset!.uploaded, true);
    assertEquals(f.objects.get(key)?.body, "AAAA");
    assertEquals(f.deletes.includes(key), false);
    assertEquals((await f.ok()).storage_key, key);
    assertEquals(f.copies.length, 1);
  }));

Deno.test("completed replay cannot promote a new same-size staging object", () =>
  fixture(async (f) => {
    const winner = await f.ok();
    f.objects.set(`_staging/${TICKET}`, object("BBBB"));
    assertEquals((await f.ok()).storage_key, winner.storage_key);
    assertEquals(f.objects.get(String(winner.storage_key))?.body, "AAAA");
    assertEquals(f.copies.length, 1);
  }));

Deno.test("same bytes and ETag cannot swap the verified Content-Type during copy", () =>
  fixture(async (f) => {
    const key = "renders/org/listing/gallery-asset.jpg",
      staged = `_staging/${key}`;
    Object.assign(f.asset!, {
      storage_key: key,
      bucket: "renders",
      kind: "photo",
      content_type: "image/jpeg",
    });
    f.objects.clear();
    f.objects.set(staged, object("AAAA", 4, "image/jpeg"));
    let swaps = 0;
    f.afterHead = async (observedKey, snapshot) => {
      if (observedKey !== staged || swaps !== 0) return;
      assertEquals(snapshot?.type, "image/jpeg");
      const replacement = object("AAAA", 4, "text/html");
      assertEquals(replacement.etag, snapshot?.etag);
      assertEquals(replacement.body, snapshot?.body);
      f.objects.set(staged, replacement);
      swaps++;
    };
    const row = await f.ok();
    assertEquals(swaps, 1);
    assertEquals(row.content_type, "image/jpeg");
    assertEquals(f.objects.get(String(row.storage_key))?.body, "AAAA");
    assertEquals(
      f.objects.get(String(row.storage_key))?.type,
      row.content_type,
      "Published storage metadata must match the verified DB type, not the replacement source type",
    );
    const headers = f.copyHeaders[0];
    assertEquals(headers.get("x-amz-metadata-directive"), "REPLACE");
    assertEquals(headers.get("content-type"), "image/jpeg");
    const signed =
      /SignedHeaders=([^, ]+)/.exec(headers.get("authorization") ?? "")?.[1]
        .split(";") ?? [];
    for (
      const name of [
        "content-type",
        "x-amz-metadata-directive",
        "x-amz-copy-source-if-match",
      ]
    ) {
      assert(
        signed.includes(name),
        `${name} must be protected by actual aws4fetch header signing`,
      );
    }
  }));

Deno.test("copy helper omission keeps existing COPY metadata behavior", () =>
  fixture(async (f) => {
    const { copyObject } = await import(
      "../../services/supabase/functions/_shared/r2.ts"
    );
    await copyObject(
      "rendprop-uploads",
      `_staging/${TICKET}`,
      "fixture-copy.mov",
      '"AAAA"',
    );
    assertEquals(f.objects.get("fixture-copy.mov")?.type, "video/quicktime");
    assertEquals(f.copyHeaders[0].get("x-amz-metadata-directive"), null);
    assertEquals(f.copyHeaders[0].get("content-type"), null);
  }));

Deno.test("copy helper rejects noncanonical replacement types before storage dispatch", () =>
  fixture(async (f) => {
    const { copyObject } = await import(
      "../../services/supabase/functions/_shared/r2.ts"
    );
    for (
      const value of [
        "",
        " image/jpeg",
        "IMAGE/JPEG",
        "image/jpeg; charset=utf-8",
        "image/jpeg\r\nx-injected: true",
        `image/${"a".repeat(128)}`,
        null,
        42,
      ]
    ) {
      await assertRejects(
        () =>
          copyObject(
            "rendprop-uploads",
            `_staging/${TICKET}`,
            "fixture-copy.mov",
            '"AAAA"',
            value as string,
          ),
        Error,
        "Invalid verified copy content-type",
      );
    }
    assertEquals(f.copies, []);
  }));

Deno.test("publication installs the allowlisted observed base type without parameters", () =>
  fixture(async (f) => {
    Object.assign(f.asset!, { kind: "photo", content_type: "image/jpeg" });
    f.objects.set(
      `_staging/${TICKET}`,
      object("AAAA", 4, "IMAGE/JPEG; charset=utf-8"),
    );
    const row = await f.ok();
    assertEquals(row.content_type, "image/jpeg");
    assertEquals(f.objects.get(String(row.storage_key))?.type, "image/jpeg");
  }));

Deno.test("publication uses observed allowed type when the ticket type was only a server guess", () =>
  fixture(async (f) => {
    Object.assign(f.asset!, {
      content_type: "video/mp4",
      content_type_declared: false,
    });
    const row = await f.ok();
    assertEquals(row.content_type, "video/quicktime");
    assertEquals(
      f.objects.get(String(row.storage_key))?.type,
      "video/quicktime",
    );
  }));

Deno.test("multipart freezes parts before assembly and rejects competing same-size manifest", () =>
  fixture(async (f) => {
    f.multipart();
    const waiting = latch(), release = latch();
    f.beforeAssembly = async () => {
      waiting.resolve();
      await release.promise;
    };
    const first = f.request("complete", { parts: PARTS });
    await waiting.promise;
    assertEquals(f.asset!.completion_parts, PARTS);
    assertEquals(
      (await f.request("complete", { parts: [{ number: 1, etag: "BBBB" }] }))
        .status,
      409,
    );
    release.resolve();
    assertEquals((await first).status, 200);
    assertEquals(f.assemblies.length, 1);
    assertEquals(f.copies.length, 0);
    assertEquals(f.objects.get(TICKET)?.body, "AAAA");
  }));

Deno.test("multipart same manifest concurrent replay can only publish the same bytes", () =>
  fixture(async (f) => {
    f.multipart();
    const [a, b] = await Promise.all([
      f.request("complete", { parts: PARTS }),
      f.request("complete", { parts: PARTS }),
    ]);
    assertEquals([a.status, b.status].sort(), [200, 503]);
    const winner = a.status === 200 ? await a.json() : await b.json();
    assertEquals(
      (await f.ok("complete", { parts: PARTS })).storage_key,
      winner.storage_key,
    );
    assertEquals(
      f.assemblies.length,
      1,
      "A concurrent completion must not dispatch a second assembly",
    );
    assert(f.assemblies.every((body) => !body.includes("BBBB")));
    assertEquals(f.objects.get(TICKET)?.body, "AAAA");
  }));

Deno.test("multipart recovery HEAD accepts only its frozen parts, not caller replacement ETags", () =>
  fixture(async (f) => {
    f.multipart();
    f.asset!.completion_parts = PARTS;
    f.objects.set(TICKET, object());
    Object.assign(f.operation("assemble"), {
      state: "uncertain",
      claim: "fixture-lost-assembly",
    });
    assertEquals(
      (await f.request("complete", { parts: [{ number: 1, etag: "BBBB" }] }))
        .status,
      409,
    );
    assertEquals(
      (await f.ok("complete", { parts: PARTS })).storage_key,
      TICKET,
    );
    assertEquals(f.assemblies.length, 0);
    assertEquals(f.copies.length, 0);
  }));

Deno.test("legacy unbound multipart assembly cannot adopt a new caller manifest", () =>
  fixture(async (f) => {
    f.multipart();
    f.objects.set(TICKET, object("BBBB"));
    f.asset!.transport_version = 1;
    for (const etag of ["AAAA", "BBBB"]) {
      const response = await f.request("complete", {
        parts: [{ number: 1, etag }],
      });
      assertEquals(response.status, 409);
      assert((await response.text()).includes("Legacy upload"));
      assertEquals(f.asset!.completion_parts, null);
      assertEquals(f.asset!.uploaded, false);
    }
    assertEquals(f.assemblies.length, 0);
    assertEquals(f.copies.length, 0);
    assertEquals(f.objects.get(TICKET)?.body, "BBBB");
  }));

Deno.test("legacy unbound assembly can be explicitly aborted and cannot later publish", () =>
  fixture(async (f) => {
    f.multipart();
    f.objects.set(TICKET, object());
    f.asset!.transport_version = 1;
    await f.ok("abort");
    assertEquals(f.asset!.upload_aborted, true);
    assertEquals((await f.sweep()).status, 200);
    assertEquals(f.objects.has(TICKET), false);
    assertEquals((await f.request("complete", { parts: PARTS })).status, 409);
  }));

Deno.test("12 GiB multipart metadata fixture completes in place without buffer/copy", () =>
  fixture(async (f) => {
    // Import only inside the fixture, after its fake env is installed: this real
    // helper module also captures R2 configuration when it is first evaluated.
    const { choosePartSize } = await import(
      "../../services/supabase/functions/_shared/r2.ts"
    );
    const bytes = 12 * 1024 ** 3;
    f.multipart(bytes);
    const partSize = choosePartSize(bytes), count = Math.ceil(bytes / partSize);
    assertEquals(partSize, 32 * 1024 ** 2);
    assertEquals(count, 384);
    f.asset!.part_size = partSize;
    f.asset!.parts_total = count;
    const parts = Array.from(
      { length: count },
      (_, index) => ({ number: index + 1, etag: `part-${index + 1}` }),
    );
    const row = await f.ok("complete", { parts });
    assertEquals(row.bytes, bytes);
    assertEquals(row.storage_key, TICKET);
    assertEquals(f.copies.length, 0);
    assertEquals(f.charges.length, 0);
    assertEquals((f.assemblies[0].match(/<Part>/g) ?? []).length, 384);
  }));

Deno.test("abort during multipart assembly fences late object and completer cleans it", () =>
  fixture(async (f) => {
    f.multipart();
    const waiting = latch(), release = latch();
    f.beforeAssembly = async () => {
      waiting.resolve();
      await release.promise;
    };
    const complete = f.request("complete", { parts: PARTS });
    await waiting.promise;
    await f.ok("abort");
    release.resolve();
    assertEquals((await complete).status, 409);
    assertEquals(f.asset!.uploaded, false);
    assertEquals((await f.sweep()).status, 200);
    assertEquals(f.objects.has(TICKET), false);
  }));

Deno.test("failed multipart abort cleanup can retry with the retained session ID", () =>
  fixture(async (f) => {
    f.multipart();
    f.failAbort = true;
    const receipt = await f.ok("abort");
    assertEquals(receipt.cleanup_pending, true);
    assertEquals((await f.sweep()).status, 503);
    assertEquals(f.asset!.upload_aborted, true);
    assertEquals(f.asset!.upload_id, "fixture-upload");
    f.failAbort = false;
    await f.ok("abort");
    assertEquals((await f.sweep()).status, 200);
    assertEquals(f.abortedSessions, 2);
    assertEquals((await f.request("part-urls", { numbers: [1] })).status, 409);
    assertEquals((await f.request("complete", { parts: PARTS })).status, 409);
  }));

Deno.test("completed multipart abort refuses without deleting its object", () =>
  fixture(async (f) => {
    f.multipart();
    await f.ok("complete", { parts: PARTS });
    assertEquals((await f.request("abort")).status, 409);
    assertEquals(f.objects.get(TICKET)?.body, "AAAA");
    assertEquals(f.deletes, []);
  }));

Deno.test("copy failure cannot publish or delete the ticket/final of another attempt", () =>
  fixture(async (f) => {
    f.failCopy = true;
    assertEquals((await f.request("complete")).status, 502);
    assertEquals(f.asset!.uploaded, false);
    assertEquals(f.deletes, []);
    assertEquals(f.objects.has(`_staging/${TICKET}`), true);
    const attempt = [...f.operations.values()].find((op) =>
      op.kind === "copy"
    )!;
    assertEquals(attempt.state, "uncertain");
    await f.ok("abort");
    assertEquals((await f.sweep()).status, 200);
    assert(f.deletes.includes(String(attempt.object_key)));
  }));

Deno.test("ticket budget still charges exactly once and completion adds no charge", () =>
  fixture(async (f) => {
    f.asset = null;
    f.objects.clear();
    const response = await f.request("ticket", {
      listing_id: "fixture-listing",
      filename: "capture.mov",
      bytes: 4,
      kind: "video",
      content_type: "video/quicktime",
    });
    assertEquals(response.status, 201, await response.clone().text());
    const ticket = await response.json();
    assertEquals(f.charges.length, 1); // one atomic reservation, no separate/refundable counters
    assertEquals((f.charges[0].p_assets as Row[])[0].bytes, 4);
    // Route lookup stays by the fixture id, but its row uses the minted id for CAS.
    f.objects.set(`_staging/${ticket.storage_key}`, object());
    const result = await f.request("complete");
    assertEquals(result.status, 200, await result.clone().text());
    assertEquals(f.charges.length, 1);
    assert(String((await result.json()).storage_key) !== ticket.storage_key);
  }));

for (
  const sample of [
    {
      name: "capture photo",
      key: "uploads/org/listing/asset.jpg",
      bucket: "uploads",
      kind: "photo",
      type: "image/jpeg",
      bytes: 4,
    },
    {
      name: "public original above poster ceiling",
      key: "renders/org/listing/original-asset.jpg",
      bucket: "renders",
      kind: "photo",
      type: "image/jpeg",
      bytes: 11 * 1024 ** 2,
    },
    {
      name: "public gallery photo",
      key: "renders/org/listing/gallery-asset.jpg",
      bucket: "renders",
      kind: "photo",
      type: "image/jpeg",
      bytes: 4,
    },
    {
      name: "app-rendered video",
      key: "renders/org/listing/asset.mp4",
      bucket: "renders",
      kind: "video",
      type: "video/mp4",
      bytes: 4,
    },
  ]
) {
  Deno.test(`single publication preserves ${sample.name} consumer key contract`, () =>
    fixture(async (f) => {
      Object.assign(f.asset!, {
        storage_key: sample.key,
        bucket: sample.bucket,
        kind: sample.kind,
        content_type: sample.type,
        bytes: sample.bytes,
      });
      f.objects.clear();
      f.objects.set(
        `_staging/${sample.key}`,
        object("AAAA", sample.bytes, sample.type),
      );
      const row = await f.ok();
      const dot = sample.key.lastIndexOf(".");
      assert(
        String(row.storage_key).startsWith(
          sample.key.slice(0, dot) + "-complete-",
        ),
      );
      assert(String(row.storage_key).endsWith(sample.key.slice(dot)));
      assertEquals(row.bucket, sample.bucket);
      assertEquals(row.kind, sample.kind);
      assertEquals(row.bytes, sample.bytes);
      assertEquals(f.objects.get(String(row.storage_key))?.body, "AAAA");
    }));
}

Deno.test("gallery ceiling is not widened by completion-attempt naming", () =>
  fixture(async (f) => {
    const key = "renders/org/listing/gallery-asset.jpg", bytes = 11 * 1024 ** 2;
    Object.assign(f.asset!, {
      storage_key: key,
      bucket: "renders",
      kind: "photo",
      content_type: "image/jpeg",
      bytes,
    });
    f.objects.clear();
    f.objects.set(`_staging/${key}`, object("AAAA", bytes, "image/jpeg"));
    assertEquals((await f.request("complete")).status, 400);
    assertEquals(f.asset!.upload_aborted, true);
    assertEquals(f.copies, []);
  }));

Deno.test("batch photo ticket also completes to a DB-selected immutable key", () =>
  fixture(async (f) => {
    f.asset = null;
    f.objects.clear();
    const response = await f.request("batch", {
      listing_id: "fixture-listing",
      kind: "photo",
      files: [{ filename: "photo.jpg", bytes: 4, content_type: "image/jpeg" }],
    });
    assertEquals(response.status, 201, await response.clone().text());
    const { assets } = await response.json();
    assertEquals(assets.length, 1);
    // Database defaults supplied by the real schema, not by the batch insert.
    Object.assign(f.asset!, { bucket: "uploads", upload_id: null });
    f.objects.set(
      `_staging/${assets[0].storage_key}`,
      object("AAAA", 4, "image/jpeg"),
    );
    const row = await f.ok();
    assert(String(row.storage_key) !== assets[0].storage_key);
    assertEquals(row.id, assets[0].asset_id);
    assertEquals(f.charges.length, 1);
  }));
