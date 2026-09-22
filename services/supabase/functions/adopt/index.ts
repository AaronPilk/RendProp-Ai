// Transfer an anonymous workspace without deleting either account/workspace.
// Expiry is NOT evidence of adoption: replay the transaction's exact bound
// receipt before asking for the old credential after a lost response.
import { handleOptions } from "../_shared/cors.ts";
import {
  assert,
  HttpError,
  json,
  readJsonLimited,
  respondError,
  throwRpc,
} from "../_shared/http.ts";
import { adminClient, getBearer } from "../_shared/supabase.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function uuid(value: unknown): value is string {
  return typeof value === "string" && UUID.test(value);
}

/** Only explicit credential rejection is absence. Outages stay recoverable. */
async function userForToken(
  token: string,
): Promise<{ id: string; is_anonymous: boolean } | null> {
  const base = Deno.env.get("SUPABASE_URL"),
    anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!base || !anon) {
    throw new HttpError(503, "Account verification is unavailable", "upstream");
  }
  let response: Response;
  try {
    response = await fetch(`${base}/auth/v1/user`, {
      headers: { Authorization: `Bearer ${token}`, apikey: anon },
      signal: AbortSignal.timeout(10000),
    });
  } catch {
    throw new HttpError(
      503,
      "Account verification is temporarily unavailable",
      "upstream",
    );
  }
  if (response.status === 401 || response.status === 403) return null;
  if (!response.ok) {
    throw new HttpError(
      503,
      "Account verification is temporarily unavailable",
      "upstream",
    );
  }
  let user;
  try {
    user = await response.json();
  } catch {
    throw new HttpError(
      502,
      "Account verification returned an invalid response",
      "upstream",
    );
  }
  if (!user || !uuid(user.id) || typeof user.is_anonymous !== "boolean") {
    throw new HttpError(
      502,
      "Account verification returned an invalid response",
      "upstream",
    );
  }
  return user;
}

function confirmed(
  value: unknown,
  source: string,
  destination: string,
  operation: string,
) {
  const row = value as Record<string, unknown> | null;
  if (
    !row || row.ok !== true || row.adopted !== true ||
    row.source_user_id !== source ||
    row.destination_user_id !== destination || row.operation_id !== operation ||
    !uuid(row.org_id)
  ) {
    throw new HttpError(
      502,
      "Workspace transfer was not confirmed; please retry",
      "upstream",
    );
  }
  return row;
}

// Preserve old builds' valid-token adoption, but never call expiry a success.
// Only the new client persists source refresh/replay credentials across restart.
async function legacyOperation(
  source: string,
  destination: string,
): Promise<string> {
  const bytes = new Uint8Array(
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(`rendprop-adoption-v1:${source}:${destination}`),
    ),
  );
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  const hex = Array.from(
    bytes.slice(0, 16),
    (v) => v.toString(16).padStart(2, "0"),
  ).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${
    hex.slice(16, 20)
  }-${hex.slice(20)}`;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return handleOptions();
  try {
    assert(req.method === "POST", 405, "Use POST /adopt");
    const bearer = getBearer(req);
    assert(bearer, 401, "Missing Authorization bearer token");
    const destination = await userForToken(bearer);
    assert(destination, 401, "Invalid or expired destination session");
    assert(
      destination.is_anonymous === false,
      403,
      "Sign in with Apple before adopting a workspace",
    );
    const body = await readJsonLimited<Record<string, unknown>>(req, 16384);
    assert(
      body && typeof body === "object" && !Array.isArray(body),
      400,
      "Invalid handoff",
    );
    const token = typeof body.anonymous_token === "string"
      ? body.anonymous_token.trim()
      : "";
    assert(
      token.length > 20 && token.length < 4096,
      400,
      "anonymous_token is required",
    );
    const legacy = body.operation_id === undefined &&
      body.source_user_id === undefined &&
      body.destination_user_id === undefined;
    let source = body.source_user_id, operation = body.operation_id;
    let verifiedSource: Awaited<ReturnType<typeof userForToken>> | undefined;
    if (legacy) {
      verifiedSource = await userForToken(token);
      if (verifiedSource) {
        source = verifiedSource.id;
        operation = await legacyOperation(source as string, destination.id);
      }
    } else {
      assert(
        uuid(source) && uuid(operation) && uuid(body.destination_user_id),
        400,
        "A complete handoff binding is required",
      );
      assert(
        body.destination_user_id === destination.id,
        403,
        "This handoff belongs to another account",
      );
    }
    if (!uuid(source) || !uuid(operation)) {
      throw new HttpError(
        409,
        "The original session needs recovery",
        "conflict",
        { adoption_state: "source_session_expired" },
      );
    }
    assert(
      source !== destination.id,
      409,
      "Source and destination must differ",
    );
    const admin = adminClient();
    const receipt = await admin.rpc("adoption_receipt", {
      p_user: destination.id,
      p_anon_user: source,
      p_operation: operation,
    });
    if (receipt.error) {
      if (receipt.error.message?.includes("RP4")) {
        throwRpc(receipt.error.message);
      }
      throw new HttpError(
        503,
        "Workspace recovery is temporarily unavailable",
        "upstream",
      );
    }
    if (receipt.data !== null) {
      return json(confirmed(receipt.data, source, destination.id, operation));
    }
    const anonymous = verifiedSource === undefined
      ? await userForToken(token)
      : verifiedSource;
    if (!anonymous) {
      throw new HttpError(
        409,
        "The original session needs recovery",
        "conflict",
        { adoption_state: "source_session_expired" },
      );
    }
    assert(
      anonymous.id === source,
      403,
      "The source session does not match this handoff",
    );
    assert(
      anonymous.is_anonymous === true,
      403,
      "Only an anonymous workspace can be adopted",
    );
    const { data: rows, error } = await admin.from("memberships").select(
      "org_id, role",
    ).eq("user_id", source);
    if (error) {
      throw new HttpError(
        503,
        "Workspace recovery is temporarily unavailable",
        "upstream",
      );
    }
    assert(
      rows?.length === 1 && uuid(rows[0].org_id),
      409,
      "The original workspace needs support; nothing was discarded",
    );
    assert(
      rows[0].role === "owner",
      403,
      "The original session must own its workspace",
    );
    const result = await admin.rpc("adopt_anonymous_org", {
      p_user: destination.id,
      p_anon_user: source,
      p_anon_org: rows[0].org_id,
      p_operation: operation,
    });
    if (result.error) throwRpc(result.error.message);
    return json(confirmed(result.data, source, destination.id, operation));
  } catch (error) {
    return respondError(error);
  }
});
