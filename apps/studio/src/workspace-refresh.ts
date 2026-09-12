import { StudioError } from "./data/config";

/** Keep a verified workspace through a transport outage, never an access failure.
 * Clearing it for every refresh remounts the editor under the local scope and
 * loses its in-memory files. Unknown/malformed responses still fail closed.
 */
export function canRetainWorkspace(error: unknown): boolean {
  return error instanceof StudioError && (
    error.code === "network" || error.code === "timeout" ||
    (error.code === "request-failed" && error.status !== undefined &&
      (error.status === 429 || (error.status >= 500 && error.status <= 599)))
  );
}
