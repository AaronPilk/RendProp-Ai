import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { bucketForKey, createStudioHandler, PAGE_SIZE } from "./handler.ts";
import type { MediaScope, PhotoRow, StudioDependencies } from "./handler.ts";
import { HttpError } from "../_shared/http.ts";
const org = "10000000-0000-4000-8000-000000000001",
  listing = "20000000-0000-4000-8000-000000000002",
  user = "30000000-0000-4000-8000-000000000003";
const scope: MediaScope = { userId: user, orgId: org, listingId: listing };
const key = `uploads/${org}/${listing}/photo.jpg`;
function fixture() {
  const signed: string[] = [];
  let reads = 0;
  const deps: StudioDependencies = {
    authorize: async () => scope,
    rateLimit: async () => true,
    read: async () => {
      reads++;
      return { photos: [], assets: [], renders: [] };
    },
    sign: async (bucket, key, ttl) => {
      signed.push(`${bucket}:${key}:${ttl}`);
      return "https://objects.example/read";
    },
    now: () => Date.parse("2026-09-12T12:00:00Z"),
  };
  return { deps, signed, reads: () => reads };
}
const request = (
  query = "",
  method = "GET",
  headers: Record<string, string> = {},
) =>
  new Request(
    `https://project.supabase.co/functions/v1/studio/media?org_id=${org}&listing_id=${listing}${query}`,
    { method, headers },
  );
const photo: PhotoRow = {
  id: "40000000-0000-4000-8000-000000000004",
  listing_id: listing,
  original_key: key,
  enhanced_key: null,
  caption: "Example room",
  is_staged: true,
  sort: 0,
  created_at: "2026-09-12T00:00:00Z",
};
Deno.test("canonical linked keys only, not arbitrary object reads", () => {
  assertEquals(bucketForKey(key, scope), "uploads");
  assertEquals(
    bucketForKey(`renders/${org}/${listing}/finished.mp4`, scope),
    "renders",
  );
  for (
    const bad of [
      null,
      "",
      `uploads/${user}/${listing}/x.jpg`,
      `uploads/${org}/${user}/x.jpg`,
      `_staging/${key}`,
      `${key}?version=1`,
      `${key}/../other`,
      `uploads/${org}/${listing}/%2e%2e/x`,
      `${key}#x`,
      `${key}\\x`,
      `ai-router/${org}/result.jpg`,
    ]
  ) {
    assertEquals(bucketForKey(bad, scope), null);
  }
});
Deno.test("OPTIONS requires no authorization or media read", async () => {
  const f = fixture();
  f.deps.authorize = () => {
    throw Error("should not run");
  };
  const r = await createStudioHandler(f.deps)(request("", "OPTIONS"));
  assertEquals(r.status, 200);
  assertEquals(f.reads(), 0);
});
Deno.test("POST cannot mutate anything", async () => {
  const f = fixture();
  assertEquals(
    (await createStudioHandler(f.deps)(request("", "POST"))).status,
    405,
  );
  assertEquals(f.reads(), 0);
});
Deno.test("unknown route is 404", async () => {
  const f = fixture();
  assertEquals(
    (
      await createStudioHandler(f.deps)(
        new Request("https://project.supabase.co/functions/v1/studio/anything"),
      )
    ).status,
    404,
  );
});
Deno.test("unauthenticated request cannot read or sign", async () => {
  const f = fixture();
  f.deps.authorize = async () => {
    throw new HttpError(401, "Sign in required.");
  };
  assertEquals((await createStudioHandler(f.deps)(request())).status, 401);
  assertEquals(f.reads(), 0);
  assertEquals(f.signed, []);
});
Deno.test("unjoined workspace cannot read or sign", async () => {
  const f = fixture();
  f.deps.authorize = async () => {
    throw new HttpError(403, "Not a member.");
  };
  assertEquals((await createStudioHandler(f.deps)(request())).status, 403);
  assertEquals(f.reads(), 0);
});
Deno.test("authorization result must match both selectors", async () => {
  for (const changed of [{ orgId: user }, { listingId: user }]) {
    const f = fixture();
    f.deps.authorize = async () => ({ ...scope, ...changed });
    assertEquals((await createStudioHandler(f.deps)(request())).status, 403);
    assertEquals(f.reads(), 0);
  }
});
Deno.test("conflicting selector fails before auth or read", async () => {
  const f = fixture();
  assertEquals(
    (
      await createStudioHandler(f.deps)(
        request("", "GET", { "x-org-id": user }),
      )
    ).status,
    400,
  );
  assertEquals(f.reads(), 0);
});
Deno.test("malformed offsets are rejected, not coerced", async () => {
  for (const raw of ["-1", "1", "NaN", "1e2", "50.5", "10050"]) {
    const f = fixture();
    assertEquals(
      (await createStudioHandler(f.deps)(request(`&offset=${raw}`))).status,
      400,
    );
    assertEquals(f.reads(), 0);
  }
});
Deno.test("rate cap prevents DB/media expansion", async () => {
  const f = fixture();
  f.deps.rateLimit = async () => false;
  assertEquals((await createStudioHandler(f.deps)(request())).status, 429);
  assertEquals(f.reads(), 0);
});
Deno.test("returns literal contract, short lifetime, no cache", async () => {
  const f = fixture();
  f.deps.read = async () => ({ photos: [photo], assets: [], renders: [] });
  const response = await createStudioHandler(f.deps)(request());
  assertEquals(response.status, 200);
  assertEquals(response.headers.get("cache-control"), "private, no-store");
  const body = await response.json();
  assertEquals(body.photos, [
    {
      id: photo.id,
      listing_id: listing,
      url: "https://objects.example/read",
      expires_at: "2026-09-12T12:10:00.000Z",
      caption: "Example room",
      is_staged: true,
      sort: 0,
    },
  ]);
  assertEquals(body.next_offset, null);
  assertEquals(f.signed, [`uploads:${key}:600`]);
  assert(!JSON.stringify(body).includes(key));
});
Deno.test(
  "unsigned references and pending captures never become URLs",
  async () => {
    const f = fixture();
    f.deps.read = async () => ({
      photos: [
        { ...photo, original_key: `uploads/${user}/${listing}/other.jpg` },
      ],
      assets: [
        {
          id: "a",
          listing_id: listing,
          storage_key: key,
          bucket: "uploads",
          uploaded: false,
          kind: "photo",
          duration_s: null,
          created_at: photo.created_at,
        },
      ],
      renders: [],
    });
    const body = await (await createStudioHandler(f.deps)(request())).json();
    assertEquals(body.photos, []);
    assertEquals(body.unavailable_count, 1);
    assertEquals(f.signed, []);
  },
);
Deno.test("row from another listing fails whole response", async () => {
  const f = fixture();
  f.deps.read = async () => ({
    photos: [{ ...photo, listing_id: user }],
    assets: [],
    renders: [],
  });
  const response = await createStudioHandler(f.deps)(request());
  assertEquals(response.status, 500);
  assertEquals(f.signed, []);
});
Deno.test("uploaded video requires bucket agreement", async () => {
  const f = fixture();
  f.deps.read = async () => ({
    photos: [],
    assets: [
      {
        id: user,
        listing_id: listing,
        storage_key: key,
        bucket: "renders",
        uploaded: true,
        kind: "video",
        duration_s: 30,
        created_at: photo.created_at,
      },
    ],
    renders: [],
  });
  const body = await (await createStudioHandler(f.deps)(request())).json();
  assertEquals(body.videos, []);
  assertEquals(f.signed, []);
});
Deno.test(
  "stored render and photo deduplicate identical object keys",
  async () => {
    const f = fixture();
    f.deps.read = async () => ({
      photos: [photo],
      assets: [
        {
          id: user,
          listing_id: listing,
          storage_key: key,
          bucket: "uploads",
          uploaded: true,
          kind: "photo",
          duration_s: null,
          created_at: photo.created_at,
        },
      ],
      renders: [
        {
          id: listing,
          listing_id: listing,
          video_key: `renders/${org}/${listing}/export.mp4`,
          duration_s: 12,
          created_at: photo.created_at,
        },
      ],
    });
    const body = await (await createStudioHandler(f.deps)(request())).json();
    assertEquals(body.photos.length, 1);
    assertEquals(body.videos.length, 1);
    assertEquals(f.signed.length, 2);
  },
);
Deno.test(
  "pagination signs at most50 of each kind, reports next offset",
  async () => {
    const f = fixture();
    f.deps.read = async (_scope, offset) => {
      assertEquals(offset, 50);
      return {
        photos: Array.from({ length: 51 }, (_, i) => ({
          ...photo,
          id: `p${i}`,
          original_key: `uploads/${org}/${listing}/${i}.jpg`,
        })),
        assets: [],
        renders: [],
      };
    };
    const body = await (
      await createStudioHandler(f.deps)(request("&offset=50"))
    ).json();
    assertEquals(body.photos.length, PAGE_SIZE);
    assertEquals(body.next_offset, 100);
    assertEquals(f.signed.length, 50);
  },
);
Deno.test(
  "partial database errors cannot look like empty success",
  async () => {
    const f = fixture();
    f.deps.read = async () => {
      throw Error("sensitive database internals");
    };
    const response = await createStudioHandler(f.deps)(request());
    assertEquals(response.status, 503);
    assert(!(await response.text()).includes("sensitive"));
  },
);
Deno.test(
  "signing failure returns generic error, never capabilities or credentials",
  async () => {
    const f = fixture();
    f.deps.read = async () => ({ photos: [photo], assets: [], renders: [] });
    f.deps.sign = async () => {
      throw Error("secret signed url");
    };
    const response = await createStudioHandler(f.deps)(request());
    assertEquals(response.status, 503);
    assert(!(await response.text()).includes("secret"));
  },
);

Deno.test("rechecks live membership and deletion after reading and signing", async () => {
  for (const status of [403, 409]) {
    const f = fixture();
    let checks = 0;
    f.deps.authorize = async () => {
      if (++checks === 2) throw new HttpError(status, "Access changed.");
      return scope;
    };
    f.deps.read = async () => ({ photos: [photo], assets: [], renders: [] });
    const response = await createStudioHandler(f.deps)(request());
    assertEquals(checks, 2);
    assertEquals(response.status, status);
    assertEquals(response.headers.get("cache-control"), "private, no-store");
    assert(!(await response.text()).includes("https://objects.example/read"));
  }
});
Deno.test("deletion already in progress stops before rate limit, read or signing", async () => {
  const f = fixture();
  f.deps.authorize = async () => {
    throw new HttpError(409, "Account deletion pending.");
  };
  f.deps.rateLimit = () => {
    throw Error("must not run");
  };
  assertEquals((await createStudioHandler(f.deps)(request())).status, 409);
  assertEquals(f.reads(), 0);
  assertEquals(f.signed.length, 0);
});
Deno.test("valid row followed by foreign lookahead fails before any signing", async () => {
  const f = fixture();
  f.deps.read = async () => ({
    photos: [photo, { ...photo, listing_id: user }],
    assets: [],
    renders: [],
  });
  assertEquals((await createStudioHandler(f.deps)(request())).status, 500);
  assertEquals(f.signed.length, 0);
});
Deno.test("oversized query result and paging-limit lookahead are explicit failures", async () => {
  for (const [count, offset, status] of [[52, 0, 500], [51, 10000, 422]]) {
    const f = fixture();
    f.deps.read = async () => ({
      photos: Array(count).fill(photo),
      assets: [],
      renders: [],
    });
    assertEquals(
      (await createStudioHandler(f.deps)(request(`&offset=${offset}`))).status,
      status,
    );
    assertEquals(f.signed.length, 0);
  }
});
Deno.test("two pages consume each source's lookahead exactly once", async () => {
  const f = fixture();
  const photos = Array.from(
    { length: 52 },
    (_, i) => ({ ...photo, id: `photo${i}`, original_key: `${key}-${i}` }),
  );
  f.deps.read = async (_scope, offset) => ({
    photos: photos.slice(offset, offset + PAGE_SIZE + 1),
    assets: [],
    renders: [],
  });
  const first = await (await createStudioHandler(f.deps)(request())).json();
  const second = await (await createStudioHandler(f.deps)(
    request(`&offset=${first.next_offset}`),
  )).json();
  assertEquals(first.photos.length, 50);
  assertEquals(second.photos.length, 2);
  assertEquals(second.next_offset, null);
  assertEquals(
    new Set([...first.photos, ...second.photos].map((p) => p.id)).size,
    52,
  );
});
Deno.test("does not return capabilities whose declared lifetime elapsed during signing", async () => {
  const f = fixture();
  f.deps.read = async () => ({ photos: [photo], assets: [], renders: [] });
  const now = f.deps.now();
  f.deps.sign = async () => {
    f.deps.now = () => now + 600_000;
    return "https://objects.example/read";
  };
  assertEquals((await createStudioHandler(f.deps)(request())).status, 503);
});
