import assert from "node:assert/strict";
import { test } from "node:test";
import type { AuthChangeEvent, Session } from "@supabase/supabase-js";
import {
  createStudioServices,
  MAX_METADATA_BYTES,
  decodeListings,
  decodeMedia,
  decodeMemberships,
  decodeWorkspace,
  decodeWorkspaceDirectory,
  scopedListingWorkspace,
  canEditListing,
  type Membership,
  readStudioConfig,
  type StudioAuth,
  type StudioConfig,
  StudioError,
  validateStudioConfig,
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
const directoryDTO = (actor = USER, active = ORG, includeOther = false) => ({
 actor_id:actor,own_org_id:ORG,billing_org_id:ORG,active_org_id:active,can_switch_agent_libraries:includeOther,
 workspaces:[{id:ORG,name:"Fixture workspace",role:"owner",access_mode:"own",library_owner_user_id:actor,billing_org_id:ORG,can_read:true,can_write:true,can_manage_subscription:true},...(includeOther?[{id:OTHER_ORG,name:"Other agent",role:"team_owner",access_mode:"team_owner",library_owner_user_id:actor===OTHER_USER?USER:OTHER_USER,billing_org_id:ORG,can_read:true,can_write:true,can_manage_subscription:false}]:[])],
});
const libraryPage=(rows:ReturnType<typeof listingDTO>[],actor=USER,total=rows.length,next:number|null=null)=>json({actor_id:actor,listings:rows,total,next_offset:next});
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
  billing:{org_id:ORG,content_org_id:orgId,serving_org_id:ORG,role:"owner",can_manage_subscription:true},
  plan: "free",
  plan_raw: "trial",
  trial_ends_at: "2026-01-01T00:00:00Z",
  plan_expires_at: null,
  usage: { listings: 1, leads: 0, leads_new: 0, renders: 0 },
});
const listingDTO = (orgId = ORG, id = LISTING, spaceType = "real_estate") => ({
  id,
  org_id: orgId,
  library_org_id:orgId,
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
      for (const [key, task] of [...tasks]) {
        if (task.at <= now) {
          tasks.delete(key);
          task.callback();
        }
      }
    },
    pending: () => tasks.size,
  };
}
function mockAuth(initial: Session | null = sessionFor()) {
  let current = initial;
  let callback:
    | ((event: AuthChangeEvent, session: Session | null) => void)
    | undefined;
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
    headers: { "Content-Type": "application/json", ...(Array.isArray(value) ? { "Content-Range": value.length ? `0-${value.length - 1}/${value.length}` : "*/0" } : {}) },
  });
}
function fixtureResponse(url: URL): Response {
  if (url.pathname === "/functions/v1/me/workspaces") return json(directoryDTO());
  if (url.pathname === "/functions/v1/me") return json(meDTO());
  return libraryPage([listingDTO()]);
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
  const legacy = `e30.${
    Buffer.from(JSON.stringify({ role: "anon" })).toString("base64url")
  }.c2ln`;
  assert.equal(
    validateStudioConfig({ ...config, publishableKey: legacy }).publishableKey,
    legacy,
  );
});

test("browser config rejects service-role, secret, malformed and unsafe URL inputs", () => {
  const service = `e30.${
    Buffer.from(JSON.stringify({ role: "service_role" })).toString("base64url")
  }.c2ln`;
  for (
    const key of [
      service,
      "sb_secret_FORBIDDEN",
      "not-a-key",
      "e30.invalid.c2ln",
    ]
  ) {
    assert.throws(
      () => validateStudioConfig({ ...config, publishableKey: key }),
      code("configuration"),
    );
  }
  for (
    const supabaseUrl of [
      "http://example.com",
      "https://user:pass@example.com",
      "https://example.com/auth",
      "https://example.com/?token=x",
      "javascript:alert(1)",
    ]
  ) {
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
  const service = `e30.${
    Buffer.from(JSON.stringify({ role: "service_role" })).toString("base64url")
  }.c2ln`;
  const legacy = `e30.${
    Buffer.from(JSON.stringify({ role: "anon" })).toString("base64url")
  }.c2ln`;
  for (const unused of [service, "sb_secret_OFFLINE_FORBIDDEN", legacy, ""]) {
    for (
      const [publishable, anon] of [
        [config.publishableKey, unused],
        [unused, legacy],
      ]
    ) {
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
  for (
    const patch of [
      { details: [] },
      { status: "unknown" },
      { created_at: "not-a-date" },
      { price_cents: Number.MAX_SAFE_INTEGER + 1 },
      { deleted_at: "2026-09-12" },
    ]
  ) {
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

test("workspace reads actor-bound directory and respects an authorized active agent library", async () => {
  const seen: Array<{ url: URL; options: RequestInit }> = [];
  const services = createStudioServices(config, {
    auth: mockAuth().auth,
    fetch: fakeFetch((url, options) => {
      seen.push({ url, options });
      if (url.pathname === "/functions/v1/me/workspaces") {
        return json(directoryDTO(USER,OTHER_ORG,true));
      }
      return json(meDTO(OTHER_ORG));
    }),
  });
  const workspace = await services.loadWorkspace();
  assert.equal(workspace.org.id, OTHER_ORG);
  assert.equal(workspace.memberships.length, 2);
  assert.equal(seen[0]?.url.pathname,"/functions/v1/me/workspaces");
  assert.equal(new Headers(seen[0]?.options.headers).get("X-Org-Id"),null);
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
  response.resolve(libraryPage([listingDTO()]));
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
        : libraryPage([listingDTO()]);
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
  response.resolve(libraryPage([listingDTO()]));
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
  response.resolve(libraryPage([listingDTO()]));
  await assert.rejects(
    pending,
    (error) => error instanceof Error && error.name === "AbortError",
  );
  services.dispose();
});

test("private media is bound to org and listing and rejects unsafe or expired URLs", () => {
  const issuedAt = Math.floor(Date.now() / 1000) * 1000;
  const validUrl = new URL(
    `https://${
      "a".repeat(32)
    }.r2.cloudflarestorage.com/rendprop-uploads/uploads/${ORG}/${LISTING}/photo.jpg`,
  );
  validUrl.search = new URLSearchParams({
    "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
    "X-Amz-Credential": "OFFLINE_FIXTURE/20260912/auto/s3/aws4_request",
    "X-Amz-Date": new Date(issuedAt).toISOString().replace(/[-:]/g, "").replace(
      ".000",
      "",
    ),
    "X-Amz-Expires": "600",
    "X-Amz-SignedHeaders": "host",
    "X-Amz-Signature": "a".repeat(64),
  }).toString();
  const dto = {
    org_id: ORG,
    listing_id: LISTING,
    photos: [
      {
        id: PHOTO,
        listing_id: LISTING,
        url: validUrl.href,
        expires_at: new Date(issuedAt + 600_000).toISOString(),
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
  for (
    const url of [
      "javascript:alert(1)",
      "http://example.com/file",
      "https://example.com/?access_token=secret",
      validUrl.href.replace(validUrl.hostname, "media.example.invalid"),
      validUrl.href.replace(ORG, OTHER_ORG),
      validUrl.href.replace(LISTING, OTHER_LISTING),
      validUrl.href.replace("/photo.jpg", "/%2fphoto.jpg"),
      `${validUrl.href}&X-Amz-Expires=600`,
      `${validUrl.href}&x-amz-expires=600`,
      validUrl.href.replace("X-Amz-Expires=600", "X-Amz-Expires=604800"),
      validUrl.href.replace("AWS4-HMAC-SHA256", "OTHER"),
      validUrl.href.replace(/X-Amz-Signature=[^&]+/, "X-Amz-Signature=invalid"),
      validUrl.href.replace(/X-Amz-Date=[^&]+/, "X-Amz-Date=20260230T120000Z"),
    ]
  ) {
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
  const staleUrl = new URL(validUrl);
  staleUrl.searchParams.set(
    "X-Amz-Date",
    new Date(issuedAt - 700_000).toISOString().replace(/[-:]/g, "").replace(
      ".000",
      "",
    ),
  );
  assert.throws(
    () =>
      decodeMedia(
        { ...dto, photos: [{ ...dto.photos[0], url: staleUrl.href }] },
        ORG,
        LISTING,
      ),
    code("media-expired"),
  );
  assert.throws(
    () =>
      decodeMedia(
        {
          ...dto,
          photos: [{ ...dto.photos[0], expires_at: "2099-01-01T00:00:00Z" }],
        },
        ORG,
        LISTING,
      ),
    code("invalid-response"),
  );
  assert.throws(
    () => decodeMedia(dto, ORG, LISTING, 1),
    code("invalid-response"),
  );
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
  const clock = manualClock(), started = deferred<void>();
  let cancelled = false;
  const services = createStudioServices(config, {
    auth: mockAuth().auth, clock, authTimeoutMs: 20, readTimeoutMs: 30,
    fetch: fakeFetch((url) => {
      if (!url.pathname.endsWith("/listings")) return fixtureResponse(url);
      return new Response(new ReadableStream({
        pull() { started.resolve(); },
        cancel() { cancelled = true; },
      }), { headers: { "Content-Range": "0-0/1" } });
    }),
  });
  await services.loadWorkspace();
  const pending = services.listListings(ORG);
  await started.promise;
  clock.advance(30);
  await assert.rejects(pending, code("timeout"));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(cancelled, true);
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

test("degraded entitlements remain explicit and never turn the stored paid plan into authority", () => {
  const degraded = decodeWorkspace({ ...meDTO(), plan: "trial", plan_raw: "team", entitlement: { degraded: true } }, USER, joined);
  assert.equal(degraded.planDegraded, true);
  assert.equal(degraded.plan, "trial");
  assert.equal(degraded.planRaw, "team");
  assert.equal(decodeWorkspace(meDTO(), USER, joined).planDegraded, false);
  assert.throws(() => decodeWorkspace({ ...meDTO(), entitlement: { degraded: "false" } }, USER, joined), code("invalid-response"));
});

function pageJson(rows: unknown[], offset: number, total: number): Response {
  return new Response(JSON.stringify(rows), { headers: {
    "Content-Type": "application/json",
    "Content-Range": rows.length ? `${offset}-${offset + rows.length - 1}/${total}` : `*/${total}`,
  } });
}
const numberedUuid = (number: number) => `90000000-0000-4000-8000-${String(number).padStart(12, "0")}`;

test("actor-bound pagination includes every authorized library row", async()=>{
 const rows=Array.from({length:1205},(_,i)=>listingDTO(ORG,numberedUuid(i))),seen:number[]=[];
 const services=createStudioServices(config,{auth:mockAuth().auth,fetch:fakeFetch((url,options)=>{
  if(!url.pathname.endsWith("/listings"))return fixtureResponse(url);
  assert.equal(url.pathname,"/functions/v1/listings");assert.equal(url.searchParams.get("library"),"1");assert.equal(url.searchParams.get("limit"),"500");assert.equal(new Headers(options.headers).get("X-Org-Id"),ORG);assert.equal(url.searchParams.has("org_id"),false);
  const offset=Number(url.searchParams.get("offset"));seen.push(offset);return libraryPage(rows.slice(offset,offset+500),USER,rows.length,offset+500<rows.length?offset+500:null);
 })});await services.loadWorkspace();assert.deepEqual((await services.listListings(ORG)).map(r=>r.id),rows.map(r=>r.id));assert.deepEqual(seen,[0,500,1000]);services.dispose();
});
test("directory refuses malformed identity, access and active-library bindings before selection",async()=>{
 for(const kind of ["actor","duplicate","own","active","delegation"]){const response=directoryDTO(USER,ORG,true);
  if(kind==="actor")response.actor_id=OTHER_USER;if(kind==="duplicate")response.workspaces[1].id=ORG;if(kind==="own")response.workspaces[0].library_owner_user_id=OTHER_USER;if(kind==="active")response.active_org_id=FOREIGN_ORG;if(kind==="delegation")response.can_switch_agent_libraries=false;
  let calls=0;const services=createStudioServices(config,{auth:mockAuth().auth,fetch:fakeFetch(url=>{if(url.pathname.endsWith("/workspaces"))return json(response);calls++;return fixtureResponse(url);})});await assert.rejects(services.loadWorkspace());assert.equal(calls,0);services.dispose();
 }
});
test("listing pagination refuses missing totals, shifted pages, changed totals and foreign libraries",async()=>{
 for(const mode of ["missing","shifted","changed","joined-foreign","duplicate"] as const){const services=createStudioServices(config,{auth:mockAuth().auth,fetch:fakeFetch(url=>{
  if(!url.pathname.endsWith("/listings"))return fixtureResponse(url);const offset=Number(url.searchParams.get("offset"));
  if(mode==="missing")return Response.json({actor_id:USER,listings:[listingDTO()]});if(mode==="shifted")return libraryPage([listingDTO()],USER,1,500);if(mode==="joined-foreign")return libraryPage([listingDTO(OTHER_ORG)]);
  return libraryPage(Array.from({length:500},(_,i)=>listingDTO(ORG,numberedUuid(mode==="duplicate"?i:i+offset))),USER,offset&&mode==="changed"?1001:1000,offset?null:500);
 })});await services.loadWorkspace();await assert.rejects(services.listListings(ORG),code(mode==="joined-foreign"?"identity-mismatch":mode==="duplicate"?"invalid-response":"incomplete-response"));services.dispose();}
});

for (const nextIdentity of [OTHER_USER, USER]) {
  for (const finish of ["resolve", "reject", "timeout"] as const) {
    test(`an old account refresh ${finish} cannot poison ${nextIdentity === USER ? "A to B to A" : "A to B"} requests`, async () => {
      const mocked = mockAuth(), clock = manualClock();
      const started = deferred<void>(), currentStarted = deferred<void>();
      const oldRefresh = deferred<{ data: { session: Session }; error: null }>();
      const currentRefresh = deferred<{ data: { session: Session }; error: null }>();
      let refreshCalls = 0;
      mocked.auth.refreshSession = () => {
        refreshCalls++;
        if (refreshCalls === 1) { started.resolve(); return oldRefresh.promise; }
        currentStarted.resolve(); return currentRefresh.promise;
      };
      const services = createStudioServices(config, {
        auth: mocked.auth, clock, readTimeoutMs: 100, authTimeoutMs: 20,
        fetch: fakeFetch((url, options) => {
          const bearer = new Headers(options.headers).get("Authorization");
          const actor = bearer === "Bearer offline-token" ? USER : nextIdentity;
          if (url.pathname === "/functions/v1/me/workspaces") return json(directoryDTO(actor));
          if (url.pathname === "/functions/v1/me") return json(meDTO(ORG, actor));
          return bearer === "Bearer current-fresh" ? libraryPage([listingDTO()],actor) : json({}, 401);
        }),
      });
      await services.loadWorkspace();
      const oldRequest = assert.rejects(services.listListings(ORG), code("stale-identity"));
      await started.promise;
      mocked.emit("SIGNED_IN", sessionFor(OTHER_USER, "current-old"));
      if (nextIdentity === USER) mocked.emit("SIGNED_IN", sessionFor(USER, "current-old"));
      await services.loadWorkspace();
      const currentRequests = Promise.all([services.listListings(ORG), services.listListings(ORG)]);
      await new Promise((resolve) => setImmediate(resolve));
      if (finish === "resolve") oldRefresh.resolve({ data: { session: sessionFor(USER, "old-refreshed") }, error: null });
      else if (finish === "reject") oldRefresh.reject(new Error("Old identity refresh failed"));
      else clock.advance(20);
      await currentStarted.promise;
      currentRefresh.resolve({ data: { session: sessionFor(nextIdentity, "current-fresh") }, error: null });
      assert.equal((await currentRequests).length, 2);
      await oldRequest;
      assert.equal(refreshCalls, 2);
      assert.equal(services.getSnapshot().identity?.userId, nextIdentity);
      if (finish === "timeout") oldRefresh.reject(new Error("Late old SDK failure"));
      await new Promise((resolve) => setImmediate(resolve));
      assert.equal(clock.pending(), 0);
      services.dispose();
    });
  }
}

test("metadata bytes are bounded with absent, dishonest and oversized Content-Length", async () => {
  for (const declared of [undefined, "1", String(MAX_METADATA_BYTES + 1)]) {
    let cancelled = false;
    let reads = 0;
    const services = createStudioServices(config, {
      auth: mockAuth().auth,
      fetch: fakeFetch((url) => {
        if (!url.pathname.endsWith("/listings")) return fixtureResponse(url);
        return new Response(new ReadableStream({
          pull(controller) { reads++; controller.enqueue(new Uint8Array(MAX_METADATA_BYTES + 1)); },
          cancel() { cancelled = true; },
        }, { highWaterMark: 0 }), { headers: {
          ...(declared ? { "Content-Length": declared } : {}),
          "Content-Range": "0-0/1",
        } });
      }),
    });
    await services.loadWorkspace();
    await assert.rejects(services.listListings(ORG), code("response-too-large"));
    assert.equal(cancelled, true);
    assert.equal(reads, declared === String(MAX_METADATA_BYTES + 1) ? 0 : 1);
    services.dispose();
  }
});

test("metadata decoding rejects oversized fields instead of truncating saved business data", () => {
  assert.throws(() => decodeListings([{ ...listingDTO(), details: { text: "x".repeat(65_537) } }], ORG, joined), code("invalid-response"));
  assert.throws(() => decodeListings([{ ...listingDTO(), address: "x".repeat(16_385) }], ORG, joined), code("invalid-response"));
});

test("mutations keep workspace scope and never replay an ambiguous or unauthorized POST", async () => {
  for (const status of [401, 503]) {
    const auth = mockAuth(); let writes=0;
    const services=createStudioServices(config,{auth:auth.auth,fetch:fakeFetch((url,options)=>{
      if(options.method==='POST') {writes++;assert.equal(new Headers(options.headers).get('X-Org-Id'),ORG);assert.equal(new Headers(options.headers).get('Idempotency-Key'),'one-action');return json({},status);}
      return fixtureResponse(url);
    })});
    await services.loadWorkspace();
    await assert.rejects(services.api('/functions/v1/renders',{orgId:ORG,method:'POST',body:{listing_id:LISTING},idempotencyKey:'one-action'}));
    assert.equal(writes,1);assert.equal(auth.refreshCalls(),0);services.dispose();
  }
});
test("trial capacity refusals give retry guidance without blaming the customer's plan", async () => {
  for (const machineCode of ["trial_capacity_unavailable", "quota_exceeded", undefined]) {
    const auth = mockAuth(); let writes = 0;
    const services = createStudioServices(config, { auth: auth.auth, fetch: fakeFetch((url, options) => {
      if (options.method === "POST") { writes++; return json({ code: machineCode, error: "https://private.invalid/?token=do-not-show" }, 402); }
      return fixtureResponse(url);
    }) });
    try {
      await services.loadWorkspace();
      await assert.rejects(services.api("/functions/v1/ai-photo", { orgId: ORG, method: "POST", body: { listing_id: LISTING } }), (error) => {
        assert(error instanceof StudioError);
        assert.equal(error.status, 402);
        assert.doesNotMatch(error.message, /private|token=/);
        if (machineCode === "trial_capacity_unavailable") {
          assert.equal(error.code, machineCode);
          assert.match(error.message, /try again later/i);
          assert.doesNotMatch(error.message, /upgrade|plan|allowance/i);
        } else {
          assert.equal(error.code, "request-failed");
          assert.match(error.message, /current plan/);
        }
        return true;
      });
      assert.equal(writes, 1);
    } finally { services.dispose(); }
  }
});
test("mutation identity change aborts and rejects late completion",async()=>{
  const auth=mockAuth(), response=deferred<Response>(),started=deferred<void>();
  const services=createStudioServices(config,{auth:auth.auth,fetch:fakeFetch((url,options)=>{
    if(options.method==='PATCH'){started.resolve();return response.promise;}return fixtureResponse(url);
  })});
  await services.loadWorkspace();const write=services.api('/functions/v1/listings/'+LISTING,{orgId:ORG,method:'PATCH',body:{address:'Changed'}});
  await started.promise;auth.emit('SIGNED_IN',sessionFor(OTHER_USER));response.resolve(json({id:LISTING}));
  await assert.rejects(write,code('stale-identity'));services.dispose();
});
test("API rejects foreign origins, traversals, missing membership and read bodies before dispatch",async()=>{
  let calls=0;const auth=mockAuth();const services=createStudioServices(config,{auth:auth.auth,fetch:fakeFetch(url=>{calls++;return fixtureResponse(url);})});
  await services.loadWorkspace();const start=calls;
  for(const path of ['https://foreign.invalid/functions/v1/me','//foreign.invalid/','/functions/v1/me/../uploads','/functions/v1/me%2fsecret'])await assert.rejects(services.api(path,{orgId:ORG}));
  await assert.rejects(services.api('/functions/v1/me',{orgId:FOREIGN_ORG}));
  await assert.rejects(services.api('/functions/v1/me',{orgId:ORG,body:{}}));assert.equal(calls,start);services.dispose();
});
test("upload sends only media content to exact capability gateway and fences session changes",async()=>{
  const auth=mockAuth();let puts=0;
  const services=createStudioServices(config,{auth:auth.auth,fetch:fakeFetch((url,options)=>{
    if(options.method==='PUT'){puts++;const h=new Headers(options.headers);assert.equal(h.get('Authorization'),null);assert.equal(h.get('apikey'),null);assert.equal(options.credentials,'omit');assert.equal(options.redirect,'error');return new Response(null,{headers:{ETag:'confirmed'}});}return fixtureResponse(url);
  })});
  await services.loadWorkspace();const path='/v2/'+LISTING+'?expires=1999999999&signature='+'a'.repeat(64);
  await assert.rejects(services.upload('https://other.invalid'+path,new Blob(['photo']),{orgId:ORG}));
  assert.deepEqual(await services.upload('https://uploads.rendprop.com'+path,new Blob(['photo']),{orgId:ORG}),{etag:'confirmed'});assert.equal(puts,1);services.dispose();
});

test("private project binary gateway is bounded, scoped and never automatically replays PUT",async()=>{
  const auth=mockAuth();let puts=0;const file=new Blob(["test"]);
  const services=createStudioServices(config,{auth:auth.auth,fetch:fakeFetch((url,options)=>{
    if(options.method==="PUT"){puts++;assert.equal(new Headers(options.headers).get("Content-Type"),"application/octet-stream");assert.equal(new Headers(options.headers).get("X-Org-Id"),ORG);assert.equal(options.body,file);assert.equal(options.redirect,"error");return json({},401);}return fixtureResponse(url);
  })});
  await services.loadWorkspace();const path="/functions/v1/studio/project-media/"+LISTING+"/0";
  for(const bad of [{method:"POST",binary:file},{method:"GET",binary:file},{method:"PUT",binary:new Blob([])},{method:"PUT",binary:new Blob([new Uint8Array(8388609)])},{method:"PUT",binary:file,body:{}}])await assert.rejects(services.api(path,{orgId:ORG,...bad} as any));
  await assert.rejects(services.api(path.replace("/project-media/","/documents/"),{orgId:ORG,method:"PUT",binary:file}));assert.equal(puts,0);
  await assert.rejects(services.api(path,{orgId:ORG,method:"PUT",binary:file}));assert.equal(puts,1);assert.equal(auth.refreshCalls(),0);services.dispose();
});

test("individual owner role does not grant agent switching, while explicit owner capability does",()=>{
  const own=decodeWorkspaceDirectory(directoryDTO(),USER);
  assert.equal(own.canSwitchAgentLibraries,false);assert.equal(own.workspaces.length,1);
  const delegated=directoryDTO(USER,OTHER_ORG,true);const checked=decodeWorkspaceDirectory(delegated,USER);
  assert.equal(checked.workspaces[1].accessMode,"team_owner");assert.equal(checked.workspaces[1].canManageSubscription,false);
  for(const bad of [{...delegated,can_switch_agent_libraries:false},{...delegated,actor_id:OTHER_USER},
    {...delegated,workspaces:[delegated.workspaces[0],{...delegated.workspaces[1],can_manage_subscription:true}]}])assert.throws(()=>decodeWorkspaceDirectory(bad,USER));
});
test("a forbidden explicit library preference never falls back or calls me",async()=>{
  let meReads=0;const services=createStudioServices(config,{auth:mockAuth().auth,fetch:fakeFetch(url=>{
    if(url.pathname.endsWith("/workspaces"))return json(directoryDTO());meReads++;return fixtureResponse(url);
  })});await assert.rejects(services.loadWorkspace(undefined,OTHER_ORG),code("membership-required"));assert.equal(meReads,0);
  const own=await services.loadWorkspace();assert.equal(own.org.id,ORG);assert.equal(own.canSwitchAgentLibraries,false);services.dispose();
});
test("legacy own-agent rows retain true org for media, grouping stays private and refresh revokes routing hints",async()=>{
  const seen:Array<{path:string;org:string|null}>=[];
  const legacy={...listingDTO(OTHER_ORG),library_org_id:ORG};
  const services=createStudioServices(config,{auth:mockAuth().auth,fetch:fakeFetch((url,options)=>{
    seen.push({path:url.pathname,org:new Headers(options.headers).get("X-Org-Id")});
    if(url.pathname.endsWith("/listings"))return libraryPage([legacy]);
    if(url.pathname.endsWith("/studio/media"))return json({org_id:OTHER_ORG,listing_id:LISTING,photos:[],videos:[],next_offset:null,unavailable_count:0});
    return fixtureResponse(url);
  })});
  const workspace=await services.loadWorkspace(),rows=await services.listListings(ORG);
  assert.equal(rows[0].orgId,OTHER_ORG);assert.equal(rows[0].libraryOrgId,ORG);assert.deepEqual(workspace.memberships.map(m=>m.orgId),[ORG]);
  const scoped=scopedListingWorkspace(workspace,rows[0]);assert.equal(scoped.org.id,OTHER_ORG);assert.equal(scoped.libraryOrgId,ORG);assert.equal(workspace.org.id,ORG);
  assert.equal(canEditListing(scoped,rows[0]),true);assert.equal(canEditListing({...scoped,memberships:scoped.memberships.map(m=>({...m,canWrite:false}))},rows[0]),false);
  await services.listMedia(rows[0].orgId,rows[0].id);assert.equal(seen.at(-1)?.org,OTHER_ORG);
  await services.loadWorkspace();const calls=seen.length;
  await assert.rejects(services.listMedia(OTHER_ORG,LISTING),code("membership-required"));assert.equal(seen.length,calls);services.dispose();
});
test("purchase root, viewed library and serving grant decode independently without alias authority",()=>{
  const directory=directoryDTO(USER,OTHER_ORG,true);directory.workspaces[1].billing_org_id=FOREIGN_ORG;
  const checked=decodeWorkspaceDirectory(directory,USER);
  const response={...meDTO(OTHER_ORG),billing:{...meDTO(OTHER_ORG).billing,serving_org_id:FOREIGN_ORG},serving_activation:{org_id:FOREIGN_ORG,available:true,funded:false,authority:"private_sponsorship"}};
  const result=decodeWorkspace(response,USER,checked.workspaces,OTHER_ORG,checked);
  assert.equal(result.org.id,OTHER_ORG);assert.equal(result.billingOrgId,ORG);assert.equal(result.servingOrgId,FOREIGN_ORG);
  for(const field of ["org_id","content_org_id","serving_org_id"]){assert.throws(()=>decodeWorkspace({...response,billing:{...response.billing,[field]:LISTING}},USER,checked.workspaces,OTHER_ORG,checked));}
  assert.throws(()=>scopedListingWorkspace(result,{...decodeListings([listingDTO()],ORG,joined)[0],libraryOrgId:ORG}));
});

test("all listing pages share one total deadline rather than resetting per page",async()=>{
  const clock=manualClock(),started=deferred<AbortSignal>(),late=deferred<Response>();
  const first=Array.from({length:500},(_,i)=>listingDTO(ORG,`66666666-6666-4666-8666-${String(i+1).padStart(12,"0")}`));
  const services=createStudioServices(config,{auth:mockAuth().auth,clock,readTimeoutMs:30,authTimeoutMs:20,fetch:fakeFetch((url,options)=>{
    if(!url.pathname.endsWith("/listings"))return fixtureResponse(url);
    if(url.searchParams.get("offset")==="0"){clock.advance(20);return libraryPage(first,USER,501,500);}
    started.resolve(options.signal!);return late.promise;
  })});
  await services.loadWorkspace();const pending=services.listListings(ORG);const signal=await started.promise;
  clock.advance(10);await assert.rejects(pending,code("timeout"));assert.equal(signal.aborted,true);
  late.reject(new Error("late synthetic page"));await new Promise(resolve=>setImmediate(resolve));assert.equal(clock.pending(),0);services.dispose();
});
