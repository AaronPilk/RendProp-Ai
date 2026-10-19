// Throwaway Worker used only by check-runtime-upstream.mjs. It runs inside the
// real Workers runtime and reports whether a subrequest with the given fetch
// options completes, so the incident combination stays provably rejected and
// the shipped combination stays provably accepted. Never deployed.
export default {
  async fetch(request, env) {
    const mode = new URL(request.url).pathname.slice(1);
    const options = mode === "combined"
      ? { cache: "no-store", cf: { cacheTtl: 0, cacheEverything: false } }
      : { cache: "no-store" };
    try {
      const response = await fetch(`${env.UPSTREAM}/tours/probe-${mode}`, { method: "GET", redirect: "manual", ...options });
      await response.text();
      return Response.json({ ok: true, status: response.status });
    } catch (error) {
      return Response.json({ ok: false, error: error instanceof Error ? error.message : String(error) });
    }
  },
};
