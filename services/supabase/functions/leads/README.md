# leads — public lead capture + the agent's inbox

Captures a lead from the tour end-card (public, no JWT) and lets the owning
org read/manage its own leads (JWT + RLS).

| Route | Auth | Answers |
|---|---|---|
| `POST /leads` | **public** | `{slug, name?, phone?, email?, extra?, _hp?, turnstile_token?}` → `201 {ok, id}` · `403` bot check failed · `429` rate limited |
| `GET /leads?listing_id=&since=&status=&limit=` | owner (JWT) | `{leads: [...]}`, RLS-scoped to the caller's org |
| `PATCH /leads/:id {status}` | owner (JWT) | `{ok, lead}` — `status` one of `new\|contacted\|won\|lost` |

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
promises) and `docs/LAUNCH-CHECKLIST.md` item 12.

Set the secret with the rest of the function secrets:

```bash
cd services/supabase && supabase secrets set TURNSTILE_SECRET_KEY=<your secret key>
```

The end-card's Turnstile **site key** (public, not a secret) goes wherever the
tour player widget is configured — see the tour-host worker / player config,
not this function.

## Other secrets

| Env var | Required? | Effect |
|---|---|---|
| `GHL_API_KEY`, `GHL_LOCATION_ID` | no | When both are set, a captured lead is upserted to GoHighLevel (tagged `rendprop_slug:<slug>` and, when known, `rendprop_org:<id>` / `rendprop_listing:<id>`). Never blocks lead capture — a GHL failure is logged and `synced_crm` stays `false`. |

## Deploy

Deployed `--no-verify-jwt` (the public `POST` has no user token; `GET`/`PATCH`
validate the JWT themselves via `getUser(req)`):

```bash
cd services/supabase && ./deploy-functions.sh
```
