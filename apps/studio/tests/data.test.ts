import assert from "node:assert/strict";
import { test } from "node:test";
import type { AuthChangeEvent, Session } from "@supabase/supabase-js";
import {
  createStudioServices,
  decodeListings,
  decodeMedia,
  decodeMemberships,
  decodeWorkspace,
  readStudioConfig,
  StudioError,
  validateStudioConfig,
  type StudioAuth,
  type StudioConfig,
  type Membership,
} from "../src/data/index";

const USER = "11111111-1111-4111-8111-111111111111";
const OTHER_USER = "22222222-2222-4222-8222-222222222222";
const ORG = "33333333-3333-4333-8333-333333333333";
const OTHER_ORG = "44444444-4444-4444-8444-444444444444";
const FOREIGN_ORG = "55555555-5555-4555-8555-555555555555";
const LISTING = "66666666-6666-4666-8666-666666666666";
const OTHER_LISTING = "77777777-7777-4777-8777-777777777777";
const PHOTO = "88888888-8888-4888-8888-888888888888";
const config: StudioConfig = {
  supabaseUrl: "https://studio-fixture.supabase.co",
  publishableKey: "sb_publishable_OFFLINE_FIXTURE_NOT_A_REAL_KEY",
  redirectTo: "http://localhost:5173/",
};
const joined: Membership[] = [
  {
    orgId: ORG,
    role: "owner",
    orgName: "Fixture workspace",
    spaceType: "real_estate",
  },
];
const membershipDTO = (orgId = ORG, userId = USER) => ({
  user_id: userId,
  org_id: orgId,
  role: "owner",
  orgs: {
    id: orgId,
    name: "Fixture workspace",
    space_type: "real_estate",
    deleted_at: null,
  },
});
const meDTO = (orgId = ORG, userId = USER) => ({
  user: {
    id: userId,
    email: "fixture@example.invalid",
    name: "Fixture user",
    avatar_url: null,
  },
  org: {
    id: orgId,
    name: "Fixture workspace",
    handle: null,
    space_type: "real_estate",
  },
  plan: "free",
  plan_raw: "trial",
  trial_ends_at: "2026-01-01T00:00:00Z",
  plan_expires_at: null,
  usage: { listings: 1, leads: 0, leads_new: 0, renders: 0 },
});
const listingDTO = (orgId = ORG, id = LISTING, spaceType = "real_estate") => ({
  id,
  org_id: orgId,
  space_type: spaceType,
  address: "Offline fixture",
  tagline: null,
  details: {},
  status: "draft",
  created_at: "2026-09-12T00:00:00Z",
  deleted_at: null,
  main_photo_key: null,
  beds: null,
  baths: null,
  sqft: null,
  price_cents: null,
});
const sessionFor = (
  userId = USER,
  token = "offline-token",
  anonymous = false,
): Session => ({
  access_token: token,
  refresh_token: "offline-refresh",
  expires_in: 3600,
  token_type: "bearer",
  user: {
    id: userId,
    email: "fixture@example.invalid",
    is_anonymous: anonymous,
    app_metadata: {},
    user_metadata: {},
    aud: "authenticated",
    created_at: "2026-09-12T00:00:00Z",
  },
});
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((r, fail) => {
    resolve = r;
    reject = fail;
  });
  return { promise, resolve, reject };
}
function manualClock() {
  let now = 0,
    id = 0;
  const tasks = new Map<number, { at: number; callback: () => void }>();
  return {
    schedule(milliseconds: number, callback: () => void) {
      const key = ++id;
      tasks.set(key, { at: now + milliseconds, callback });
      return () => {
        tasks.delete(key);
      };
    },
    advance(milliseconds: number) {
      now += milliseconds;
      for (const [key, task] of [...tasks])
        if (task.at <= now) {
          tasks.delete(key);
          task.callback();
        }
    },
    pending: () => tasks.size,
  };
}
function mockAuth(initial: Session | null = sessionFor()) {
  let current = initial;
  let callback:
    ((event: AuthChangeEvent, session: Session | null) => void) | undefined;
  let refreshCalls = 0;
  const signInArgs: unknown[] = [];
  const signOutArgs: unknown[] = [];
  const auth: StudioAuth = {
    getSession: async () => ({ data: { session: current }, error: null }),
    refreshSession: async () => {
      refreshCalls += 1;
      return { data: { session: current }, error: null };
    },
    signInWithOAuth: async (input) => {
      signInArgs.push(input);
      return { error: null };
    },
    signOut: async (input) => {
      signOutArgs.push(input);
      current = null;
      callback?.("SIGNED_OUT", null);
      return { error: null };
    },
    onAuthStateChange: (cb) => {
      callback = cb;
      return {
        data: {
          subscription: {
            unsubscribe() {
              callback = undefined;
            },
          },
        },
      };
    },
  };
  return {
    auth,
    signInArgs,
    signOutArgs,
    refreshCalls: () => refreshCalls,
    emit(event: AuthChangeEvent, session: Session | null) {
      current = session;
      callback?.(event, session);
    },
  };
}
function fakeFetch(
  handler: (url: URL, options: RequestInit) => Response | Promise<Response>,
): typeof fetch {
  return (async (input, options = {}) =>
    handler(new URL(String(input)), options)) as typeof fetch;
}
function json(value: unknown, status = 200) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
function fixtureResponse(url: URL): Response {
  if (url.pathname === "/rest/v1/memberships") return json([membershipDTO()]);
  if (url.pathname === "/functions/v1/me") return json(meDTO());
  return json([listingDTO()]);
}
function code(expected: string) {
  return (error: unknown) =>
    error instanceof StudioError && error.code === expected;
}

test("browser config accepts publishable and legacy anon keys, normalizes origin", () => {
  assert.deepEqual(
    readStudioConfig(
      {
        VITE_SUPABASE_URL: `${config.supabaseUrl}/`,
        VITE_SUPABASE_PUBLISHABLE_KEY: config.publishableKey,
      },
      "http://localhost:5173",
    ),
    config,
  );
  const legacy = `e30.${Buffer.from(JSON.stringify({ role: "anon" })).toString("base64url")}.c2ln`;
  assert.equal(
    validateStudioConfig({ ...config, publishableKey: legacy }).publishableKey,
    legacy,
  );
});

test("browser config rejects service-role, secret, malformed and unsafe URL inputs", () => {
  const service = `e30.${Buffer.from(JSON.stringify({ role: "service_role" })).toString("base64url")}.c2ln`;
  for (const key of [
    service,
    "sb_secret_FORBIDDEN",
    "not-a-key",
    "e30.invalid.c2ln",
  ]) {
    assert.throws(
      () => validateStudioConfig({ ...config, publishableKey: key }),
      code("configuration"),
    );
  }
  for (const supabaseUrl of [
    "http://example.com",
    "https://user:pass@example.com",
    "https://example.com/auth",
    "https://example.com/?token=x",
    "javascript:alert(1)",
  ]) {
    assert.throws(
      () => validateStudioConfig({ ...config, supabaseUrl }),
      code("configuration"),
    );
  }
  assert.throws(
    () => readStudioConfig({}, "https://studio.example.com"),
    code("configuration"),
  );
  assert.throws(
    () =>
      readStudioConfig(
        {
          VITE_SUPABASE_URL: config.supabaseUrl,
          VITE_SUPABASE_PUBLISHABLE_KEY: config.publishableKey,
          VITE_SUPABASE_SERVICE_ROLE_KEY: "forbidden",
        },
        "https://studio.example.com",
      ),
    code("configuration"),
  );
});

test("browser config rejects ambiguous key fields before an unused secret can be bundled", () => {
  const service = `e30.${Buffer.from(JSON.stringify({ role: "service_role" })).toString("base64url")}.c2ln`;
  const legacy = `e30.${Buffer.from(JSON.stringify({ role: "anon" })).toString("base64url")}.c2ln`;
  for (const unused of [service, "sb_secret_OFFLINE_FORBIDDEN", legacy, ""]) {
    for (const [publishable, anon] of [
      [config.publishableKey, unused],
      [unused, legacy],
    ]) {
      assert.throws(
        () =>
          readStudioConfig(
            {
              VITE_SUPABASE_URL: config.supabaseUrl,
              VITE_SUPABASE_PUBLISHABLE_KEY: publishable,
              VITE_SUPABASE_ANON_KEY: anon,
            },
            config.redirectTo,
          ),
        (error: unknown) =>
          error instanceof StudioError &&
          error.code === "configuration" &&
          error.message.includes("never both") &&
          !error.message.includes(service) &&
          !error.message.includes("sb_secret_OFFLINE_FORBIDDEN"),
      );
    }
  }
  assert.equal(
    readStudioConfig(
      { VITE_SUPABASE_URL: config.supabaseUrl, VITE_SUPABASE_ANON_KEY: legacy },
      config.redirectTo,
    ).publishableKey,
    legacy,
  );
});

test("existing snake_case workspace fields normalize without inventing entitlement", () => {
  const result = decodeWorkspace(meDTO(), USER, joined);
  assert.equal(result.org.spaceType, "real_estate");
  assert.equal(result.plan, "free");
  assert.equal(result.planRaw, "trial");
  assert.equal(result.usage.leadsNew, 0);
  assert.throws(
    () =>
      decodeWorkspace({ ...meDTO(), user: { id: OTHER_USER } }, USER, joined),
    code("identity-mismatch"),
  );
  assert.throws(
    () => decodeWorkspace(meDTO(OTHER_ORG), USER, joined),
    code("identity-mismatch"),
  );
  assert.throws(
    () =>
      decodeWorkspace(
        { ...meDTO(), usage: { ...meDTO().usage, leads_new: "0" } },
        USER,
        joined,
      ),
    code("invalid-response"),
  );
});

test("membership response rejects other users and mismatched joined organization", () => {
  assert.equal(decodeMemberships([membershipDTO()], USER)[0]?.orgId, ORG);
  assert.throws(
    () => decodeMemberships([membershipDTO(ORG, OTHER_USER)], USER),
    code("identity-mismatch"),
  );
  assert.throws(
    () =>
      decodeMemberships(
        [
          {
            ...membershipDTO(),
            orgs: { ...membershipDTO().orgs, id: OTHER_ORG },
          },
        ],
        USER,
      ),
    code("identity-mismatch"),
  );
  assert.throws(
    () => decodeMemberships([{ ...membershipDTO(), role: "superuser" }], USER),
    code("invalid-response"),
  );
});

test("listings retain every industry and select only the requested joined workspace", () => {
  const memberships = [...joined, { ...joined[0]!, orgId: OTHER_ORG }];
  const data = [
    listingDTO(),
    listingDTO(ORG, OTHER_LISTING, "hospitality"),
    listingDTO(OTHER_ORG, PHOTO, "yacht"),
  ];
  const result = decodeListings(data, ORG, memberships);
  assert.deepEqual(
    result.map((row) => row.spaceType),
    ["real_estate", "hospitality"],
  );
  assert.ok(result.every((row) => row.orgId === ORG));
  assert.throws(
    () =>
      decodeListings(
        [...data, listingDTO(FOREIGN_ORG, USER)],
        ORG,
        memberships,
      ),
    code("identity-mismatch"),
  );
});

test("listings reject malformed snake_case fields and unsafe integer money", () => {
  const { org_id: _orgId, ...withoutOrg } = listingDTO();
  assert.throws(
    () => decodeListings([{ ...withoutOrg, orgId: ORG }], ORG, joined),
    code("invalid-response"),
  );
  for (const patch of [
    { details: [] },
    { status: "unknown" },
    { created_at: "not-a-date" },
    { price_cents: Number.MAX_SAFE_INTEGER + 1 },
    { deleted_at: "2026-09-12" },
  ]) {
    assert.throws(
      () => decodeListings([{ ...listingDTO(), ...patch }], ORG, joined),
      code("invalid-response"),
    );
  }
});

test("uses Apple OAuth and browser-local sign out without affecting native session", async () => {
  const mocked = mockAuth();
  const services = createStudioServices(config, {
    auth: mocked.auth,
    fetch: fakeFetch(fixtureResponse),
  });
  await services.ready();
  await services.signIn();
  assert.deepEqual(mocked.signInArgs, [
    { provider: "apple", options: { redirectTo: config.redirectTo } },
  ]);
  await services.signOut();
  assert.deepEqual(mocked.signOutArgs, [{ scope: "local" }]);
  assert.equal(services.getSnapshot().identity, null);
  await assert.rejects(services.loadWorkspace(), code("sign-in-required"));
  services.dispose();
});

test("a request captures account identity at invocation before its first await", async () => {
  const mocked = mockAuth();
  const services = createStudioServices(config, {
    auth: mocked.auth,
    fetch: fakeFetch(fixtureResponse),
  });
  await services.ready();
  const pending = services.loadWorkspace();
  mocked.emit("SIGNED_IN", sessionFor(OTHER_USER));
  await assert.rejects(pending, code("stale-identity"));
  services.dispose();
});

test("anonymous session is distinct from Apple account and cannot imply cross-device connection", async () => {
  let calls = 0;
  const services = createStudioServices(config, {
    auth: mockAuth(sessionFor(USER, "anon", true)).auth,
    fetch: fakeFetch(() => {
      calls++;
      return json({});
    }),
  });
  await services.ready();
  assert.equal(services.getSnapshot().identity?.isAnonymous, true);
  await assert.rejects(
    services.loadWorkspace(),
    code("identified-account-required"),
  );
  assert.equal(calls, 0);
  services.dispose();
});

test("workspace reads authenticated RLS memberships and respects server active workspace", async () => {
  const seen: Array<{ url: URL; options: RequestInit }> = [];
  const services = createStudioServices(config, {
    auth: mockAuth().auth,
    fetch: fakeFetch((url, options) => {
      seen.push({ url, options });
      if (url.pathname === "/rest/v1/memberships")
        return json([membershipDTO(), membershipDTO(OTHER_ORG)]);
      return json(meDTO(OTHER_ORG));
    }),
  });
  const workspace = await services.loadWorkspace();
  assert.equal(workspace.org.id, OTHER_ORG);
  assert.equal(workspace.memberships.length, 2);
  assert.equal(seen[0]?.url.searchParams.get("user_id"), `eq.${USER}`);
  for (const { options } of seen) {
    assert.equal(options.cache, "no-store");
    assert.equal(options.redirect, "error");
    assert.equal(options.credentials, "omit");
    assert.equal(
      new Headers(options.headers).get("Authorization"),
      "Bearer offline-token",
    );
  }
  services.dispose();
});

test("same-identity token refresh does not discard an in-flight response", async () => {
  const mocked = mockAuth();
  const started = deferred<void>();
  const response = deferred<Response>();
  const services = createStudioServices(config, {
    auth: mocked.auth,
    fetch: fakeFetch((url) => {
      if (url.pathname.endsWith("/listings")) {
        started.resolve();
        return response.promise;
      }
      return fixtureResponse(url);
    }),
  });
  await services.loadWorkspace();
  const version = services.getSnapshot().identityVersion;
  const pending = services.listListings(ORG);
  await started.promise;
  mocked.emit("TOKEN_REFRESHED", sessionFor(USER, "refreshed-token"));
  response.resolve(json([listingDTO()]));
  assert.equal((await pending)[0]?.id, LISTING);
  assert.equal(services.getSnapshot().identityVersion, version);
  services.dispose();
});

test("401 retry is single-flight with a new token and same workspace", async () => {
  const mocked = mockAuth();
  let refreshCount = 0;
  const refreshStarted = deferred<void>();
  const refreshed = deferred<{ data: { session: Session }; error: null }>();
  mocked.auth.refreshSession = () => {
    refreshCount++;
    refreshStarted.resolve();
    return refreshed.promise;
  };
  const listingHeaders: Headers[] = [];
  const services = createStudioServices(config, {
    auth: mocked.auth,
    fetch: fakeFetch((url, options) => {
      if (!url.pathname.endsWith("/listings")) return fixtureResponse(url);
      const headers = new Headers(options.headers);
      listingHeaders.push(headers);
      return headers.get("Authorization") === "Bearer offline-token"
        ? json({}, 401)
        : json([listingDTO()]);
    }),
  });
  await services.loadWorkspace();
  const pending = Promise.all([
    services.listListings(ORG),
    services.listListings(ORG),
  ]);
  await refreshStarted.promise;
  // Allow both rejected HTTP responses to reach the shared refresh promise.
  await new Promise((resolve) => setImmediate(resolve));
  const next = sessionFor(USER, "refreshed-token");
  mocked.emit("TOKEN_REFRESHED", next);
  refreshed.resolve({ data: { session: next }, error: null });
  assert.equal((await pending).length, 2);
  assert.equal(refreshCount, 1);
  assert.equal(listingHeaders.length, 4);
  assert.ok(listingHeaders.every((headers) => headers.get("X-Org-Id") === ORG));
  services.dispose();
});

test("second 401 fails visibly; it never returns sample data", async () => {
  const mocked = mockAuth();
  let calls = 0;
  const services = createStudioServices(config, {
    auth: mocked.auth,
    fetch: fakeFetch((url) => {
      if (!url.pathname.endsWith("/listings")) return fixtureResponse(url);
      calls++;
      return json({ message: "sensitive backend response" }, 401);
    }),
  });
  await services.loadWorkspace();
  await assert.rejects(
    services.listListings(ORG),
    (error) =>
      code("request-failed")(error) &&
      !(error as Error).message.includes("sensitive"),
  );
  assert.equal(calls, 2);
  assert.equal(mocked.refreshCalls(), 1);
  services.dispose();
});

test("account switch A to B to A aborts and rejects the original response", async () => {
  const mocked = mockAuth();
  const started = deferred<AbortSignal>();
  const response = deferred<Response>();
  const services = createStudioServices(config, {
    auth: mocked.auth,
    fetch: fakeFetch((url, options) => {
      if (url.pathname.endsWith("/listings")) {
        started.resolve(options.signal!);
        return response.promise;
      }
      return fixtureResponse(url);
    }),
  });
  await services.loadWorkspace();
  const pending = services.listListings(ORG);
  const signal = await started.promise;
  mocked.emit("SIGNED_IN", sessionFor(OTHER_USER));
  mocked.emit("SIGNED_IN", sessionFor(USER));
  assert.equal(signal.aborted, true);
  response.resolve(json([listingDTO()]));
  await assert.rejects(pending, code("stale-identity"));
  await assert.rejects(services.listListings(ORG), code("membership-required"));
  services.dispose();
});

test("sign out fences already-running media and removes identity synchronously", async () => {
  const mocked = mockAuth();
  const started = deferred<void>();
  const response = deferred<Response>();
  const services = createStudioServices(config, {
    auth: mocked.auth,
    fetch: fakeFetch((url) => {
      if (url.pathname.endsWith("/studio/media")) {
        started.resolve();
        return response.promise;
      }
      return fixtureResponse(url);
    }),
  });
  await services.loadWorkspace();
  const pending = services.listMedia(ORG, LISTING);
  await started.promise;
  const signout = services.signOut();
  assert.equal(services.getSnapshot().identity, null);
  response.resolve(json({}));
  await assert.rejects(pending, code("stale-identity"));
  await signout;
  services.dispose();
});

test("late initial session cannot overwrite a newer account event", async () => {
  const mocked = mockAuth();
  const initial = deferred<{ data: { session: Session }; error: null }>();
  mocked.auth.getSession = () => initial.promise;
  const services = createStudioServices(config, {
    auth: mocked.auth,
    fetch: fakeFetch(fixtureResponse),
  });
  mocked.emit("SIGNED_IN", sessionFor(OTHER_USER));
  initial.resolve({ data: { session: sessionFor(USER) }, error: null });
  assert.equal((await services.ready()).identity?.userId, OTHER_USER);
  services.dispose();
});

test("explicit AbortSignal rejects a late response after workspace navigation", async () => {
  const mocked = mockAuth();
  const started = deferred<void>();
  const response = deferred<Response>();
  const services = createStudioServices(config, {
    auth: mocked.auth,
    fetch: fakeFetch((url) => {
      if (url.pathname.endsWith("/listings")) {
        started.resolve();
        return response.promise;
      }
      return fixtureResponse(url);
    }),
  });
  await services.loadWorkspace();
  const controller = new AbortController();
  const pending = services.listListings(ORG, controller.signal);
  await started.promise;
  controller.abort();
  response.resolve(json([listingDTO()]));
  await assert.rejects(
    pending,
    (error) => error instanceof Error && error.name === "AbortError",
  );
  services.dispose();
});

test("private media is bound to org and listing and rejects unsafe or expired URLs", () => {
  const dto = {
    org_id: ORG,
    listing_id: LISTING,
    photos: [
      {
        id: PHOTO,
        listing_id: LISTING,
        url: "https://private.example.invalid/object?X-Amz-Signature=fixture",
        expires_at: "2099-01-01T00:00:00Z",
        caption: null,
        is_staged: true,
        sort: 0,
      },
    ],
    videos: [],
    next_offset: null,
    unavailable_count: 0,
  };
  const result = decodeMedia(dto, ORG, LISTING);
  assert.equal(result.photos[0]?.isStaged, true);
  assert.throws(
    () => decodeMedia({ ...dto, org_id: OTHER_ORG }, ORG, LISTING),
    code("identity-mismatch"),
  );
  assert.throws(
    () =>
      decodeMedia(
        { ...dto, photos: [{ ...dto.photos[0], listing_id: OTHER_LISTING }] },
        ORG,
        LISTING,
      ),
    code("identity-mismatch"),
  );
  for (const url of [
    "javascript:alert(1)",
    "http://example.com/file",
    "https://example.com/?access_token=secret",
  ]) {
    assert.throws(
      () =>
        decodeMedia(
          { ...dto, photos: [{ ...dto.photos[0], url }] },
          ORG,
          LISTING,
        ),
      code("invalid-response"),
    );
  }
  assert.throws(
    () =>
      decodeMedia(
        {
          ...dto,
          photos: [{ ...dto.photos[0], expires_at: "2000-01-01T00:00:00Z" }],
        },
        ORG,
        LISTING,
      ),
    code("media-expired"),
  );
  assert.equal(
    decodeMedia({ ...dto, next_offset: 50, unavailable_count: 2 }, ORG, LISTING)
      .nextOffset,
    50,
  );
  assert.throws(
    () => decodeMedia({ ...dto, next_offset: 0 }, ORG, LISTING),
    code("invalid-response"),
  );
  assert.throws(
    () => decodeMedia({ ...dto, next_offset: 75 }, ORG, LISTING),
    code("invalid-response"),
  );
  assert.throws(
    () =>
      decodeMedia(
        { ...dto, photos: Array(101).fill(dto.photos[0]) },
        ORG,
        LISTING,
      ),
    code("invalid-response"),
  );
});

test("never-resolving initial session stops loading at the SDK deadline and ignores its late result", async () => {
  const clock = manualClock(),
    mocked = mockAuth(),
    started = deferred<void>(),
    result = deferred<{ data: { session: Session }; error: null }>();
  mocked.auth.getSession = () => {
    started.resolve();
    return result.promise;
  };
  const services = createStudioServices(config, {
    auth: mocked.auth,
    clock,
    authTimeoutMs: 20,
    readTimeoutMs: 30,
    fetch: fakeFetch(fixtureResponse),
  });
  const ready = services.ready();
  await started.promise;
  clock.advance(20);
  const snapshot = await ready;
  assert.equal(snapshot.status, "error");
  assert.match(snapshot.error!, /timed out/);
  result.resolve({ data: { session: sessionFor() }, error: null });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(services.getSnapshot().identity, null);
  assert.equal(clock.pending(), 0);
  services.dispose();
});

test("never-resolving network times out, aborts the request, consumes late rejection and allows retry", async () => {
  const clock = manualClock(),
    started = deferred<AbortSignal>(),
    result = deferred<Response>();
  let stall = true;
  const services = createStudioServices(config, {
    auth: mockAuth().auth,
    clock,
    authTimeoutMs: 20,
    readTimeoutMs: 30,
    fetch: fakeFetch((url, options) => {
      if (url.pathname.endsWith("/listings") && stall) {
        started.resolve(options.signal!);
        return result.promise;
      }
      return fixtureResponse(url);
    }),
  });
  await services.loadWorkspace();
  const pending = services.listListings(ORG);
  const signal = await started.promise;
  clock.advance(30);
  await assert.rejects(pending, code("timeout"));
  assert.equal(signal.aborted, true);
  result.reject(new Error("late fixture network rejection"));
  await new Promise((resolve) => setImmediate(resolve));
  stall = false;
  assert.equal((await services.listListings(ORG))[0]?.id, LISTING);
  assert.equal(clock.pending(), 0);
  services.dispose();
});

test("the same total read deadline includes a stalled JSON response body", async () => {
  const clock = manualClock(),
    started = deferred<void>(),
    body = deferred<unknown>();
  const services = createStudioServices(config, {
    auth: mockAuth().auth,
    clock,
    authTimeoutMs: 20,
    readTimeoutMs: 30,
    fetch: fakeFetch((url) => {
      if (!url.pathname.endsWith("/listings")) return fixtureResponse(url);
      const response = json({});
      Object.defineProperty(response, "json", {
        value: () => {
          started.resolve();
          return body.promise;
        },
      });
      return response;
    }),
  });
  await services.loadWorkspace();
  const pending = services.listListings(ORG);
  await started.promise;
  clock.advance(30);
  await assert.rejects(pending, code("timeout"));
  body.resolve([listingDTO()]);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(clock.pending(), 0);
  services.dispose();
});

test("a stalled refresh cannot exceed the read deadline or replay the request later", async () => {
  const clock = manualClock(),
    mocked = mockAuth(),
    started = deferred<void>(),
    result = deferred<{ data: { session: Session }; error: null }>();
  let listingCalls = 0;
  mocked.auth.refreshSession = () => {
    started.resolve();
    return result.promise;
  };
  const services = createStudioServices(config, {
    auth: mocked.auth,
    clock,
    authTimeoutMs: 60,
    readTimeoutMs: 30,
    fetch: fakeFetch((url) => {
      if (url.pathname.endsWith("/listings")) {
        listingCalls++;
        return json({}, 401);
      }
      return fixtureResponse(url);
    }),
  });
  await services.loadWorkspace();
  const pending = services.listListings(ORG);
  await started.promise;
  clock.advance(30);
  await assert.rejects(pending, code("timeout"));
  result.resolve({
    data: { session: sessionFor(USER, "late-refreshed-token") },
    error: null,
  });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(listingCalls, 1);
  assert.equal(clock.pending(), 0);
  services.dispose();
});

test("stalled sign-in and sign-out return safe errors without leaving a visible identity", async () => {
  const clock = manualClock(),
    mocked = mockAuth(),
    signinStarted = deferred<void>(),
    signoutStarted = deferred<void>();
  mocked.auth.signInWithOAuth = () => {
    signinStarted.resolve();
    return new Promise(() => {});
  };
  mocked.auth.signOut = () => {
    signoutStarted.resolve();
    return new Promise(() => {});
  };
  const services = createStudioServices(config, {
    auth: mocked.auth,
    clock,
    authTimeoutMs: 20,
    fetch: fakeFetch(fixtureResponse),
  });
  await services.ready();
  const signin = services.signIn();
  await signinStarted.promise;
  clock.advance(20);
  await assert.rejects(signin, code("timeout"));
  const signout = services.signOut();
  assert.equal(services.getSnapshot().identity, null);
  await signoutStarted.promise;
  clock.advance(20);
  await assert.rejects(signout, code("sign-out-failed"));
  assert.equal(services.getSnapshot().identity, null);
  assert.equal(clock.pending(), 0);
  services.dispose();
});
