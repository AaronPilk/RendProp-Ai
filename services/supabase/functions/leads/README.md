# leads — public lead capture + the agent's inbox

Captures a lead from the tour end-card (public, no JWT) and lets the owning
org read/manage its own leads (JWT + RLS).

| Route | Auth | Answers |
|---|---|---|
| `POST /leads` | **public** | `{slug, name?, phone?, email?, extra?, _hp?, turnstile_token?}` → `201 {ok: true}` · `403` bot check failed · `429` rate limited |
| `GET /leads?listing_id=&since=&status=&limit=` | active selected-workspace member (JWT) | `{leads: [...]}`, RLS-scoped to the caller's workspace |
| `PATCH /leads/:id {status}` | workspace owner/admin/agent (JWT) | `{ok, lead}` — `status` one of `new\|contacted\|won\|lost` |
| `POST /leads/:id/send-to-client` | workspace owner/admin/agent + saved recipient verification | `{request_id: UUID, expected_recipient_email}` → `{ok, delivery}`; destination comes from the saved listing client. |

| `DELETE /leads/:id` | named selected-workspace owner/admin/agent | `{ok, lead_id, deleted, cleanup_pending}`; removes pending buyer snapshots and journals legacy CRM cleanup when needed. |
| `POST /leads/client-recipient-verification` | named selected-workspace owner/admin/agent | `{listing_id}` → `{ok, state: "queued" | "verified"}`; no typed destination override. |
| `POST /leads/verify-client-recipient` | public possession of confirmation nonce | `{token: 64 lowercase hex characters}` → `{ok: true}`; generic invalid/expired response, no buyer data. |

Per-listing client routing retains inquiries in the photographer's account and
queues an external email through the existing service-only notification sender only after the saved recipient confirms their email. Saving a contact or publishing the listing does not require that confirmation; inquiries remain in the account inbox while forwarding is inactive.
`GET /leads` includes private `client_delivery` status and the current recipient
for explicit resend confirmation. Provider acceptance is labelled **Email sent**;
it does not certify inbox delivery. See
[photographer client delivery](../../../../docs/studio/photographer-client-delivery.md)
for revision, privacy, retry and recipient-change behavior. The historical production baseline was **leads v36 / notify v11**; the October 5 verification, deletion and notification privacy changes are source fixes awaiting coordinated deployment.
[The release handoff](../../../../docs/handoff/PHOTOGRAPHER-CLIENT-DELIVERY-20261001.md)
records source/readback verification; actual client inbox placement remains a
controlled owner acceptance check.

---

## Bot protection (Cloudflare Turnstile)

`POST /leads` is public and unauthenticated, so it needs its own defense
against bots: a honeypot field (`_hp` — a real user never fills it), a durable
per-IP rate limit (`durableRateLimit`, 20/min), and Cloudflare Turnstile.

**Turnstile FAILS CLOSED.** If `TURNSTILE_SECRET_KEY` is not set, the
submission is **rejected** (`403`) — not silently accepted. This was an
audit finding: the earlier behavior treated a missing secret as "not
configured yet, don't block," which meant the public lead form had *no* bot
protection at all until someone remembered to set the secret, with nothing in
the logs to say so.

| Env var | Required? | Effect |
|---|---|---|
| `TURNSTILE_SECRET_KEY` | **yes**, unless `TURNSTILE_OPTIONAL=1` | Cloudflare Turnstile secret key. When set, every `POST /leads` must carry a valid `turnstile_token` (from the widget's site key on the tour end-card) or it is rejected. |
| `TURNSTILE_OPTIONAL` | no | Set to the literal string `"1"` to **knowingly** accept running with no bot protection when `TURNSTILE_SECRET_KEY` is unset — a local dev box with no Cloudflare account, or a production deploy that has deliberately chosen to launch without Turnstile. Any other value (`"true"`, `"yes"`, unset) does **not** opt out. |

Whichever path is taken when the secret is missing — rejected, or allowed via
the opt-out — a single line is logged every time, naming
`TURNSTILE_SECRET_KEY`:

```
leads: TURNSTILE_SECRET_KEY is not set — REJECTING public lead submissions. Set TURNSTILE_SECRET_KEY (see services/supabase/DEPLOYMENT.md), or set TURNSTILE_OPTIONAL=1 to accept no bot protection knowingly.
```

or, with the opt-out set:

```
leads: TURNSTILE_SECRET_KEY is not set — ALLOWING public lead submissions with NO bot protection (TURNSTILE_OPTIONAL=1 is set). Set TURNSTILE_SECRET_KEY ...
```

This is logged on **every** unconfigured request, not once at deploy — an
operator who left `TURNSTILE_SECRET_KEY` unset cannot miss it in the function
logs. See `turnstile.ts` (and `turnstile.test.ts` for the behavior this table
promises) and [launch checklist](../../../../docs/LAUNCH-CHECKLIST.md).

Configure the secret through the project's secret manager or a protected local
environment file using the Supabase CLI's `--env-file` option and explicit project
reference. Do not put a real secret in shell history, a README or browser code.

The end-card's Turnstile **site key** is public and belongs in the
[tour-host configuration](../../../edge/tour-host/README.md). It is different
from the server secret. Verify a real permitted lead submission separately from
an unauthenticated GET probe; the 24 September Studio release did not certify
this form.

## Other secrets

| Env var | Required? | Effect |
|---|---|---|
| `GHL_API_KEY`, `GHL_LOCATION_ID` | legacy cleanup only | Public capture never upserts buyer contacts into a global CRM location. These credentials are used only by service-side cleanup of historical contacts, with exact buyer identity and tenant-tag checks. |

## Deploy

Deployed `--no-verify-jwt` (public capture/nonce confirmation have no user token; all workspace routes
validate the JWT themselves via `getUser(req)`):

Use a targeted deployment with `verify_jwt=false` preserved for this function.
See [the functions deployment guide](../README.md); the historical broad deploy
script is not an appropriate way to update one handler and can overwrite
unrelated authentication settings.

## October 5 privacy rollout

Apply the verified-recipient and cleanup inventory migrations before deploying the matching Leads, Notify and Me handlers. Deploy the public confirmation page and fragment script before enabling queued verification email delivery. Verify Vault-backed maintenance scheduling and inspect a read-only cleanup inventory before any production sweep. The technical monthly upload ceiling does not establish a storage retention margin budget. Existing direct public media URLs require a separate revocation rollout.

Confirmation links carry the nonce in a URL fragment. Opening the page does not consume it; the recipient explicitly confirms by POST. The database stores its hash, binds it to the saved listing/contact revision, and expires it after 24 hours. Terminal verification outbox rows scrub the fragment token. Retention removes expired token records after seven days and terminal message snapshots after 30 days without deleting the photographer's lead inbox.

Ordinary account email notifications use the confirmed, named Supabase Auth email. Editable profile/public contact addresses never select their destination. Promotional `first_tour_nudge` and `free_week_ending` emails stay disabled until explicit email opt-in and unsubscribe are supported; transactional notices retain their preferences. Service email uses RendProp LLC's supplied postal address and Reply-To.

The offline `run_verified_recipients.py`, `run_privacy_cleanup_inventory.py` and `run_upload_privacy_admission.py` runners test the final migration chain on owned disposable databases with compiled failing controls. Handler tests prohibit unmodeled network requests. They do not send real customer emails or delete real media.
