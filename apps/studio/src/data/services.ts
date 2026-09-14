import {
  createClient,
  type AuthChangeEvent,
  type Session,
} from "@supabase/supabase-js";
import { StudioError, validateStudioConfig, type StudioConfig } from "./config";
import {
  decodeListings,
  decodeMedia,
  decodeMemberships,
  decodeWorkspace,
  mediaOffset,
  uuid,
  type Membership,
} from "./contracts";

// Metadata has a separate, measured budget from the editor's media downloads.
export const MAX_METADATA_BYTES = 2 * 1024 * 1024;
const READ_PAGE_SIZE = 100;
const MAX_READ_ROWS = 10_000;
const LISTING_COLUMNS = "id,org_id,space_type,address,tagline,details,status,created_at,deleted_at,main_photo_key,beds,baths,sqft,price_cents";

type ReadPage = { offset: number; limit: number };
type PageResult = { rows: unknown[]; total: number };

async function boundedJson(response: Response, signal: AbortSignal): Promise<unknown> {
  const tooLarge = () => new StudioError("response-too-large", "This workspace response is too large to load safely. Contact support.");
  const declared = response.headers.get("content-length");
  if (declared && /^\d+$/.test(declared) && Number(declared) > MAX_METADATA_BYTES) {
    void response.body?.cancel().catch(() => {});
    throw tooLarge();
  }
  if (!response.body) throw new StudioError("invalid-response", "The server returned an empty response. Please retry.");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  const cancel = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener("abort", cancel, { once: true });
  try {
    signal.throwIfAborted();
    for (;;) {
      const { done, value } = await reader.read();
      signal.throwIfAborted();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_METADATA_BYTES) throw tooLarge();
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } finally {
    signal.removeEventListener("abort", cancel);
    // A misbehaving stream must not extend the enclosing total request deadline.
    void reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

function decodePage(rows: unknown, response: Response, page: ReadPage): PageResult {
  const fail = () => { throw new StudioError("incomplete-response", "The workspace response was incomplete. Refresh to load all of your data."); };
  const range = response.headers.get("content-range") ?? "";
  const match = /^(?:(\d+)-(\d+)|\*)\/(\d+)$/.exec(range);
  if (!Array.isArray(rows) || !match) return fail();
  const total = Number(match[3]);
  if (!Number.isSafeInteger(total) || total > MAX_READ_ROWS) return fail();
  if (!rows.length) {
    if (total !== page.offset || (match[1] !== undefined && total !== 0)) return fail();
  } else if (rows.length > page.limit || Number(match[1]) !== page.offset ||
    Number(match[2]) !== page.offset + rows.length - 1 || page.offset + rows.length > total) return fail();
  return { rows, total };
}

export type SessionIdentity = Readonly<{
  userId: string;
  email: string | null;
  isAnonymous: boolean;
}>;
export type SessionSnapshot = Readonly<{
  status: "loading" | "signed-out" | "signed-in" | "error";
  identity: SessionIdentity | null;
  identityVersion: number;
  error: string | null;
}>;
type AuthResult = { data: { session: Session | null }; error: unknown };
/** Small seam for deterministic transport race tests; production uses the official SDK. */
export interface StudioAuth {
  getSession(): Promise<AuthResult>;
  refreshSession(): Promise<AuthResult>;
  signInWithOAuth(input: {
    provider: "apple";
    options: { redirectTo: string };
  }): Promise<{ error: unknown }>;
  signOut(input: { scope: "local" }): Promise<{ error: unknown }>;
  onAuthStateChange(
    callback: (event: AuthChangeEvent, session: Session | null) => void,
  ): { data: { subscription: { unsubscribe(): void } } };
}
export type DeadlineClock = {
  schedule(milliseconds: number, callback: () => void): () => void;
};
export type StudioDependencies = {
  auth?: StudioAuth;
  fetch?: typeof fetch;
  storage?: Storage;
  clock?: DeadlineClock;
  readTimeoutMs?: number;
  authTimeoutMs?: number;
};

export function createStudioServices(
  rawConfig: StudioConfig,
  dependencies: StudioDependencies = {},
) {
  const config = validateStudioConfig(rawConfig);
  const fetcher = dependencies.fetch ?? globalThis.fetch.bind(globalThis);
  const clock: DeadlineClock = dependencies.clock ?? {
    schedule(milliseconds, callback) {
      const timer = globalThis.setTimeout(callback, milliseconds);
      return () => globalThis.clearTimeout(timer);
    },
  };
  const readTimeoutMs = dependencies.readTimeoutMs ?? 30_000;
  const authTimeoutMs = dependencies.authTimeoutMs ?? 20_000;
  if (
    ![readTimeoutMs, authTimeoutMs].every(
      (value) => Number.isSafeInteger(value) && value > 0 && value <= 300_000,
    )
  ) {
    throw new StudioError(
      "configuration",
      "Connection timeouts must be positive whole milliseconds, up to five minutes.",
    );
  }
  function deadline<T>(
    start: () => Promise<T>,
    milliseconds: number,
    message: string,
    onTimeout?: () => void,
  ): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      let settled = false;
      const cancel = clock.schedule(milliseconds, () => {
        if (settled) return;
        settled = true;
        onTimeout?.();
        reject(new StudioError("timeout", message));
      });
      // Attach both handlers even after a timeout: a late SDK/fetch rejection
      // must never become an unhandled rejection or resume a completed read.
      Promise.resolve()
        .then(start)
        .then(
          (value) => {
            if (!settled) {
              settled = true;
              cancel();
              resolve(value);
            }
          },
          (error) => {
            if (!settled) {
              settled = true;
              cancel();
              reject(error);
            }
          },
        );
    });
  }
  let storage: Storage | undefined = dependencies.storage;
  if (!dependencies.auth && !storage) {
    try {
      storage = window.localStorage;
    } catch {
      throw new StudioError(
        "storage-unavailable",
        "Allow browser storage to keep your Rendprop account connected.",
      );
    }
  }
  const storageKey = `rendprop-studio-auth:${new URL(config.supabaseUrl).host}`;
  const auth: StudioAuth =
    dependencies.auth ??
    createClient(config.supabaseUrl, config.publishableKey, {
      auth: {
        flowType: "pkce",
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
        storage,
        storageKey,
      },
    }).auth;
  let session: Session | null = null;
  let snapshot: SessionSnapshot = Object.freeze({
    status: "loading",
    identity: null,
    identityVersion: 0,
    error: null,
  });
  const listeners = new Set<(snapshot: SessionSnapshot) => void>();
  const activeRequests = new Set<AbortController>();
  let memberships: Membership[] = [];
  let authRevision = 0;
  let disposed = false;
  let signingOut = false;
  let refreshFlight: { version: number; promise: Promise<void> } | null = null;

  function publish(next: Session | null, error: string | null = null) {
    if (disposed) return;
    const identity: SessionIdentity | null = next
      ? Object.freeze({
          userId: uuid(next.user.id, "session user id"),
          email: next.user.email ?? null,
          isAnonymous: next.user.is_anonymous === true,
        })
      : null;
    const changed =
      identity?.userId !== snapshot.identity?.userId ||
      identity?.isAnonymous !== snapshot.identity?.isAnonymous;
    session = next;
    if (changed) {
      memberships = [];
      // Even A → B → A must reject an operation created in the first A session.
      for (const request of activeRequests) request.abort();
    }
    snapshot = Object.freeze({
      status: error ? "error" : next ? "signed-in" : "signed-out",
      identity,
      identityVersion: snapshot.identityVersion + (changed ? 1 : 0),
      error,
    });
    // Auth callbacks stay synchronous and never call back into Supabase Auth.
    for (const listener of listeners) listener(snapshot);
  }

  const subscription = auth.onAuthStateChange((_event, next) => {
    authRevision += 1;
    if (!signingOut || !next) publish(next);
  }).data.subscription;
  const initialRevision = authRevision;
  const initialization = deadline(
    () => auth.getSession(),
    authTimeoutMs,
    "Restoring your account timed out. Check your connection and sign in again.",
  )
    .then(({ data, error }) => {
      if (authRevision !== initialRevision || disposed || signingOut) return;
      if (error)
        publish(
          null,
          "Your saved session could not be restored. Sign in again.",
        );
      else publish(data.session);
    })
    .catch((error) => {
      if (authRevision === initialRevision && !disposed && !signingOut)
        publish(
          null,
          error instanceof StudioError
            ? error.message
            : "Your saved session could not be restored. Sign in again.",
        );
    });

  function assertCurrent(version: number, signal?: AbortSignal) {
    if (disposed || snapshot.identityVersion !== version || signingOut)
      throw new StudioError(
        "stale-identity",
        "The account changed while this request was running.",
      );
    signal?.throwIfAborted();
  }
  async function identity(signal?: AbortSignal) {
    const invokedVersion =
      snapshot.status === "loading" ? null : snapshot.identityVersion;
    await initialization;
    if (invokedVersion !== null) assertCurrent(invokedVersion, signal);
    signal?.throwIfAborted();
    if (disposed || signingOut || !session || !snapshot.identity)
      throw new StudioError(
        "sign-in-required",
        "Sign in with Apple to open your existing Rendprop workspace.",
      );
    if (snapshot.identity.isAnonymous)
      throw new StudioError(
        "identified-account-required",
        "Use the Apple account connected to Rendprop on your iPhone to open its workspace here.",
      );
    return {
      version: snapshot.identityVersion,
      userId: snapshot.identity.userId,
    };
  }
  async function refresh(version: number, rejectedToken: string) {
    assertCurrent(version);
    if (session?.access_token !== rejectedToken) return;
    // The SDK serializes refresh internally. Settle an older identity's SDK work,
    // then reread this identity's session; never inherit its failure or token.
    while (refreshFlight && refreshFlight.version !== version) {
      await refreshFlight.promise.catch(() => {});
      assertCurrent(version);
      const readRevision = authRevision;
      const { data, error } = await deadline(
        () => auth.getSession(), authTimeoutMs,
        "Restoring your current session timed out. Check your connection and retry.",
      );
      assertCurrent(version);
      if (error || !data.session || data.session.user.id.toLowerCase() !== snapshot.identity?.userId)
        throw new StudioError("session-expired", "Your current session could not be restored. Sign in again.");
      if (authRevision === readRevision) publish(data.session);
      if (session?.access_token !== rejectedToken) return;
    }
    if (!refreshFlight) {
      const startRevision = authRevision;
      const flight = { version, promise: Promise.resolve() };
      flight.promise = (async () => {
        const { data, error } = await deadline(
          () => auth.refreshSession(), authTimeoutMs,
          "Refreshing your session timed out. Check your connection and retry.",
        );
        assertCurrent(version);
        if (error || !data.session)
          throw new StudioError("session-expired", "Your session expired. Sign in again.");
        if (data.session.user.id.toLowerCase() !== snapshot.identity?.userId)
          throw new StudioError("session-expired", "Your current session could not be refreshed. Sign in again.");
        if (authRevision === startRevision) publish(data.session);
      })().finally(() => {
        if (refreshFlight === flight) refreshFlight = null;
      });
      refreshFlight = flight;
    }
    await refreshFlight.promise;
    assertCurrent(version);
  }

  async function request(
    path: string,
    version: number,
    signal?: AbortSignal,
    orgId?: string,
    page?: ReadPage,
  ): Promise<unknown> {
    assertCurrent(version, signal);
    const controller = new AbortController();
    const abort = () => controller.abort(signal?.reason);
    signal?.addEventListener("abort", abort, { once: true });
    activeRequests.add(controller);
    try {
      return await deadline(
        async () => {
          for (let attempt = 0; attempt < 2; attempt++) {
            assertCurrent(version, controller.signal);
            const token = session?.access_token;
            if (!token)
              throw new StudioError(
                "sign-in-required",
                "Sign in to load your workspace.",
              );
            const headers: Record<string, string> = {
              Accept: "application/json",
              apikey: config.publishableKey,
              Authorization: `Bearer ${token}`,
            };
            if (orgId) headers["X-Org-Id"] = orgId;
            if (page) headers.Prefer = "count=exact";
            const response = await fetcher(`${config.supabaseUrl}${path}`, {
              method: "GET",
              headers,
              signal: controller.signal,
              cache: "no-store",
              credentials: "omit",
              redirect: "error",
            });
            assertCurrent(version, controller.signal);
            if (response.status === 401 && attempt === 0) {
              void response.body?.cancel().catch(() => {});
              await refresh(version, token);
              continue;
            }
            if (!response.ok) {
              const message =
                response.status === 401
                  ? "Your session expired. Sign in again."
                  : response.status === 403
                    ? "You no longer have access to this workspace. Reload your workspaces."
                    : response.status === 404
                      ? "This listing or media is unavailable."
                      : "Rendprop could not load your data. Please retry.";
              throw new StudioError("request-failed", message, response.status);
            }
            let result: unknown;
            try {
              result = await boundedJson(response, controller.signal);
            } catch (error) {
              if (error instanceof StudioError) throw error;
              throw new StudioError(
                "invalid-response",
                "The server returned an unreadable response. Please retry.",
              );
            }
            assertCurrent(version, controller.signal);
            return page ? decodePage(result, response, page) : result;
          }
          throw new StudioError(
            "session-expired",
            "Your session expired. Sign in again.",
          );
        },
        readTimeoutMs,
        "Loading your Rendprop data timed out. Check your connection and retry.",
        () => controller.abort(),
      );
    } catch (error) {
      assertCurrent(version, signal);
      if (error instanceof StudioError) throw error;
      throw new StudioError(
        "network",
        "Could not reach Rendprop. Check your connection and retry.",
      );
    } finally {
      signal?.removeEventListener("abort", abort);
      activeRequests.delete(controller);
    }
  }

  async function readPages(
    path: string, query: URLSearchParams, version: number,
    signal?: AbortSignal, orgId?: string,
  ): Promise<unknown[]> {
    const controller = new AbortController();
    const abort = () => controller.abort(signal?.reason);
    signal?.addEventListener("abort", abort, { once: true });
    try {
      assertCurrent(version, signal);
      return await deadline(async () => {
        const all: unknown[] = [];
        let total: number | undefined;
        let metadataBytes = 0;
        do {
          query.set("limit", String(READ_PAGE_SIZE));
          query.set("offset", String(all.length));
          const page = await request(`${path}?${query}`, version, controller.signal, orgId,
            { offset: all.length, limit: READ_PAGE_SIZE }) as PageResult;
          assertCurrent(version, controller.signal);
          if (total !== undefined && total !== page.total)
            throw new StudioError("incomplete-response", "Your workspace changed while loading. Refresh to get its latest contents.");
          total = page.total;
          metadataBytes += new TextEncoder().encode(JSON.stringify(page.rows)).byteLength;
          if (metadataBytes > MAX_METADATA_BYTES * 4)
            throw new StudioError("response-too-large", "This workspace has too much metadata to load at once. Contact support.");
          all.push(...page.rows);
        } while (all.length < total);
        return all;
      }, readTimeoutMs, "Loading all of your workspace data timed out. Check your connection and retry.", () => controller.abort());
    } finally {
      signal?.removeEventListener("abort", abort);
    }
  }

  return {
    async ready(): Promise<SessionSnapshot> {
      await initialization;
      return snapshot;
    },
    getSnapshot: (): SessionSnapshot => snapshot,
    subscribe(listener: (snapshot: SessionSnapshot) => void) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    async signIn(): Promise<void> {
      await initialization;
      if (disposed)
        throw new StudioError(
          "disposed",
          "Reload Studio to connect your account.",
        );
      signingOut = false;
      const { error } = await deadline(
        () =>
          auth.signInWithOAuth({
            provider: "apple",
            options: { redirectTo: config.redirectTo },
          }),
        authTimeoutMs,
        "Apple sign-in timed out. Check your connection and try again.",
      ).catch((error) => {
        if (error instanceof StudioError) throw error;
        return { error: true };
      });
      if (error)
        throw new StudioError(
          "sign-in-failed",
          "Apple sign-in could not start. Check your connection and try again.",
        );
    },
    async signOut(): Promise<void> {
      signingOut = true;
      authRevision += 1;
      publish(null);
      // Local scope preserves the iPhone session; global is the SDK default.
      const { error } = await deadline(
        () => auth.signOut({ scope: "local" }),
        authTimeoutMs,
        "Signing out timed out.",
      ).catch(() => ({ error: true }));
      if (error) {
        // Keep this browser fenced even if server revocation was unreachable.
        try {
          storage?.removeItem(storageKey);
          storage?.removeItem(`${storageKey}-code-verifier`);
        } catch {
          /* UI remains signed out. */
        }
        throw new StudioError(
          "sign-out-failed",
          "This browser is disconnected, but session revocation could not be confirmed. Retry sign out when online.",
        );
      }
      signingOut = false;
    },
    async loadWorkspace(signal?: AbortSignal, preferredOrgId?: string) {
      const actor = await identity(signal);
      const selected = preferredOrgId
        ? uuid(preferredOrgId, "selected organization")
        : undefined;
      const query = new URLSearchParams({
        select: "user_id,org_id,role,orgs!inner(id,name,space_type,deleted_at)",
        user_id: `eq.${actor.userId}`,
        "orgs.deleted_at": "is.null",
        order: "org_id.asc",
      });
      const rows = await readPages(
        "/rest/v1/memberships", query, actor.version, signal,
      );
      const found = decodeMemberships(rows, actor.userId);
      if (!found.length)
        throw new StudioError(
          "membership-required",
          "No existing workspace was found for this Apple account. Connect the same Apple account in Rendprop on your iPhone.",
        );
      if (selected && !found.some((m) => m.orgId === selected))
        throw new StudioError(
          "membership-required",
          "You no longer belong to the selected workspace.",
        );
      const me = await request(
        "/functions/v1/me",
        actor.version,
        signal,
        selected,
      );
      const workspace = decodeWorkspace(me, actor.userId, found, selected);
      assertCurrent(actor.version, signal);
      memberships = found;
      return workspace;
    },
    async listListings(orgId: string, signal?: AbortSignal) {
      const actor = await identity(signal);
      const selected = uuid(orgId, "selected organization");
      const allowed = [...memberships];
      if (!allowed.some((m) => m.orgId === selected))
        throw new StudioError(
          "membership-required",
          "Load this workspace before opening its listings.",
        );
      const query = new URLSearchParams({
        select: LISTING_COLUMNS,
        org_id: `eq.${selected}`,
        deleted_at: "is.null",
        order: "created_at.desc,id.desc",
      });
      // The existing native /listings endpoint caps all joined orgs before filtering.
      // Query the selected org through the existing user-token RLS policy instead.
      const rows = await readPages("/rest/v1/listings", query, actor.version, signal, selected);
      return decodeListings(rows, selected, allowed.filter((membership) => membership.orgId === selected));
    },
    async listMedia(
      orgId: string,
      listingId: string,
      signal?: AbortSignal,
      offset = 0,
    ) {
      const actor = await identity(signal);
      const selected = uuid(orgId, "selected organization");
      const listing = uuid(listingId, "selected listing");
      if (!memberships.some((m) => m.orgId === selected))
        throw new StudioError(
          "membership-required",
          "Load this workspace before opening its media.",
        );
      const page = mediaOffset(offset);
      const query = new URLSearchParams({
        org_id: selected,
        listing_id: listing,
        offset: String(page),
      });
      const result = await request(
        `/functions/v1/studio/media?${query}`,
        actor.version,
        signal,
        selected,
      );
      return decodeMedia(result, selected, listing, page);
    },
    dispose() {
      disposed = true;
      subscription.unsubscribe();
      for (const controller of activeRequests) controller.abort();
      activeRequests.clear();
      listeners.clear();
      memberships = [];
      session = null;
    },
  };
}
export type StudioServices = ReturnType<typeof createStudioServices>;
