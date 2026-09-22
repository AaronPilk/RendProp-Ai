// join.ts — the page an invited agent lands on.
//
// WHY THIS EXISTS. Owner feedback from a real TestFlight session, 13 Sep 2026:
// "A user would find it difficult to go to settings and put in the code.
// People are idiots this ux and process needs to be easier for a user to do."
//
// He is right, and the app said so itself. The old path was: the owner gets a
// code, sends it somehow, and the agent then has to find Settings -> Team ->
// Join a team and hand-type twelve characters. Five steps and a typing test,
// four hundred times over for a brokerage.
//
// The new path is: tap the link in the invite mail. That is it.
//
// ── WHY A WEB PAGE AND NOT ONLY A DEEP LINK ─────────────────────────────────
// Most people receiving this will not have Rendprop installed yet — that is
// what being invited to a team usually means. A bare `rendprop://` link does
// nothing on a phone without the app, and a Universal Link only opens the app
// once iOS has fetched the association file and the app is present. So the
// page is the thing that always works, and it does three jobs in order of how
// likely they are to be needed:
//
//   1. Shows the code, large, with one tap to copy. Even in the worst case —
//      wrong phone, no app, corporate mail client stripping links — the person
//      can read it and carry it across.
//   2. Offers the App Store, carrying the code through so it is still on the
//      clipboard when they come back.
//   3. Tries the app directly for anyone who already has it.
//
// ── THE CODE IS IN THE URL, AND THAT IS FINE ────────────────────────────────
// An invite code is single-use, expires in 14 days, and is useless without the
// e-mail that carried it. It is a capability, not a credential: this is the
// same shape as a password-reset link. What matters is that this page is
// `noindex` and `Cache-Control: no-store`, so the code never enters a search
// index or an intermediary cache. The Worker does NOT validate the code — it
// has no database — which is deliberate: a page that told a stranger whether a
// code was real would be an oracle for guessing them. Validation stays where it
// belongs, in POST /team/accept, under the org lock.

import { escapeAttr, escapeHtml } from "./html";
import { APP_STORE_URL } from "./attribution";

/** A join code is 12 chars in XXXX-XXXX-XXXX form; dashes optional in a URL. */
const CODE_RE = /^[A-Z0-9]{4}-?[A-Z0-9]{4}-?[A-Z0-9]{4}$/i;

export function normalizeJoinCode(raw: string | null | undefined): string | null {
  const s = decodeURIComponent(String(raw ?? "")).trim().toUpperCase();
  if (!CODE_RE.test(s)) return null;
  const bare = s.replace(/-/g, "");
  return `${bare.slice(0, 4)}-${bare.slice(4, 8)}-${bare.slice(8, 12)}`;
}

export function joinPage(code: string | null): string {
  const valid = code !== null;
  const shown = valid ? code : "";
  // ct= is the same campaign-token scheme every other store link uses, so an
  // install that started from an invite is distinguishable in App Analytics
  // from one that started from a tour.
  const store = `${APP_STORE_URL}?ct=invite`;
  const deep = valid ? `rendprop://join/${encodeURIComponent(shown.replace(/-/g, ""))}` : "";

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex, nofollow">
<title>${valid ? "Join your team on Rendprop" : "That invite link is incomplete"}</title>
<style>
  :root{
    --bg:#F7F6F3; --card:#FFF; --ink:#14181C; --dim:#5A656E; --rule:#E3E0D9; --accent:#6D3BEB;
  }
  @media (prefers-color-scheme: dark){
    :root{ --bg:#0D1113; --card:#161C1F; --ink:#ECEAE5; --dim:#A3ADB3; --rule:#283034; --accent:#9B7BFF; }
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);
       font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;
       -webkit-font-smoothing:antialiased}
  .wrap{min-height:100svh;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:28px 20px}
  .box{width:100%;max-width:400px;text-align:center}
  .mark{font-size:11px;letter-spacing:.34em;text-transform:uppercase;color:var(--dim);margin-bottom:26px}
  h1{font-size:25px;font-weight:680;letter-spacing:-.015em;margin:0 0 10px;text-wrap:balance}
  .lede{color:var(--dim);font-size:15.5px;margin:0 0 26px}
  .code{background:var(--card);border:1px solid var(--rule);border-radius:14px;padding:20px 16px;margin-bottom:12px}
  .code .label{font-size:11px;letter-spacing:.16em;text-transform:uppercase;color:var(--dim);margin-bottom:9px}
  .code .val{font:650 27px/1.15 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
             letter-spacing:.06em;word-break:break-all}
  button,.btn{display:block;width:100%;padding:15px 18px;border-radius:13px;font-size:16px;font-weight:650;
        text-decoration:none;border:1px solid transparent;cursor:pointer;margin-bottom:10px;
        font-family:inherit;-webkit-appearance:none}
  .primary{background:var(--accent);color:#fff}
  .secondary{background:var(--card);color:var(--ink);border-color:var(--rule)}
  .note{font-size:13.5px;color:var(--dim);margin-top:18px;line-height:1.5}
  .steps{text-align:left;background:var(--card);border:1px solid var(--rule);border-radius:13px;
         padding:16px 18px;margin-top:20px;font-size:14.5px;color:var(--dim)}
  .steps b{color:var(--ink);font-weight:620}
  .steps ol{margin:8px 0 0;padding-left:20px}
  .steps li{margin-bottom:5px}
  #copied{display:none;color:var(--accent);font-weight:640;font-size:14px;margin-bottom:10px}
</style>
</head>
<body>
<div class="wrap"><div class="box">
  <div class="mark">RENDPROP</div>
${
    valid
      ? `  <h1>You've been added to a team</h1>
  <p class="lede">One tap and you're in. Nothing to type.</p>
  <div class="code">
    <div class="label">Your join code</div>
    <div class="val" id="code">${escapeHtml(shown)}</div>
  </div>
  <div id="copied">Copied</div>
  <button class="primary" id="open">Open in Rendprop</button>
  <a class="btn secondary" href="${escapeAttr(store)}">Get the app</a>
  <button class="secondary" id="copy">Copy code</button>
  <div class="steps">
    <b>If the app doesn't open</b>
    <ol>
      <li>Tap <b>Get the app</b> and install Rendprop.</li>
      <li>Come back here and tap <b>Open in Rendprop</b>.</li>
      <li>Or paste the code in Settings &rarr; Team &rarr; Join a team.</li>
    </ol>
  </div>
  <p class="note">This code works once and expires 14 days after it was sent.</p>`
      : `  <h1>That invite link is incomplete</h1>
  <p class="lede">The link may have been cut short by the app you opened it in. Ask whoever invited you to send it again, or paste the code straight into Rendprop.</p>
  <a class="btn secondary" href="https://rendprop.com">Go to Rendprop</a>`
  }
</div></div>
${
    valid
      ? `<script>
(function(){
  var code = ${JSON.stringify(shown)};
  var copied = document.getElementById("copied");
  function flash(){ copied.style.display = "block"; setTimeout(function(){ copied.style.display = "none"; }, 2200); }
  function copy(){
    // Clipboard API needs a secure context and can be refused; the textarea
    // fallback is what actually works in an in-app browser, which is where
    // most of these links get opened.
    if (navigator.clipboard && window.isSecureContext) {
      navigator.clipboard.writeText(code).then(flash, fallback);
    } else { fallback(); }
    function fallback(){
      try {
        var t = document.createElement("textarea");
        t.value = code; t.setAttribute("readonly","");
        t.style.position = "fixed"; t.style.opacity = "0";
        document.body.appendChild(t); t.select();
        document.execCommand("copy"); document.body.removeChild(t); flash();
      } catch (e) { /* the code is on screen either way */ }
    }
  }
  document.getElementById("copy").addEventListener("click", copy);
  document.getElementById("open").addEventListener("click", function(){
    // Copy FIRST. If the app is not installed the deep link does nothing
    // visible, and the one thing that must survive that dead end is the code
    // being on the clipboard for when they come back from the App Store.
    copy();
    window.location.href = ${JSON.stringify(deep)};
  });
})();
</script>`
      : ""
  }
</body>
</html>`;
}
