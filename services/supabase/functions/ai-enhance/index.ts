// The former worker enhancement queue has no consumer or durable paid admission.
// Keep this authenticated endpoint closed until a reviewed execution flow exists.
import { handleOptions } from "../_shared/cors.ts";
import { HttpError, respondError } from "../_shared/http.ts";
import { getUser } from "../_shared/supabase.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return handleOptions();
  try {
    if (req.method !== "POST") {
      throw new HttpError(405, "Only POST is supported");
    }
    await getUser(req);
    throw new HttpError(
      503,
      "Worker AI enhancements are unavailable. Use the photo and video tools instead.",
      "upstream",
    );
  } catch (err) {
    return respondError(err);
  }
});
