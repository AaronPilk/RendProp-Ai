import type { Env } from "./types";
import { escapeHtml } from "./html";

const TOKEN = /^[a-f0-9]{64}$/i;
const MAX_BODY = 4096;

function page(message: string, status = 200, showForm = false): Response {
  return new Response(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>Confirm listing email · Rendprop</title><style>body{margin:0;background:#f5f4f8;color:#201b32;font:17px/1.6 system-ui,sans-serif}main{max-width:440px;margin:12vh auto;padding:32px;background:white;border-radius:24px}h1{font-size:26px;line-height:1.25}button{width:100%;padding:16px;border:0;border-radius:14px;background:#7538ee;color:white;font:600 17px system-ui;cursor:pointer}button:disabled{opacity:.5;cursor:default}p{color:#5d586c}a{color:#6530ce}@media(max-width:500px){main{margin:10vh 20px;padding:24px}}</style>${showForm ? '<script src="/recipient-confirmation.js" defer></script>' : ''}</head><body><main><strong>RENDPROP</strong><h1>Confirm your listing email</h1><p id="message">${escapeHtml(message)}</p>${showForm ? '<form method="post" action="/verify-client-email"><input type="hidden" id="token" name="token"><button id="confirm" disabled>Confirm email</button></form>' : '<a href="https://studio.rendprop.com/">Open Rendprop Studio</a>'}</main></body></html>`, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer", "X-Robots-Tag": "noindex, nofollow, noarchive",
      "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
    },
  });
}

/** Email scanners can open the page safely. Only the recipient's button press
 * exchanges the fragment token, which never travels in the URL or referrer. */
export async function handleRecipientConfirmation(req: Request, env: Env): Promise<Response> {
  if (req.method === "GET" || req.method === "HEAD") {
    const response = page("Confirm this address to receive inquiries for the listing. This does not subscribe you to marketing.", 200, true);
    return req.method === "HEAD" ? new Response(null, response) : response;
  }
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405, headers: { Allow: "GET, HEAD, POST" } });
  const origin = new URL(req.url).origin;
  if (req.headers.get("origin") !== origin || !/^application\/x-www-form-urlencoded(?:;|$)/i.test(req.headers.get("content-type") ?? "")) {
    return page("Open the confirmation link from your email and press Confirm email.", 400);
  }
  const statedSize = Number(req.headers.get("content-length") ?? 0);
  if (!Number.isFinite(statedSize) || statedSize < 0 || statedSize > MAX_BODY) return page("The confirmation request is too large.", 413);
  const reader = req.body?.getReader();
  if (!reader) return page("The confirmation link is invalid or expired.", 400);
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > MAX_BODY) { await reader.cancel(); return page("The confirmation request is too large.", 413); }
      chunks.push(value);
    }
  } catch { return page("The confirmation request could not be read. Please try again.", 400); }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  const fields = new URLSearchParams(new TextDecoder().decode(bytes));
  const token = fields.get("token");
  if (!token || fields.getAll("token").length !== 1 || !TOKEN.test(token)) return page("The confirmation link is invalid or expired.", 400);
  try {
    const response = await fetch(`${env.SUPABASE_FUNCTIONS_URL.replace(/\/+$/, "")}/leads/verify-client-recipient`, {
      method: "POST", headers: { "Content-Type": "application/json", apikey: env.SUPABASE_ANON_KEY ?? "" },
      body: JSON.stringify({ token }), signal: AbortSignal.timeout(8000), redirect: "error",
    });
    // Never echo an upstream message, token, recipient, or buyer payload.
    let confirmed = false;
    if (response.status === 200 && response.body) {
      const reader = response.body.getReader();
      let text = "", length = 0;
      const decoder = new TextDecoder();
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        length += chunk.value.byteLength;
        if (length > 1024) { await reader.cancel(); return page("Email confirmation is temporarily unavailable. Please try again.", 503); }
        text += decoder.decode(chunk.value, { stream: true });
      }
      text += decoder.decode();
      try { confirmed = JSON.parse(text)?.ok === true; } catch { /* fail closed */ }
    } else await response.body?.cancel();
    if (confirmed) return page("Email confirmed. New listing inquiries can now be sent to this address.");
    if (response.status === 400) return page("The confirmation link is invalid or expired. Ask the person managing the listing to send a new one.", 400);
    return page("Email confirmation is temporarily unavailable. Please open your email link and try again.", 503);
  } catch { return page("Email confirmation is temporarily unavailable. Please open your email link and try again.", 503); }
}
