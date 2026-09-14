// Browser owner media bridge. Same Supabase identity, membership and RLS as iOS;
// no storage key, role, org membership or publication state is accepted from the client.
import { createStudioHandler } from "./handler.ts";
import { createStudioRepository } from "./repository.ts";
import {
  adminClient,
  assertNotDeleting,
  getUser,
  orgForUser,
  userClient,
} from "../_shared/supabase.ts";
import { assert, HttpError, json, pathSegments } from "../_shared/http.ts";
import { presignGet } from "../_shared/providers/common.ts";
import { R2_BUCKET_RENDERS, R2_BUCKET_UPLOADS } from "../_shared/r2.ts";

import { handleOptions } from "../_shared/cors.ts";
import { handleDocuments } from "./documents.ts";
import { handleListingState } from "./listing-state.ts";
import { handleListingActions } from "./listing-actions.ts";
import { handleCreative } from "./creative.ts";
import type { StudioContext } from "./context.ts";

// Keep request-local RLS client ownership explicit: no global current-user client.
export async function handleStudio(req: Request): Promise<Response> {
  const seg = pathSegments(req, "studio");
  if (req.method === "OPTIONS") return handleOptions();
  if (seg.length === 1 && seg[0] === "media") return await createStudioHandler({
    ...createStudioRepository(req, {
      getUser,
      assertNotDeleting,
      orgForUser,
      userClient,
    }),
    async rateLimit(scope) {
      const { data, error } = await adminClient().rpc("bump_rate", {
        p_key: `studio-read:${scope.userId}`,
        p_window_seconds: 60,
        p_max: 60,
        p_cost: 1,
      });
      if (error) {
        throw new HttpError(503, "Library refresh is temporarily unavailable.");
      }
      return data === true;
    },
    sign: (bucket, key, seconds) =>
      presignGet(
        bucket === "uploads" ? R2_BUCKET_UPLOADS : R2_BUCKET_RENDERS,
        key,
        seconds,
      ),
    now: () => Date.now(),
  })(req);
  try {
    const user = await getUser(req);
    assert(!user.is_anonymous, 403, "Connect your Apple account to sync your work.");
    await assertNotDeleting(user.id);
    const url = new URL(req.url);
    const selector = req.headers.get("x-org-id") ?? url.searchParams.get("org_id") ?? "";
    assert(/^[0-9a-f-]{36}$/i.test(selector), 400, "Choose a workspace.");
    assert(!url.searchParams.has("org_id") || url.searchParams.get("org_id") === selector, 400, "Workspace selectors disagree.");
    const org = await orgForUser(user.id, selector);
    assert(org === selector, 403, "Workspace authorization failed.");
    const db = userClient(req), admin = adminClient();
    const active = await db.from("orgs").select("id").eq("id", org).is("deleted_at", null).maybeSingle();
    assert(!active.error && active.data, 403, "This workspace is unavailable.");
    const repository = createStudioRepository(req, { getUser, assertNotDeleting, orgForUser, userClient });
    const context: StudioContext = { userId: user.id, orgId: org, db, admin,
      async authorizeListing(id) {
        assert(/^[0-9a-f-]{36}$/i.test(id), 400, "Choose a valid listing.");
        await repository.authorize(req, org, id);
      },
    };
    const rate = await admin.rpc("bump_rate", { p_key: `studio-work:${user.id}`, p_window_seconds: 60, p_max: 120, p_cost: 1 });
    assert(!rate.error, 503, "Workspace actions are temporarily unavailable.");
    assert(rate.data === true, 429, "Please wait a moment before refreshing again.");
    if (seg.length === 1 && seg[0] === "documents") return await handleDocuments(req, context);
    if (seg.length === 1 && seg[0] === "listing-state") return await handleListingState(req, context);
    const action = await handleListingActions(req, context);
    if (action) return action;
    const creative = await handleCreative(req, context);
    if (creative) return creative;
    throw new HttpError(404, "Studio action not found.");
  } catch (error) {
    const known = error instanceof HttpError;
    return json({ error: known && error.status < 500 ? error.message : "Studio could not complete this action. Please retry.", code: known ? error.code : "upstream" },
      known ? error.status : 503, { "Cache-Control": "private, no-store" });
  }
}
Deno.serve(handleStudio);
