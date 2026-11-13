// asset-range.ts — byte ranges for self-hosted video and audio assets.
//
// iOS WebKit and AVFoundation require HTTP byte-range support for media: they
// open a video with `Range: bytes=0-1` and seek with further ranges. The
// static-assets binding answers those requests with the whole file and a 200,
// so the hosted sample tour (/assets/demo-tour.mp4, the scrub source of
// /f/estate-demo?embed=1 that the app's Home "See it in action" embeds) could
// not start on an iPhone. This wraps the binding's answer for video/audio only:
// a single satisfiable range becomes a 206 with Content-Range, an unsatisfiable
// one a 416, and every media answer advertises Accept-Ranges. Anything else,
// including multi-range and malformed headers, keeps the binding's response.

const SINGLE_RANGE = /^bytes=(\d*)-(\d*)$/;
const MEDIA_TYPE = /^(video|audio)\//i;

export function isMediaAsset(res: Response): boolean {
  return MEDIA_TYPE.test(res.headers.get("Content-Type") ?? "");
}

/** Parses one `bytes=` range against `size`. null = ignore the header (serve 200). */
export function parseRange(header: string | null, size: number): { start: number; end: number } | "unsatisfiable" | null {
  if (!header) return null;
  const match = SINGLE_RANGE.exec(header.trim());
  if (!match) return null;
  const [, first, last] = match;
  if (first === "" && last === "") return null;
  if (size <= 0) return "unsatisfiable";
  if (first === "") {
    const suffix = Number(last);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return "unsatisfiable";
    return { start: Math.max(0, size - suffix), end: size - 1 };
  }
  const start = Number(first);
  const end = last === "" ? size - 1 : Math.min(Number(last), size - 1);
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= size || start > end) return "unsatisfiable";
  return { start, end };
}

export async function withAssetRange(req: Request, res: Response): Promise<Response> {
  if (res.status !== 200 || !isMediaAsset(res)) return res;
  if (req.method !== "GET" && req.method !== "HEAD") return res;
  const headers = new Headers(res.headers);
  headers.set("Accept-Ranges", "bytes");
  const rangeHeader = req.headers.get("Range");
  if (req.method === "HEAD" || !rangeHeader) {
    return new Response(req.method === "HEAD" ? null : res.body, { status: 200, statusText: res.statusText, headers });
  }
  const body = await res.arrayBuffer();
  const range = parseRange(rangeHeader, body.byteLength);
  if (range === null) {
    headers.set("Content-Length", String(body.byteLength));
    return new Response(body, { status: 200, statusText: res.statusText, headers });
  }
  if (range === "unsatisfiable") {
    headers.delete("Content-Length");
    headers.set("Content-Range", `bytes */${body.byteLength}`);
    return new Response(null, { status: 416, headers });
  }
  headers.set("Content-Range", `bytes ${range.start}-${range.end}/${body.byteLength}`);
  headers.set("Content-Length", String(range.end - range.start + 1));
  return new Response(body.slice(range.start, range.end + 1), { status: 206, headers });
}
